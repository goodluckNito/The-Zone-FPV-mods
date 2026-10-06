#!/usr/bin/env python3
"""Bake a map's original lighting into a .glb that has since been edited.

`forge.py --bake-lightmaps` works off BSP faces. The moment geometry only
exists in the .glb - a roof closed by hand in Blender, a pillar modelled from
scratch - that path is gone: there is no BSP face to read luxels from, and the
.bsp on disk no longer matches what you fly.

This bakes the .glb itself:

  * every world mesh is cut into planar charts and given its own patch of a
    shared atlas;
  * each texel samples the mesh's OWN material texture through its OWN UVs, so
    hand-unwrapped geometry bakes exactly as it currently looks;
  * the light comes from the original .bsp, looked up in world space;
  * props and any mesh used by more than one node are left alone - they are
    instanced, and baking would make every copy unique.

    python tools/bake_glb.py edited.glb --bsp maps/de_cache.bsp -o baked.glb

The .glb is metres, Y-up and recentred; the .bsp is Hammer units, Z-up, at its
own origin. `convert_report.json` (written beside every build) carries the
`scale_m_per_unit` and `origin_shift` that relate them, and is picked up
automatically from beside the input .glb. Without it the shift is estimated
from the two bounding boxes - always check the reported `exact` percentage,
which is how much of the map found a real BSP face underneath. It should be
high; a few per cent means the alignment is wrong.

Light for geometry the BSP knows nothing about comes, in order: from a
same-facing face on the same plane (an extended roof matches its neighbours
seam for seam), else from the nearest same-facing lit surface, else from a
coarse grid of the map's own luxels, so a new pillar in a dim room comes out
dim and one in a lit atrium comes out bright.
"""
import argparse, collections, json, math, os, re, struct, sys, time
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from zonemap import bsp as B
from zonemap.glb import Glb
from zonemap.materials import _srgb_to_lin, _lin_to_srgb, _png, _jpg
from zonemap.lightmap import (_decode, EXPOSURE_PCT, LIGHT_FLOOR,
                              LIGHT_FULL, BRIGHTNESS, KNEE_AT, KNEE_FLAT,
                              tonemap, ZONE_FLAT_NORMAL, ZONE_FLAT_GAIN,
                              ZONE_NOSPEC_NORMAL, ZONE_NOSPEC_GAIN,
                              ZONE_LOW_NORMAL, ZONE_LOW_GAIN,
                              ZONE_MID_NORMAL, ZONE_MID_GAIN,
                              ZONE_BAKED_ROUGHNESS, ZONE_BEST_SKY_ROTATION,
                              ZONE_NOSPEC_GAMMA)

PAD = 2
TEXEL_MIN_M, TEXEL_MAX_M, TEXEL_K = 0.03, 0.30, 48.0
MAT_PREFIX = '#lm'
GRID_UNITS = 128.0
DISP_CELL = 512.0        # displacement lookup grid, Hammer units
DISP_PAD = 256.0         # how far a displacement may rise off its base quad

