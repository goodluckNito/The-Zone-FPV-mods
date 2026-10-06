"""Source StudioModel reader: .mdl + .vvd + .dx90.vtx -> triangle meshes (LOD 0)."""
import struct, math, numpy as np

VERT_SIZE = 48          # mstudiovertex_t


def _cstr(buf, off):
    if off < 0 or off >= len(buf):
        return ''
    e = buf.find(b'\0', off)
    return buf[off:e if e >= 0 else len(buf)].decode('ascii', 'replace')


class Mdl:
    """The .mdl half: material names and the bodypart/model/mesh tree."""

    def __init__(self, blob):
        self.blob = blob
        if blob[:4] not in (b'IDST', b'MDLZ'):
            raise ValueError('not an MDL')
        self.version, = struct.unpack_from('<i', blob, 4)
        self.checksum, = struct.unpack_from('<i', blob, 8)
        self.name = _cstr(blob, 12)
        ntex, texidx = struct.unpack_from('<2i', blob, 204)
        ncd, cdidx = struct.unpack_from('<2i', blob, 212)
        self.nskinref, self.nskinfam, self.skinidx = struct.unpack_from('<3i', blob, 220)
        nbody, bodyidx = struct.unpack_from('<2i', blob, 232)
        self.flags, = struct.unpack_from('<i', blob, 152)
        self.is_staticprop = bool(self.flags & 0x10)

        # Bones. Vertices in the .vvd live in BONE space; the compiler only
        # bakes them into model space when the model is $staticprop (then every
        # bone is identity). Models without that flag need the bind pose
        # applied or they come out rotated - e.g. de_inferno/elevatordoor has
        # bone 0 at quat (.707,0,0,.707), a 90 deg turn about X.
        nbones, boneidx = struct.unpack_from('<2i', blob, 156)
        self.bones = []
        for i in range(nbones):
            bb = boneidx + i * 216
            parent, = struct.unpack_from('<i', blob, bb + 4)
            pos = struct.unpack_from('<3f', blob, bb + 32)
            quat = struct.unpack_from('<4f', blob, bb + 44)
            self.bones.append((parent, np.array(pos, np.float64),
                               np.array(quat, np.float64)))

        self.textures = []
        for i in range(ntex):
            b = texidx + i * 64
            szname, = struct.unpack_from('<i', blob, b)
            self.textures.append(_cstr(blob, b + szname))
        self.cdmaterials = []
        for i in range(ncd):
            p, = struct.unpack_from('<i', blob, cdidx + i * 4)
            self.cdmaterials.append(_cstr(blob, p).replace('\\', '/'))

        # skin table: nskinfam rows x nskinref cols of short
        self.skins = []
        if self.skinidx and self.nskinref:
            for fam in range(max(1, self.nskinfam)):
                row = struct.unpack_from(f'<{self.nskinref}h', blob,
                                         self.skinidx + fam * self.nskinref * 2)
                self.skins.append(list(row))

        self.bodyparts = []
        for i in range(nbody):
            b = bodyidx + i * 16
            szname, nmodels, base, modelidx = struct.unpack_from('<4i', blob, b)
            models = []
            for m in range(nmodels):
                mb = b + modelidx + m * 148
                nmesh, meshidx = struct.unpack_from('<2i', blob, mb + 72)
                nverts, vertidx = struct.unpack_from('<2i', blob, mb + 80)
                meshes = []
                for k in range(nmesh):
                    kb = mb + meshidx + k * 116
                    material, modelindex, nv, voff = struct.unpack_from('<4i', blob, kb)
                    meshes.append(dict(material=material, numverts=nv, vertoffset=voff))
                models.append(dict(name=_cstr(blob, mb), numverts=nverts,
                                   vertexindex=vertidx, meshes=meshes))
            self.bodyparts.append(dict(name=_cstr(blob, b + szname), models=models))


def _quat_mat(q):
    """Source Quaternion (x, y, z, w) -> 3x3."""
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w)
    if n < 1e-9:
        return np.eye(3)
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def bind_matrices(mdl):
    """(R, T, all_identity): bone->model bind pose for every bone."""
    n = len(mdl.bones)
    R = np.zeros((max(n, 1), 3, 3)); T = np.zeros((max(n, 1), 3))
    R[:] = np.eye(3)
    ident = True
    for i, (parent, pos, quat) in enumerate(mdl.bones):
        lr = _quat_mat(quat)
        if parent >= 0 and parent < i:
            R[i] = R[parent] @ lr
            T[i] = R[parent] @ pos + T[parent]
        else:
            R[i] = lr
            T[i] = pos
        if (np.abs(R[i] - np.eye(3)).max() > 1e-4
                or np.abs(T[i]).max() > 1e-4):
            ident = False
    return R, T, ident


