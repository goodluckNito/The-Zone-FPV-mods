"""Make alpha cut-out collision match what you actually see.

The Zone builds a trimesh collider from every visible mesh, and a '-collider'
mesh neither replaces that collider nor hides itself (verified in game). So the
only way to stop a drone hitting a flat pane of empty air beside a tree is to
delete the empty air from the mesh itself.

A foliage card is 2 triangles spanning ~200 m2 at ~16% opacity. Subdividing it
in barycentric space and dropping sub-triangles whose UV footprint contains no
opaque texel leaves the render identical - only fully transparent area goes -
while the collider becomes roughly leaf-shaped.

Only worth doing on big sparse triangles: on de_inferno 90% of the phantom area
sits in 395 triangles, while tree_large's 73,720 tris at 0.09 m2 each are
already finer than the texel grid.
"""
import numpy as np


class OpaqueMask:
    """Integral image over the alpha channel, for 'any opaque texel in box?'."""

    def __init__(self, alpha, cutoff=128, max_px=512):
        a = np.asarray(alpha)
        if max(a.shape) > max_px:            # decimate, keeping 'any opaque'
            fy = max(1, a.shape[0] // max_px)
            fx = max(1, a.shape[1] // max_px)
            h, w = a.shape[0] // fy * fy, a.shape[1] // fx * fx
            a = a[:h, :w].reshape(h // fy, fy, w // fx, fx).max(axis=(1, 3))
        self.op = (a >= cutoff)
        self.h, self.w = self.op.shape
        self.coverage = float(self.op.mean())
        ii = np.zeros((self.h + 1, self.w + 1), np.int64)
        ii[1:, 1:] = np.cumsum(np.cumsum(self.op.astype(np.int64), 0), 1)
        self.ii = ii

    def any_opaque(self, u0, v0, u1, v1):
        """Vectorised box query in UV space. Conservative: True when unsure."""
        span_u = u1 - u0
        span_v = v1 - v0
        wraps = (span_u >= 1.0) | (span_v >= 1.0) | \
                (np.floor(u0) != np.floor(u1)) | (np.floor(v0) != np.floor(v1))
        fu0 = np.mod(u0, 1.0); fv0 = np.mod(v0, 1.0)
        fu1 = fu0 + np.clip(span_u, 0, 1.0); fv1 = fv0 + np.clip(span_v, 0, 1.0)
        x0 = np.clip((fu0 * self.w).astype(np.int64), 0, self.w)
        x1 = np.clip(np.ceil(fu1 * self.w).astype(np.int64), 0, self.w)
        y0 = np.clip((fv0 * self.h).astype(np.int64), 0, self.h)
        y1 = np.clip(np.ceil(fv1 * self.h).astype(np.int64), 0, self.h)
        x1 = np.maximum(x1, x0 + 1); y1 = np.maximum(y1, y0 + 1)
        x1 = np.minimum(x1, self.w); y1 = np.minimum(y1, self.h)
        ii = self.ii
        cnt = ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0]
        return wraps | (cnt > 0)


def trim(pos, nrm, uv, tris, mask, unit=0.0254, min_area_m2=4.0,
         target_m2=0.75, max_k=24):
    """Return (pos, nrm, uv, tris) with transparent area removed.

    pos/nrm/uv are per-corner arrays indexed by `tris` (model units).
    Triangles smaller than min_area_m2 pass through untouched.
    """
    a = pos[tris[:, 0]]; b = pos[tris[:, 1]]; c = pos[tris[:, 2]]
    area = np.linalg.norm(np.cross(b - a, c - a), axis=1) / 2.0 * unit * unit
    big = area >= min_area_m2
    if not big.any():
        return pos, nrm, uv, tris, 0, 0

    keep_small = tris[~big]
    out_p, out_n, out_u, out_t = [pos], [nrm], [uv], [keep_small]
    base = len(pos)
    added = 0

    for ti in np.flatnonzero(big):
        i0, i1, i2 = tris[ti]
        A, B, C = pos[i0], pos[i1], pos[i2]
        nA, nB, nC = nrm[i0], nrm[i1], nrm[i2]
        tA, tB, tC = uv[i0], uv[i1], uv[i2]
        k = int(np.clip(np.ceil(np.sqrt(area[ti] / target_m2)), 2, max_k))

        # barycentric lattice: P(i,j) = A + (B-A)*i/k + (C-A)*j/k, i+j <= k
        ij = np.array([(i, j) for j in range(k + 1) for i in range(k + 1 - j)])
        idx_of = {}
        for n_, (i, j) in enumerate(ij):
            idx_of[(int(i), int(j))] = n_
        s = ij[:, 0] / k; t = ij[:, 1] / k
        P = A + np.outer(s, B - A) + np.outer(t, C - A)
        Nn = nA + np.outer(s, nB - nA) + np.outer(t, nC - nA)
        ln = np.linalg.norm(Nn, axis=1, keepdims=True)
        Nn = Nn / np.where(ln < 1e-9, 1, ln)
        T = tA + np.outer(s, tB - tA) + np.outer(t, tC - tA)

        sub = []
        for j in range(k):
            for i in range(k - j):
                sub.append((idx_of[(i, j)], idx_of[(i + 1, j)], idx_of[(i, j + 1)]))
                if i + j < k - 1:
                    sub.append((idx_of[(i + 1, j)], idx_of[(i + 1, j + 1)],
                                idx_of[(i, j + 1)]))
        sub = np.array(sub, np.int64)
        su = T[sub][:, :, 0]; sv = T[sub][:, :, 1]
        keep = mask.any_opaque(su.min(1), sv.min(1), su.max(1), sv.max(1))
        sub = sub[keep]
        if len(sub) == 0:
            continue
        used, remap = np.unique(sub, return_inverse=True)
        out_p.append(P[used]); out_n.append(Nn[used]); out_u.append(T[used])
        out_t.append(remap.reshape(-1, 3).astype(np.uint32) + base)
        base += len(used)
        added += len(sub)

    return (np.concatenate(out_p), np.concatenate(out_n),
            np.concatenate(out_u).astype(np.float32),
            np.concatenate(out_t).astype(np.uint32),
            int(big.sum()), added)
