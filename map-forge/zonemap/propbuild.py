"""Place Source static props (and prop_* entities) into the glTF as instanced nodes."""
import math, collections, numpy as np
from . import mdl as MD, props as PR, build as BU, cutout as CUT
from .materials import is_light_effect

# Source -> glTF basis change: (x, y, z)_src -> (x, z, -y)_gltf
C = np.array([[1.0, 0.0, 0.0],
              [0.0, 0.0, 1.0],
              [0.0, -1.0, 0.0]])

# Valve's own comment on this bit is the whole story:
#     STATIC_PROP_NO_DRAW = 0x4,  // computed at run time based on dx level
# It is not an authoring flag. Nothing in the BSP is meant to be read out of
# it, and honouring it threw away 845 of ctf_2fort's 2,265 static props (37 %),
# including most of the map's fences. The pair that proves it: the yard's two
# big fences are the same prop mirrored, `security_fence_big01` with flags=191
# and `security_fence_big02` with flags=1 - both plainly drawn in game.
#
# CS:S (lump v5/v6) never sets it: de_dust2, de_nuke and de_inferno between
# them use only flags {0,1,2,3,16,17,18,19}. TF2 (v10) writes 29 distinct
# values including 248, 230, 210, 143, 99, 52 and 7, i.e. bits the authoring
# enum does not define. So the test was a no-op on CS:S and pure damage on TF2.
STATIC_PROP_NO_DRAW = 0x4   # kept for documentation; deliberately NOT tested


