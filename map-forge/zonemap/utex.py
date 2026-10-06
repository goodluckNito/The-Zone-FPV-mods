"""Cooked UE4 Texture2D -> RGBA array (BCn through Pillow's decoder)."""
import struct, numpy as np
from .uasset import object_guid

BULK_AT_END, BULK_UNUSED, BULK_INLINE, BULK_SEPARATE, BULK_OPTIONAL, BULK_64, BULK_BADVER, BULK_NOFIX = \
    0x1, 0x20, 0x40, 0x100, 0x800, 0x2000, 0x8000, 0x10000


def bulk(pkg, r):
    """FByteBulkData at r -> bytes (or None if not stored)"""
    flags = r.u32()
    if flags & BULK_64: count = r.i64(); size = r.i64()
    else: count = r.i32(); size = r.i32()
    off = r.i64()
    if flags & BULK_BADVER: r.o += 2
    if flags & BULK_UNUSED or count == 0: return b''
    if flags & BULK_INLINE or not (flags & (BULK_AT_END | BULK_SEPARATE)):
        d = r.b[r.o:r.o + size]; r.o += size; return d
    if flags & BULK_OPTIONAL: return None
    if flags & BULK_SEPARATE:
        ub = pkg.load_ubulk()
        if ub is None: return None
        return ub[off:off + size]
    if not (flags & BULK_NOFIX): off += pkg.bulk_start
    return pkg.data[off:off + size]


def texture_mips(pkg, exp):
    """-> (pixel format, [(w, h, bytes|None), ...]) for the first cooked platform"""
    props, r = pkg.export_props(exp)
    object_guid(r)
    r.o += 4                     # strip flags: UTexture, UTexture2D
    cooked = r.i32()
    if not cooked: return None, []
    pf = pkg.name(r)
    if pf == 'None': return None, []
    r.i64()                      # skip offset
    w = r.i32(); h = r.i32(); packed = r.u32(); fmt = r.fstring()
    if packed & (1 << 30): r.o += 8
    first = r.i32(); n = r.i32(); mips = []
    for i in range(n):
        r.i32()                  # bCooked
        d = bulk(pkg, r)
        mw = r.i32(); mh = r.i32(); r.i32()
        mips.append((mw, mh, d))
    return fmt, mips


def _bcn(data, w, h, n, mode):
    from PIL import Image
    bw, bh = max(4, (w + 3) // 4 * 4), max(4, (h + 3) // 4 * 4)
    im = Image.frombytes(mode, (bw, bh), data, 'bcn', n)
    if (bw, bh) != (w, h): im = im.crop((0, 0, w, h))
    return np.asarray(im.convert('RGBA'))


def decode(fmt, w, h, d):
    """-> HxWx4 uint8 RGBA (BC5 normals come back as R, G, reconstructed B)"""
    if fmt == 'PF_B8G8R8A8':
        a = np.frombuffer(d, np.uint8)[:w * h * 4].reshape(h, w, 4); return a[..., [2, 1, 0, 3]].copy()
    if fmt == 'PF_R8G8B8A8':
        return np.frombuffer(d, np.uint8)[:w * h * 4].reshape(h, w, 4).copy()
    if fmt in ('PF_G8', 'PF_L8', 'PF_A8'):
        g = np.frombuffer(d, np.uint8)[:w * h].reshape(h, w)
        a = np.empty((h, w, 4), np.uint8); a[..., :3] = g[..., None]; a[..., 3] = 255; return a
    if fmt == 'PF_DXT1': return _bcn(d, w, h, 1, 'RGBA')
    if fmt == 'PF_DXT3': return _bcn(d, w, h, 2, 'RGBA')
    if fmt == 'PF_DXT5': return _bcn(d, w, h, 3, 'RGBA')
    if fmt == 'PF_BC4':
        from PIL import Image
        bw, bh = (w + 3) // 4 * 4, (h + 3) // 4 * 4
        g = np.asarray(Image.frombytes('L', (bw, bh), d, 'bcn', 4))[:h, :w]
        a = np.empty((h, w, 4), np.uint8); a[..., :3] = g[..., None]; a[..., 3] = 255; return a
    if fmt == 'PF_BC5':
        from PIL import Image
        bw, bh = (w + 3) // 4 * 4, (h + 3) // 4 * 4
        rg = np.asarray(Image.frombytes('RGB', (bw, bh), d, 'bcn', 5))[:h, :w].astype(np.float32)
        x = rg[..., 0] / 127.5 - 1; y = rg[..., 1] / 127.5 - 1
        z = np.sqrt(np.clip(1 - x * x - y * y, 0, 1))
        a = np.empty((h, w, 4), np.uint8)
        a[..., 0] = rg[..., 0]; a[..., 1] = rg[..., 1]; a[..., 2] = (z * 127.5 + 127.5).astype(np.uint8); a[..., 3] = 255
        return a
    if fmt == 'PF_BC7': return _bcn(d, w, h, 7, 'RGBA')
    if fmt == 'PF_FloatRGBA':
        f = np.frombuffer(d, np.float16)[:w * h * 4].reshape(h, w, 4).astype(np.float32)
        return (np.clip(f, 0, 1) * 255 + 0.5).astype(np.uint8)
    raise ValueError('pixel format ' + fmt)


def best_mip(fmt, mips, max_px=1024):
    """the largest stored mip no bigger than max_px"""
    ok = [(w, h, d) for w, h, d in mips if d]
    if not ok: return None
    for w, h, d in ok:
        if max(w, h) <= max_px: return w, h, d
    return ok[-1]


def texture_rgba(pkg, exp, max_px=1024):
    fmt, mips = texture_mips(pkg, exp)
    if not fmt: return None
    m = best_mip(fmt, mips, max_px)
    if m is None: return None
    w, h, d = m
    return decode(fmt, w, h, d)
