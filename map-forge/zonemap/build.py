"""Turn a Source BSP into chunked, Y-up, metre-scale geometry for The Zone."""
import numpy as np, collections, re, math
from . import bsp as B

# 1 Hammer unit == 1 inch. Verified against HL2 player eye height (64u -> 1.63 m)
# and standard door height (84u -> 2.13 m).
UNIT = 0.0254

TOOL_RE = re.compile(r'^(tools/|.*\b(nodraw|skybox|skip|hint|clip|areaportal|'
                     r'trigger|origin|block_?los|invisible|playerclip|npcclip)\b)', re.I)


def tool_material_is_drawn(name, flags):
    """Is this `tools/` face actually meant to be rendered?

    Not every tools/ material is invisible. `tools/toolsblack` is an ordinary
    LightmappedGeneric with a real $basetexture, and Source uses it to seal off
    voids you can see into - the flat black backing behind a vent grate, a
    window, a doorway to nowhere. vbsp sets a non-render surface flag on every
    genuinely invisible tool brush, so a tools/ face that survives compilation
    with flags == 0 was kept on purpose.

    Dropping these left rectangular holes straight through walls: 92 faces on
    ctf_2fort (476 m2, median 0.9 m2 - vent-sized), and 881 across the CS:S
    maps, including 84 on de_inferno and 24 on de_nuke.
    """
    return flags == 0 and str(name).lower().startswith('tools/')


def to_gltf(v, scale=UNIT):
    """Source Z-up (x fwd, y left, z up) -> glTF Y-up. Returns float32."""
    v = np.asarray(v, np.float64)
    out = np.empty_like(v)
    out[..., 0] = v[..., 0]
    out[..., 1] = v[..., 2]
    out[..., 2] = -v[..., 1]
    return (out * scale).astype(np.float32)


def face_uv(bsp, fi, pos_src):
    """UVs in texture space from the face's texinfo vectors."""
    ti = int(bsp.faces[fi]['texinfo'])
    t = bsp.texinfo[ti]
    td = bsp.texdata[t['texdata']]
    w = float(td['view_width']) or 1.0
    h = float(td['view_height']) or 1.0
    tv = t['tex_vecs'].astype(np.float64)
    u = (pos_src @ tv[0, :3] + tv[0, 3]) / w
    v = (pos_src @ tv[1, :3] + tv[1, 3]) / h
    return np.stack([u, v], axis=1).astype(np.float32)


def subdivide_tris(pos, nrm, uv, alpha, target_m2=1.5, max_k=8, scale=UNIT):
    """Barycentrically subdivide a triangle soup until triangles are smallish.

    Needed for WorldVertexTransition ground. de_nuke's blend displacements are
    only power-2 (a 5x5 grid), so a single face can be 65 m across and its
    triangles over 100 m2 - quantising the blend weight per triangle at that
    size would read as huge flat patches instead of a gradient. Subdividing to
    ~1.5 m first turns the same quantisation into a soft mottle.

    pos/nrm/uv/alpha are per-vertex, 3 rows per triangle. Returns the same.
    """
    pos = np.asarray(pos, np.float64).reshape(-1, 3, 3)
    nrm = np.asarray(nrm, np.float64).reshape(-1, 3, 3)
    uv = np.asarray(uv, np.float64).reshape(-1, 3, 2)
    al = np.asarray(alpha, np.float64).reshape(-1, 3)
    a, b, c = pos[:, 0], pos[:, 1], pos[:, 2]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1) * scale * scale
    k = np.clip(np.ceil(np.sqrt(np.maximum(area, 0) / max(target_m2, 1e-6))),
                1, max_k).astype(int)

    # barycentric sub-triangle corner weights, cached per k
    lut = {}

    def bary(kk):
        if kk in lut:
            return lut[kk]
        tri = []
        for i in range(kk):
            for j in range(kk - i):
                # upright
                tri.append(((i, j), (i + 1, j), (i, j + 1)))
                if i + j < kk - 1:      # inverted
                    tri.append(((i + 1, j), (i + 1, j + 1), (i, j + 1)))
        w = np.empty((len(tri), 3, 3))
        for t, corners in enumerate(tri):
            for v, (i, j) in enumerate(corners):
                u_, v_ = i / kk, j / kk
                w[t, v] = (1.0 - u_ - v_, u_, v_)
        lut[kk] = w
        return w

    op, on, ou, oa = [], [], [], []
    for kk in np.unique(k):
        sel = k == kk
        w = bary(int(kk))                       # (T, 3, 3)
        # (F, 1, 1, 3) x (1, T, 3, 3) -> per sub-vertex barycentric mix
        def mix(arr, dim):
            return np.einsum('tvb,fbd->ftvd', w, arr[sel]).reshape(-1, dim)
        op.append(mix(pos, 3)); on.append(mix(nrm, 3))
        ou.append(mix(uv, 2))
        oa.append(np.einsum('tvb,fb->ftv', w, al[sel]).reshape(-1))
    P = np.concatenate(op); N = np.concatenate(on)
    U = np.concatenate(ou); A = np.concatenate(oa)
    ln = np.linalg.norm(N, axis=1, keepdims=True)
    N = N / np.where(ln == 0, 1.0, ln)
    return P, N, U, A