def mat_to_quat(R):
    """3x3 rotation -> glTF quaternion [x, y, z, w]."""
    t = R[0, 0] + R[1, 1] + R[2, 2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        w = 0.25 * s
        x = (R[2, 1] - R[1, 2]) / s
        y = (R[0, 2] - R[2, 0]) / s
        z = (R[1, 0] - R[0, 1]) / s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = math.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        w = (R[2, 1] - R[1, 2]) / s
        x = 0.25 * s
        y = (R[0, 1] + R[1, 0]) / s
        z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = math.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        w = (R[0, 2] - R[2, 0]) / s
        x = (R[0, 1] + R[1, 0]) / s
        y = 0.25 * s
        z = (R[1, 2] + R[2, 1]) / s
    else:
        s = math.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        w = (R[1, 0] - R[0, 1]) / s
        x = (R[0, 2] + R[2, 0]) / s
        y = (R[1, 2] + R[2, 1]) / s
        z = 0.25 * s
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    return [x / n, y / n, z / n, w / n]


def collect(bsp, include_entities=True, nonsolid='keep', exclude=()):
    """All prop placements: [(model, skin, origin, angles, scale, source)]

    solid==0 props are pass-through in Source (window frames, vines, balcony
    railings, lamps - the brushwork or a clip brush behind them does the
    colliding). The Zone builds a trimesh collider for every mesh and offers no
    way to opt out, so keeping them means a drone snags on things a CS player
    walks through.
    """
    out = []
    excl = tuple(e.lower() for e in exclude if e)

    def dropped(model):
        m = model.lower()
        return any(e in m for e in excl)

    sp, names, meta = PR.static_props(bsp)
    for p in sp:
        if nonsolid == 'skip' and p['solid'] == 0:
            continue
        if dropped(p['model']):
            continue
        out.append((p['model'], p['skin'], np.array(p['origin']),
                    p['angles'], p['scale'], 'static', None))
    if include_entities:
        for e in bsp.entities:
            cn = e.get('classname', '')
            if not cn.startswith('prop_'):
                continue
            if cn in ('prop_ragdoll',):
                continue
            m = e.get('model', '')
            if not m.lower().endswith('.mdl'):
                continue
            if dropped(m):
                continue
            if nonsolid == 'skip' and e.get('solid') == '0':
                continue
            if e.get('StartDisabled') == '1' or e.get('renderamt') == '0':
                continue
            try:
                o = np.array([float(x) for x in e.get('origin', '0 0 0').split()[:3]])
            except ValueError:
                continue
            a = (0.0, 0.0, 0.0)
            if e.get('angles'):
                try:
                    pa = [float(x) for x in e['angles'].split()[:3]]
                    a = (pa[0], pa[1], pa[2])
                except (ValueError, IndexError):
                    pass
            try:
                s = float(e.get('modelscale', 1.0) or 1.0)
            except ValueError:
                s = 1.0
            out.append((m, int(float(e.get('skin', 0) or 0)), o, a, s, cn,
                        e.get('parentname')))
    return out, names, meta


def add_props(glb, fs, bank, bsp, scale=BU.UNIT, include_entities=True,
              keep_region=None, nonsolid='keep', exclude=(),
              trim_cutouts=True, cutout_cell=0.75, offset=None,
              light_effects=False, carriers=(), skybox_expand=None,
              verbose=True):
    """Build one glTF mesh per (model, skin) and one node per placement."""
    placements, names, meta = collect(bsp, include_entities,
                                      nonsolid=nonsolid, exclude=exclude)
    if not placements:
        return [], dict(placements=0)

    stats = collections.Counter()
    failed = []
    mesh_cache = {}
    nodes = []

    # group so each unique model+skin is loaded and uploaded once
    by_model = collections.defaultdict(list)
    for m, skin, o, a, s, src, par in placements:
        by_model[(m.lower(), skin)].append((o, a, s, src, par))

    for (path, skin), inst in sorted(by_model.items()):
        model, err = MD.load_model(fs, path, skin)
        if model is None:
            stats['model_failed'] += 1
            stats['instances_lost'] += len(inst)
            failed.append((path, err))
            if verbose and len(failed) <= 5:
                print(f'      ! {path}: {err}')
            elif verbose and len(failed) == 6:
                print('      ! ...further model failures summarised at the end')
            continue
        try:
            mm = MD.Mdl(fs.read(path if path.startswith('models/') else 'models/' + path))
            cdm = mm.cdmaterials
        except Exception:
            cdm = []

        prims = []
        for matname, pos, nrm, uv, tris in model.parts:
            resolved = MD.resolve_material(fs, matname, cdm)
            if not light_effects and resolved and is_light_effect(fs, resolved):
                stats['light_effect_parts_skipped'] += 1
                continue
            mi = bank.get(resolved) if resolved else bank.get(matname)
            if resolved is None:
                stats['material_unresolved'] += 1
            if trim_cutouts:
                cm = bank.cutouts.get(mi)
                if cm is not None and cm.coverage < 0.9:
                    pos, nrm, uv, tris, nbig, nadd = CUT.trim(
                        pos, nrm, uv, tris, cm, unit=scale,
                        target_m2=cutout_cell)
                    if nbig:
                        stats['cutout_tris_trimmed'] += nbig
                        stats['cutout_tris_added'] += nadd
            # model-local Source coords -> glTF-local metres
            lp = (pos @ C.T) * scale
            ln = nrm @ C.T
            if mi in getattr(bank, 'two_sided', ()):
                # the game drops cull_mode, so two-sided art needs real
                # back faces (see convert.mirror_faces)
                nv = len(lp)
                lp = np.concatenate([lp, lp])
                ln = np.concatenate([ln, -ln])
                uv = np.concatenate([uv, uv])
                tris = np.concatenate(
                    [np.asarray(tris).reshape(-1, 3),
                     np.asarray(tris).reshape(-1, 3)[:, ::-1] + nv])
                stats['two_sided_tris_added'] += len(tris) // 2
            prims.append((lp.astype(np.float32), ln.astype(np.float32),
                          uv, tris, mi))
        if not prims:
            stats['model_empty'] += 1
            continue
        nm = 'prop_' + path.split('/')[-1].replace('.mdl', '') + (f'_s{skin}' if skin else '')
        mesh = glb.mesh(nm, prims)
        mesh_cache[(path, skin)] = mesh
        stats['models'] += 1
        stats['unique_tris'] += model.triangles

        for (o, a, s, src, par) in inst:
            M = MD._angle_matrix(*a)
            if carriers:
                o, M, car = BU.carry_point(np.asarray(o, np.float64), M,
                                           carriers, parentname=par)
                if car is not None:
                    stats['carried_with_' + car['classname']] += 1
            Rg = C @ M @ C.T
            t = (C @ o) * scale
            mult = 1.0
            if skybox_expand is not None:
                # `(p - sky_camera.origin) * N`, in the pre-shift frame - the
                # prop grows with the landscape it stands on, or a 1/16-scale
                # barn ends up a doll's house on a real hillside.
                test, usky, factor, ceiling = skybox_expand
                if test(t):
                    t = (t - usky) * factor
                    mult = factor
                    if ceiling is not None and float(t[1]) > ceiling:
                        stats['skybox_above_ceiling'] += 1
                        continue          # a cloud card, not scenery
                    stats['skybox_expanded_props'] += 1
            if offset is not None:
                t = t + np.asarray(offset)
            if keep_region is not None and not keep_region(t):
                stats['outside_region'] += 1
                continue
            sc = float(s) * mult
            nodes.append(glb.node(
                nm, mesh=mesh,
                translation=[float(x) for x in t],
                rotation=mat_to_quat(Rg),
                scale=[sc] * 3 if abs(sc - 1.0) > 1e-4 else None))
            stats['placed'] += 1
            stats['placed_tris'] += model.triangles

    stats['placements'] = len(placements)
    stats['prop_models_in_lump'] = len(names)
    if failed and verbose:
        import collections as _c
        why = _c.Counter(e for _, e in failed)
        print(f"      {len(failed)} prop models could not be loaded: "
              + ', '.join(f'{v}x {k}' for k, v in why.most_common(4)))
    return nodes, dict(stats)
