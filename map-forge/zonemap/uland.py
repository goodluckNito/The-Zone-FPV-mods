"""Unreal landscape (cooked) -> heightfield -> an adaptive glTF terrain.

A cooked landscape keeps its heights in the heightmap textures its
components point at: 16 bits in R (high) and G (low), with each component
reading its own (ComponentSizeQuads+1)^2 window (HeightmapScaleBias).

The terrain is cut back to the components, and each component block gets
the coarsest of the steps 1, 3, 9 and 63 quads whose worst height error
stays under a tolerance that grows with distance from where the map is
flown. The steps divide each other, so a fine block's edge can be pinned to
its coarser neighbour's edge exactly: no cracks.
"""
import numpy as np
from . import utex, ugeo



def _texels(csq, ssq, nsub):
    """component vertex -> texel within its window: each subsection keeps its
    own (SubsectionSizeQuads + 1) samples, so the shared edge is stored twice"""
    q = np.arange(csq + 1)
    s_ = np.minimum(q // max(ssq, 1), nsub - 1)
    return s_ * (ssq + 1) + (q - s_ * ssq)


def landscape_heights(pkg, land_exp, layer_name=None):
    """-> dict(z=(rows, cols) cm, x0, y0, dx, dy, csq, weights={layer: uint8
    grid}) in Unreal world space. layer_name maps a LayerInfo object path to
    its layer's name (without it, no weights are read)."""
    lp, _ = pkg.export_props(land_exp)
    root = pkg.ref(lp['RootComponent'][1])[1]
    rp, _ = pkg.export_props(root)
    loc = np.array(rp.get('RelativeLocation', (0, 0, 0)), float)
    scl = np.array(rp.get('RelativeScale3D', (1, 1, 1)), float)
    rot = rp.get('RelativeRotation', (0, 0, 0))
    if any(abs(x) > 1e-3 for x in rot):
        raise ValueError('rotated landscapes are not supported')
    csq = int(lp['ComponentSizeQuads'])
    ssq = int(lp.get('SubsectionSizeQuads', csq))
    nsub = int(lp.get('NumSubsections', 1))
    tix = _texels(csq, ssq, nsub)
    comps = []
    for c in lp.get('LandscapeComponents', []):
        ce = pkg.ref(c[1])[1]
        cp, _ = pkg.export_props(ce)
        comps.append((int(cp.get('SectionBaseX', 0)), int(cp.get('SectionBaseY', 0)), cp))
    if not comps:
        raise ValueError('no landscape components')
    x0 = min(c[0] for c in comps); y0 = min(c[1] for c in comps)
    W = max(c[0] for c in comps) - x0 + csq + 1
    H = max(c[1] for c in comps) - y0 + csq + 1
    assumed = False
    if 'RelativeScale3D' not in rp and W * 1.0 < 10000:
        # Uncrashed's flat base levels (desert, grass, asphalt) store no
        # scale at all, which reads as 1 cm a quad: a 20 m landscape inside
        # a 2.2 km flight box. They sit exactly where BaseLandscape04 does,
        # whose scale is stored: 128 (1.28 m a quad).
        scl = np.array([128.0, 128.0, 128.0])
        assumed = True
    hf = np.full((H, W), np.nan, np.float32)
    have = np.zeros(((H - 1) // csq, (W - 1) // csq), bool)
    weights = {}
    cache = {}
    names = {}

    def tex(ti):
        if ti not in cache:
            try:
                cache[ti] = utex.texture_rgba(pkg, pkg.ref(ti)[1], max_px=1 << 16)
            except Exception:
                cache[ti] = None
        return cache[ti]
    n = csq + 1
    for sx, sy, cp in comps:
        t = tex(cp['HeightmapTexture'][1])
        if t is None:
            continue
        th, tw = t.shape[:2]
        sb = cp.get('HeightmapScaleBias', (1, 1, 0, 0))
        ox = int(round(sb[2] * tw)); oy = int(round(sb[3] * th))
        if oy + tix[-1] >= th or ox + tix[-1] >= tw:
            continue
        blk = t[np.ix_(oy + tix, ox + tix)]
        h = (blk[..., 0].astype(np.int32) << 8) | blk[..., 1].astype(np.int32)
        r0, c0 = sy - y0, sx - x0
        hf[r0:r0 + n, c0:c0 + n] = h
        have[r0 // csq, c0 // csq] = True
        if layer_name is None:
            continue
        wts = cp.get('WeightmapTextures') or []
        wsb = cp.get('WeightmapScaleBias', (1, 1, 0, 0))
        for al in cp.get('WeightmapLayerAllocations', []) or []:
            try:
                li = al['LayerInfo'][2]
                wt = tex(wts[al['WeightmapTextureIndex']][1])
                ch = int(al['WeightmapTextureChannel'])
            except (KeyError, IndexError, TypeError):
                continue
            if wt is None or not li:
                continue
            if li not in names:
                names[li] = layer_name(li) or li.split('.')[-1]
            nm = names[li]
            wh, ww = wt.shape[:2]
            wx = int(round(wsb[2] * ww - 0.5)); wy = int(round(wsb[3] * wh - 0.5))
            if wy + tix[-1] >= wh or wx + tix[-1] >= ww:
                continue
            g = weights.get(nm)
            if g is None:
                g = weights[nm] = np.zeros((H, W), np.uint8)
            g[r0:r0 + n, c0:c0 + n] = wt[np.ix_(wy + tix, wx + tix)][..., ch]
    z = (hf - 32768.0) / 128.0 * scl[2] + loc[2]
    return dict(z=z, have=have, x0=loc[0] + x0 * scl[0], y0=loc[1] + y0 * scl[1],
                dx=scl[0], dy=scl[1], csq=csq, scale_assumed=assumed, weights=weights)


def steps_for(csq):
    """a chain of block steps that divide each other, coarse to fine: the
    component size's prime factors, smallest first from the fine end, so
    63 quads gives 63, 9, 3, 1"""
    f, n, p = [], csq, 2
    while n > 1:
        while n % p == 0:
            f.append(p); n //= p
        p += 1
    out = [1]
    for k in f:
        out.append(out[-1] * k)
    return tuple(reversed(out))


def _block_error(zb, s):
    """worst |height - what a grid of step s shows| over a block"""
    n = zb.shape[0] - 1
    idx = np.arange(0, n + 1, s)
    c = zb[np.ix_(idx, idx)]
    # bilinear back-interpolation onto the full grid
    t = np.arange(n + 1) / s
    i0 = np.minimum(np.floor(t).astype(int), len(idx) - 2)
    f = t - i0
    r0 = c[i0] * (1 - f)[:, None] + c[i0 + 1] * f[:, None]
    full = r0[:, i0] * (1 - f)[None, :] + r0[:, i0 + 1] * f[None, :]
    return float(np.nanmax(np.abs(full - zb)))


def build(L, focus_xy, tol_near=3.0, tol_slope=0.004, block=4, max_step=1 << 16,
          min_step=1):
    """-> list of (cell (bx, by), pos (N,3) glTF m, nrm, idx) chunk meshes

    focus_xy: (xmin, ymin, xmax, ymax) Unreal cm - where the map is flown.
    tol_near (cm) is the allowed error there; it grows by tol_slope per cm of
    distance. block: components per output chunk (each way)."""
    z = L['z']; have = L['have']; csq = L['csq']
    nby, nbx = have.shape
    steps = [s for s in steps_for(csq) if min_step <= s <= max_step] or [1]
    fx0, fy0, fx1, fy1 = focus_xy
    step = np.zeros((nby, nbx), int)
    for by in range(nby):
        for bx in range(nbx):
            if not have[by, bx]:
                continue
            zb = z[by * csq:(by + 1) * csq + 1, bx * csq:(bx + 1) * csq + 1]
            cx = L['x0'] + (bx + 0.5) * csq * L['dx']
            cy = L['y0'] + (by + 0.5) * csq * L['dy']
            d = np.hypot(max(fx0 - cx, 0, cx - fx1), max(fy0 - cy, 0, cy - fy1))
            tol = tol_near + tol_slope * d
            st = steps[-1]
            for s in steps:
                if _block_error(zb, s) <= tol:
                    st = s
                    break
            step[by, bx] = st
    out = []
    for cy in range(0, nby, block):
        for cx in range(0, nbx, block):
            P, N, I = [], [], []
            base = 0
            for by in range(cy, min(cy + block, nby)):
                for bx in range(cx, min(cx + block, nbx)):
                    s = step[by, bx]
                    if s == 0:
                        continue
                    p, n, i = _block_mesh(L, by, bx, s, step)
                    P.append(p); N.append(n); I.append(i + base); base += len(p)
            if P:
                out.append(((cx // block, cy // block), np.concatenate(P),
                            np.concatenate(N), np.concatenate(I)))
    return out, step


def _block_mesh(L, by, bx, s, step):
    z = L['z']; csq = L['csq']
    nby, nbx = step.shape
    zb = z[by * csq:(by + 1) * csq + 1, bx * csq:(bx + 1) * csq + 1].astype(np.float64)
    idx = np.arange(0, csq + 1, s)
    g = zb[np.ix_(idx, idx)].copy()
    m = len(idx)

    def nb(dy, dx):
        y, x = by + dy, bx + dx
        if 0 <= y < nby and 0 <= x < nbx and step[y, x] > 0:
            return step[y, x]
        return 0

    def pin(line, full_line, s2):
        # samples at multiples of s2 stay; the rest lie on the straight edge
        if s2 <= s:
            return line
        k = s2 // s
        out = line.copy()
        for a in range(0, m - 1, k):
            b = a + k
            for j in range(1, k):
                f = j / k
                out[a + j] = line[a] * (1 - f) + line[b] * f
        return out

    g[0, :] = pin(g[0, :], None, nb(-1, 0))
    g[-1, :] = pin(g[-1, :], None, nb(1, 0))
    g[:, 0] = pin(g[:, 0], None, nb(0, -1))
    g[:, -1] = pin(g[:, -1], None, nb(0, 1))
    X = L['x0'] + (bx * csq + idx) * L['dx']
    Y = L['y0'] + (by * csq + idx) * L['dy']
    XX, YY = np.meshgrid(X, Y)
    pos = ugeo.to_gltf_points(np.stack([XX.ravel(), YY.ravel(), g.ravel()], axis=1))
    # normals from the full-resolution heights (smooth shading)
    gy, gx = np.gradient(z[by * csq:(by + 1) * csq + 1, bx * csq:(bx + 1) * csq + 1]
                         .astype(np.float64), L['dy'], L['dx'])
    gx = gx[np.ix_(idx, idx)].ravel(); gy = gy[np.ix_(idx, idx)].ravel()
    n_ue = np.stack([-gx, -gy, np.ones_like(gx)], axis=1)
    n_ue /= np.linalg.norm(n_ue, axis=1, keepdims=True)
    nrm = ugeo.to_gltf_dirs(n_ue)
    r, c = np.meshgrid(np.arange(m - 1), np.arange(m - 1), indexing='ij')
    v00 = (r * m + c).ravel(); v01 = v00 + 1; v10 = v00 + m; v11 = v10 + 1
    # glTF x = Unreal X (columns), z = Unreal Y (rows): CCW seen from +y
    tri = np.concatenate([np.stack([v00, v10, v01], 1), np.stack([v01, v10, v11], 1)])
    return pos.astype(np.float32), nrm.astype(np.float32), tri.astype(np.uint32).ravel()