def tri_normals(pos, tris):
    a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
    n = np.cross(b - a, c - a)
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    return n / np.where(ln == 0, 1, ln)


class Chunker:
    """Accumulates triangles keyed by (material, spatial cell)."""

    def __init__(self, cell_m=48.0):
        self.cell = cell_m
        self.data = collections.defaultdict(lambda: {'pos': [], 'nrm': [], 'uv': []})

    def add(self, mat, pos, nrm, uv):
        if len(pos) == 0:
            return
        # Source faces carry the vertices of every T-junction along an edge,
        # so fanning from vertex 0 produces runs of zero-area triangles - 9,339
        # of gm_br_pitfalls' 106,233, and 7 % of every map. They draw nothing
        # and collide with nothing, but they are still vertices and collision
        # triangles, so drop them here where every caller passes through.
        tp = pos.reshape(-1, 3, 3)
        keep = (np.linalg.norm(np.cross(tp[:, 1] - tp[:, 0],
                                        tp[:, 2] - tp[:, 0]), axis=1)
                > 2e-7)
        if not keep.all():
            if not keep.any():
                return
            pos = tp[keep].reshape(-1, 3)
            nrm = nrm.reshape(-1, 3, 3)[keep].reshape(-1, 3)
            uv = uv.reshape(-1, 3, 2)[keep].reshape(-1, 2)
        centre = pos.reshape(-1, 3, 3).mean(axis=1)
        keys = np.floor(centre / self.cell).astype(np.int32)
        # group the triangles of this batch by cell
        order = np.lexsort((keys[:, 2], keys[:, 1], keys[:, 0]))
        keys, = (keys[order],)
        tri_pos = pos.reshape(-1, 3, 3)[order]
        tri_nrm = nrm.reshape(-1, 3, 3)[order]
        tri_uv = uv.reshape(-1, 3, 2)[order]
        bounds = np.flatnonzero(np.any(np.diff(keys, axis=0) != 0, axis=1)) + 1
        for s, e in zip(np.r_[0, bounds], np.r_[bounds, len(keys)]):
            d = self.data[(mat, tuple(int(x) for x in keys[s]))]
            d['pos'].append(tri_pos[s:e].reshape(-1, 3))
            d['nrm'].append(tri_nrm[s:e].reshape(-1, 3))
            d['uv'].append(tri_uv[s:e].reshape(-1, 2))

    def finish(self):
        out = []
        for (mat, cell), d in self.data.items():
            pos = np.concatenate(d['pos'])
            nrm = np.concatenate(d['nrm'])
            uv = np.concatenate(d['uv'])
            idx = np.arange(len(pos), dtype=np.uint32).reshape(-1, 3)
            out.append((mat, cell, pos, nrm, uv, idx))
        return out


INVISIBLE_ENT = (
    'trigger_', 'func_buyzone', 'func_bomb_target', 'func_hostage_rescue',
    'func_areaportal', 'func_occluder', 'func_nav', 'func_clip',
    'func_ladder', 'env_', 'info_', 'point_', 'ambient_', 'light',
    'func_instance', 'func_precipitation', 'func_smokevolume',
    'func_dustmotes', 'func_dustcloud', 'func_fish_pool', 'func_conveyor',
    # --- Team Fortress 2 -------------------------------------------------
    # Mostly invisible gameplay volumes. The one that matters is
    # func_respawnroomvisualizer: in game it is a translucent wall the enemy
    # team sees and your own team walks through, but converted as ordinary
    # geometry it becomes a solid pane sealing every spawn doorway.
    'func_respawnroom', 'func_nobuild', 'func_no_build', 'func_regenerate',
    'func_forcefield', 'func_capturezone', 'func_flagdetectionzone',
    'func_croc', 'func_achievement', 'func_upgradestation',
    'func_suggested_build', 'func_powerupvolume', 'func_tfbot_hint',
    'team_control_point', 'game_', 'tf_',
)



