"""Unreal -> glTF transforms and an indexed, cell-chunked mesh accumulator."""
import math, collections, numpy as np

# Unreal is left-handed, Z up, in centimetres; glTF is right-handed, Y up, in
# metres. Swapping Y and Z is a reflection, which is exactly the change of
# handedness: x = X, y = Z, z = Y.
P = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]])
CM = 0.01


def quat_matrix(x, y, z, w):
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def rotator_matrix(pitch, yaw, roll):
    """FRotator (degrees) -> 3x3 acting on column vectors"""
    sp, cp = math.sin(math.radians(pitch)), math.cos(math.radians(pitch))
    sy, cy = math.sin(math.radians(yaw)), math.cos(math.radians(yaw))
    sr, cr = math.sin(math.radians(roll)), math.cos(math.radians(roll))
    rows = np.array([
        [cp * cy, cp * sy, sp],
        [sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp],
        [-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp]])
    return rows.T


def trs(t=(0, 0, 0), r=None, s=(1, 1, 1)):
    """4x4 (Unreal space): translate * rotate * scale"""
    m = np.eye(4)
    rm = np.eye(3) if r is None else r
    m[:3, :3] = rm @ np.diag(s)
    m[:3, 3] = t
    return m


def ftransform(d):
    """a JSON FTransform {Rotation{X,Y,Z,W}, Translation{X,Y,Z}, Scale3D{X,Y,Z}}"""
    q = d.get('Rotation', {}); t = d.get('Translation', {}); s = d.get('Scale3D', {})
    return trs((t.get('X', 0), t.get('Y', 0), t.get('Z', 0)),
               quat_matrix(q.get('X', 0), q.get('Y', 0), q.get('Z', 0), q.get('W', 1)),
               (s.get('X', 1), s.get('Y', 1), s.get('Z', 1)))


def relative(props):
    """a SceneComponent's RelativeLocation/Rotation/Scale3D -> 4x4"""
    loc = props.get('RelativeLocation', (0, 0, 0))
    rot = props.get('RelativeRotation', (0, 0, 0))
    scl = props.get('RelativeScale3D', (1, 1, 1))
    if not (isinstance(loc, tuple) and len(loc) == 3):
        loc = (0, 0, 0)
    if not (isinstance(rot, tuple) and len(rot) == 3):
        rot = (0, 0, 0)
    if not (isinstance(scl, tuple) and len(scl) == 3):
        scl = (1, 1, 1)
    return trs(loc, rotator_matrix(*rot), scl)


def to_gltf_points(p):
    """(N,3) Unreal cm -> glTF m"""
    p = np.asarray(p, np.float64)
    return np.stack([p[:, 0], p[:, 2], p[:, 1]], axis=1) * CM


def to_gltf_dirs(n):
    n = np.asarray(n, np.float64)
    return np.stack([n[:, 0], n[:, 2], n[:, 1]], axis=1)


def gltf_matrix(m):
    """4x4 Unreal (cm) -> 4x4 glTF (m), acting on glTF-space mesh vertices"""
    g = np.eye(4)
    g[:3, :3] = P @ m[:3, :3] @ P.T
    g[:3, 3] = P @ m[:3, 3] * CM
    return g


