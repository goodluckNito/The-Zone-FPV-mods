"""Unreal Engine 4 .pak archives (version 8-11, as 4.22-4.27 write them).

Read-only, zlib or stored entries, no encryption. A game ships its content
as a set of numbered chunks (pakchunk0, pakchunk0_s1, ...); PakSet opens
every one in a folder and looks files up by their game path:

    paks = PakSet('.../Uncrashed/Content/Paks')
    data = paks.read('/Game/MapEditor/DataTables/DT_MapEditorAssets.uasset')

Nothing is unpacked to disk.
"""
import os, struct, zlib

MAGIC = 0x5A6F12E1


def _fstring(b, o):
    n, = struct.unpack_from('<i', b, o); o += 4
    if n == 0:
        return '', o
    if n < 0:
        return b[o:o - 2 * n].decode('utf-16-le').rstrip('\0'), o - 2 * n
    return b[o:o + n].decode('utf-8', 'replace').rstrip('\0'), o + n


class PakFile:
    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        size = os.path.getsize(path)
        self.f.seek(max(0, size - 1024))
        tail = self.f.read()
        m = tail.rfind(struct.pack('<I', MAGIC))
        if m < 17:
            raise ValueError(f'{path}: not a .pak')
        self.encrypted_index = tail[m - 1] != 0
        self.version, = struct.unpack_from('<I', tail, m + 4)
        off, isz = struct.unpack_from('<QQ', tail, m + 8)
        self.methods = ['None'] + [
            tail[m + 44 + 32 * i:m + 76 + 32 * i].rstrip(b'\0').decode('latin-1')
            for i in range(5)]
        if self.encrypted_index:
            raise ValueError(f'{path}: the index is encrypted')
        if self.version < 10:
            raise ValueError(f'{path}: pak version {self.version} is not supported '
                             f'(4.25 and later only)')
        self.f.seek(off)
        b = self.f.read(isz)
        self.mount, o = _fstring(b, 0)
        o += 4 + 8                                   # entry count, path hash seed
        has_phi, = struct.unpack_from('<i', b, o); o += 4
        if has_phi:
            o += 8 + 8 + 20
        has_fdi, = struct.unpack_from('<i', b, o); o += 4
        if not has_fdi:
            raise ValueError(f'{path}: no full directory index')
        fdi_off, fdi_size = struct.unpack_from('<qq', b, o); o += 8 + 8 + 20
        n, = struct.unpack_from('<i', b, o); o += 4
        self.enc = b[o:o + n]
        self.f.seek(fdi_off)
        d = self.f.read(fdi_size)
        q = 0
        ndirs, = struct.unpack_from('<i', d, q); q += 4
        self.files = {}
        for _ in range(ndirs):
            dname, q = _fstring(d, q)
            nf, = struct.unpack_from('<i', d, q); q += 4
            for _ in range(nf):
                fname, q = _fstring(d, q)
                loc, = struct.unpack_from('<i', d, q); q += 4
                if loc >= 0:
                    self.files[self.mount + dname + fname] = loc

    def entry(self, loc):
        """-> (offset, compressed size, size, method)"""
        e = self.enc
        v, = struct.unpack_from('<I', e, loc); k = loc + 4
        comp = (v >> 23) & 0x3f
        if (v & 0x3f) == 0x3f:
            k += 4                                   # explicit block size
        if v & (1 << 31):
            off, = struct.unpack_from('<I', e, k); k += 4
        else:
            off, = struct.unpack_from('<q', e, k); k += 8
        if v & (1 << 30):
            usize, = struct.unpack_from('<I', e, k); k += 4
        else:
            usize, = struct.unpack_from('<q', e, k); k += 8
        size = usize
        if comp:
            if v & (1 << 29):
                size, = struct.unpack_from('<I', e, k); k += 4
            else:
                size, = struct.unpack_from('<q', e, k); k += 8
        if v & (1 << 22):
            raise ValueError('encrypted entry')
        return off, size, usize, comp

    def read_loc(self, loc):
        off, size, usize, comp = self.entry(loc)
        f = self.f
        if not comp:
            f.seek(off + 53)
            return f.read(usize)
        method = self.methods[comp] if comp < len(self.methods) else '?'
        if method.lower() != 'zlib':
            raise ValueError(f'compression {method!r} is not supported')
        # the entry's own header sits in front of its data and lists the blocks
        f.seek(off + 48)
        nb, = struct.unpack('<i', f.read(4))
        blocks = struct.unpack(f'<{2 * nb}q', f.read(16 * nb))
        out = []
        for i in range(nb):
            f.seek(off + blocks[2 * i])
            out.append(zlib.decompress(f.read(blocks[2 * i + 1] - blocks[2 * i])))
        d = b''.join(out)
        if len(d) != usize:
            raise ValueError('bad decompressed size')
        return d


class PakSet:
    """Every .pak in a folder; later chunks override earlier ones."""

    def __init__(self, paks_dir):
        self.dir = paks_dir
        self.paks = []
        self.index = {}
        names = sorted(n for n in os.listdir(paks_dir) if n.lower().endswith('.pak'))
        if not names:
            raise ValueError(f'no .pak files in {paks_dir}')
        for n in names:
            pk = PakFile(os.path.join(paks_dir, n))
            self.paks.append(pk)
            for name, loc in pk.files.items():
                self.index[self._key(name)] = (pk, loc)
        # '../../../Uncrashed/Content/' -> the project name, for /Game paths
        self.project = None
        for k in self.index:
            parts = k.split('/')
            if len(parts) > 2 and parts[1] == 'content' and parts[0] != 'engine':
                self.project = parts[0]
                break

    @staticmethod
    def _key(name):
        while name.startswith('../'):
            name = name[3:]
        return name.lower()

    def _resolve(self, path):
        p = path.replace('\\', '/')
        if p.startswith('/Game/'):
            p = f'{self.project}/content/' + p[6:]
        elif p.startswith('/Engine/'):
            p = 'engine/content/' + p[8:]
        return self._key(p)

    def exists(self, path):
        return self._resolve(path) in self.index

    def read(self, path):
        e = self.index.get(self._resolve(path))
        if e is None:
            return None
        return e[0].read_loc(e[1])

    def files(self):
        return list(self.index)
