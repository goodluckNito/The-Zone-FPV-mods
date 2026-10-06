"""Source engine BSP reader (VBSP v19-v21). Geometry, displacements, entities, static props."""
import struct, lzma, numpy as np, re

L_ENTITIES, L_PLANES, L_TEXDATA, L_VERTEXES = 0, 1, 2, 3
L_TEXINFO, L_FACES, L_EDGES, L_SURFEDGES = 6, 7, 12, 13
L_MODELS, L_DISPINFO, L_DISP_VERTS = 14, 26, 33
L_GAME_LUMP, L_PAKFILE = 35, 40
L_TDSD, L_TDST = 43, 44

# Source 2009+ can LZMA-compress individual lumps. TF2, L4D2, Portal 2 and
# CS:GO all ship maps like this; CS:S does not. A compressed lump starts with
# an lzma_header_t and lump_t.fourCC holds the uncompressed size, so the
# giveaway is a lump whose length is not a multiple of its element size.
LZMA_ID = 0x414D5A4C          # 'LZMA'


def lump_decompress(buf):
    """Decompress a BSP lump if it carries Valve's lzma_header_t.

    struct lzma_header_t { uint id; uint actualSize; uint lzmaSize;
                           uchar properties[5]; }   // 17 bytes, then LZMA1

    Valve strips the 13-byte LZMA-alone header and stores the pieces itself, so
    rebuild it: 5 property bytes + the uncompressed size as a uint64. Passing
    the real size matters because these streams have no end-of-stream marker.
    """
    if len(buf) < 17:
        return buf
    ident, actual, lzma_size = struct.unpack_from('<3I', buf, 0)
    if ident != LZMA_ID:
        return buf
    props = bytes(buf[12:17])
    payload = bytes(buf[17:17 + lzma_size]) if lzma_size else bytes(buf[17:])
    # Valve's encoder declares the size and writes no end-of-stream marker, so
    # the declared size is what terminates the stream. Other encoders (Python's
    # own among them) write the marker and leave the size unknown, and liblzma
    # rejects a stream that has both. Try Valve's way, fall back to the other.
    last = None
    for size in (actual, 0xFFFFFFFFFFFFFFFF):
        try:
            d = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
            out = d.decompress(props + struct.pack('<Q', size) + payload)
            if len(out) >= actual:
                return out[:actual]
            last = ValueError(f'short: got {len(out)}, want {actual}')
        except lzma.LZMAError as ex:
            last = ex
    raise ValueError(f'lzma lump: {last}')


SURF_LIGHT, SURF_SKY2D, SURF_SKY, SURF_WARP = 0x1, 0x2, 0x4, 0x8
SURF_TRANS, SURF_NOPORTAL, SURF_TRIGGER, SURF_NODRAW = 0x10, 0x20, 0x40, 0x80
SURF_HINT, SURF_SKIP, SURF_NOLIGHT = 0x100, 0x200, 0x400

# faces we never want in a flyable map
SKIP_FLAGS = SURF_NODRAW | SURF_SKY | SURF_SKY2D | SURF_HINT | SURF_SKIP | SURF_TRIGGER