def _vec(txt, default=(0.0, 0.0, 0.0)):
    try:
        v = [float(x) for x in str(txt).split()[:3]]
        return np.array(v if len(v) == 3 else default, np.float64)
    except (ValueError, AttributeError):
        return np.array(default, np.float64)


def _angles_to_forward(pitch, yaw, roll=0.0):
    p, y = math.radians(pitch), math.radians(yaw)
    return np.array([math.cos(p) * math.cos(y), math.cos(p) * math.sin(y),
                     -math.sin(p)], np.float64)


def model_face_centre(bsp, mi):
    m = bsp.models[mi]
    f0, fn = int(m['firstface']), int(m['numfaces'])
    vs = []
    for fi in range(f0, f0 + fn):
        loop = bsp.face_loop(fi)
        if loop:
            vs.append(bsp.verts[loop])
    if not vs:
        return None
    allv = np.concatenate(vs)
    return (allv.min(0) + allv.max(0)) / 2.0


def model_centre(bsp, mi):
    """Centre of a brush model's own geometry, faces or not.

    `model_face_centre` returns None for a model with no drawn faces, which
    made `local` default to False for every nodraw mover - so its stored
    vertices were treated as world-space when they are in fact recentred on
    the entity's origin. In ctf_2fort that put all six spawn-door carrier
    boxes at (0, 0, 0), i.e. the middle of the bridge, and the position
    fallback then dragged three unrelated props 124 units into the air.
    The dmodel bbox is the right stand-in: vbsp computes it from the same
    vertices.
    """
    fc = model_face_centre(bsp, mi)
    if fc is not None:
        return fc
    m = bsp.models[mi]
    return (np.array(m['mins'], np.float64) + np.array(m['maxs'], np.float64)) / 2.0


def brush_entity_transform(bsp, mi, ent, doors='open'):
    """(R, t) taking this brush model's stored vertices to world space.

    vbsp recentres a brush entity's geometry around its `origin` when it has
    one, so the stored vertices are MODEL-LOCAL and the origin is where they
    belong. Entities without an origin brush keep world coordinates. Detect
    which by comparing the geometry's centre to the origin rather than
    assuming - getting it wrong piles every brush entity at the world origin.
    """
    R = np.eye(3)
    O = _vec(ent.get('origin', '0 0 0'))
    fc = model_centre(bsp, mi)
    local = False
    if fc is not None and np.linalg.norm(O) > 1.0:
        local = np.linalg.norm(fc) < 0.5 * np.linalg.norm(O)
    t = O.copy() if local else np.array(bsp.models[mi]['origin'], np.float64)

    cn = ent.get('classname', '')
    if doors == 'open':
        try:
            sf = int(float(ent.get('spawnflags', 0) or 0))
        except ValueError:
            sf = 0
        # A ROTATING door needs its origin brush as the pivot, so it can only
        # be opened when the geometry is model-local. A SLIDING door does not:
        # it is a pure translation along movedir and works either way. Gating
        # both on `local` meant sliding doors never opened - and most
        # func_door entities have no origin brush at all, which is why TF2's
        # spawn garage doors stayed shut and sealed the spawn room.
        if cn == 'func_door_rotating' and local:
            try:
                deg = float(ent.get('distance', 90) or 90)
            except ValueError:
                deg = 90.0
            if sf & 1:            # already starts open
                deg = 0.0
            if sf & 2:            # reverse dir
                deg = -deg
            axis = 2              # yaw by default
            if sf & 64:
                axis = 2
            elif sf & 128:
                axis = 0
            a = math.radians(deg)
            c, sn = math.cos(a), math.sin(a)
            if axis == 2:
                R = np.array([[c, -sn, 0], [sn, c, 0], [0, 0, 1]], np.float64)
            else:
                R = np.array([[1, 0, 0], [0, c, -sn], [0, sn, c]], np.float64)
        elif (cn in ('func_door', 'func_movelinear')
              or (cn == 'func_door_rotating' and not local)):
            # A rotating door with no origin brush has no pivot to swing
            # about. Source treats movedir as a slide in that case, so do the
            # same rather than leaving it shut.
            md = ent.get('movedir')
            ang = _vec(md) if md else _vec(ent.get('angles', '0 0 0'))
            d = _angles_to_forward(ang[0], ang[1], ang[2])
            m = bsp.models[mi]
            ext = np.array(m['maxs'], np.float64) - np.array(m['mins'], np.float64)
            try:
                lip = float(ent.get('lip', 0) or 0)
            except ValueError:
                lip = 0.0
            travel = abs(d @ ext) - lip
            if sf & 1:
                travel = 0.0
            t = t + d * max(travel, 0.0)
    return R, t


