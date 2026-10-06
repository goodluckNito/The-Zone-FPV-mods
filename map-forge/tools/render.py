"""Tiny numpy z-buffer rasteriser: preview a .glb without a GPU."""
import json, struct, sys, io, math, numpy as np
from PIL import Image

CT = {5120: 'i1', 5121: 'u1', 5122: '<i2', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


class G:
    def __init__(self, path):
        f = open(path, 'rb'); assert f.read(4) == b'glTF'
        struct.unpack('<II', f.read(8))
        self.j = None; self.bin = b''
        while True:
            h = f.read(8)
            if len(h) < 8: break
            ln, ty = struct.unpack('<II', h); d = f.read(ln)
            if ty == 0x4E4F534A: self.j = json.loads(d)
            else: self.bin = d
        f.close()

    def acc(self, i):
        a = self.j['accessors'][i]
        v = self.j['bufferViews'][a['bufferView']]
        off = v.get('byteOffset', 0) + a.get('byteOffset', 0)
        n = NC[a['type']]
        arr = np.frombuffer(self.bin, CT[a['componentType']],
                            count=a['count'] * n, offset=off)
        return arr.reshape(a['count'], n) if n > 1 else arr

    def tex_img_rgba(self, ti):
        t = self.j['textures'][ti]; im = self.j['images'][t['source']]
        v = self.j['bufferViews'][im['bufferView']]
        o = v.get('byteOffset', 0)
        return Image.open(io.BytesIO(self.bin[o:o + v['byteLength']])).convert('RGBA')

    def tex_img(self, ti):
        t = self.j['textures'][ti]; im = self.j['images'][t['source']]
        v = self.j['bufferViews'][im['bufferView']]
        o = v.get('byteOffset', 0)
        return Image.open(io.BytesIO(self.bin[o:o + v['byteLength']])).convert('RGB')


def _trs(n):
    T = np.eye(4)
    if 'matrix' in n:
        return np.array(n['matrix'], np.float64).reshape(4, 4).T
    if 'rotation' in n:
        x, y, z, w = n['rotation']
        T[:3, :3] = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    if 'scale' in n:
        T[:3, :3] = T[:3, :3] @ np.diag(n['scale'])
    if 'translation' in n:
        T[:3, 3] = n['translation']
    return T


def gather(g):
    """Walk the scene graph so node transforms (instanced props) are applied."""
    P, UV, N, M = [], [], [], []
    cache = {}

    def prim_arrays(pr):
        key = id(pr)
        if key not in cache:
            at = pr['attributes']
            p = g.acc(at['POSITION']).astype(np.float32)
            idx = g.acc(pr['indices']).astype(np.int64).reshape(-1, 3)
            nn = g.acc(at['NORMAL']).astype(np.float32) if 'NORMAL' in at else None
            uu = g.acc(at['TEXCOORD_0']).astype(np.float32) if 'TEXCOORD_0' in at else None
            cache[key] = (p[idx].reshape(-1, 3),
                          nn[idx].reshape(-1, 3) if nn is not None
                          else np.zeros((idx.size, 3), np.float32),
                          uu[idx].reshape(-1, 2) if uu is not None
                          else np.zeros((idx.size, 2), np.float32),
                          np.full(len(idx), pr.get('material', -1), np.int32))
        return cache[key]

    def walk(ni, X):
        n = g.j['nodes'][ni]
        X = X @ _trs(n)
        if 'mesh' in n:
            for pr in g.j['meshes'][n['mesh']]['primitives']:
                p, nn, uu, mm = prim_arrays(pr)
                P.append(p @ X[:3, :3].T + X[:3, 3])
                N.append(nn @ X[:3, :3].T)
                UV.append(uu)
                M.append(mm)
        for c in n.get('children', []):
            walk(c, X)

    for r in g.j['scenes'][g.j.get('scene', 0)]['nodes']:
        walk(r, np.eye(4))
    return (np.concatenate(P).astype(np.float32), np.concatenate(N).astype(np.float32),
            np.concatenate(UV), np.concatenate(M))


def render(path, out, W=1200, H=760, mode='iso', tex=True, sun=(-0.45, 0.8, 0.4),
           fov=34.0, alpha_test=True, cull=True, eye_at=None, look_at=None):
    g = G(path)
    P, N, UV, M = gather(g)
    acache = {}
    if alpha_test:
        for mi, mat in enumerate(g.j['materials']):
            if mat.get('alphaMode') not in ('MASK', 'BLEND'):
                continue
            t = mat.get('pbrMetallicRoughness', {}).get('baseColorTexture')
            if not t:
                continue
            im = np.asarray(g.tex_img_rgba(t['index']))[:, :, 3]
            acache[mi] = im
    lo, hi = P.min(0), P.max(0)
    c = (lo + hi) / 2.0
    span = float(np.max(hi - lo))

    if eye_at is not None:
        eye = np.array(eye_at, np.float64); up = np.array([0, 1, 0.])
        c = np.array(look_at, np.float64) if look_at is not None else c
    elif mode == 'top':
        eye = c + np.array([0.01, span * 1.15, 0.01]); up = np.array([0, 0, -1.0])
    elif mode == 'iso':
        eye = c + np.array([span * .60, span * .50, span * .60]); up = np.array([0, 1, 0.])
    else:
        eye = c + np.array([span * .05, span * .10, span * .70]); up = np.array([0, 1, 0.])
    fwd = c - eye; fwd = fwd / np.linalg.norm(fwd)
    right = np.cross(fwd, up); right = right / np.linalg.norm(right)
    up2 = np.cross(right, fwd)
    Vm = np.stack([right, up2, -fwd])
    cam = (P - eye) @ Vm.T
    z = -cam[:, 2]
    ok = z > 1e-3
    zz = np.maximum(z, 1e-3)
    f = 1.0 / math.tan(math.radians(fov))
    px = (cam[:, 0] * f / zz * 0.5 + 0.5) * W
    py = (1 - (cam[:, 1] * f * (float(W) / H) / zz * 0.5 + 0.5)) * H

    S = np.stack([px, py, z], 1).reshape(-1, 3, 3)
    vis = ok.reshape(-1, 3).all(1)
    if cull:
        tp = P.reshape(-1, 3, 3)
        gn = np.cross(tp[:, 1] - tp[:, 0], tp[:, 2] - tp[:, 0])
        facing = ((eye - tp[:, 0]) * gn).sum(1) > 0
        dbl = np.array([g.j['materials'][int(m)].get('doubleSided', False)
                        if m >= 0 else True for m in M], bool)
        vis = vis & (facing | dbl)
    zbuf = np.full((H, W), np.inf, np.float32)
    tid = np.full((H, W), -1, np.int32)
    bar = np.zeros((H, W, 3), np.float32)

    for i in np.flatnonzero(vis):
        a, b, cc = S[i]
        x0 = max(0, int(min(a[0], b[0], cc[0]))); x1 = min(W - 1, int(max(a[0], b[0], cc[0])) + 1)
        y0 = max(0, int(min(a[1], b[1], cc[1]))); y1 = min(H - 1, int(max(a[1], b[1], cc[1])) + 1)
        if x1 < x0 or y1 < y0: continue
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 600000: continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + .5, np.arange(y0, y1 + 1) + .5)
        d = (b[1] - cc[1]) * (a[0] - cc[0]) + (cc[0] - b[0]) * (a[1] - cc[1])
        if abs(d) < 1e-9: continue
        w0 = ((b[1] - cc[1]) * (gx - cc[0]) + (cc[0] - b[0]) * (gy - cc[1])) / d
        w1 = ((cc[1] - a[1]) * (gx - cc[0]) + (a[0] - cc[0]) * (gy - cc[1])) / d
        w2 = 1 - w0 - w1
        m = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not m.any(): continue
        mi_ = int(M[i])
        if mi_ in acache:
            tu = UV.reshape(-1, 3, 2)[i]
            uu = w0 * tu[0, 0] + w1 * tu[1, 0] + w2 * tu[2, 0]
            vv = w0 * tu[0, 1] + w1 * tu[1, 1] + w2 * tu[2, 1]
            A = acache[mi_]
            ah, aw = A.shape
            av = A[(np.mod(vv, 1.0) * (ah - 1)).astype(int),
                   (np.mod(uu, 1.0) * (aw - 1)).astype(int)]
            m = m & (av >= 128)
            if not m.any(): continue
        # perspective-correct weights: interpolate attribute/z, then divide
        iw = np.stack([w0 / a[2], w1 / b[2], w2 / cc[2]])
        isum = iw.sum(0)
        iw = iw / np.where(np.abs(isum) < 1e-12, 1, isum)
        w0, w1, w2 = iw[0], iw[1], iw[2]
        zi = 1.0 / np.maximum(isum, 1e-12)
        sub = zbuf[y0:y1 + 1, x0:x1 + 1]
        upd = m & (zi < sub)
        if not upd.any(): continue
        sub[upd] = zi[upd]
        tid[y0:y1 + 1, x0:x1 + 1][upd] = i
        bar[y0:y1 + 1, x0:x1 + 1][upd] = np.stack([w0, w1, w2], -1)[upd]

    img = np.full((H, W, 3), 0.09, np.float32)
    hit = tid >= 0
    ii = tid[hit]
    bw = bar[hit]
    nrm = (N.reshape(-1, 3, 3)[ii] * bw[:, :, None]).sum(1)
    ln = np.linalg.norm(nrm, axis=1, keepdims=True)
    nrm = nrm / np.where(ln == 0, 1, ln)
    s = np.array(sun, np.float32); s = s / np.linalg.norm(s)
    lam = np.clip(np.abs(nrm @ s), 0, 1) * 0.76 + 0.24

    base = np.full((len(ii), 3), 0.62, np.float32)
    if tex:
        matlist = M[ii]   # M is one entry per triangle
        uvh = (UV.reshape(-1, 3, 2)[ii] * bw[:, :, None]).sum(1)
        cache = {}
        for mi in np.unique(matlist):
            sel = matlist == mi
            if mi < 0: continue
            mat = g.j['materials'][int(mi)]
            pbr = mat.get('pbrMetallicRoughness', {})
            t = pbr.get('baseColorTexture')
            if t is None:
                base[sel] = pbr.get('baseColorFactor', [.6, .6, .6, 1])[:3]; continue
            if t['index'] not in cache:
                cache[t['index']] = np.asarray(g.tex_img(t['index']), np.float32) / 255.0
            T = cache[t['index']]
            th, tw = T.shape[:2]
            u = np.mod(uvh[sel, 0], 1.0) * (tw - 1)
            v = np.mod(uvh[sel, 1], 1.0) * (th - 1)
            base[sel] = T[v.astype(int), u.astype(int)]
    img[hit] = base * lam[:, None]
    img = np.clip(np.clip(img, 0, 1) ** (1 / 2.2), 0, 1)
    Image.fromarray((img * 255).astype(np.uint8)).save(out)
    return dict(tris=len(P) // 3, drawn=int(vis.sum()),
                covered=round(float(hit.mean()), 3),
                bbox=[lo.round(2).tolist(), hi.round(2).tolist()])
