"""An Unreal level (.umap) -> what it draws.

    lv = level_contents(packages, '/Game/LEVELS/TheDock')
    lv['meshes']    [(mesh, 4x4 world, override materials, name)]
    lv['splines']   [(mesh, 4x4 world, spline params, override materials, name)]
    lv['landscapes'] [(package, landscape actor export)]
    lv['player_start'] 4x4 or None
    lv['sublevels'] [level paths it streams in, lighting variants left out]

Every component's properties are merged with its archetype's (uasset.
Packages), because a Blueprint actor placed in a level stores only what
differs from the Blueprint: half of TheDock's 4,084 static mesh components
name no mesh of their own.

Instanced components (ISM, HISM, foliage) carry their instances natively
after the tagged properties, as a bulk array of 4x4 matrices; it is found by
its header (element size 64) and checked (a transform's last column is
0, 0, 0, 1) rather than by walking the LOD data in front of it.
"""
import re, struct, collections
import numpy as np
from . import ugeo

MESH = 'StaticMeshComponent'
INSTANCED = ('InstancedStaticMeshComponent', 'HierarchicalInstancedStaticMeshComponent',
             'FoliageInstancedStaticMeshComponent')
SPLINE = 'SplineMeshComponent'
LANDSCAPE = ('Landscape', 'LandscapeProxy', 'LandscapeStreamingProxy')
SKIP_OWNERS = ('LODActor', 'WorldSettings')
LIGHTING = re.compile(r'(_sun|_after|_rain|_cloud|_night|_light|daylight|_snow|_fog|_dawn|'
                      r'_sunset|_storm|_lme_)', re.I)


def _obj(v):
    return v[2] if isinstance(v, tuple) and len(v) > 2 and v[0] == 'obj' else None


def _no_collision(pr):
    bi = pr.get('BodyInstance')
    if isinstance(bi, dict):
        if 'NoCollision' in str(bi.get('CollisionEnabled', '')) or \
                str(bi.get('CollisionProfileName', '')) == 'NoCollision':
            return True
    return False


def instances(pkg, exp, props_end):
    """the per-instance 4x4s (Unreal row-vector layout) of an instanced component"""
    b = pkg.data
    end = exp['offset'] + exp['size']
    for o in range(props_end, min(end - 8, props_end + 8192)):
        es, n = struct.unpack_from('<ii', b, o)
        if es != 64 or n <= 0 or o + 8 + 64 * n > end:
            continue
        m = np.frombuffer(b, '<f4', 16 * n, o + 8).reshape(n, 4, 4)
        k = min(n, 8)
        if np.allclose(m[:k, :3, 3], 0, atol=1e-3) and np.allclose(m[:k, 3, 3], 1, atol=1e-3):
            return m
    return None


def level_contents(pc, path, foliage_min_radius=150.0, keep_uncollidable_foliage=False):
    pkg = pc.get(path)
    if pkg is None:
        return None
    out = dict(meshes=[], splines=[], landscapes=[], player_start=None, sublevels=[],
               stats=collections.Counter(), package=pkg)
    ex = pkg.exports
    cls = [pkg.class_name(e) for e in ex]
    P = lambda i: pc.props(pkg, i)
    world_cache = {}

    def world(i, depth=0):
        if i in world_cache:
            return world_cache[i]
        pr = P(i)
        m = ugeo.relative(pr)
        ap = pr.get('AttachParent')
        if isinstance(ap, tuple) and ap[0] == 'obj' and ap[1] > 0 and depth < 24:
            m = world(ap[1], depth + 1) @ m
        world_cache[i] = m
        return m

    def owner_hidden(i):
        o = ex[i - 1]['outer']
        if o <= 0:
            return False
        if cls[o - 1] in SKIP_OWNERS:
            return True
        op = P(o)
        return bool(op.get('bHidden')) or bool(op.get('bIsEditorOnlyActor'))

    light_levels = set()
    for i, c in enumerate(cls, 1):
        if c.endswith('_C'):
            pr = P(i)
            for v in pr.get('LightLevelName', []) or []:
                light_levels.add(str(v).lower())
    for i, c in enumerate(cls, 1):
        if c in LANDSCAPE:
            out['landscapes'].append((pkg, ex[i - 1]))
            continue
        if c == 'PlayerStart' and out['player_start'] is None:
            rc = P(i).get('RootComponent')
            if isinstance(rc, tuple) and rc[1] > 0:
                out['player_start'] = world(rc[1])
            continue
        if 'LevelStreaming' in c:
            wa = P(i).get('WorldAsset')
            if isinstance(wa, tuple) and wa[0] == 'soft' and wa[1] and wa[1] != 'None':
                lp = wa[1].split('.')[0]
                leaf = lp.split('/')[-1].lower()
                if leaf in light_levels or (c != 'LevelStreamingAlwaysLoaded' and LIGHTING.search(leaf)):
                    out['stats']['lighting_sublevels_skipped'] += 1
                else:
                    out['sublevels'].append(lp)
            continue
        if c not in (MESH, SPLINE) + INSTANCED:
            continue
        pr = P(i)
        if pr.get('bHiddenInGame') or pr.get('bVisible', True) is False or pr.get('bIsEditorOnly'):
            out['stats']['hidden'] += 1
            continue
        if owner_hidden(i):
            out['stats']['hidden'] += 1
            continue
        mesh = _obj(pr.get('StaticMesh'))
        if not mesh:
            continue
        over = [_obj(x) for x in (pr.get('OverrideMaterials') or [])]
        W = world(i)
        name = ex[i - 1]['name']
        if c == SPLINE:
            out['splines'].append((mesh, W, pr, over, name))
        elif c in INSTANCED:
            try:
                _, r = pkg.export_props(ex[i - 1])
                m = instances(pkg, ex[i - 1], r.o)
            except Exception:
                m = None
            if m is None or not len(m):
                out['stats']['instanced_without_instances'] += 1
                continue
            foliage = c == 'FoliageInstancedStaticMeshComponent'
            if foliage and _no_collision(pr) and not keep_uncollidable_foliage:
                out['stats']['foliage_skipped_no_collision'] += len(m)
                out['stats']['foliage_skipped_no_collision_meshes'] += 1
                continue
            for k in range(len(m)):
                out['meshes'].append((mesh, W @ m[k].T, over, name, foliage))
            out['stats']['instances'] += len(m)
        else:
            out['meshes'].append((mesh, W, over, name, False))
    return out