class Vvd:
    """The .vvd half: vertex array, with LOD fixups applied."""

    def __init__(self, blob):
        if blob[:4] != b'IDSV':
            raise ValueError('not a VVD')
        (self.version, self.checksum, self.num_lods) = struct.unpack_from('<3i', blob, 4)
        self.lod_counts = struct.unpack_from('<8i', blob, 16)
        (self.num_fixups, self.fixup_start,
         self.vert_start, self.tan_start) = struct.unpack_from('<4i', blob, 48)
        n = self.lod_counts[0] if self.num_fixups == 0 else \
            max(self.lod_counts[:max(1, self.num_lods)])
        total = (self.tan_start - self.vert_start) // VERT_SIZE if self.tan_start else n
        total = max(total, n)
        raw = np.frombuffer(blob, dtype=np.dtype([
            ('weight', '<3f4'), ('bone', 'u1', 3), ('nbones', 'u1'),
            ('pos', '<3f4'), ('nrm', '<3f4'), ('uv', '<2f4')]),
            count=total, offset=self.vert_start)
        if self.num_fixups:
            parts = {k: [] for k in ('pos', 'nrm', 'uv', 'weight', 'bone', 'nbones')}
            for i in range(self.num_fixups):
                lod, src, cnt = struct.unpack_from('<3i', blob,
                                                   self.fixup_start + i * 12)
                if lod < 0:
                    continue
                for k in parts:
                    parts[k].append(raw[k][src:src + cnt])
            for k in parts:
                setattr(self, k, np.concatenate(parts[k]) if parts[k] else raw[k])
        else:
            for k in ('pos', 'nrm', 'uv', 'weight', 'bone', 'nbones'):
                setattr(self, k, raw[k])


class Vtx:
    """The .dx90.vtx half: LOD-0 index/strip data."""

    def __init__(self, blob, mdl_version=48):
        (self.version, self.vert_cache) = struct.unpack_from('<2i', blob, 0)
        self.max_bones_strip, self.max_bones_tri = struct.unpack_from('<2H', blob, 8)
        (self.max_bones_vert, self.checksum, self.num_lods,
         self.mat_repl_off, self.num_bodyparts,
         self.bodypart_off) = struct.unpack_from('<6i', blob, 12)
        self.blob = blob
        self.sg_extra = 8 if mdl_version >= 49 else 0

    def lod0(self):
        """-> [[ (mesh_index, indices ndarray, origverts ndarray) ... ] per model ] per bodypart"""
        b = self.blob
        out = []
        for bp in range(self.num_bodyparts):
            bpb = self.bodypart_off + bp * 8
            nmodels, model_off = struct.unpack_from('<2i', b, bpb)
            models = []
            for m in range(nmodels):
                mb = bpb + model_off + m * 8
                nlods, lod_off = struct.unpack_from('<2i', b, mb)
                meshes = []
                if nlods > 0:
                    lb = mb + lod_off          # LOD 0
                    nmesh, mesh_off, _sw = struct.unpack_from('<2if', b, lb)
                    for k in range(nmesh):
                        kb = lb + mesh_off + k * 9
                        nsg, sg_off = struct.unpack_from('<2i', b, kb)
                        idx_all, ov_all = [], []
                        for s in range(nsg):
                            sb = kb + sg_off + s * (25 + self.sg_extra)
                            (nv, v_off, ni, i_off, nstr,
                             str_off) = struct.unpack_from('<6i', b, sb)
                            if ni <= 0 or nv <= 0:
                                continue
                            inds = np.frombuffer(b, '<u2', count=ni, offset=sb + i_off)
                            vb = sb + v_off
                            ov = np.frombuffer(b, dtype=np.dtype([
                                ('bwi', 'u1', 3), ('nb', 'u1'),
                                ('orig', '<u2'), ('bone', 'u1', 3)]),
                                count=nv, offset=vb)['orig']
                            # walk strips so triangle-strip groups are handled
                            for t in range(nstr):
                                tb = sb + str_off + t * 27
                                (tni, ti_off, tnv, tv_off) = struct.unpack_from('<4i', b, tb)
                                flags = b[tb + 18]
                                seg = inds[ti_off:ti_off + tni]
                                if flags & 0x2:            # STRIP_TRISTRIP
                                    tri = []
                                    for q in range(len(seg) - 2):
                                        a, c, e = seg[q], seg[q + 1], seg[q + 2]
                                        if a == c or c == e or a == e:
                                            continue
                                        tri.append((a, e, c) if q % 2 else (a, c, e))
                                    seg = np.array(tri, np.uint32).reshape(-1)
                                idx_all.append(np.asarray(seg, np.uint32))
                                ov_all.append(ov)
                        meshes.append((k, idx_all, ov_all))
                models.append(meshes)
            out.append(models)
        return out


def _angle_matrix(pitch, yaw, roll):
    """Source QAngle -> 3x3 rotation (columns: forward, left, up)."""
    p, y, r = map(math.radians, (pitch, yaw, roll))
    sp, cp = math.sin(p), math.cos(p)
    sy, cy = math.sin(y), math.cos(y)
    sr, cr = math.sin(r), math.cos(r)
    return np.array([
        [cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy],
        [cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy],
        [-sp,     sr * cp,                cr * cp],
    ], np.float64)


