"""Valve Pak (VPK v1/v2) reader."""
import struct, os

VPK_SIG = 0x55AA1234


class Vpk:
    def __init__(self, dir_path):
        self.dir_path = dir_path
        base = os.path.basename(dir_path)
        assert base.endswith('_dir.vpk'), dir_path
        self.prefix = os.path.join(os.path.dirname(dir_path), base[:-8])
        self.entries = {}          # 'path/name.ext' -> entry dict
        self._handles = {}
        self._parse()

    def _parse(self):
        with open(self.dir_path, 'rb') as f:
            blob = f.read()
        sig, ver = struct.unpack_from('<II', blob, 0)
        if sig != VPK_SIG:
            raise ValueError('bad VPK signature')
        if ver == 1:
            tree_size, = struct.unpack_from('<I', blob, 8)
            o = 12
        elif ver == 2:
            tree_size, = struct.unpack_from('<I', blob, 8)
            o = 28
        else:
            raise ValueError(f'unsupported VPK version {ver}')
        self.data_offset = o + tree_size      # embedded data follows the tree

        def cstr():
            nonlocal o
            e = blob.index(b'\0', o)
            s = blob[o:e].decode('utf-8', 'replace')
            o = e + 1
            return s

        while True:
            ext = cstr()
            if not ext:
                break
            while True:
                path = cstr()
                if not path:
                    break
                while True:
                    name = cstr()
                    if not name:
                        break
                    crc, pre_len, arch, off, ln, term = struct.unpack_from('<IHHIIH', blob, o)
                    o += 18
                    preload = blob[o:o + pre_len]
                    o += pre_len
                    full = (f'{path}/{name}.{ext}' if path not in ('', ' ')
                            else f'{name}.{ext}')
                    self.entries[full.lower()] = dict(
                        arch=arch, off=off, len=ln, preload=preload)

    def _fh(self, arch):
        if arch not in self._handles:
            p = (self.dir_path if arch == 0x7FFF
                 else f'{self.prefix}_{arch:03d}.vpk')
            self._handles[arch] = open(p, 'rb')
        return self._handles[arch]

    def read(self, path):
        e = self.entries.get(path.lower().replace('\\', '/'))
        if e is None:
            return None
        if e['len'] == 0:
            return e['preload']
        f = self._fh(e['arch'])
        base = self.data_offset if e['arch'] == 0x7FFF else 0
        f.seek(base + e['off'])
        return e['preload'] + f.read(e['len'])

    def __contains__(self, path):
        return path.lower().replace('\\', '/') in self.entries
