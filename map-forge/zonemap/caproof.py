"""Cap rooms that never had a roof.

CS maps are sealed by one shell high above the playing area, so a mapper only
has to roof what a 1.8 m player can see from inside. Whole interiors are left
open at the top: on de_cache **15,669 m2 of the map's 16,000 m2 footprint has
nothing above it but that shell**, and among the yards and streets that is
supposed to cover are genuine rooms - walls, doorways, a strip light on the
wall, and open sky where the ceiling should be. A player never notices. A drone
flies in over the wall and is then inside a sealed box.

There is nothing to recover here: the roof does not exist in the BSP, so the
only options are to invent one or to leave the hole. This module invents one,
and only for spaces small enough to be a room.

The test is deliberately blunt because the distinction is a judgement call:
a cell is *enclosed* when, looking out in 8 directions within `radius`, at
least 7 find geometry `rise` metres taller. That catches rooms, and it also
catches alleys and yards - so the patches are grouped and only those under
`max_area_m2` are capped. de_cache's rooms run 10-60 m2; its yards run 100-800.
"""
import collections
import numpy as np
from . import build as BU


def _height_grid(chunks, cell, x0, z0, nx, nz):
    """Topmost surface height per cell, and the material it came from.

    Point-in-triangle, not bounding boxes. Filling a triangle's bbox floods a
    whole room with the height of the roof triangle next to it, which made the
    room look solid and the detector find nothing at all.
    """
    T = np.full((nx, nz), np.nan)
    MAT = np.empty((nx, nz), object)
    for c in chunks:
        pos, idx = c[2].astype(np.float64), c[5]
        tri = pos[np.asarray(idx).reshape(-1)].reshape(-1, 3, 3)
        if not len(tri):
            continue
        a, b, d = tri[:, 0], tri[:, 1], tri[:, 2]
        n = np.cross(b - a, d - a)
        ln = np.linalg.norm(n, axis=1)
        ok = (ln > 1e-9)
        ok &= np.divide(n[:, 1], np.where(ln > 0, ln, 1)) > 0.5
        den = ((b[:, 2] - d[:, 2]) * (a[:, 0] - d[:, 0])
               + (d[:, 0] - b[:, 0]) * (a[:, 2] - d[:, 2]))
        ok &= np.abs(den) > 1e-9
        for k in np.flatnonzero(ok):
            A, B, D = a[k], b[k], d[k]
            i0 = max(0, int((min(A[0], B[0], D[0]) - x0) / cell))
            i1 = min(nx - 1, int((max(A[0], B[0], D[0]) - x0) / cell))
            j0 = max(0, int((min(A[2], B[2], D[2]) - z0) / cell))
            j1 = min(nz - 1, int((max(A[2], B[2], D[2]) - z0) / cell))
            if i1 < i0 or j1 < j0:
                continue
            gi = np.arange(i0, i1 + 1)
            gj = np.arange(j0, j1 + 1)
            px = x0 + (gi + 0.5) * cell
            pz = z0 + (gj + 0.5) * cell
            PX, PZ = np.meshgrid(px, pz, indexing='ij')
            de = den[k]
            w0 = ((B[2] - D[2]) * (PX - D[0]) + (D[0] - B[0]) * (PZ - D[2])) / de
            w1 = ((D[2] - A[2]) * (PX - D[0]) + (A[0] - D[0]) * (PZ - D[2])) / de
            w2 = 1.0 - w0 - w1
            inside = (w0 >= -1e-9) & (w1 >= -1e-9) & (w2 >= -1e-9)
            if not inside.any():
                continue
            y = w0 * A[1] + w1 * B[1] + w2 * D[1]
            sub = T[i0:i1 + 1, j0:j1 + 1]
            m = inside & (np.isnan(sub) | (y > sub))
            if m.any():
                sub[m] = y[m]
                MAT[i0:i1 + 1, j0:j1 + 1][m] = c[0]
    return T, MAT