class Bsp:
    def __init__(self, path, data=None):
        """`data` lets a map be read straight out of an archive.

        A Garry's Mod Workshop map is a .bsp inside a 1.6 GB .gma, and
        `self.raw` is the whole file in memory either way, so extracting it to
        disk first would only cost a second copy. `path` is then just a label
        for error messages and for the map name.
        """
        self.path = path
        if data is not None:
            self.raw = data
        else:
            with open(path, 'rb') as f:
                self.raw = f.read()
        ident, self.version = struct.unpack_from('<4si', self.raw, 0)
        if ident != b'VBSP':
            raise ValueError(f'not a VBSP file: {ident!r}')
        self.lumps = []
        for i in range(64):
            off, ln, lver, fourcc = struct.unpack_from('<iiii', self.raw, 8 + i * 16)
            self.lumps.append((off, ln, lver, fourcc))
        self._lump_cache = {}
        self.compressed_lumps = []
        self._load()

    def lump(self, i):
        if i in self._lump_cache:
            return self._lump_cache[i]
        off, ln, _, _ = self.lumps[i]
        raw = self.raw[off:off + ln]
        try:
            out = lump_decompress(raw)
        except Exception as ex:
            raise ValueError(f'lump {i}: {ex}') from None
        if out is not raw:
            self.compressed_lumps.append(i)
        self._lump_cache[i] = out
        return out

    def _arr(self, idx, dtype):
        return np.frombuffer(self.lump(idx), dtype=dtype)

    def _load(self):
        self.verts = self._arr(L_VERTEXES, '<3f4').reshape(-1, 3)
        self.planes = np.frombuffer(self.lump(L_PLANES), dtype=np.dtype([
            ('normal', '<3f4'), ('dist', '<f4'), ('type', '<i4')]))
        self.edges = self._arr(L_EDGES, '<u2').reshape(-1, 2)
        self.surfedges = self._arr(L_SURFEDGES, '<i4')

        self.faces = np.frombuffer(self.lump(L_FACES), dtype=np.dtype([
            ('planenum', '<u2'), ('side', 'u1'), ('onnode', 'u1'),
            ('firstedge', '<i4'), ('numedges', '<i2'), ('texinfo', '<i2'),
            ('dispinfo', '<i2'), ('fogvolume', '<i2'), ('styles', 'u1', 4),
            ('lightofs', '<i4'), ('area', '<f4'),
            ('lm_mins', '<2i4'), ('lm_size', '<2i4'), ('origface', '<i4'),
            ('numprims', '<u2'), ('firstprim', '<u2'), ('smoothing', '<u4')]))

        self.texinfo = np.frombuffer(self.lump(L_TEXINFO), dtype=np.dtype([
            ('tex_vecs', '<f4', (2, 4)), ('lm_vecs', '<f4', (2, 4)),
            ('flags', '<i4'), ('texdata', '<i4')]))

        self.texdata = np.frombuffer(self.lump(L_TEXDATA), dtype=np.dtype([
            ('reflectivity', '<3f4'), ('name_id', '<i4'),
            ('width', '<i4'), ('height', '<i4'),
            ('view_width', '<i4'), ('view_height', '<i4')]))

        # material name strings
        sdata = self.lump(L_TDSD)
        stable = self._arr(L_TDST, '<i4')
        self.tex_names = []
        for o in stable:
            e = sdata.find(b'\0', o)
            self.tex_names.append(sdata[o:e].decode('ascii', 'replace'))

        self.models = np.frombuffer(self.lump(L_MODELS), dtype=np.dtype([
            ('mins', '<3f4'), ('maxs', '<3f4'), ('origin', '<3f4'),
            ('headnode', '<i4'), ('firstface', '<i4'), ('numfaces', '<i4')]))

        self._load_dispinfo()
        self.entities = parse_entities(self.lump(L_ENTITIES))

    def _load_dispinfo(self):
        d = self.lump(L_DISPINFO)
        n = len(d) // 176
        self.dispinfo = []
        for i in range(n):
            b = i * 176
            start = struct.unpack_from('<3f', d, b)
            vstart, tstart, power = struct.unpack_from('<3i', d, b + 12)
            mapface = struct.unpack_from('<H', d, b + 36)[0]
            self.dispinfo.append(dict(start=np.array(start, np.float64),
                                      vstart=vstart, tstart=tstart,
                                      power=power, mapface=mapface))
        self.dispverts = np.frombuffer(self.lump(L_DISP_VERTS), dtype=np.dtype([
            ('vec', '<3f4'), ('dist', '<f4'), ('alpha', '<f4')]))

    def face_material(self, fi):
        ti = self.faces[fi]['texinfo']
        if ti < 0:
            return None, 0, 1, 1
        t = self.texinfo[ti]
        td = self.texdata[t['texdata']]
        return (self.tex_names[td['name_id']], int(t['flags']),
                int(td['view_width']) or 1, int(td['view_height']) or 1)

    def face_loop(self, fi):
        """Ordered vertex indices around a face."""
        f = self.faces[fi]
        fe, ne = int(f['firstedge']), int(f['numedges'])
        out = []
        for se in self.surfedges[fe:fe + ne]:
            out.append(int(self.edges[se][0]) if se >= 0 else int(self.edges[-se][1]))
        return out

    def worldspawn(self):
        for e in self.entities:
            if e.get('classname') == 'worldspawn':
                return e
        return {}