def occlusion_only_models(bsp):
    """Brush entity models whose every drawn face is `tools/toolsblack`.

    These are areaportal visibility hacks, not scenery: a flat black panel
    dropped into a doorway so the engine can hide what is beyond it. They are
    named for what they are - `portal_brush01`..`04` on de_nuke, `portal01`..
    `portal14` on de_inferno, `Portalwindow01`.. on de_train - and most carry
    `Solidity 1`, "Never Solid", so a CS:S player walks straight through.

    Rendering them gives you a black pane sealing a doorway that you then
    collide with, since the game makes every mesh solid.

    The all-black test is what separates these from the OTHER use of
    toolsblack, which must be kept: the flat black backing behind a vent or
    window, painted on ordinary WORLD brushwork. The split is total in
    practice - de_nuke, de_inferno and de_train have 100 % of their toolsblack
    in these entities, ctf_2fort has 100 % of its in the world.
    """
    out = set()
    for mi in model_entities(bsp):
        m = bsp.models[mi]
        f0, fn = int(m['firstface']), int(m['numfaces'])
        black = drawn = 0
        for fi in range(f0, f0 + fn):
            nm, flags, _w, _h = bsp.face_material(fi)
            if not nm or (flags & B.SKIP_FLAGS):
                continue
            drawn += 1
            if nm.lower() == 'tools/toolsblack':
                black += 1
        if drawn and black == drawn:
            out.add(mi)
    return out


def model_entities(bsp):
    """model index -> entity dict, for models referenced as '*N'."""
    out = {}
    for e in bsp.entities:
        m = e.get('model', '')
        if m.startswith('*'):
            try:
                out[int(m[1:])] = e
            except ValueError:
                pass
    return out


def is_visible_ent(e):
    cn = e.get('classname', '').lower()
    if any(cn.startswith(p) for p in INVISIBLE_ENT):
        return False
    # explicitly hidden brushes
    if e.get('rendermode') in ('10',) or e.get('StartDisabled') == '1':
        return False
    if e.get('renderamt') == '0':
        return False
    return True


BREAKABLE_CLASSES = ('func_breakable', 'func_breakable_surf', 'func_physbox',
                      'func_physbox_multiplayer')


def brush_entity_policy(e, doors='open', breakables='remove'):
    """'place' | 'remove' | 'ignore' for one brush entity.

    'remove' means we deliberately drop its geometry - which still has to be
    excluded from the nodraw fill, or the fill rebuilds its hidden sides from
    the world-space BRUSHES lump and you get invisible collision exactly where
    the thing you removed used to be.
    """
    cn = str(e.get('classname', '')).lower()
    if not is_visible_ent(e):
        return 'ignore'
    if breakables == 'remove' and cn in BREAKABLE_CLASSES:
        return 'remove'
    if doors == 'remove' and cn.startswith(('func_door', 'prop_door')):
        return 'remove'
    return 'place'


