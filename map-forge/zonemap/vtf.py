"""VTF (Valve Texture Format) decoder -> numpy RGBA uint8."""
import struct, io, math, numpy as np
from PIL import Image

IMG = {0: ('RGBA8888', 4), 1: ('ABGR8888', 4), 2: ('RGB888', 3), 3: ('BGR888', 3),
       4: ('RGB565', 2), 5: ('I8', 1), 6: ('IA88', 2), 7: ('P8', 1), 8: ('A8', 1),
       9: ('RGB888_BS', 3), 10: ('BGR888_BS', 3), 11: ('ARGB8888', 4),
       12: ('BGRA8888', 4), 13: ('DXT1', 0.5), 14: ('DXT3', 1), 15: ('DXT5', 1),
       16: ('BGRX8888', 4), 17: ('BGR565', 2), 18: ('BGRX5551', 2),
       19: ('BGRA4444', 2), 20: ('DXT1A', 0.5), 21: ('BGRA5551', 2),
       22: ('UV88', 2), 23: ('UVWQ8888', 4), 24: ('RGBA16F', 8),
       25: ('RGBA16', 8), 26: ('UVLX8888', 4)}

DXT = {13: (b'DXT1', 8), 20: (b'DXT1', 8), 14: (b'DXT3', 16), 15: (b'DXT5', 16)}
RSRC_IMAGE = b'\x30\x00\x00'


def _mip_size(fmt, w, h):
    if fmt in DXT:
        _, bs = DXT[fmt]
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * bs
    bpp = IMG.get(fmt, (None, 0))[1]
    return int(w * h * bpp)


def _dds_header(fourcc, w, h, size):
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000       # CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE
    hdr = b'DDS ' + struct.pack('<7I', 124, flags, h, w, size, 0, 0)
    hdr += b'\0' * 44                                 # reserved1[11]
    hdr += struct.pack('<2I', 32, 0x4)                # pfSize, DDPF_FOURCC
    hdr += fourcc + struct.pack('<5I', 0, 0, 0, 0, 0)
    hdr += struct.pack('<5I', 0x1000, 0, 0, 0, 0)     # caps TEXTURE
    return hdr


def _decode_uncompressed(fmt, data, w, h):
    name, bpp = IMG[fmt]
    need = int(w * h * bpp)
    data = data[:need]
    if len(data) < need:
        data = data + b'\0' * (need - len(data))
    if bpp == 4:
        a = np.frombuffer(data, np.uint8).reshape(h, w, 4)
        order = {'RGBA8888': [0, 1, 2, 3], 'ABGR8888': [3, 2, 1, 0],
                 'ARGB8888': [1, 2, 3, 0], 'BGRA8888': [2, 1, 0, 3],
                 'BGRX8888': [2, 1, 0, 3], 'UVWQ8888': [0, 1, 2, 3],
                 'UVLX8888': [0, 1, 2, 3]}[name]
        out = a[:, :, order].copy()
        if name == 'BGRX8888':
            out[:, :, 3] = 255
        return out
    if bpp == 3:
        a = np.frombuffer(data, np.uint8).reshape(h, w, 3)
        if name.startswith('BGR'):
            a = a[:, :, ::-1]
        return np.dstack([a, np.full((h, w, 1), 255, np.uint8)])
    if name == 'I8':
        a = np.frombuffer(data, np.uint8).reshape(h, w, 1)
        return np.dstack([a, a, a, np.full((h, w, 1), 255, np.uint8)])
    if name == 'A8':
        a = np.frombuffer(data, np.uint8).reshape(h, w, 1)
        return np.dstack([np.full((h, w, 3), 255, np.uint8), a])
    if name == 'IA88':
        a = np.frombuffer(data, np.uint8).reshape(h, w, 2)
        l = a[:, :, 0:1]
        return np.dstack([l, l, l, a[:, :, 1:2]])
    if name in ('RGB565', 'BGR565'):
        v = np.frombuffer(data, '<u2').reshape(h, w)
        r = ((v >> 11) & 0x1F) * 255 // 31
        g = ((v >> 5) & 0x3F) * 255 // 63
        bl = (v & 0x1F) * 255 // 31
        if name == 'BGR565':
            r, bl = bl, r
        return np.dstack([r, g, bl, np.full((h, w), 255)]).astype(np.uint8)
    if name == 'UV88':
        a = np.frombuffer(data, np.uint8).reshape(h, w, 2)
        return np.dstack([a[:, :, 0:1], a[:, :, 1:2],
                          np.full((h, w, 1), 255, np.uint8),
                          np.full((h, w, 1), 255, np.uint8)])
    raise NotImplementedError(f'VTF format {name}')


