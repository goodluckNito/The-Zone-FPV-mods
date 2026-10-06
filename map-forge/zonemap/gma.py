"""Garry's Mod addon archives (.gma).

A Workshop map is not a folder of files, it is one `.gma` - a flat archive
holding the .bsp together with every model, material and sound it needs.
`gm_br_pitfalls` ships in a 1.6 GB one with 11,621 files, two maps and 1,595
models. The format is small enough to read directly, so nothing has to be
unpacked to disk:

    'GMAD'                     magic
    uint8                      format version (3 in the wild)
    uint64                     steamid    (unused)
    uint64                     timestamp
    [cstring]* ''              required content tags, version > 1 only
    cstring                    addon name
    cstring                    description (usually JSON)
    cstring                    author
    int32                      addon version
    { uint32 index != 0        file table, terminated by index 0
      cstring path
      int64  size
      uint32 crc }*
    <file bytes, concatenated in table order>
    uint32                     whole-archive crc

Paths inside are already lower-case, forward-slashed and rooted the way Source
expects (`materials/...`, `models/...`, `maps/...`), so the archive can be
layered straight into `SourceFs` next to a VPK.
"""
import struct


class Gma:
    def __init__(self, path):
        self.path = path
        self.entries = {}          # lower-case path -> (offset, size)
        self.order = []
        self._f = open(path, 'rb')
        f = self._f
        if f.read(4) != b'GMAD':
            raise ValueError(f'not a GMA archive: {path}')
        self.version = f.read(1)[0]
        struct.unpack('<Q', f.read(8))          # steamid, unused
        struct.unpack('<Q', f.read(8))          # timestamp

        def cstr():
            out = bytearray()
            while True:
                c = f.read(1)
                if not c or c == b'\0':
                    break
                out += c
            return out.decode('utf-8', 'replace')

        if self.version > 1:
            while cstr():                        # required content tags
                pass
        self.name = cstr()
        self.description = cstr()
        self.author = cstr()
        self.addon_version, = struct.unpack('<i', f.read(4))

        table = []
        while True:
            num, = struct.unpack('<I', f.read(4))
            if num == 0:
                break
            fn = cstr()
            size, = struct.unpack('<q', f.read(8))
            struct.unpack('<I', f.read(4))       # per-file crc, not checked
            table.append((fn, size))
        pos = f.tell()
        for fn, size in table:
            key = fn.lower().replace('\\', '/')
            self.entries[key] = (pos, size)
            self.order.append(key)
            pos += size

    def read(self, path):
        hit = self.entries.get(path.lower().replace('\\', '/').lstrip('/'))
        if hit is None:
            return None
        off, size = hit
        self._f.seek(off)
        return self._f.read(size)

    def maps(self):
        """Every .bsp inside, biggest first - the playable one usually wins."""
        got = [(n, self.entries[n][1]) for n in self.order if n.endswith('.bsp')]
        got.sort(key=lambda r: -r[1])
        return got

    def close(self):
        try:
            self._f.close()
        except Exception:
            pass