def find_open_rooms(chunks, scale=BU.UNIT, cell=1.0, rise=2.5, radius=6.0,
                    max_area_m2=80.0, min_area_m2=4.0, sides=7):
    """-> [(cells, floor_y, cap_y, material)] for each room that wants a lid."""
    if not chunks:
        return [], {}
    allp = np.concatenate([c[2] for c in chunks])
    x0, z0 = float(allp[:, 0].min()), float(allp[:, 2].min())
    nx = int((float(allp[:, 0].max()) - x0) / cell) + 2
    nz = int((float(allp[:, 2].max()) - z0) / cell) + 2
    if nx * nz > 4_000_000:
        return [], {'cap_skipped_too_big': 1}
    T, MAT = _height_grid(chunks, cell, x0, z0, nx, nz)
    have = ~np.isnan(T)
    R = max(1, int(round(radius / cell)))
    dirs = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))
    enclosed = np.zeros((nx, nz), bool)
    wall = np.full((nx, nz), np.nan)
    for i in range(nx):
        for j in range(nz):
            if not have[i, j]:
                continue
            t = T[i, j]
            hits, tops = 0, []
            for du, dv in dirs:
                for s in range(1, R + 1):
                    u, v = i + du * s, j + dv * s
                    if u < 0 or v < 0 or u >= nx or v >= nz:
                        break
                    if have[u, v] and T[u, v] > t + rise:
                        hits += 1
                        tops.append(T[u, v])
                        break
            if hits >= sides:
                enclosed[i, j] = True
                wall[i, j] = float(np.median(tops))
    lab = np.zeros((nx, nz), bool)
    out = []
    stats = collections.Counter()
    for i in range(nx):
        for j in range(nz):
            if not enclosed[i, j] or lab[i, j]:
                continue
            stack, cells = [(i, j)], []
            while stack:
                u, v = stack.pop()
                if (u < 0 or v < 0 or u >= nx or v >= nz
                        or lab[u, v] or not enclosed[u, v]):
                    continue
                lab[u, v] = True
                cells.append((u, v))
                stack += [(u + 1, v), (u - 1, v), (u, v + 1), (u, v - 1)]
            area = len(cells) * cell * cell
            if area < min_area_m2:
                stats['cap_too_small'] += 1
                continue
            if area > max_area_m2:
                stats['cap_too_big_probably_a_yard'] += 1
                continue
            cap = float(np.median([wall[u, v] for u, v in cells]))
            floor = float(np.median([T[u, v] for u, v in cells]))
            mats = collections.Counter(MAT[u, v] for u, v in cells
                                       if MAT[u, v] is not None)
            out.append((cells, floor, cap, mats.most_common(1)[0][0] if mats else None))
            stats['cap_rooms'] += 1
            stats['cap_area_m2'] += int(area)
    return out, (dict(stats) | {'cap_cell': cell, 'cap_x0': x0, 'cap_z0': z0})


def cap_chunks(rooms, cell, x0, z0, material=None):
    """Turn each room's cells into one flat quad per cell, facing up."""
    made = []
    for cells, floor, cap, mat in rooms:
        pos, nrm, uv, idx = [], [], [], []
        n = 0
        for (u, v) in cells:
            x, z = x0 + u * cell, z0 + v * cell
            q = np.array([[x, cap, z], [x + cell, cap, z],
                          [x + cell, cap, z + cell], [x, cap, z + cell]])
            pos += [q[0], q[1], q[2], q[0], q[2], q[3]]
            nrm += [[0, 1, 0]] * 6
            uv += [[x, z], [x + cell, z], [x + cell, z + cell],
                   [x, z], [x + cell, z + cell], [x, z + cell]]
            n += 6
        made.append((material or mat or 'z_concrete2',
                     (0, 0, 0),
                     np.array(pos, np.float32),
                     np.array(nrm, np.float32),
                     (np.array(uv, np.float32) * (1.0 / 2.0)),
                     np.arange(n, dtype=np.uint32).reshape(-1, 3)))
    return made