def mat_to_quat(R):
    t = R[0, 0] + R[1, 1] + R[2, 2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        w = 0.25 * s; x = (R[2, 1] - R[1, 2]) / s
        y = (R[0, 2] - R[2, 0]) / s; z = (R[1, 0] - R[0, 1]) / s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = math.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        w = (R[2, 1] - R[1, 2]) / s; x = 0.25 * s
        y = (R[0, 1] + R[1, 0]) / s; z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = math.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        w = (R[0, 2] - R[2, 0]) / s; x = (R[0, 1] + R[1, 0]) / s
        y = 0.25 * s; z = (R[1, 2] + R[2, 1]) / s
    else:
        s = math.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        w = (R[1, 0] - R[0, 1]) / s; x = (R[0, 2] + R[2, 0]) / s
        y = (R[1, 2] + R[2, 1]) / s; z = 0.25 * s
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    return [x / n, y / n, z / n, w / n]


def decompose(g, tol=1e-3):
    """glTF 4x4 -> (t, quat, scale) or None when it needs shear or a mirror"""
    L = g[:3, :3]
    s = np.linalg.norm(L, axis=0)
    if (s < 1e-9).any() or np.linalg.det(L) <= 0:
        return None
    R = L / s
    if np.abs(R.T @ R - np.eye(3)).max() > tol:
        return None
    return g[:3, 3].copy(), mat_to_quat(R), s


def apply(g, pos, nrm):
    """bake a glTF 4x4 into points and normals; flips winding if mirrored"""
    L = g[:3, :3]
    p = pos @ L.T + g[:3, 3]
    try:
        N = np.linalg.inv(L).T
    except np.linalg.LinAlgError:
        N = L
    n = nrm @ N.T
    ln = np.linalg.norm(n, axis=1, keepdims=True)
    n = n / np.where(ln < 1e-12, 1.0, ln)
    return p, n, np.linalg.det(L) < 0


class Chunks:
    """Indexed geometry keyed by (material, cell); each add() is one whole
    piece (an instance), placed in the cell of its centre so it stays in one
    mesh."""

    def __init__(self, cell_m=48.0, keep_pieces=True):
        self.cell = cell_m
        self.data = collections.defaultdict(lambda: {'pos': [], 'nrm': [], 'uv': [], 'idx': [], 'n': 0})
        self.keep_pieces = keep_pieces
        self.pieces = []            # (pos, idx) of each solid piece, for decals

    def add(self, mat, pos, nrm, uv, idx, centre=None, surface=True):
        if len(idx) == 0:
            return
        pos = np.asarray(pos, np.float32)
        idx = np.asarray(idx, np.uint32).reshape(-1)
        if surface and self.keep_pieces:
            self.pieces.append((pos, idx))
        c = np.asarray(centre if centre is not None else pos.mean(axis=0))
        key = (mat, tuple(int(x) for x in np.floor(c / self.cell)))
        d = self.data[key]
        d['pos'].append(pos)
        d['nrm'].append(np.asarray(nrm, np.float32))
        d['uv'].append(np.asarray(uv, np.float32))
        d['idx'].append(idx + d['n'])
        d['n'] += len(pos)

    def finish(self):
        out = []
        for (mat, cell), d in sorted(self.data.items(), key=lambda kv: (kv[0][0], kv[0][1])):
            out.append((mat, cell, np.concatenate(d['pos']), np.concatenate(d['nrm']),
                        np.concatenate(d['uv']), np.concatenate(d['idx'])))
        return out

    def tris(self):
        return sum(sum(len(i) for i in d['idx']) // 3 for d in self.data.values())


def box_uv(pos, nrm, idx, tile_m):
    """world-aligned (triplanar) mapping: each triangle takes the plane its
    face normal is closest to; corners shared across planes are split.
    -> (pos, nrm, uv, idx)"""
    t = idx.reshape(-1, 3)
    a, b, c = pos[t[:, 0]], pos[t[:, 1]], pos[t[:, 2]]
    fn = np.cross(b - a, c - a)
    ax = np.argmax(np.abs(fn), axis=1)
    keys = t * 3 + ax[:, None]
    uk, inv = np.unique(keys.reshape(-1), return_inverse=True)
    vi = uk // 3; va = uk % 3
    p = pos[vi]; n = nrm[vi]
    u = np.where(va == 0, p[:, 2], p[:, 0])
    v = np.where(va == 1, p[:, 2], p[:, 1])
    uv = np.stack([u, -v], axis=1) / float(tile_m)
    return p, n, uv.astype(np.float32), inv.astype(np.uint32)


def _clip(poly, axis, sign):
    """Sutherland-Hodgman against the plane sign*p[axis] <= 1"""
    out = []
    n = len(poly)
    for i in range(n):
        a = poly[i]; b = poly[(i + 1) % n]
        da = sign * a[axis] - 1.0; db = sign * b[axis] - 1.0
        if da <= 0:
            out.append(a)
        if (da <= 0) != (db <= 0):
            t = da / (da - db)
            out.append(a + (b - a) * t)
    return out


def project_decal(M, t, sources, offset=0.012):
    """Cut a decal out of the surfaces it covers.

    M, t: glTF world = M @ q + t for q in the decal's box [-1, 1]^3 (its
    local X is the projection axis). sources: [(pos, idx)] world triangles.
    -> (pos, nrm, uv, idx) world, lifted `offset` m off the surface. The
    image's down runs along local +Y (the map editor stands wall decals with
    +Y pointing down) and its right along whichever of local +-Z is the
    right-hand side seen from in front of the surface it lands on, so that
    lettering reads the right way round whichever way X was pointed.

    The decal goes on the surfaces facing one way along X: whichever way
    covers more of the box (the map editor points X into a floor, but walls
    come both ways)."""
    Minv = np.linalg.inv(M)
    xdir = M[:, 0] / max(np.linalg.norm(M[:, 0]), 1e-12)
    picks = []
    for pos, idx in sources:
        q = (pos.astype(np.float64) - t) @ Minv.T
        tri = idx.reshape(-1, 3)
        tq = q[tri]
        inside = (tq.min(axis=1) <= 1.0).all(axis=1) & (tq.max(axis=1) >= -1.0).all(axis=1)
        if not inside.any():
            continue
        tw = pos[tri[inside]].astype(np.float64)
        fn = np.cross(tw[:, 1] - tw[:, 0], tw[:, 2] - tw[:, 0])
        ln = np.linalg.norm(fn, axis=1)
        ok = ln > 1e-12
        fn = fn[ok] / ln[ok, None]
        picks.append((tq[inside][ok], fn))
    if not picks:
        return None
    TQ = np.concatenate([p[0] for p in picks]); FN = np.concatenate([p[1] for p in picks])
    face = FN @ xdir
    full = (np.abs(TQ) <= 1.0).all(axis=(1, 2))
    W_ = TQ @ M.T
    area = np.linalg.norm(np.cross(W_[:, 1] - W_[:, 0], W_[:, 2] - W_[:, 0]), axis=1) / 2
    # pick the side by the area it would cover (a partly-inside triangle
    # counts half) and cut only that one
    best, best_a, us = None, 0.0, 1.0
    for sel, sign in ((face < -0.5, 1.0), (face > 0.5, -1.0)):
        a = float(area[sel & full].sum() + 0.5 * area[sel & ~full].sum())
        if sel.any() and a > best_a * 1.05:
            best, best_a, us = sel, a, sign
    if best is None:
        return None
    got = _cut(TQ[best], FN[best], M, t, offset, us)
    return None if got is None else got[:4]


def _cut(TQ, FN, M, t, offset, us=1.0):
    P_, N_, U_, I_ = [], [], [], []
    area = 0.0
    # triangles wholly inside the box need no clipping
    full = (np.abs(TQ) <= 1.0).all(axis=(1, 2))
    if full.any():
        q = TQ[full].reshape(-1, 3)
        fn = np.repeat(FN[full], 3, axis=0)
        P_.append(q @ M.T + t + fn * offset); N_.append(fn)
        U_.append(np.stack([(1 + us * q[:, 2]) * 0.5, (q[:, 1] + 1) * 0.5], axis=1))
        I_.append(np.arange(len(q)))
        area += 1.0
    base = sum(len(p) for p in P_)
    for tq, fn in zip(TQ[~full], FN[~full]):
        poly = [tq[0], tq[1], tq[2]]
        for ax in range(3):
            for sg in (1.0, -1.0):
                poly = _clip(poly, ax, sg)
                if len(poly) < 3:
                    break
            if len(poly) < 3:
                break
        if len(poly) < 3:
            continue
        qp = np.array(poly)
        w = qp @ M.T + t
        k = len(qp)
        tri = np.array([(0, j, j + 1) for j in range(1, k - 1)])
        a = np.linalg.norm(np.cross(w[tri[:, 1]] - w[tri[:, 0]], w[tri[:, 2]] - w[tri[:, 0]]), axis=1).sum() / 2
        if a < 1e-6:
            continue
        area += a
        P_.append(w + fn * offset); N_.append(np.tile(fn, (k, 1)))
        U_.append(np.stack([(1 + us * qp[:, 2]) * 0.5, (qp[:, 1] + 1) * 0.5], axis=1))
        I_.append((tri + base).reshape(-1))
        base += k
    if not P_:
        return None
    P = np.concatenate(P_); N = np.concatenate(N_); U = np.concatenate(U_)
    I = np.concatenate(I_)
    # weld: the cut keeps every triangle's own corners, three times the
    # vertices a decal on a tessellated floor needs
    key = np.round(np.concatenate([P * 1000.0, N * 100.0], axis=1)).astype(np.int64)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return (P[first].astype(np.float32), N[first].astype(np.float32),
            U[first].astype(np.float32), inv.reshape(-1)[I].astype(np.uint32), area)