CT = {5120: 'i1', 5121: 'u1', 5122: '<i2', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


# ------------------------------------------------------------------ glTF in
class GlbIn:
    def __init__(self, path):
        f = open(path, 'rb')
        assert f.read(4) == b'glTF', f'not a .glb: {path}'
        struct.unpack('<II', f.read(8))
        self.j, self.bin = None, b''
        while True:
            h = f.read(8)
            if len(h) < 8:
                break
            ln, ty = struct.unpack('<II', h)
            d = f.read(ln)
            if ty == 0x4E4F534A:
                self.j = json.loads(d)
            else:
                self.bin = d
        f.close()

    def acc(self, i):
        a = self.j['accessors'][i]
        v = self.j['bufferViews'][a['bufferView']]
        off = v.get('byteOffset', 0) + a.get('byteOffset', 0)
        n = NC[a['type']]
        arr = np.frombuffer(self.bin, CT[a['componentType']],
                            count=a['count'] * n, offset=off)
        arr = arr.reshape(a['count'], n) if n > 1 else arr
        if a.get('normalized') and arr.dtype != np.float32:
            arr = arr.astype(np.float32) / np.iinfo(arr.dtype).max
        return arr

    def view_bytes(self, i):
        v = self.j['bufferViews'][i]
        o = v.get('byteOffset', 0)
        return self.bin[o:o + v['byteLength']]

    def image_bytes(self, i):
        im = self.j['images'][i]
        if 'bufferView' in im:
            return self.view_bytes(im['bufferView']), im.get('mimeType', 'image/png')
        raise ValueError('external image URIs are not supported')

    def mat_albedo_image(self, mi):
        if mi is None or mi < 0:
            return None
        pbr = self.j['materials'][mi].get('pbrMetallicRoughness', {})
        t = pbr.get('baseColorTexture')
        if t is None:
            return None
        tex = self.j['textures'][t['index']]
        return tex.get('source')


def node_matrix(n):
    if 'matrix' in n:
        return np.array(n['matrix'], np.float64).reshape(4, 4).T
    M = np.eye(4)
    if 'scale' in n:
        M[:3, :3] = M[:3, :3] @ np.diag(n['scale'])
    if 'rotation' in n:
        x, y, z, w = n['rotation']
        R = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        M[:3, :3] = R @ M[:3, :3]
    if 'translation' in n:
        M[:3, 3] = n['translation']
    return M


def decompose(M):
    t = M[:3, 3].tolist()
    A = M[:3, :3]
    s = [float(np.linalg.norm(A[:, i])) or 1.0 for i in range(3)]
    R = A / np.array(s)[None, :]
    tr = R[0, 0] + R[1, 1] + R[2, 2]
    if tr > 0:
        w = math.sqrt(1 + tr) / 2
        x = (R[2, 1] - R[1, 2]) / (4 * w)
        y = (R[0, 2] - R[2, 0]) / (4 * w)
        z = (R[1, 0] - R[0, 1]) / (4 * w)
    else:
        i = int(np.argmax([R[0, 0], R[1, 1], R[2, 2]]))
        if i == 0:
            d = math.sqrt(max(1e-12, 1 + R[0, 0] - R[1, 1] - R[2, 2])) * 2
            w, x, y, z = (R[2, 1] - R[1, 2]) / d, d / 4, (R[0, 1] + R[1, 0]) / d, (R[0, 2] + R[2, 0]) / d
        elif i == 1:
            d = math.sqrt(max(1e-12, 1 + R[1, 1] - R[0, 0] - R[2, 2])) * 2
            w, x, y, z = (R[0, 2] - R[2, 0]) / d, (R[0, 1] + R[1, 0]) / d, d / 4, (R[1, 2] + R[2, 1]) / d
        else:
            d = math.sqrt(max(1e-12, 1 + R[2, 2] - R[0, 0] - R[1, 1])) * 2
            w, x, y, z = (R[1, 0] - R[0, 1]) / d, (R[0, 2] + R[2, 0]) / d, (R[1, 2] + R[2, 1]) / d, d / 4
    return t, [float(x), float(y), float(z), float(w)], s


# ------------------------------------------------------------------- light
class LightField:
    """Valve's lightmap, queryable at any world point."""

    def __init__(self, bsp, verbose=True):
        self.bsp = bsp
        raw = bsp.lump(8)
        if not len(raw):
            raw = bsp.lump(53)
        self.raw = raw
        self.by_plane = collections.defaultdict(list)
        self.grid = {}
        self.by_cell = collections.defaultdict(list)
        self._cellcache = {}
        self._nearcache = {}
        f = bsp.faces
        acc = collections.defaultdict(lambda: [np.zeros(3), 0])
        self.faces = []
        for fi in range(len(f)):
            if int(f[fi]['lightofs']) < 0:
                continue
            loop = bsp.face_loop(fi)
            if len(loop) < 3:
                continue
            lm = self._luxels(fi)
            if lm is None:
                continue
            q = bsp.verts[loop].astype(np.float64)
            pn = np.array(bsp.planes[int(f[fi]['planenum'])]['normal'], np.float64)
            d = float(pn @ q[0])
            ti = bsp.texinfo[int(f[fi]['texinfo'])]
            rec = (pn, d, np.asarray(ti['lm_vecs'], np.float64),
                   np.asarray(f[fi]['lm_mins'], np.float64), lm, q.mean(0),
                   q.min(0), q.max(0))
            idx = len(self.faces)
            self.faces.append(rec)
            ax = int(np.argmax(np.abs(pn)))
            self.by_plane[(ax, 1 if pn[ax] >= 0 else -1,
                           int(round(d / 16.0)))].append(idx)
            if int(f[fi]['dispinfo']) >= 0:
                # A displacement's geometry is nowhere near its face plane, so
                # a plane lookup never finds it - and de_aztec is mostly
                # terrain. Its lightmap axes are the texture axes, which for a
                # ground quad are horizontal, so the DISPLACED point still maps
                # to the right luxel; only the plane test has to go. Index it
                # by the cells its base quad covers instead.
                lo = np.floor((q.min(0) - DISP_PAD) / DISP_CELL).astype(int)
                hi = np.floor((q.max(0) + DISP_PAD) / DISP_CELL).astype(int)
                for cx in range(lo[0], hi[0] + 1):
                    for cy in range(lo[1], hi[1] + 1):
                        for cz in range(lo[2], hi[2] + 1):
                            self.by_cell[(cx, cy, cz)].append(idx)
            c = rec[5]
            k = tuple(np.floor(c / GRID_UNITS).astype(int))
            a = acc[k]
            a[0] += lm.reshape(-1, 3).mean(0)
            a[1] += 1
        self.grid = {k: v[0] / max(v[1], 1) for k, v in acc.items()}
        self.gridkeys = np.array(list(self.grid.keys()), np.int64) if self.grid \
            else np.zeros((0, 3), np.int64)
        self.gridvals = np.array(list(self.grid.values()), np.float64) if self.grid \
            else np.zeros((0, 3), np.float64)
        self.median = (np.median(self.gridvals, axis=0) if len(self.gridvals)
                       else np.ones(3))
        if verbose:
            print(f'      light: {len(self.faces)} lit faces, '
                  f'{len(self.grid)} grid cells')

    def _luxels(self, fi):
        f = self.bsp.faces[fi]
        off = int(f['lightofs'])
        w = int(f['lm_size'][0]) + 1
        h = int(f['lm_size'][1]) + 1
        if w < 1 or h < 1 or off + w * h * 4 > len(self.raw):
            return None
        try:
            return _decode(self.raw[off:off + w * h * 4], w * h).reshape(h, w, 3)
        except ValueError:
            return None

    @staticmethod
    def _lux(rec, pts):
        lv, mins = rec[2], rec[3]
        s = pts @ lv[0, :3] + lv[0, 3] - mins[0]
        t = pts @ lv[1, :3] + lv[1, 3] - mins[1]
        return s, t

    @staticmethod
    def _bilinear(lm, s, t):
        h, w = lm.shape[:2]
        s = np.clip(s, 0, w - 1); t = np.clip(t, 0, h - 1)
        x0 = np.floor(s).astype(np.int64); y0 = np.floor(t).astype(np.int64)
        x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
        fx = (s - x0)[:, None]; fy = (t - y0)[:, None]
        a = lm[y0, x0] * (1 - fx) + lm[y0, x1] * fx
        b = lm[y1, x0] * (1 - fx) + lm[y1, x1] * fx
        return a * (1 - fy) + b * fy

    def sample(self, pts, n, stats=None):
        """(N,3) Hammer-space points on a plane with normal `n` -> (N,3) light."""
        out = np.zeros((len(pts), 3), np.float64)
        todo = np.ones(len(pts), bool)
        n = np.asarray(n, np.float64)
        ax = int(np.argmax(np.abs(n)))
        sg = 1 if n[ax] >= 0 else -1
        d = pts @ n
        dk = int(round(float(np.median(d)) / 16.0))
        cand = []
        for k in (dk - 1, dk, dk + 1):
            cand += self.by_plane.get((ax, sg, k), [])
        for fi in cand:
            if not todo.any():
                break
            rec = self.faces[fi]
            if rec[0] @ n < 0.99:
                continue
            near = todo & (np.abs(d - rec[1]) < 2.0)
            if not near.any():
                continue
            s, t = self._lux(rec, pts[near])
            h, w = rec[4].shape[:2]
            inside = (s >= -0.75) & (t >= -0.75) & (s <= w - 0.25) & (t <= h - 0.25)
            if not inside.any():
                continue
            sel = np.nonzero(near)[0][inside]
            out[sel] = self._bilinear(rec[4], s[inside], t[inside])
            todo[sel] = False
        if todo.any():
            self._disp_pass(pts, out, todo)
        if stats is not None:
            stats['exact'] += int((~todo).sum())
        if todo.any():
            out[todo] = self._fallback(pts[todo], n, ax, sg, stats)
            if stats is not None:
                stats['inexact'] += int(todo.sum())
        return out

    def _disp_pass(self, pts, out, todo):
        seen = set()
        key = np.floor(pts / DISP_CELL).astype(np.int64)
        for k in map(tuple, np.unique(key, axis=0)):
            for fi in self.by_cell.get(k, ()):
                if fi in seen or not todo.any():
                    continue
                seen.add(fi)
                rec = self.faces[fi]
                near = todo & (pts >= rec[6] - DISP_PAD).all(1) \
                    & (pts <= rec[7] + DISP_PAD).all(1)
                if not near.any():
                    continue
                s, t = self._lux(rec, pts[near])
                h, w = rec[4].shape[:2]
                inside = (s >= -0.75) & (t >= -0.75) & (s <= w - 0.25) & (t <= h - 0.25)
                if not inside.any():
                    continue
                sel = np.nonzero(near)[0][inside]
                out[sel] = self._bilinear(rec[4], s[inside], t[inside])
                todo[sel] = False

    def _fallback(self, pts, n, ax, sg, stats=None):
        """Nearest same-facing lit surface, else the grid."""
        out = np.zeros((len(pts), 3), np.float64)
        d = pts @ n
        dk = int(round(float(np.median(d)) / 16.0))
        cen = pts.mean(0)
        # memoised: this scan is per-texel-group and was the slowest thing in
        # the bake, repeated for every chart standing on the same shell
        ck = (ax, sg, dk, int(cen[0] // 256), int(cen[1] // 256), int(cen[2] // 256))
        hit = self._nearcache.get(ck, 0)
        if hit != 0:
            best, bestd = hit
        else:
            best = None
            bestd = 1e18
            for k in range(dk - 8, dk + 9):          # +-128 units
                for fi in self.by_plane.get((ax, sg, k), []):
                    rec = self.faces[fi]
                    if rec[0] @ n < 0.9:
                        continue
                    dist = float(np.linalg.norm(rec[5] - cen))
                    if dist < bestd:
                        bestd, best = dist, rec
            self._nearcache[ck] = (best, bestd)
        if best is not None and bestd < 512.0:
            s, t = self._lux(best, pts)
            h, w = best[4].shape[:2]
            out[:] = self._bilinear(best[4], np.clip(s, 0, w - 1),
                                    np.clip(t, 0, h - 1))
            if stats is not None:
                stats['near'] += len(pts)
            return out
        if self.grid:
            # one lookup per distinct cell, not per texel: a chart's texels
            # nearly all land in the same cell, and scanning every cell per
            # point was the slowest thing in the bake
            key = np.floor(pts / GRID_UNITS).astype(np.int64)
            uniq, inv = np.unique(key, axis=0, return_inverse=True)
            vals = np.empty((len(uniq), 3))
            for i, k in enumerate(map(tuple, uniq)):
                vals[i] = self._cell(k)
            out[:] = vals[inv]
            if stats is not None:
                stats['grid'] += len(pts)
        else:
            out[:] = self.median
        return out

    def _cell(self, k, max_r=6):
        hit = self._cellcache.get(k)
        if hit is not None:
            return hit
        for r in range(max_r + 1):
            best, bd = None, 1e18
            for dx in range(-r, r + 1):
                for dy in range(-r, r + 1):
                    for dz in range(-r, r + 1):
                        if r and max(abs(dx), abs(dy), abs(dz)) != r:
                            continue
                        v = self.grid.get((k[0] + dx, k[1] + dy, k[2] + dz))
                        if v is not None:
                            d = dx * dx + dy * dy + dz * dz
                            if d < bd:
                                bd, best = d, v
            if best is not None:
                self._cellcache[k] = best
                return best
        self._cellcache[k] = self.median
        return self.median


# ------------------------------------------------------------------ charts
def plane_basis(n):
    a = np.zeros(3)
    a[int(np.argmin(np.abs(n)))] = 1.0
    u = np.cross(n, a)
    u /= np.linalg.norm(u)
    return u, np.cross(n, u)


class Chart:
    __slots__ = ('tris', 'n', 'org', 'u', 'v', 's0', 't0', 'tw', 'th',
                 'texel', 'page', 'x', 'y', 'prim', 'lit')


def build_charts(P, tris, dot_tol=0.94, slab=0.25):
    """Grow triangles into near-planar charts.

    Not a hash of (normal, distance): bucketing splits a floor wherever it
    crosses a bucket boundary, and de_aztec came out as 28,397 two-triangle
    charts. Not strict coplanarity either - displacement terrain is subdivided
    per blend band, so no two triangles are exactly coplanar and every one
    would be its own tile.

    So: region growing. A chart starts at one triangle and swallows its
    neighbours while they stay within `dot_tol` of the chart's running average
    normal AND within `slab` metres of its plane. The angle bound keeps the
    projection from stretching (20 degrees is 6 % at the edge); the thickness
    bound stops a staircase merging into one enormous sparse tile.
    """
    a, b, c = P[tris[:, 0]], P[tris[:, 1]], P[tris[:, 2]]
    cr = np.cross(b - a, c - a)
    ln = np.linalg.norm(cr, axis=1)
    ok = ln > 1e-12
    nn = cr / np.where(ln[:, None] == 0, 1, ln[:, None])
    cen = (a + b + c) / 3.0

    at = collections.defaultdict(list)
    for i in np.nonzero(ok)[0]:
        for vi in tris[i]:
            at[tuple(np.round(P[vi] * 1000).astype(np.int64))].append(int(i))
    nb = collections.defaultdict(set)
    for _, group in at.items():
        for x in group:
            nb[x].update(group)

    done = np.zeros(len(tris), bool)
    done[~ok] = True
    order = np.argsort(-ln)
    out = []
    for seed in order:
        seed = int(seed)
        if done[seed]:
            continue
        nsum = nn[seed] * ln[seed]
        org = cen[seed]
        members = [seed]
        done[seed] = True
        queue = list(nb[seed])
        while queue:
            i = queue.pop()
            if done[i]:
                continue
            navg = nsum / np.linalg.norm(nsum)
            if nn[i] @ navg < dot_tol:
                continue
            if abs(float((cen[i] - org) @ navg)) > slab:
                continue
            done[i] = True
            members.append(i)
            nsum = nsum + nn[i] * ln[i]
            queue.extend(nb[i] - set(members))
        ch = Chart()
        ch.tris = np.array(members)
        ch.n = nsum / np.linalg.norm(nsum)
        out.append(ch)
    return out


def shelf_pack(charts, page_px, is_alpha=None):
    """Pack charts into pages, opaque first, alpha-tested onto pages of their
    own. A page is one texture and one material, so a cut-out leaf cannot share
    a page with a wall: the wall pages stay JPEG, and only the pages that need
    a cut-out pay for RGBA PNG."""
    st = {'page': 0, 'x': 0, 'y': 0, 'shelf': 0}
    used, apages = set(), set()
    if is_alpha is None:
        is_alpha = [False] * len(charts)
    for want in (False, True):
        idxs = [i for i in range(len(charts)) if bool(is_alpha[i]) is want]
        if not idxs:
            continue
        if want and used:
            st['page'] += 1
            st['x'] = st['y'] = st['shelf'] = 0
        for i in sorted(idxs, key=lambda i: -charts[i].th):
            ch = charts[i]
            bw, bh = ch.tw + 2 * PAD, ch.th + 2 * PAD
            if st['x'] + bw > page_px:
                st['x'] = 0
                st['y'] += st['shelf']
                st['shelf'] = 0
            if st['y'] + bh > page_px:
                st['page'] += 1
                st['x'] = st['y'] = st['shelf'] = 0
            ch.page, ch.x, ch.y = st['page'], st['x'] + PAD, st['y'] + PAD
            st['x'] += bw
            st['shelf'] = max(st['shelf'], bh)
            used.add(ch.page)
            if want:
                apages.add(ch.page)
    return sorted(used), sorted(apages)


def mips_of(img, keep_alpha=False):
    mode = 'RGBA' if keep_alpha else 'RGB'
    out = [np.asarray(img.convert(mode), np.float32)]
    cur = img.convert(mode)
    while min(cur.size) > 1:
        cur = cur.resize((max(1, cur.width // 2), max(1, cur.height // 2)), Image.BOX)
        out.append(np.asarray(cur, np.float32))
    return out


def sample_tex(tex, u, v):
    h, w = tex.shape[:2]
    x = np.mod((u * w).astype(np.int64), w)
    y = np.mod((v * h).astype(np.int64), h)
    return tex[y, x]


def dilate(rgb, mask, rounds=3):
    """Grow the covered texels outward, so a chart edge never samples black."""
    out = rgb.copy()
    m = mask.copy()
    for _ in range(rounds):
        if m.all():
            break
        acc = np.zeros_like(out)
        cnt = np.zeros(m.shape, np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            s = np.roll(np.roll(out, dy, 0), dx, 1)
            w = np.roll(np.roll(m, dy, 0), dx, 1).astype(np.float32)
            acc += s * w[:, :, None]
            cnt += w
        new = (~m) & (cnt > 0)
        out[new] = acc[new] / cnt[new][:, None]
        m = m | new
    return out


def load_bsp(spec, mapname=None):
    if spec.lower().endswith('.gma'):
        from zonemap.gma import Gma
        arc = Gma(spec)
        maps = arc.maps()
        if not maps:
            raise SystemExit(f'no .bsp inside {spec}')
        pick = maps[0][0]
        if mapname:
            want = os.path.splitext(os.path.basename(mapname))[0].lower()
            pick = next((m for m, _ in maps
                         if os.path.splitext(os.path.basename(m))[0] == want), pick)
        print(f'[1/5] reading {pick} from the archive')
        return B.Bsp(pick, data=arc.read(pick))
    return B.Bsp(spec)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('glb', help='the edited .glb to bake')
    ap.add_argument('--bsp', required=True, help='the original .bsp or .gma')
    ap.add_argument('--map', help='which map inside a .gma')
    ap.add_argument('--report', help='convert_report.json (default: beside the .glb)')
    ap.add_argument('-o', '--out', help='output .glb (default: <name>_baked.glb)')
    ap.add_argument('--texel', type=float, default=4.0, metavar='CM',
                    help='atlas density in cm per texel (default 4). 0 picks '
                         'it per chart from sqrt(area)/48, which suits the '
                         'face-sized tiles of the BSP bake but goes coarse '
                         'here, where a chart can be a whole wall')
    ap.add_argument('--page', type=int, default=2048)
    ap.add_argument('--unlit-texel', type=float, default=16.0, metavar='CM',
                    help='density for large surfaces with no lightmap under '
                         'them at all - the rebuilt outer shell (default 16)')
    ap.add_argument('--unlit-area', type=float, default=20.0, metavar='M2',
                    help='how big an unlit chart must be to get that coarser '
                         'density (default 20)')
    ap.add_argument('--budget', type=float, default=128.0, metavar='M',
                    help='soft cap on atlas size in millions of texels '
                         '(default 128, about 1 MB of JPEG per 4 M). '
                         'Density is coarsened to fit; 0 = off')
    ap.add_argument('--exposure', type=float, default=None, metavar='L',
                    help=f'the light value that counts as fully lit (default '
                         f'{LIGHT_FULL:.0f}, which is what Source means by a '
                         'lightmap of 255 with its overbright of 2). Lower it '
                         'to brighten the map')
    ap.add_argument('--brightness', type=float, default=BRIGHTNESS,
                    metavar='F',
                    help='multiplier on the light before that (default 1.0). '
                         'Anchoring on a percentile instead left the baked '
                         'atlas at p50 19/255 against the source textures at '
                         '112, and the game pulled it back up until the '
                         'sunlit faces bloomed')
    ap.add_argument('--jpeg-q', type=int, default=90)
    ap.add_argument('--roughness-min', type=float,
                    default=ZONE_BAKED_ROUGHNESS, metavar='F',
                    help='floor on every material roughness in the output, '
                         'props included (default 0.9), and metallic to 0. '
                         'The game gives an imported material a GGX lobe that '
                         'its own baked maps never get, and below about 0.5 '
                         'that lobe is most of the pixel at the mirror angle - '
                         'the wet-plastic look. 0 leaves both alone')
    ap.add_argument('--cycles', action='store_true',
                    help="bake the light in Blender's Cycles instead of "
                         "reading Valve's lightmap: the map's own light "
                         'entities are rebuilt as Blender lights and the '
                         'irradiance is path-traced, which brings ambient '
                         'occlusion, soft shadows and colour bleed that a '
                         '2004 radiosity solve does not have')
    ap.add_argument('--blender', help='path to blender (searched if omitted)')
    ap.add_argument('--samples', type=int, default=128,
                    help='Cycles samples per texel (default 128)')
    ap.add_argument('--bounces', type=int, default=4)
    ap.add_argument('--point-scale', type=float, default=1.0, metavar='F',
                    help='multiplier on point/spot lights against the sun')
    ap.add_argument('--sun-scale', type=float, default=1.0, metavar='F')
    ap.add_argument('--no-occluders', action='store_true',
                    help='leave props out of the Cycles scene. Much smaller '
                         'and much faster, and every shadow they cast is lost')
    ap.add_argument('--flat-normals', nargs='?', const='auto', default=None,
                    metavar='X,Y,Z',
                    help='point every baked surface the same way so the baked '
                         'light is what renders, instead of the game lighting '
                         'the map a second time. Default "auto" is the one '
                         'direction the game responds to flatly: it faces '
                         'away from the only shadow-casting sun, so the '
                         "realtime shadow drops out and cannot leak through a "
                         'roof. Presets, dimmest and cleanest first: nospec '
                         '(no specular at all, white tops out at 123), low '
                         '(145, a faint 16/255 lobe), mid (160, 28/255), auto '
                         '(217, the 108/255 blob). Or give x,y,z yourself')
    ap.add_argument('--normal-blend', type=float, default=0.0, metavar='T',
                    help='mix T of each face\'s real normal back into the flat '
                         'one (0 = fully flat, 1 = untouched). A shared normal '
                         'makes every specular lobe line up into one map-wide '
                         'blob; any T > 0 aims each surface differently. Costs '
                         'evenness: T=0.25 swings the game\'s multiplier 1.4x '
                         'across orientations, T=0.5 swings it 5x, T=1 swings '
                         'it 100x because a ceiling gets no sky at all')
    ap.add_argument('--flat-gain', type=float, default=None, metavar='F',
                    help=f'gain on the finished albedo x light, to undo the '
                         f'constant the game multiplies a flat-normal surface '
                         f'by. Defaults to {ZONE_FLAT_GAIN} (1/0.45) with '
                         f'--flat-normals and 1.0 without. This is NOT '
                         f'--brightness: that one scales the light before the '
                         f'tone curve and so lifts the shadows, this one '
                         f'scales the finished pixel and so lifts the whole '
                         f'map, clipping the brightest albedo toward white')
    ap.add_argument('--force', action='store_true',
                    help='bake even if the input is already a baked build')
    ap.add_argument('--install', nargs='?', const='auto', metavar='DIR',
                    help="copy the result into The Zone's custom_maps as "
                         '<name>/<name>.glb with the manifest beside it. The '
                         'game loads custom_maps/<folder>/<folder>.glb, so a '
                         'file whose name does not match its folder loads as '
                         'an empty map')
    ap.add_argument('--reuse-bake', metavar='DIR',
                    help='load the light pages from an earlier --keep-scene '
                         'run instead of baking again. The bake does not '
                         'depend on --brightness or --flat-normals, so this '
                         'turns dialling those in from a four-minute loop '
                         'into a one-minute one. Only valid if nothing about '
                         'the charts changed (same --texel, --budget, --page)')
    ap.add_argument('--light-gamma', type=float, default=None, metavar='G',
                    help=f'lift the finished pixel by pow(v, G) in linear '
                         f'space. Under 1 this brightens the midtones and '
                         f'leaves the highlights where they are, which is what '
                         f'a baked map needs: the game passes a fifth of the '
                         f'light and then tonemaps with ACES, whose toe eats '
                         f'the result. Defaults to {ZONE_NOSPEC_GAMMA} with '
                         f'--flat-normals, 1.0 without. Lower is brighter and '
                         f'flatter; 0.45 is about as far as it goes')
    ap.add_argument('--sky-rotation', metavar='DEG',
                    help=f'rewrite the installed manifest\'s sky_rotation. '
                         f'It is the only skybox field the game applies to a '
                         f'custom map, and rotating the panorama rotates the '
                         f'sky ambient with it - which with a nospec normal is '
                         f'the whole of the light. "auto" uses '
                         f'{ZONE_BEST_SKY_ROTATION:.0f}, worth nearly double '
                         f'what de_cpl_strike\'s own 143 gives, for nothing '
                         f'but the visible sun no longer matching the baked '
                         f'shadows')
    ap.add_argument('--drop-material', metavar='SUBSTR',
                    help='delete every primitive whose material name contains '
                         'any of these comma-separated substrings, before '
                         'anything else looks at the map. Nothing is baked or '
                         'written for them, so the chart layout is unchanged '
                         'if they were not being baked anyway - which makes '
                         'this a two-minute A/B against --reuse-bake: drop a '
                         'suspect surface and see whether the thing you are '
                         'chasing goes with it')
    ap.add_argument('--keep-scene', action='store_true',
                    help='keep the intermediate Blender scene and light pages')
    ap.add_argument('--bake-foliage', action='store_true',
                    help='also bake alpha-tested props - trees, vines, ivy, '
                         'hay. Off by default because every leaf card is its '
                         'own chart island: on de_cpl_strike it takes the '
                         'chart count from 9k to about 60k, and the rasterise '
                         'from one minute to fifteen, for geometry that reads '
                         'as foliage catching the light either way')
    ap.add_argument('--no-bake-props', dest='bake_props', action='store_false',
                    help='leave props dynamically lit. They then render at the '
                         'game\'s own multiplier - up to 1.0 against the 0.13 '
                         'a nospec build gives the world, which is why an '
                         'unbaked crate glares next to a baked wall')
    ap.add_argument('--bake-props', dest='bake_props', action='store_true',
                    default=True,
                    help='also bake single-use prop meshes')
    ap.add_argument('--shift', type=float, nargs=3, metavar=('X', 'Y', 'Z'),
                    help="override the report's origin_shift")
    a = ap.parse_args()
    if a.reuse_bake:
        a.cycles = True          # reusing a Cycles bake implies --cycles
    t0 = time.time()

    g = GlbIn(a.glb)
    J = g.j
    if a.drop_material:
        pats = [x.strip().lower() for x in a.drop_material.split(',') if x.strip()]
        drop = {i for i, m in enumerate(J.get('materials', []))
                if any(x in (m.get('name') or '').lower() for x in pats)}
        if drop:
            gone = 0
            for m in J['meshes']:
                keep = [pr for pr in m['primitives']
                        if pr.get('material') not in drop]
                gone += len(m['primitives']) - len(keep)
                m['primitives'] = keep
            names = sorted(J['materials'][i].get('name', '?') for i in drop)
            print(f'[1/5] --drop-material: removed {gone} primitives from '
                  f'{len(drop)} material(s): {", ".join(names[:4])}'
                  f'{" ..." if len(names) > 4 else ""}')
        else:
            print(f'[1/5] --drop-material {a.drop_material!r} matched nothing')
    print(f'[1/5] {os.path.basename(a.glb)}: {len(J["meshes"])} meshes, '
          f'{len(J.get("materials", []))} materials, {len(J["nodes"])} nodes')

    # Light in, light out. A .glb built with forge.py --bake-lightmaps already
    # carries the lightmap in its albedo; baking it again multiplies the two
    # and the map comes out black in the corners and blown out in the middle.
    already = [m.get('name', '') for m in J.get('materials', [])
               if re.match(r'^(src_)?#?lm\d+$', str(m.get('name', '')))]
    if already and not a.force:
        raise SystemExit(
            f'{os.path.basename(a.glb)} is already a baked build - it has '
            f'{len(already)} atlas materials ({", ".join(already[:3])}...).\n'
            '  Baking it again applies the light twice. Convert without\n'
            '  --bake-lightmaps and bake that .glb instead:\n'
            f'    forge.py <map> --roughness-min 0.9\n'
            f'    tools/bake_glb.py <that .glb> --bsp <map.bsp> --cycles\n'
            '  (--force overrides this.)')

    # ---- how this .glb relates to the .bsp -------------------------------
    scale, shift = 0.0254, np.zeros(3)
    rep = a.report or os.path.join(os.path.dirname(os.path.abspath(a.glb)),
                                   'convert_report.json')
    if os.path.isfile(rep):
        r = json.load(open(rep))
        scale = float(r.get('scale_m_per_unit', scale))
        shift = np.array(r.get('origin_shift', [0, 0, 0]), np.float64)
        print(f'[1/5] {os.path.basename(rep)}: scale {scale}, '
              f'origin_shift {shift.round(2).tolist()}')
    else:
        print(f'[1/5] no convert_report.json beside the .glb - the origin shift '
              f'will be estimated from the bounding boxes')
    if a.shift:
        shift = np.array(a.shift, np.float64)

    bsp = load_bsp(a.bsp, a.map)
    light = LightField(bsp)

    # ---- walk the scene --------------------------------------------------
    nodes = J['nodes']
    if a.bake_props:
        # De-instance. Two placements of the same crate stand in different
        # light, so they cannot share one atlas region. Give every node its own
        # mesh entry - the copies share accessors, so this costs a dict here
        # and duplicated vertex data only in the output (de_cpl_strike: 54,650
        # unique prop triangles become 188,495, which is nothing at 120 fps).
        seen = set()
        for nd in nodes:
            mi = nd.get('mesh')
            if mi is None:
                continue
            if mi in seen:
                J['meshes'].append(dict(J['meshes'][mi]))
                nd['mesh'] = len(J['meshes']) - 1
            else:
                seen.add(mi)
    users = collections.Counter(n['mesh'] for n in nodes if 'mesh' in n)
    wm = {}

    def walk(i, M):
        Mi = M @ node_matrix(nodes[i])
        wm[i] = Mi
        for c in nodes[i].get('children', ()):
            walk(c, Mi)

    for rt in J['scenes'][J.get('scene', 0)]['nodes']:
        walk(rt, np.eye(4))

    bake_prims = []            # (mesh, prim, world pos, nrm, uv, tris, matidx)
    skipped = collections.Counter()
    for ni, n in enumerate(nodes):
        mi = n.get('mesh')
        if mi is None:
            continue
        if users[mi] > 1:
            skipped['instanced'] += 1
            continue
        nm = ((n.get('name') or '') + '|' + (J['meshes'][mi].get('name') or '')).lower()
        is_prop = 'prop_' in nm or nm.startswith('prop')
        if not a.bake_props and is_prop:
            skipped['prop'] += 1
            continue
        if a.bake_props and is_prop:
            skipped['prop_baked'] += 1
        M = wm.get(ni, np.eye(4))
        for pi, pr in enumerate(J['meshes'][mi]['primitives']):
            at = pr['attributes']
            if 'POSITION' not in at or 'TEXCOORD_0' not in at:
                skipped['no_uv'] += 1
                continue
            if not a.bake_foliage and is_prop:
                # Only PROP foliage is skipped. Alpha-tested WORLD geometry -
                # ivy sheets, fences, grates - is a handful of flat charts and
                # has to stay baked: de_cpl_strike hangs 1,588 m2 of
                # alpha-blended ivy canopy over its courtyards, and leaving
                # that dynamically lit puts a bright translucent veil with
                # hard brush edges across everything underneath it.
                _m = pr.get('material')
                if _m is not None and (J['materials'][_m]
                                       .get('alphaMode', 'OPAQUE') != 'OPAQUE'):
                    skipped['prop_foliage'] += 1
                    continue
            P = g.acc(at['POSITION']).astype(np.float64)
            P = P @ M[:3, :3].T + M[:3, 3]
            N = (g.acc(at['NORMAL']).astype(np.float64) @ M[:3, :3].T
                 if 'NORMAL' in at else None)
            UV = g.acc(at['TEXCOORD_0']).astype(np.float64)
            idx = (g.acc(pr['indices']).astype(np.int64).reshape(-1, 3)
                   if 'indices' in pr else
                   np.arange(len(P), dtype=np.int64).reshape(-1, 3))
            bake_prims.append([mi, pi, P, N, UV, idx, pr.get('material')])
    print(f'[2/5] baking {len(bake_prims)} primitives; skipped '
          f'{dict(skipped)}')

    if not bake_prims:
        raise SystemExit('nothing to bake')

    if not os.path.isfile(rep) and not a.shift:
        allp = np.concatenate([b[2] for b in bake_prims])
        gc = (allp.min(0) + allp.max(0)) / 2
        v = bsp.verts.astype(np.float64)
        bc = (v.min(0) + v.max(0)) / 2
        bc_glb = np.array([bc[0], bc[2], -bc[1]]) * scale
        shift = gc - bc_glb
        print(f'[2/5] estimated origin_shift {shift.round(2).tolist()}')

    def to_src(P):
        return np.stack([(P[:, 0] - shift[0]) / scale,
                         -(P[:, 2] - shift[2]) / scale,
                         (P[:, 1] - shift[1]) / scale], axis=1)

    def dir_to_src(n):
        return np.array([n[0], -n[2], n[1]], np.float64)

    # ---- charts ----------------------------------------------------------
    # Chart per MATERIAL, not per primitive. The converter chunks the world by
    # (material, 48 m cell), so one floor arrives as twenty primitives; charting
    # each on its own turns it into twenty tiles, each paying its own gutter.
    groups = collections.defaultdict(list)
    for bp in bake_prims:
        groups[bp[6]].append(bp)
    charts = []
    for mat, prims in groups.items():
        Ps, Us, Ts, own = [], [], [], []
        base = 0
        for bp in prims:
            Ps.append(bp[2]); Us.append(bp[4])
            Ts.append(bp[5] + base)
            own += [(bp[0], bp[1], k) for k in range(len(bp[5]))]
            base += len(bp[2])
        grp = {'P': np.concatenate(Ps), 'UV': np.concatenate(Us),
               'T': np.concatenate(Ts), 'own': own, 'mat': mat}
        for ch in build_charts(grp['P'], grp['T']):
            ch.prim = grp
            charts.append(ch)
    # An L-shaped or diagonal chart pays for its whole bounding box, so split
    # the wasteful ones: a long balcony rail merged into one chart can cost
    # twenty times the texels it uses.
    work, charts = charts, []
    for _ in range(5):
        nxt = []
        for ch in work:
            P = ch.prim['P']
            q3 = P[ch.prim['T'][ch.tris]]
            ch.org = q3[0, 0].copy()
            ch.u, ch.v = plane_basis(ch.n)
            s = (q3.reshape(-1, 3) - ch.org) @ ch.u
            t = (q3.reshape(-1, 3) - ch.org) @ ch.v
            ar = float(0.5 * np.linalg.norm(
                np.cross(q3[:, 1] - q3[:, 0], q3[:, 2] - q3[:, 0]), axis=1).sum())
            box = max(s.max() - s.min(), 1e-6) * max(t.max() - t.min(), 1e-6)
            if ar / box >= 0.4 or len(ch.tris) < 6:
                charts.append(ch)
                continue
            cs = s.reshape(-1, 3).mean(1)
            ct = t.reshape(-1, 3).mean(1)
            axis = cs if (s.max() - s.min()) >= (t.max() - t.min()) else ct
            cut = float(np.median(axis))
            m = axis <= cut
            if m.all() or not m.any():
                charts.append(ch)
                continue
            for sub in (m, ~m):
                c2 = Chart()
                c2.tris = ch.tris[sub]
                c2.n = ch.n
                c2.prim = ch.prim
                nxt.append(c2)
        work = nxt
        if not work:
            break
    charts += work

    for ch in charts:
        tri = ch.tris
        P = ch.prim['P']
        pts = P[ch.prim['T'][tri].reshape(-1)]
        ch.org = pts[0].copy()
        ch.u, ch.v = plane_basis(ch.n)
        s = (pts - ch.org) @ ch.u
        t = (pts - ch.org) @ ch.v
        q3 = P[ch.prim['T'][tri]]
        ar = float(0.5 * np.linalg.norm(
            np.cross(q3[:, 1] - q3[:, 0], q3[:, 2] - q3[:, 0]), axis=1).sum())
        texel = (a.texel / 100.0) if a.texel > 0 else float(
            np.clip(math.sqrt(max(ar, 1e-6)) / TEXEL_K, TEXEL_MIN_M, TEXEL_MAX_M))
        # Probe the light before sizing the tile. A big chart that finds no
        # lightmap at all is a --fill slab - the outer shell of the map, the
        # ground skirt - and its light will be one smooth grid value however
        # many texels it gets. de_aztec's world is 228,000 m2 and most of it is
        # exactly that, so giving those a coarse density is the difference
        # between a 40-page atlas and a 12-page one. Small charts keep the fine
        # density, because that is where hand-patched geometry lives.
        probe = q3[:min(6, len(q3)), 0]
        pst = collections.Counter()
        light.sample(to_src(probe), dir_to_src(ch.n), pst)
        ch.lit = pst['exact'] > 0
        if not ch.lit and ar > a.unlit_area:
            texel = max(texel, a.unlit_texel / 100.0)
        ch.texel = texel
        ch.s0, ch.t0 = s.min() - texel, t.min() - texel
        lim = a.page - 2 * PAD
        ch.tw = int(min(lim, max(2, math.ceil((s.max() - ch.s0) / texel) + 1)))
        ch.th = int(min(lim, max(2, math.ceil((t.max() - ch.t0) / texel) + 1)))
        # a chart clamped to the page limit would stretch; shrink its density
        need_w = (s.max() - ch.s0) / texel + 1
        need_h = (t.max() - ch.t0) / texel + 1
        if need_w > lim or need_h > lim:
            ch.texel = texel * max(need_w / lim, need_h / lim)
            ch.s0, ch.t0 = s.min() - ch.texel, t.min() - ch.texel
            ch.tw = int(min(lim, max(2, math.ceil((s.max() - ch.s0) / ch.texel) + 1)))
            ch.th = int(min(lim, max(2, math.ceil((t.max() - ch.t0) / ch.texel) + 1)))
    budget = a.budget * 1e6
    est = sum((c.tw + 2 * PAD) * (c.th + 2 * PAD) for c in charts)
    if budget > 0 and est > budget:
        f = math.sqrt(est / budget)
        print(f'[3/5] atlas would be {est/1e6:.0f} M texels; coarsening '
              f'density x{f:.2f} to fit --budget {a.budget}')
        lim = a.page - 2 * PAD
        for ch in charts:
            ch.texel *= f
            ch.s0 = ch.s0 + 0.0
            ch.tw = int(min(lim, max(2, math.ceil(ch.tw / f))))
            ch.th = int(min(lim, max(2, math.ceil(ch.th / f))))
    def _is_alpha(mi):
        if mi is None:
            return False
        m = J['materials'][mi]
        return m.get('alphaMode', 'OPAQUE') != 'OPAQUE'

    chart_alpha = [_is_alpha(ch.prim['mat']) for ch in charts]
    pages, alpha_pages = shelf_pack(charts, a.page, chart_alpha)
    alpha_pages = set(alpha_pages)
    texels = sum(c.tw * c.th for c in charts)
    print(f'[3/5] {len(charts)} charts -> {len(pages)} x {a.page}px pages '
          f'({texels/1e6:.1f} M texels, {100*texels/(len(pages)*a.page**2):.0f}% full)')

    # ---- render ----------------------------------------------------------
    expo = a.exposure

    # atlas UVs first: the Cycles scene needs them before anything is drawn
    _ = expo
    uvout = {}
    for ch in charts:
        grp = ch.prim
        P, idx = grp['P'], grp['T']
        for k in ch.tris:
            q = P[idx[k]]
            sc_ = (q - ch.org) @ ch.u
            tc_ = (q - ch.org) @ ch.v
            uu = (ch.x + (sc_ - ch.s0) / ch.texel) / a.page
            vv = (ch.y + (tc_ - ch.t0) / ch.texel) / a.page
            om, op, ok_ = grp['own'][int(k)]
            uvout.setdefault((om, op), {})[ok_] = (np.stack([uu, vv], 1), ch.page)

    cyc = None
    cyc_env = None
    if a.cycles:
        cyc, cyc_env = run_cycles(a, g, J, charts, uvout, bake_prims, pages,
                                  bsp, scale, shift)

    # A Source lightmap and a Cycles bake are not in the same units, and
    # exposing one as if it were the other is what turned the big outdoor
    # pages into blank white sheets. A lightmap value is absolute - 128 is
    # "fully lit" because the engine's overbright is 2 - whereas a Cycles
    # DIFFUSE pass with use_pass_color off is irradiance/pi in the scene's own
    # watts. On de_cpl_strike that is sky 129 + sun 829/pi, so "fully lit" is
    # 393, not 128: at 128 the median texel already tonemapped to 0.92 and 71%
    # of page 0 sat above it, which is exactly the blown-out look.
    ref = expo if expo is not None else LIGHT_FULL
    if expo is None and cyc is not None:
        ref = cycles_reference(cyc_env, cyc)
    knee = KNEE_AT
    lgamma = a.light_gamma
    if lgamma is None:
        lgamma = ZONE_NOSPEC_GAMMA if a.flat_normals else 1.0
    fgain = a.flat_gain
    if fgain is None:
        fgain = parse_flat_normal(a.flat_normals)[1] if a.flat_normals else 1.0
    if False:
        if cyc is not None:
            v = np.concatenate([p[p.sum(2) > 0][:, :3].reshape(-1, 3)[::7]
                                for p in cyc.values() if (p.sum(2) > 0).any()]) \
                if any((p.sum(2) > 0).any() for p in cyc.values()) else None
            lm = (v @ np.array([.2126, .7152, .0722])) if v is not None else None
            ref = max(float(np.percentile(lm, EXPOSURE_PCT)), 1e-4) \
                if lm is not None and len(lm) else 1.0
        else:
            lum = []
            for rec in light.faces:
                vv = rec[4].reshape(-1, 3)
                lum.append(vv[::max(1, len(vv) // 32)]
                           @ np.array([.2126, .7152, .0722]))
            ref = max(
                float(np.percentile(np.concatenate(lum), EXPOSURE_PCT)), 1e-4)
    print(f'[3/5] light: fully lit at {ref:.0f}, brightness {a.brightness}, '
          f'flat gain {fgain:.2f}, gamma {lgamma} '
          f'({"Cycles watts" if cyc is not None else "Source lightmap units"})')
    if a.flat_normals:
        _fn = parse_flat_normal(a.flat_normals)[0]
        print(f'[3/5] flat normal {_fn[0]:+.3f},{_fn[1]:+.3f},{_fn[2]:+.3f}'
              f'  roughness {max(a.roughness_min, 0.04):.2f}'
              f'  blend {getattr(a, "normal_blend", 0.0)}'
              f'  (game multiplies the atlas by ~{1.0 / fgain:.2f})')

    imgs = {p: np.zeros((a.page, a.page, 4 if p in alpha_pages else 3),
                        np.uint8) for p in pages}
    mipcache = {}
    stats = collections.Counter()
    for ci, ch in enumerate(charts):
        grp = ch.prim
        P, UV, idx, matidx = grp['P'], grp['UV'], grp['T'], grp['mat']
        want_a = ch.page in alpha_pages
        key = (matidx if matidx is not None else -1, want_a)
        if key not in mipcache:
            src = g.mat_albedo_image(matidx)
            if src is None:
                col = (J['materials'][matidx].get('pbrMetallicRoughness', {})
                       .get('baseColorFactor', [0.7, 0.7, 0.7, 1])
                       if matidx is not None else [0.7, 0.7, 0.7, 1])
                flat = np.zeros((2, 2, 4 if want_a else 3), np.float32)
                flat[:, :, :3] = np.array(col[:3], np.float32) * 255.0
                if want_a:
                    flat[:, :, 3] = 255.0
                mipcache[key] = [flat]
            else:
                data, _mime = g.image_bytes(src)
                import io
                mipcache[key] = mips_of(Image.open(io.BytesIO(data)), want_a)
        mips = mipcache[key]

        tw, th = ch.tw, ch.th
        acc_uv = np.zeros((th, tw, 2))
        acc_p = np.zeros((th, tw, 3))
        acc_n = np.zeros((th, tw, 3))
        mask = np.zeros((th, tw), bool)
        for k in ch.tris:
            tri = idx[k]
            q = P[tri]
            s = (q - ch.org) @ ch.u
            t = (q - ch.org) @ ch.v
            x = (s - ch.s0) / ch.texel
            y = (t - ch.t0) / ch.texel
            x0 = max(0, int(math.floor(x.min())) - 1)
            x1 = min(tw - 1, int(math.ceil(x.max())) + 1)
            y0 = max(0, int(math.floor(y.min())) - 1)
            y1 = min(th - 1, int(math.ceil(y.max())) + 1)
            if x1 < x0 or y1 < y0:
                continue
            gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5,
                                 np.arange(y0, y1 + 1) + 0.5)
            v0 = np.array([x[1] - x[0], y[1] - y[0]])
            v1 = np.array([x[2] - x[0], y[2] - y[0]])
            v2x = gx - x[0]; v2y = gy - y[0]
            den = v0[0] * v1[1] - v1[0] * v0[1]
            if abs(den) < 1e-12:
                continue
            bu = (v2x * v1[1] - v1[0] * v2y) / den
            bv = (v0[0] * v2y - v2x * v0[1]) / den
            e = 0.5 / max(tw, th)
            ins = (bu >= -e) & (bv >= -e) & (bu + bv <= 1 + e)
            if not ins.any():
                continue
            w0 = (1 - bu - bv)[ins]; w1 = bu[ins]; w2 = bv[ins]
            tuv = (UV[tri[0]][None, :] * w0[:, None] + UV[tri[1]][None, :] * w1[:, None]
                   + UV[tri[2]][None, :] * w2[:, None])
            ys = (gy[ins] - 0.5).astype(int); xs = (gx[ins] - 0.5).astype(int)
            tp = (q[0][None, :] * w0[:, None] + q[1][None, :] * w1[:, None]
                  + q[2][None, :] * w2[:, None])
            fn = np.cross(q[1] - q[0], q[2] - q[0])
            fl = np.linalg.norm(fn)
            acc_uv[ys, xs] = tuv
            acc_p[ys, xs] = tp
            acc_n[ys, xs] = fn / fl if fl > 1e-12 else ch.n
            mask[ys, xs] = True
        if not mask.any():
            continue
        wsel = acc_p[mask]
        sel = mask
        # albedo, at the mip matching this chart's density
        tex0 = mips[0]
        # How many source texels one atlas texel covers. Take it from the
        # chart's own (s,t)->(u,v) Jacobian: differencing the tile instead
        # walks over the uncovered texels, reads a huge gradient at every
        # chart edge and pins the whole thing to the 1x1 mip - which is what
        # turned the first render into coloured mush.
        kbig = ch.tris[int(np.argmax(np.linalg.norm(np.cross(
            P[idx[ch.tris]][:, 1] - P[idx[ch.tris]][:, 0],
            P[idx[ch.tris]][:, 2] - P[idx[ch.tris]][:, 0]), axis=1)))]
        q3 = P[idx[kbig]]
        s3 = (q3 - ch.org) @ ch.u
        t3 = (q3 - ch.org) @ ch.v
        A = np.array([[s3[1] - s3[0], t3[1] - t3[0]],
                      [s3[2] - s3[0], t3[2] - t3[0]]])
        duv = np.array([UV[idx[kbig][1]] - UV[idx[kbig][0]],
                        UV[idx[kbig][2]] - UV[idx[kbig][0]]])
        try:
            Jm = np.linalg.solve(A, duv)          # rows: d(uv)/ds, d(uv)/dt
        except np.linalg.LinAlgError:
            Jm = np.zeros((2, 2))
        px = np.abs(Jm) * np.array([tex0.shape[1], tex0.shape[0]])[None, :]
        foot = max(float(px.max()) * ch.texel, 1.0)
        lvl = int(np.clip(round(math.log2(foot)), 0, len(mips) - 1))
        alb = sample_tex(mips[lvl], acc_uv[sel][:, 0], acc_uv[sel][:, 1])
        if cyc is not None:
            # Cycles already baked into this exact tile - no lookup at all
            li = cyc[ch.page][ch.y:ch.y + th, ch.x:ch.x + tw][mask]
            stats['exact'] += int(mask.sum())
        else:
            # the light query is keyed on the TRIANGLE's normal, not the
            # chart's average: a chart is allowed 20 degrees of curvature, and
            # a face only matches its BSP original within about 8
            nsel = acc_n[mask]
            li = np.zeros((len(wsel), 3))
            qn = np.round(nsel * 100).astype(np.int64)
            uq, inv = np.unique(qn, axis=0, return_inverse=True)
            for gi in range(len(uq)):
                m = inv == gi
                li[m] = light.sample(to_src(wsel[m]),
                                     dir_to_src(nsel[m][0]), stats)
        nch = 4 if ch.page in alpha_pages else 3
        out = np.zeros((th, tw, nch), np.float32)
        if nch == 4:
            out[:, :, 3] = 255.0
        a_chan = alb[:, 3] if alb.shape[1] == 4 else None
        alb = alb[:, :3]
        val = _srgb_to_lin(alb) * np.maximum(
            tonemap(li, ref, a.brightness, knee), LIGHT_FLOOR)
        if fgain != 1.0:
            # The gain belongs on the finished pixel, not on the light. The
            # game multiplies ALBEDO by a flat ~0.45, so what has to come back
            # up is albedo x light, not light alone - putting it on the light
            # only pushes the tone curve into its shoulder and washes the
            # lighting out while leaving the map just as dark.
            val = tonemap(val, 1.0, fgain, KNEE_AT)
        if lgamma != 1.0:
            val = np.power(np.clip(val, 0.0, 1.0), lgamma)
        rgb = _lin_to_srgb(np.clip(val, 0, 1)).astype(np.float32)
        if nch == 4:
            # the cut-out is the source texture's own alpha, straight through:
            # lighting a leaf must not change its shape
            ac = a_chan if a_chan is not None else np.full(len(rgb), 255.0)
            out[sel] = np.concatenate([rgb, ac[:, None]], axis=1)
        else:
            out[sel] = rgb
        out = dilate(out, mask)
        page = imgs[ch.page]
        page[ch.y:ch.y + th, ch.x:ch.x + tw] = out.astype(np.uint8)
        for dy in range(1, PAD + 1):
            if ch.y - dy >= 0:
                page[ch.y - dy, ch.x:ch.x + tw] = out[0]
            if ch.y + th + dy - 1 < a.page:
                page[ch.y + th + dy - 1, ch.x:ch.x + tw] = out[-1]
            if ch.x - dy >= 0:
                page[ch.y - PAD:ch.y + th + PAD, ch.x - dy] = \
                    page[ch.y - PAD:ch.y + th + PAD, ch.x]
            if ch.x + tw + dy - 1 < a.page:
                page[ch.y - PAD:ch.y + th + PAD, ch.x + tw + dy - 1] = \
                    page[ch.y - PAD:ch.y + th + PAD, ch.x + tw - 1]
        # atlas UVs for this chart's triangles
        if (ci + 1) % 500 == 0:
            print(f'      {ci+1}/{len(charts)} charts')
    tot = stats['exact'] + stats['inexact']
    if cyc is not None:
        print(f'[4/5] light: Cycles, {len(cyc)} pages, '
              f'{stats["exact"]/1e6:.1f} M texels lit')
    else:
        print(f'[4/5] light lookups: {100*stats["exact"]/max(tot,1):.1f}% exact, '
              f'{stats["near"]} nearest-surface, {stats["grid"]} grid')
    if cyc is None and tot and stats['exact'] / tot < 0.25:
        print('      ! most of the map found no BSP face under it - the origin '
              'shift is probably wrong. Pass --shift or the right --report.')
    write_glb(a, g, imgs, pages, uvout, bake_prims)
    print(f'[5/5] done in {time.time()-t0:.1f}s')


def find_blender(explicit=None):
    import shutil
    if explicit:
        return explicit
    hit = shutil.which('blender')
    if hit:
        return hit
    pats = [r'C:\Program Files\Blender Foundation\Blender *\blender.exe',
            r'C:\Program Files (x86)\Steam\steamapps\common\Blender\blender.exe',
            '/Applications/Blender.app/Contents/MacOS/Blender',
            '/usr/bin/blender', '/usr/local/bin/blender']
    import glob as _g
    got = []
    for pat in pats:
        got += _g.glob(pat)
    if not got:
        raise SystemExit(
            'could not find Blender. Pass --blender "<path to blender.exe>".')
    got.sort()
    return got[-1]          # the newest version found


def copy_materials(g, out, rough_min=0.0):
    """Copy every image and material from the input .glb into `out`.

    `rough_min` floors roughness on the way through and zeroes metallic: both
    feed the specular lobe the game's own baked maps never get.
    """
    J = g.j
    img_map, mat_map = {}, {}

    def copy_image(i):
        if i in img_map:
            return img_map[i]
        data, mime = g.image_bytes(i)
        v = out._view(data)
        out.j['images'].append({'bufferView': v, 'mimeType': mime,
                                'name': J['images'][i].get('name', f'img{i}')})
        out.j['textures'].append({'sampler': 0,
                                  'source': len(out.j['images']) - 1})
        img_map[i] = len(out.j['textures']) - 1
        return img_map[i]

    for mi, m in enumerate(J.get('materials', [])):
        pbr = m.get('pbrMetallicRoughness', {})
        alb = pbr.get('baseColorTexture')
        nrm = m.get('normalTexture')
        ai = copy_image(J['textures'][alb['index']]['source']) if alb else None
        ni = copy_image(J['textures'][nrm['index']]['source']) if nrm else None
        mat_map[mi] = out.material(
            m.get('name', f'mat{mi}'), albedo_tex=ai, normal_tex=ni,
            roughness=max(float(pbr.get('roughnessFactor', 0.85)), rough_min),
            metallic=(0.0 if rough_min > 0
                      else float(pbr.get('metallicFactor', 0.0))),
            base_color=tuple(pbr.get('baseColorFactor', (1, 1, 1, 1))),
            alpha_mode=m.get('alphaMode', 'OPAQUE'),
            double_sided=bool(m.get('doubleSided', False)),
            emissive=tuple(m.get('emissiveFactor')) if m.get('emissiveFactor')
            else None)
    return mat_map


def run_cycles(a, g, J, charts, uvout, bake_prims, pages, bsp, scale, shift):
    """Write a scene, bake it in Blender, and read the light pages back."""
    import subprocess, tempfile
    from zonemap import srclights

    if a.reuse_bake:
        cyc = {}
        for p in pages:
            f = os.path.join(a.reuse_bake, f'page{p}.npy')
            if not os.path.isfile(f):
                raise SystemExit(
                    f'--reuse-bake {a.reuse_bake}: no page{p}.npy. The chart '
                    'layout must match the run that produced it (same '
                    '--texel/--budget/--page).')
            # mmap, not load: 21 pages of 2048^2 float32 is a gigabyte, and
            # numpy short-reads rather than raising when it cannot get it -
            # which surfaces as "cannot reshape array of size 2057184".
            # The rasterise only ever reads one chart's slice at a time.
            cyc[p] = np.load(f, mmap_mode='r')
        print(f'[3/5] reusing {len(cyc)} light pages from {a.reuse_bake}')
        _, env = srclights.collect(bsp, scale=scale, shift=shift,
                                   point_scale=a.point_scale,
                                   sun_scale=a.sun_scale) if bsp else (None, None)
        return cyc, env

    work = (os.path.splitext(a.out or a.glb)[0] + '_cycles') if a.keep_scene \
        else tempfile.mkdtemp(prefix='zonebake_')
    os.makedirs(work, exist_ok=True)
    scene_path = os.path.join(work, 'scene.glb')

    out = Glb(generator='zone-map-forge cycles scene')
    mat_map = copy_materials(g, out, a.roughness_min)
    # The bake runs with use_pass_color off, so a page object's albedo is never
    # read - but its ALPHA is: an alpha-blended bake target comes back empty,
    # which would black out every tree. One opaque material for all of them.
    bake_mat = out.material('lm_bake_target', roughness=1.0, metallic=0.0)

    # one object per page: the bake target has to own a UV set that is inside
    # 0-1 for exactly one image, and splitting by page is the cheapest way
    by_page = collections.defaultdict(lambda: collections.defaultdict(list))
    for ch in charts:
        grp = ch.prim
        for k in ch.tris:
            om, op, ok_ = grp['own'][int(k)]
            uv3, page = uvout[(om, op)][ok_]
            by_page[page][grp['mat']].append((grp['P'][grp['T'][k]],
                                              grp['UV'][grp['T'][k]], uv3))
    nodes = []
    for page, mats in sorted(by_page.items()):
        prims = []
        for mat, tris in mats.items():
            pos = np.concatenate([t[0] for t in tris]).astype(np.float32)
            uv0 = np.concatenate([t[1] for t in tris]).astype(np.float32)
            uv1 = np.concatenate([t[2] for t in tris]).astype(np.float32)
            nrm = np.zeros_like(pos)
            tp = pos.reshape(-1, 3, 3)
            fn = np.cross(tp[:, 1] - tp[:, 0], tp[:, 2] - tp[:, 0])
            fl = np.linalg.norm(fn, axis=1, keepdims=True)
            fn = fn / np.where(fl == 0, 1, fl)
            nrm = np.repeat(fn, 3, axis=0).astype(np.float32)
            idx = np.arange(len(pos), dtype=np.uint32).reshape(-1, 3)
            prims.append((pos, nrm, uv0, idx, bake_mat, uv1))
        nodes.append(out.node(f'bakepage_{page}', mesh=out.mesh(f'bakepage_{page}',
                                                                prims)))
    # occluders: everything the bake does not target still has to cast shadows
    nocc = 0
    if not a.no_occluders:
        users = collections.Counter(n['mesh'] for n in J['nodes'] if 'mesh' in n)
        wm = {}

        def walk(i, M):
            Mi = M @ node_matrix(J['nodes'][i])
            wm[i] = Mi
            for c in J['nodes'][i].get('children', ()):
                walk(c, Mi)
        for rt in J['scenes'][J.get('scene', 0)]['nodes']:
            walk(rt, np.eye(4))
        baked_meshes = {b[0] for b in bake_prims}
        for ni, n in enumerate(J['nodes']):
            mi = n.get('mesh')
            if mi is None or mi in baked_meshes:
                continue
            M = wm.get(ni, np.eye(4))
            prims = []
            for pr in J['meshes'][mi]['primitives']:
                at = pr['attributes']
                if 'POSITION' not in at:
                    continue
                P = g.acc(at['POSITION']).astype(np.float64)
                P = (P @ M[:3, :3].T + M[:3, 3]).astype(np.float32)
                nr = (g.acc(at['NORMAL']).astype(np.float64) @ M[:3, :3].T
                      ).astype(np.float32) if 'NORMAL' in at else \
                    np.tile(np.array([0, 1, 0], np.float32), (len(P), 1))
                uv = (g.acc(at['TEXCOORD_0']).astype(np.float32)
                      if 'TEXCOORD_0' in at else np.zeros((len(P), 2), np.float32))
                idx = (g.acc(pr['indices']).astype(np.uint32).reshape(-1, 3)
                       if 'indices' in pr else
                       np.arange(len(P), dtype=np.uint32).reshape(-1, 3))
                prims.append((P, nr, uv, idx,
                              mat_map.get(pr.get('material'), 0)))
            if prims:
                nodes.append(out.node(f'occ_{ni}',
                                      mesh=out.mesh(f'occ_{ni}', prims)))
                nocc += 1
    root = out.node('scene', children=nodes)
    out.root(root)
    mb = out.save(scene_path) / 1e6
    print(f'[3/5] cycles scene: {len(by_page)} page objects, {nocc} occluders, '
          f'{mb:.0f} MB -> {scene_path}')

    lights, env = srclights.collect(bsp, scale=scale, shift=shift,
                                    point_scale=a.point_scale,
                                    sun_scale=a.sun_scale)
    lj = os.path.join(work, 'lights.json')
    json.dump({'lights': lights, 'env': env, 'page_px': a.page,
               'bounces': a.bounces}, open(lj, 'w'))
    print(f'[3/5] lights: {len(lights)} point/spot'
          + (', sun' if env else ', no light_environment'))

    exe = find_blender(a.blender)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          'bake_cycles_blender.py')
    # --factory-startup: load none of the user's add-ons or preferences. A
    # real Blender install has both, and in background mode they misbehave -
    # this one raised "GPU functions for drawing requires the gpu module to be
    # initialized" at startup and then a handler on depsgraph_update_post that
    # threw AttributeError: 'Scene' object has no attribute 'vs' on EVERY
    # depsgraph update, which during a bake is constant. Nothing here needs a
    # user add-on: glTF import and Cycles are both built in, and the GPU
    # device is selected explicitly rather than read from preferences.
    cmd = [exe, '-b', '--factory-startup', '--disable-autoexec',
           '-P', script, '--', scene_path, lj, work,
           '--samples', str(a.samples)]
    print(f'[3/5] {os.path.basename(exe)} baking {len(by_page)} pages at '
          f'{a.samples} samples, {a.bounces} bounces - this is the slow part.\n'
          f'      Each page prints when it finishes; if the gap between pages '
          f'is minutes, cut --samples or --bounces.', flush=True)
    # Stream it. Capturing meant no sign of life for however long the bake
    # took - and once the lights were fixed and rays actually started bouncing,
    # that became long enough to look like a hang. Read bytes, not text:
    # Blender writes bytes Windows' cp1252 cannot decode, and with text=True
    # that failure lands in subprocess's reader THREAD, so the bake goes on
    # while stdout comes back empty and the traceback looks like a crash.
    t_b = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, bufsize=0)
    tail = collections.deque(maxlen=40)
    for raw_line in iter(proc.stdout.readline, b''):
        line = raw_line.decode('utf-8', 'replace').rstrip()
        tail.append(line)
        if line.startswith('[cycles]') or 'Error' in line or 'error' in line[:40]:
            print(f'      [{time.time()-t_b:5.0f}s] {line}', flush=True)
    proc.stdout.close()
    rc = proc.wait()
    if rc != 0:
        print('\n'.join(tail))
        raise SystemExit(f'blender exited {rc}')
    cyc = {}
    for p in pages:
        f = os.path.join(work, f'page{p}.npy')
        if not os.path.isfile(f):
            raise SystemExit(f'blender produced no page {p} ({f})')
        cyc[p] = np.load(f, mmap_mode='r' if a.keep_scene else None)
    if not a.keep_scene:
        import shutil as _sh
        _sh.rmtree(work, ignore_errors=True)
    return cyc, env


def cycles_reference(env, cyc):
    """"Fully lit", in the units a Cycles DIFFUSE pass comes back in.

    The pass is irradiance / pi - the number the albedo gets multiplied by -
    so a surface under an open sky of radiance S reads S, and one facing the
    sun head-on reads sun_irradiance / pi on top of it. That sum is the
    brightest a diffuse surface gets from the environment, which is what the
    tone curve should call 1.0. Measured against the real bake: page 0 of
    de_cpl_strike peaks at 366.6 and 129 + 829/pi = 393.
    """
    if env and env.get('type') == 'sun':
        # both terms / PI: the sun because the pass is irradiance/PI, and the
        # sky because the world is now fed as radiance (amb / PI), so a surface
        # open to the whole sky reads amb / PI in the pass, not amb.
        return max((float(env.get('energy', 0.0))
                    + float(env.get('ambient', 0.0))) / math.pi, 1e-4)
    # no light_environment (an indoor map): nothing absolute to anchor on, so
    # fall back on the map's own bright end
    lit = [p[p.sum(2) > 0][::17] for p in cyc.values() if (p.sum(2) > 0).any()]
    if not lit:
        return LIGHT_FULL
    v = np.concatenate(lit) @ np.array([.2126, .7152, .0722])
    return max(float(np.percentile(v, EXPOSURE_PCT)), 1e-4)


PRESET_NORMALS = {'auto': (ZONE_FLAT_NORMAL, ZONE_FLAT_GAIN),
                  'default': (ZONE_FLAT_NORMAL, ZONE_FLAT_GAIN),
                  '': (ZONE_FLAT_NORMAL, ZONE_FLAT_GAIN),
                  'nospec': (ZONE_NOSPEC_NORMAL, ZONE_NOSPEC_GAIN),
                  'low': (ZONE_LOW_NORMAL, ZONE_LOW_GAIN),
                  'mid': (ZONE_MID_NORMAL, ZONE_MID_GAIN)}


def parse_flat_normal(spec):
    """'auto' | 'nospec' | 'x,y,z' -> (unit normal, its default gain)."""
    key = str(spec).strip().lower()
    if key in PRESET_NORMALS:
        v, gain = PRESET_NORMALS[key]
        return np.array(v, np.float32), gain
    v = np.array([float(x) for x in str(spec).split(',')], np.float32)
    n = float(np.linalg.norm(v))
    if n <= 1e-9:
        return np.array(ZONE_FLAT_NORMAL, np.float32), ZONE_FLAT_GAIN
    return v / n, ZONE_FLAT_GAIN


def write_glb(a, g, imgs, pages, uvout, bake_prims):
    flat_n = None
    if a.flat_normals:
        flat_n, _ = parse_flat_normal(a.flat_normals)
    blend = float(getattr(a, 'normal_blend', 0.0) or 0.0)
    J = g.j
    out = Glb(generator='zone-map-forge bake_glb (lightmap baked into the albedo)')
    mat_map = copy_materials(g, out, a.roughness_min)

    flat = np.zeros((4, 4, 3), np.uint8)
    flat[:, :, 0] = 128; flat[:, :, 1] = 128; flat[:, :, 2] = 255
    nflat = out.image(_png(Image.fromarray(flat, 'RGB')), 'lm_flat_normal')
    atlas_mat = {}
    npng = 0
    for p in pages:
        name = f'{MAT_PREFIX}{p}'
        arr = imgs[p]
        masked = arr.shape[2] == 4
        if masked:
            # a cut-out cannot survive JPEG, and the loader picks
            # CustomMaterialAlpha off has_alpha(), so this page has to be PNG
            tex = out.image(_png(Image.fromarray(arr, 'RGBA')), name)
            npng += 1
        else:
            tex = out.image(_jpg(Image.fromarray(arr, 'RGB'), a.jpeg_q), name)
        # roughness 1: env_dynamic leaves the sky as the reflection source, so
        # anything smoother turns a dark baked albedo into a mirror of the sky
        # - the "glossy dark areas". There is no gloss worth keeping once the
        # light is in the texture.
        atlas_mat[p] = out.material(name, albedo_tex=tex, normal_tex=nflat,
                                    roughness=max(a.roughness_min, 0.04),
                                    metallic=0.0,
                                    alpha_mode='MASK' if masked else 'OPAQUE',
                                    double_sided=masked)
    if npng:
        print(f'[5/5] {npng} of {len(pages)} pages are cut-out (RGBA PNG)')

    prim_src = {(b[0], b[1]): b for b in bake_prims}
    mesh_map = {}
    for mi, m in enumerate(J['meshes']):
        prims = []
        for pi, pr in enumerate(m['primitives']):
            baked = uvout.get((mi, pi))
            if baked:
                _mi, _pi, P, N, UV, idx, matidx = prim_src[(mi, pi)]
                pos_l = g.acc(pr['attributes']['POSITION']).astype(np.float32)
                nrm_l = (g.acc(pr['attributes']['NORMAL']).astype(np.float32)
                         if 'NORMAL' in pr['attributes'] else None)
                by_page = collections.defaultdict(list)
                for k, (uv3, page) in baked.items():
                    by_page[page].append((k, uv3))
                for page, items in by_page.items():
                    tri = np.array([idx[k] for k, _ in items])
                    uv = np.concatenate([u for _, u in items]).astype(np.float32)
                    pp = pos_l[tri].reshape(-1, 3)
                    nn = (nrm_l[tri].reshape(-1, 3) if nrm_l is not None
                          else np.tile(np.array([0, 1, 0], np.float32), (len(pp), 1)))
                    if flat_n is not None:
                        if blend > 0.0:
                            # keep a trace of the real normal so every surface
                            # aims its specular lobe somewhere different
                            nn = (1.0 - blend) * flat_n[None, :] + blend * nn
                            ln = np.linalg.norm(nn, axis=1, keepdims=True)
                            nn = (nn / np.where(ln < 1e-6, 1.0, ln)
                                  ).astype(np.float32)
                        else:
                            nn = np.tile(flat_n,
                                         (len(pp), 1)).astype(np.float32)
                    ii = np.arange(len(pp), dtype=np.uint32).reshape(-1, 3)
                    prims.append((pp, nn, uv, ii, atlas_mat[page]))
                # triangles no chart claimed (degenerate) are dropped
            else:
                at = pr['attributes']
                pos = g.acc(at['POSITION']).astype(np.float32)
                nrm = (g.acc(at['NORMAL']).astype(np.float32) if 'NORMAL' in at
                       else np.tile(np.array([0, 1, 0], np.float32), (len(pos), 1)))
                uv = (g.acc(at['TEXCOORD_0']).astype(np.float32) if 'TEXCOORD_0' in at
                      else np.zeros((len(pos), 2), np.float32))
                idx = (g.acc(pr['indices']).astype(np.uint32).reshape(-1, 3)
                       if 'indices' in pr else
                       np.arange(len(pos), dtype=np.uint32).reshape(-1, 3))
                mat = mat_map.get(pr.get('material'), None)
                if mat is None:
                    mat = out.material(f'mesh{mi}_p{pi}', roughness=0.9)
                prims.append((pos, nrm, uv, idx, mat))
        if prims:
            mesh_map[mi] = out.mesh(m.get('name', f'mesh{mi}'), prims)

    node_map = {}
    for ni, n in enumerate(J['nodes']):
        t = r = s = None
        if any(k in n for k in ('matrix', 'translation', 'rotation', 'scale')):
            t, r, s = decompose(node_matrix(n))
            if np.allclose(s, 1.0):
                s = None
            if np.allclose(r, [0, 0, 0, 1]):
                r = None
            if np.allclose(t, 0.0):
                t = None
        node_map[ni] = out.node(n.get('name', f'n{ni}'),
                                mesh=mesh_map.get(n.get('mesh')),
                                translation=t, rotation=r, scale=s)
    for ni, n in enumerate(J['nodes']):
        kids = [node_map[c] for c in n.get('children', ()) if c in node_map]
        if kids:
            out.j['nodes'][node_map[ni]]['children'] = kids
    for rt in J['scenes'][J.get('scene', 0)]['nodes']:
        out.root(node_map[rt])

    # the same final pass forge.py makes: 'src_' keeps imported materials
    # clear of the game's z_ substitution table, and the game caches converted
    # materials by resource_name, so every name has to be unique
    from zonemap.convert import slug
    seen = {}
    for mm in out.j['materials']:
        if not mm['name'].startswith(('z_', 'src_')):
            mm['name'] = 'src_' + slug(mm['name'])
        if mm['name'] in seen:
            seen[mm['name']] += 1
            mm['name'] = f"{mm['name']}_{seen[mm['name']]}"
        else:
            seen[mm['name']] = 0

    dest = a.out or os.path.splitext(a.glb)[0] + '_baked.glb'
    n = out.save(dest)
    print(f'[5/5] {dest}  {n/1e6:.1f} MB  ({len(pages)} atlas pages)')
    if a.install:
        import shutil
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from zonemap import locate
        root = (locate.find_zone_custom_maps() if a.install == 'auto'
                else a.install)
        name = os.path.splitext(os.path.basename(dest))[0]
        folder = os.path.join(root, name)
        os.makedirs(folder, exist_ok=True)
        shutil.copy2(dest, os.path.join(folder, name + '.glb'))
        man = os.path.join(os.path.dirname(os.path.abspath(a.glb)), 'manifest.json')
        if os.path.isfile(man):
            out_man = os.path.join(folder, 'manifest.json')
            if a.sky_rotation:
                rot = (ZONE_BEST_SKY_ROTATION
                       if str(a.sky_rotation).strip().lower() == 'auto'
                       else float(a.sky_rotation))
                with open(man) as fh:
                    mj = json.load(fh)
                was = mj.get('skybox', {}).get('sky_rotation')
                for blk in ([mj.get('skybox')] +
                            [v.get('skybox') for v in
                             (mj.get('lighting_variations') or {}).values()]):
                    if isinstance(blk, dict):
                        blk['sky_rotation'] = rot
                with open(out_man, 'w') as fh:
                    json.dump(mj, fh, indent=1)
                print(f'[5/5] sky_rotation {was} -> {rot}')
            else:
                shutil.copy2(man, out_man)
        print(f'[5/5] installed -> {folder}{os.sep}{name}.glb')


if __name__ == '__main__':
    main()