class Model:
    """A loaded static-prop model: list of (material_name, pos, nrm, uv, tris)."""

    def __init__(self, parts, name):
        self.parts, self.name = parts, name

    @property
    def triangles(self):
        return sum(len(p[4]) for p in self.parts)

    def instance(self, origin, angles, scale=1.0):
        """Place this model in Source world space."""
        M = _angle_matrix(*angles) * float(scale)
        o = np.asarray(origin, np.float64)
        Mn = _angle_matrix(*angles)
        out = []
        for mat, pos, nrm, uv, tris in self.parts:
            out.append((mat, pos @ M.T + o, nrm @ Mn.T, uv, tris))
        return out


def load_model(fs, path, skin=0):
    """Read a .mdl (+ .vvd/.vtx) out of a SourceFs."""
    # mappers sometimes leave a './' or a leading slash in the model keyvalue
    p = path.lower().replace('\\', '/').strip()
    while p.startswith('./') or p.startswith('/'):
        p = p.lstrip('/')
        if p.startswith('./'):
            p = p[2:]
    if not p.startswith('models/'):
        p = 'models/' + p
    base = p[:-4] if p.endswith('.mdl') else p
    mb = fs.read(base + '.mdl')
    if mb is None:
        return None, 'mdl missing'
    vb = fs.read(base + '.vvd')
    if vb is None:
        return None, 'vvd missing'
    xb = None
    for suf in ('.dx90.vtx', '.vtx', '.dx80.vtx', '.sw.vtx'):
        xb = fs.read(base + suf)
        if xb is not None:
            break
    if xb is None:
        return None, 'vtx missing'
    try:
        mdl, vvd = Mdl(mb), Vvd(vb)
        vtx = Vtx(xb, mdl.version)
        tree = vtx.lod0()
    except Exception as e:
        return None, f'{type(e).__name__}: {e}'

    # NOTE: do NOT apply the bone bind pose here. .vvd vertices are already in
    # MODEL space: the runtime skinning matrix is boneToWorld * poseToBone, and
    # at rest those cancel to identity. Three inferno models (elevatordoor,
    # tv_monitor01, grainbasket01c) lack the $staticprop flag and have bone 0 at
    # quat (.707,0,0,.707); applying it lays a standing 104x2.4x116 door panel
    # flat on the floor. bind_matrices() is kept for a future animated path.
    src_pos, src_nrm = vvd.pos, vvd.nrm

    parts = []
    for bi, bp in enumerate(mdl.bodyparts):
        if bi >= len(tree):
            break
        for mi, model in enumerate(bp['models']):
            if mi >= len(tree[bi]):
                break
            vbase = model['vertexindex'] // VERT_SIZE
            for (k, idx_all, ov_all) in tree[bi][mi]:
                if k >= len(model['meshes']):
                    continue
                mesh = model['meshes'][k]
                texid = mesh['material']
                if mdl.skins and skin < len(mdl.skins) and texid < len(mdl.skins[skin]):
                    texid = mdl.skins[skin][texid]
                matname = mdl.textures[texid] if 0 <= texid < len(mdl.textures) else ''
                gidx, guv = [], None
                for inds, ov in zip(idx_all, ov_all):
                    if len(inds) == 0:
                        continue
                    orig = ov[inds].astype(np.int64)
                    gidx.append(vbase + mesh['vertoffset'] + orig)
                if not gidx:
                    continue
                flat = np.concatenate(gidx)
                flat = flat[:len(flat) - len(flat) % 3]
                if len(flat) == 0 or flat.max() >= len(src_pos):
                    continue
                pos = np.asarray(src_pos)[flat].astype(np.float64)
                nrm = np.asarray(src_nrm)[flat].astype(np.float64)
                tris = np.arange(len(flat), dtype=np.uint32).reshape(-1, 3)
                # StudioModel triangles are wound clockwise; make them CCW so
                # they agree with the authored vertex normals (and so Godot's
                # front-face-only concave collision actually collides).
                a, c, e = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
                gn = np.cross(c - a, e - a)
                vn = nrm[tris[:, 0]] + nrm[tris[:, 1]] + nrm[tris[:, 2]]
                flip = (gn * vn).sum(1) < 0
                if flip.any():
                    tris[flip] = tris[flip][:, ::-1]
                parts.append((matname, pos, nrm,
                              vvd.uv[flat].astype(np.float32),
                              np.ascontiguousarray(tris)))
    if not parts:
        return None, 'no geometry'
    return Model(parts, base), None


def resolve_material(fs, mdl_texname, cdmaterials):
    """Find the VMT path for an MDL texture reference."""
    from . import vmt as V
    t = mdl_texname.replace('\\', '/').strip('/')
    cands = [c.strip('/') + '/' + t for c in cdmaterials if c] + [t]
    for c in cands:
        if fs.read('materials/' + c + '.vmt') is not None:
            return c
    return None