def door_carriers(bsp, doors='open', include_brush_ents=True, pad=4.0):
    """Brush entities we MOVE, so anything attached to them can come along.

    Source links attachments with `parentname` -> the mover's `targetname`, and
    that is authoritative: on de_nuke each rotating door has exactly two
    prop_dynamic handles and one func_breakable glass pane parented to it. Use
    that rather than geometry - doors *47 and *48 are 7 units apart, so a
    bounding-box match carries *48's handles with *47's swing.

    A closed-position box is still kept as a fallback for unparented props
    resting on a mover, resolved to the NEAREST carrier.

    Each entry transforms a world point p as
        p' = R @ (p - pivot) + pivot + delta      and  M' = R @ M
    """
    out = []
    if not include_brush_ents or doors != 'open':
        return out
    for mi, e in model_entities(bsp).items():
        if brush_entity_policy(e, doors=doors, breakables='keep') != 'place':
            continue
        try:
            R, t = brush_entity_transform(bsp, mi, e, doors='open')
            _R0, t0 = brush_entity_transform(bsp, mi, e, doors='closed')
        except Exception:
            continue
        if np.abs(R - np.eye(3)).max() <= 1e-9 and np.linalg.norm(t - t0) <= 1e-6:
            continue
        m = bsp.models[mi]
        f0, fn = int(m['firstface']), int(m['numfaces'])
        vs = [bsp.verts[l] for l in (bsp.face_loop(fi) for fi in range(f0, f0 + fn)) if l]
        boxed = bool(vs)
        if vs:
            w = np.concatenate(vs).astype(np.float64) + t0
        else:
            # A mover with NO drawn faces is not a dead end - it is the normal
            # modern pattern: a nodraw func_door provides the motion and
            # collision while a prop_dynamic is the door you actually see,
            # parented to it. de_inferno has two, and TF2's spawn doors are
            # built the same way, which is why the garage door stayed shut.
            # Skipping these meant the prop had no carrier to ride.
            lo = np.array(m['mins'], np.float64) + t0
            hi = np.array(m['maxs'], np.float64) + t0
            if not np.all(np.isfinite(lo)) or (hi < lo).any():
                continue
            w = np.stack([lo, hi])
        out.append(dict(R=R, pivot=t0.copy(), delta=(t - t0), boxed=boxed,
                        lo=w.min(0) - pad, hi=w.max(0) + pad,
                        centre=(w.min(0) + w.max(0)) / 2.0,
                        targetname=str(e.get('targetname', '') or '').lower(),
                        classname=e.get('classname', '?'), model=mi))
    return out


def find_carrier(carriers, parentname=None, point=None):
    if not carriers:
        return None
    pn = str(parentname or '').lower()
    if pn:
        for c in carriers:
            if c['targetname'] and c['targetname'] == pn:
                return c
        return None          # explicitly parented elsewhere: do not guess
    if point is None:
        return None
    best = None
    for c in carriers:
        # Only carriers with real drawn geometry may claim a prop by position.
        # A nodraw mover's box is just a doorway volume, and the door you can
        # actually see is a prop_dynamic that names it via parentname - so the
        # fallback buys nothing there and risks dragging anything standing in
        # the doorway.
        if not c.get('boxed', True):
            continue
        if (point >= c['lo']).all() and (point <= c['hi']).all():
            d = float(np.linalg.norm(point - c['centre']))
            if best is None or d < best[0]:
                best = (d, c)
    return best[1] if best else None


def apply_carrier(c, rot, shift):
    """Compose a carrier onto an existing (rot, shift) brush transform."""
    new_rot = c['R'] @ rot
    new_shift = c['R'] @ (shift - c['pivot']) + c['pivot'] + c['delta']
    return new_rot, new_shift


def carry_point(p, M, carriers, parentname=None):
    c = find_carrier(carriers, parentname, np.asarray(p, np.float64))
    if c is None:
        return p, M, None
    return (c['R'] @ (np.asarray(p, np.float64) - c['pivot']) + c['pivot'] + c['delta'],
            c['R'] @ M, c)