def parse_entities(buf):
    """Parse the BSP entity lump into a list of dicts."""
    txt = buf.split(b'\0', 1)[0].decode('utf-8', 'replace')
    ents, cur = [], None
    for line in txt.splitlines():
        line = line.strip()
        if line == '{':
            cur = {}
        elif line == '}':
            if cur is not None:
                ents.append(cur)
            cur = None
        elif cur is not None:
            m = re.match(r'"((?:[^"\\]|\\.)*)"\s+"((?:[^"\\]|\\.)*)"', line)
            if m:
                k, v = m.group(1), m.group(2)
                if k in cur:
                    cur[k] = cur[k] + '\n' + v   # repeated keys (outputs)
                else:
                    cur[k] = v
    return ents


def displace(bsp, fi, di):
    """Build the displacement vertex grid + triangles for face fi."""
    info = bsp.dispinfo[di]
    p = info['power']
    n = (1 << p) + 1
    loop = bsp.face_loop(fi)
    if len(loop) != 4:
        return None
    corners = np.array([bsp.verts[v] for v in loop], np.float64)
    # rotate so corners[0] is the recorded start position
    d = np.linalg.norm(corners - info['start'], axis=1)
    k = int(np.argmin(d))
    corners = np.roll(corners, -k, axis=0)

    t = np.linspace(0.0, 1.0, n)
    # edge 0->1 and edge 3->2, then interpolate across
    e0 = corners[0][None, :] * (1 - t)[:, None] + corners[1][None, :] * t[:, None]
    e1 = corners[3][None, :] * (1 - t)[:, None] + corners[2][None, :] * t[:, None]
    base = e0[:, None, :] * (1 - t)[None, :, None] + e1[:, None, :] * t[None, :, None]

    dv = bsp.dispverts[info['vstart']:info['vstart'] + n * n]
    offs = (dv['vec'].astype(np.float64) * dv['dist'].astype(np.float64)[:, None]).reshape(n, n, 3)
    pos = (base + offs).reshape(-1, 3)
    alpha = dv['alpha'].astype(np.float32).reshape(-1)

    tris = []
    for i in range(n - 1):
        for j in range(n - 1):
            a = i * n + j; b = a + 1; c = a + n; e = c + 1
            if (i + j) % 2 == 0:
                tris += [(a, b, c), (b, e, c)]
            else:
                tris += [(a, e, c), (a, b, e)]
    tris = np.array(tris, np.uint32)

    # Orient the sheet so its faces point the same way as the base plane
    # (Source winds clockwise; glTF/Godot want counter-clockwise front faces).
    pn = np.array(bsp.planes[int(bsp.faces[fi]['planenum'])]['normal'], np.float64)
    ga = pos[tris[:, 0]]; gb = pos[tris[:, 1]]; gc = pos[tris[:, 2]]
    if float((np.cross(gb - ga, gc - ga) @ pn).sum()) < 0:
        tris = tris[:, ::-1].copy()

    # smooth per-vertex normals - terrain shades far better than flat facets
    ga = pos[tris[:, 0]]; gb = pos[tris[:, 1]]; gc = pos[tris[:, 2]]
    fn = np.cross(gb - ga, gc - ga)
    vn = np.zeros_like(pos)
    for k in range(3):
        np.add.at(vn, tris[:, k], fn)
    ln = np.linalg.norm(vn, axis=1, keepdims=True)
    vn = vn / np.where(ln == 0, 1, ln)
    return pos, tris, corners, alpha, vn