class Vtf:
    def __init__(self, blob):
        if blob[:4] != b'VTF\0':
            raise ValueError('not a VTF')
        vmaj, vmin = struct.unpack_from('<II', blob, 4)
        self.version = (vmaj, vmin)
        self.header_size, = struct.unpack_from('<I', blob, 12)
        self.width, self.height = struct.unpack_from('<HH', blob, 16)
        self.flags, = struct.unpack_from('<I', blob, 20)
        self.frames, self.first_frame = struct.unpack_from('<HH', blob, 24)
        self.bump_scale, = struct.unpack_from('<f', blob, 48)
        self.fmt, = struct.unpack_from('<I', blob, 52)
        self.mip_count = blob[56]
        self.lowres_fmt, = struct.unpack_from('<I', blob, 57)
        self.lowres_w, self.lowres_h = blob[61], blob[62]
        self.depth = struct.unpack_from('<H', blob, 63)[0] if vmin >= 2 else 1
        self.blob = blob
        self.faces = 7 if (self.flags & 0x4000) else 1   # ENVMAP

        self._image_off = None
        if vmin >= 3:
            n, = struct.unpack_from('<I', blob, 68)
            for i in range(n):
                tag = blob[80 + i * 8: 83 + i * 8]
                off, = struct.unpack_from('<I', blob, 84 + i * 8)
                if tag == RSRC_IMAGE:
                    self._image_off = off
        if self._image_off is None:
            off = self.header_size
            if self.lowres_fmt != 0xFFFFFFFF and self.lowres_w:
                off += _mip_size(self.lowres_fmt, self.lowres_w, self.lowres_h)
            self._image_off = off

    def mip0(self):
        """Decode the largest mip of frame 0, face 0 -> HxWx4 uint8."""
        W, H, n = self.width, self.height, max(1, self.mip_count)
        per_mip = []
        for i in range(n):
            w, h = max(1, W >> i), max(1, H >> i)
            per_mip.append(_mip_size(self.fmt, w, h))
        # VTF stores mips smallest-first; mip 0 is last
        skip = sum(per_mip[i] * self.frames * self.faces * max(1, self.depth >> i)
                   for i in range(n - 1, 0, -1))
        start = self._image_off + skip
        size = per_mip[0]
        data = self.blob[start:start + size]
        if len(data) < size:                     # some VTFs lie about mip count
            data = self.blob[-size:] if len(self.blob) >= size else data
        if self.fmt in DXT:
            fourcc, _ = DXT[self.fmt]
            img = Image.open(io.BytesIO(_dds_header(fourcc, W, H, size) + data))
            return np.array(img.convert('RGBA'))
        return _decode_uncompressed(self.fmt, data, W, H)

    def __repr__(self):
        return (f'<Vtf {self.width}x{self.height} v{self.version[0]}.{self.version[1]} '
                f'fmt={IMG.get(self.fmt,("?",0))[0]} mips={self.mip_count} '
                f'flags=0x{self.flags:x}>')


def load_vtf(fs, name):
    p = name.lower().replace('\\', '/').lstrip('/')
    if not p.endswith('.vtf'):
        p += '.vtf'
    if not p.startswith('materials/'):
        p = 'materials/' + p
    blob = fs.read(p)
    return Vtf(blob) if blob else None