def extract(bsp, scale=UNIT, cell_m=48.0, include_brush_ents=True,
            keep_translucent=True, fill_mode='exposed', doors='open',
            breakables='remove', blend_bands=None, blend_cell=1.5,
            rebuild_culled=True, min_exposed=0.10, bake=None, verbose=True):
    """Walk the BSP and return (chunks, stats). Chunks are in glTF space."""
    ch = Chunker(cell_m)
    stats = collections.Counter()
    disp_by_face = {d['mapface']: i for i, d in enumerate(bsp.dispinfo)}
    ments = model_entities(bsp) if include_brush_ents else {}
    occl = occlusion_only_models(bsp) if include_brush_ents else set()
    nmodels = len(bsp.models) if include_brush_ents else 1
    _carriers = door_carriers(bsp, doors=doors, include_brush_ents=include_brush_ents)
    # report rotated and slid separately: 'doors_opened' only ever counted
    # rotations, so a sliding door that stayed shut looked the same in the
    # report as one that opened. That is the exact failure TF2 hit.
    for _c in _carriers:
        if np.abs(_c['R'] - np.eye(3)).max() > 1e-9:
            stats['doors_rotated'] += 1
        elif np.linalg.norm(_c['delta']) > 1e-6:
            stats['doors_slid'] += 1

    for mi in range(nmodels):
        mdl = bsp.models[mi]
        rot = None
        if mi:
            e = ments.get(mi)
            if e is None:
                stats['skipped_ent_model'] += 1
                continue
            if mi in occl:
                stats['skipped_occlusion_brush'] += 1
                continue
            pol = brush_entity_policy(e, doors=doors, breakables=breakables)
            if pol == 'ignore':
                stats['skipped_ent_model'] += 1
                continue
            if pol == 'remove':
                cn = str(e.get('classname', '')).lower()
                key = ('breakables_removed' if cn in BREAKABLE_CLASSES
                       else 'doors_removed')
                stats[key] += 1
                continue
            rot, shift = brush_entity_transform(bsp, mi, e, doors=doors)
            if _carriers and e.get('parentname'):
                _c = find_carrier(_carriers, e.get('parentname'))
                if _c is not None and _c['model'] != mi:
                    rot, shift = apply_carrier(_c, rot, shift)
                    stats['brush_ents_carried'] += 1
            if np.abs(rot - np.eye(3)).max() > 1e-9:
                stats['doors_opened'] += 1
            if np.linalg.norm(shift) > 1.0:
                stats['ent_models_offset'] += 1
        else:
            shift = np.zeros(3)
        f0, fn = int(mdl['firstface']), int(mdl['numfaces'])
        for fi in range(f0, f0 + fn):
            name, flags, w, h = bsp.face_material(fi)
            if name is None:
                stats['no_texinfo'] += 1; continue
            if flags & B.SKIP_FLAGS:
                stats['skipped_flags'] += 1; continue
            if TOOL_RE.match(name):
                if tool_material_is_drawn(name, flags):
                    stats['tool_material_kept'] += 1
                else:
                    stats['skipped_tool'] += 1; continue
            if (flags & B.SURF_TRANS) and not keep_translucent:
                stats['skipped_trans'] += 1; continue

            di = disp_by_face.get(fi, -1)
            if di >= 0:
                r = B.displace(bsp, fi, di)
                if r is None:
                    stats['bad_disp'] += 1; continue
                dpos, dtris, _corners, _alpha, dvn = r
                src = (dpos @ rot.T if rot is not None else dpos) + shift
                uv_all = face_uv(bsp, fi, dpos)
                p = src[dtris].reshape(-1, 3)
                u = uv_all[dtris].reshape(-1, 2)
                gp = to_gltf(p, scale)
                gn = to_gltf(dvn[dtris].reshape(-1, 3), 1.0)
                nbands = blend_bands(name.lower()) if blend_bands else 0
                if nbands >= 2 and _alpha is not None and len(_alpha) == len(dpos):
                    # WorldVertexTransition: pick the nearest pre-composited
                    # mix per triangle from the displacement's vertex alpha.
                    # One albedo sampler in the game shader means no live
                    # blend, so subdivide first - nuke's blend displacements
                    # are power-2 and up to 65 m across, and banding 11 m
                    # triangles would look like flat patches.
                    sp, sn, su, sa = subdivide_tris(
                        gp, gn, u, _alpha[dtris].reshape(-1),
                        target_m2=blend_cell, scale=1.0)
                    w = np.clip(sa.reshape(-1, 3).mean(axis=1) / 255.0, 0.0, 1.0)
                    k = np.rint(w * (nbands - 1)).astype(np.int32)
                    tp = sp.reshape(-1, 3, 3).astype(np.float32)
                    tn = sn.reshape(-1, 3, 3).astype(np.float32)
                    tu = su.reshape(-1, 3, 2).astype(np.float32)
                    for kk in np.unique(k):
                        sel = k == kk
                        ch.add(f'{name.lower()}#b{int(kk)}/{nbands}',
                               tp[sel].reshape(-1, 3), tn[sel].reshape(-1, 3),
                               tu[sel].reshape(-1, 2))
                    stats['blend_faces'] += 1
                    stats['blend_tris'] += len(dtris)
                    stats['blend_tris_after_subdiv'] += len(tp)
                else:
                    ch.add(name.lower(), gp, gn, u)
                stats['disp_faces'] += 1
                stats['disp_tris'] += len(dtris)
            else:
                loop = bsp.face_loop(fi)
                if len(loop) < 3:
                    stats['degenerate'] += 1; continue
                vs = bsp.verts[loop].astype(np.float64)

                # A face's normal is its plane's normal. The 'side' flag says
                # which side of the plane the node is on - it does NOT flip the
                # face. Source stores the vertex loop clockwise about that
                # normal; glTF (and Godot's concave collision, which only
                # collides front faces) needs counter-clockwise. Derive the
                # winding rather than assume it, so unusual maps still work.
                nrm = np.array(bsp.planes[int(bsp.faces[fi]['planenum'])]['normal'],
                               np.float64)
                newell = np.cross(vs, np.roll(vs, -1, axis=0)).sum(axis=0)
                if newell @ nrm < 0:
                    vs = vs[::-1].copy()
                    stats['rewound'] += 1

                uv_all = face_uv(bsp, fi, vs)
                src = (vs @ rot.T if rot is not None else vs) + shift
                k = len(vs)
                fan = np.stack([np.zeros(k - 2, np.int64),
                                np.arange(1, k - 1), np.arange(2, k)], axis=1)
                p = src[fan].reshape(-1, 3)
                u = uv_all[fan].reshape(-1, 2)
                gp = to_gltf(p, scale)
                gn = np.tile(to_gltf(nrm[None, :], 1.0), (len(gp), 1))
                # a baked face carries atlas UVs and its page's material
                # instead of the tiled one - see lightmap.Bake
                bmat = bake.material_name(fi) if (bake is not None and mi == 0) \
                    else None
                bu = bake.uv(fi, p) if bmat else None
                if bu is not None:
                    ch.add(bmat, gp, gn, bu)
                    stats['baked_faces'] += 1
                    stats['baked_tris'] += k - 2
                else:
                    ch.add(name.lower(), gp, gn, u)
                    stats['brush_faces'] += 1
                    stats['brush_tris'] += k - 2

    if fill_mode and fill_mode != 'none':
        from . import nodraw as ND
        # brush entities own their brushes; don't rebuild their hidden sides
        excl = []
        for mi, e in (ments.items() if include_brush_ents else ()):
            # only for entities whose geometry we place ourselves - a
            # trigger_soundscape can blanket 168,000 m3 and would wipe out
            # every legitimate world fill inside it
            if brush_entity_policy(e, doors=doors,
                                   breakables=breakables) == 'ignore':
                continue
            try:
                _r, _t = brush_entity_transform(bsp, mi, e, doors=doors)
            except Exception:
                continue
            # bound the ACTUAL transformed vertices. dmodel mins/maxs are
            # model-local, so mins+t is a box at the world origin for
            # world-space entities and would swallow real world fills.
            m = bsp.models[mi]
            f0, fn = int(m['firstface']), int(m['numfaces'])
            vs = []
            for fi in range(f0, f0 + fn):
                loop = bsp.face_loop(fi)
                if loop:
                    vs.append(bsp.verts[loop])
            if not vs:
                continue
            w = np.concatenate(vs).astype(np.float64)
            w = (w @ _r.T if _r is not None else w) + _t
            excl.append((w.min(0) - 2.0, w.max(0) + 2.0))
        if verbose:
            print(f"[2/5] rebuilding hidden (nodraw) faces, mode={fill_mode}...")
        fills, fstats = ND.collect(bsp, mode=fill_mode, scale=scale,
                                   exclude_volumes=excl,
                                   rebuild_culled=rebuild_culled,
                                   min_exposed=min_exposed,
                                   verbose=verbose)
        for mat, donor_ti, q, n in fills:
            if (donor_ti is not None and donor_ti >= 0
                    and ND.donor_axes_ok(bsp, donor_ti, n)):
                uv_all = ND.donor_uv(bsp, donor_ti, q)
            else:
                uv_all = ND.box_uv(q, n, scale=scale)
                stats['fill_box_uv'] += 1
            k = len(q)
            fan = np.stack([np.zeros(k - 2, np.int64),
                            np.arange(1, k - 1), np.arange(2, k)], axis=1)
            gp = to_gltf(q[fan].reshape(-1, 3), scale)
            u = uv_all[fan].reshape(-1, 2)
            gn = np.tile(to_gltf(n[None, :], 1.0), (len(gp), 1))
            ch.add(mat if mat.startswith('z_') else mat.lower(), gp, gn, u)
            stats['filled_faces'] += 1
            stats['filled_tris'] += k - 2
        for kk, vv in fstats.items():
            stats['fill_' + kk] = vv
    return ch.finish(), stats