# ---- spline meshes ---------------------------------------------------------------
def _hermite(p0, t0, p1, t1, a):
    a2 = a * a; a3 = a2 * a
    pos = ((2 * a3 - 3 * a2 + 1)[:, None] * p0 + (a3 - 2 * a2 + a)[:, None] * t0
           + (a3 - a2)[:, None] * t1 + (-2 * a3 + 3 * a2)[:, None] * p1)
    d = ((6 * a2 - 6 * a)[:, None] * p0 + (3 * a2 - 4 * a + 1)[:, None] * t0
         + (3 * a2 - 2 * a)[:, None] * t1 + (-6 * a2 + 6 * a)[:, None] * p1)
    return pos, d


def deform_spline(pos, nrm, pr):
    """a spline mesh's vertices (Unreal cm, component space) bent along its
    cubic Hermite segment, as USplineMeshComponent::CalcSliceTransform does"""
    sp = pr.get('SplineParams') or {}
    v3 = lambda k, d: np.array(sp.get(k, d) if isinstance(sp.get(k), tuple) else d, float)
    p0 = v3('StartPos', (0, 0, 0)); t0 = v3('StartTangent', (100, 0, 0))
    p1 = v3('EndPos', (100, 0, 0)); t1 = v3('EndTangent', (100, 0, 0))
    s0 = np.array(sp.get('StartScale', (1, 1)) if isinstance(sp.get('StartScale'), tuple) else (1, 1), float)
    s1 = np.array(sp.get('EndScale', (1, 1)) if isinstance(sp.get('EndScale'), tuple) else (1, 1), float)
    o0 = np.array(sp.get('StartOffset', (0, 0)) if isinstance(sp.get('StartOffset'), tuple) else (0, 0), float)
    o1 = np.array(sp.get('EndOffset', (0, 0)) if isinstance(sp.get('EndOffset'), tuple) else (0, 0), float)
    r0 = float(sp.get('StartRoll', 0.0) or 0.0); r1 = float(sp.get('EndRoll', 0.0) or 0.0)
    up = np.array(pr.get('SplineUpDir', (0, 0, 1)) if isinstance(pr.get('SplineUpDir'), tuple) else (0, 0, 1), float)
    axis = {'ESplineMeshAxis::Y': 1, 'ESplineMeshAxis::Z': 2}.get(str(pr.get('ForwardAxis', '')), 0)
    lo = float(pr.get('SplineBoundaryMin', 0.0) or 0.0); hi = float(pr.get('SplineBoundaryMax', 0.0) or 0.0)
    if hi <= lo:
        lo, hi = float(pos[:, axis].min()), float(pos[:, axis].max())
    rng = max(hi - lo, 1e-6)
    a = (pos[:, axis] - lo) / rng
    h = a * a * (3 - 2 * a) if pr.get('bSmoothInterpRollScale') else a
    sp_pos, d = _hermite(p0, t0, p1, t1, a)
    ln = np.linalg.norm(d, axis=1, keepdims=True)
    fwd = d / np.where(ln < 1e-9, 1, ln)
    bx = np.cross(up, fwd); bx /= np.maximum(np.linalg.norm(bx, axis=1, keepdims=True), 1e-9)
    by = np.cross(fwd, bx); by /= np.maximum(np.linalg.norm(by, axis=1, keepdims=True), 1e-9)
    off = o0[None] * (1 - h)[:, None] + o1[None] * h[:, None]
    sp_pos = sp_pos + off[:, :1] * bx + off[:, 1:] * by
    roll = r0 * (1 - h) + r1 * h
    c, s = np.cos(roll)[:, None], np.sin(roll)[:, None]
    xv = c * bx - s * by
    yv = c * by + s * bx
    scl = s0[None] * (1 - h)[:, None] + s1[None] * h[:, None]
    # which mesh axis goes on which slice-frame axis, as UE builds the slice
    # transform: X forward (dir, x, y); Y forward (y, dir, x); Z (x, y, dir)
    sx, sy = scl[:, 0], scl[:, 1]
    (ia, ea, sa), (ib, eb, sb) = {0: ((1, xv, sx), (2, yv, sy)),
                                  1: ((0, yv, sy), (2, xv, sx)),
                                  2: ((0, xv, sx), (1, yv, sy))}[axis]
    new = sp_pos + ea * (pos[:, ia] * sa)[:, None] + eb * (pos[:, ib] * sb)[:, None]
    # normals: the slice frame turns them; the scale is left out
    n2 = (fwd * nrm[:, axis:axis + 1] + ea * nrm[:, ia:ia + 1] + eb * nrm[:, ib:ib + 1])
    n2 /= np.maximum(np.linalg.norm(n2, axis=1, keepdims=True), 1e-9)
    return new, n2
