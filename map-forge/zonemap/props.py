"""GAME_LUMP 'sprp' static prop reader."""
import struct, collections
from . import bsp as B

SPRP = 0x73707270  # 'sprp', stored little-endian


def _sub_lump(src, start, ln):
    """Slice one game sub-lump, decompressing it if it carries lzma_header_t.

    For a compressed sub-lump the directory's `filelen` is the UNCOMPRESSED
    size, so it cannot be used to bound the read; lzma_header_t.lzmaSize is
    what says how far the stream runs.
    """
    if start < 0 or start >= len(src):
        return b''
    if len(src) - start >= 17 and struct.unpack_from('<I', src, start)[0] == B.LZMA_ID:
        _actual, lzs = struct.unpack_from('<2I', src, start + 4)
        end = start + 17 + lzs if lzs else len(src)
        return B.lump_decompress(bytes(src[start:end]))
    return bytes(src[start:start + ln]) if ln > 0 else bytes(src[start:])


def game_lumps(bsp):
    """Index the GAME_LUMP directory.

    The game lump is the awkward one. Its sub-lump offsets are offsets into the
    WHOLE FILE, not into the lump. And Valve compresses it sub-lump by
    sub-lump, leaving this directory in the clear - so the usual "is the lump
    LZMA" check at the lump level says no while the 'sprp' payload inside it is
    compressed anyway. That is how TF2 and other Source 2009+ maps ship.

    Both layouts are handled: normally the absolute offsets are read straight
    out of the file, but if the whole lump turned out to be compressed then the
    file offsets no longer point anywhere real and they get rebased onto the
    decompressed bytes instead.
    """
    d = bsp.lump(B.L_GAME_LUMP)
    if not d:
        return {}
    n, = struct.unpack_from('<i', d, 0)
    base_off, _, _, _ = bsp.lumps[B.L_GAME_LUMP]
    whole_compressed = B.L_GAME_LUMP in getattr(bsp, 'compressed_lumps', ())
    out = {}
    for i in range(n):
        gid, flags, ver, ofs, ln = struct.unpack_from('<iHHii', d, 4 + i * 16)
        if whole_compressed:
            src, start = d, (ofs - base_off if ofs >= base_off else ofs)
        else:
            src, start = bsp.raw, ofs
        out[gid] = dict(version=ver, flags=flags, off=ofs, len=ln,
                        data=_sub_lump(src, start, ln))
    return out


def static_props(bsp):
    gl = game_lumps(bsp).get(SPRP)
    if not gl:
        return [], [], None
    d, ver = gl['data'], gl['version']
    o = 0
    ndict, = struct.unpack_from('<i', d, o); o += 4
    names = []
    for i in range(ndict):
        names.append(d[o:o + 128].split(b'\0', 1)[0].decode('ascii', 'replace'))
        o += 128
    nleaf, = struct.unpack_from('<i', d, o); o += 4
    o += nleaf * 2
    ncount, = struct.unpack_from('<i', d, o); o += 4
    if ncount <= 0:
        return [], names, ver
    entry_size = (len(d) - o) // ncount
    # A wrong stride silently scatters every prop across the map, so refuse to
    # guess. Known sizes: v4 56, v5 60, v6 64, v7/v8 68, v9 72, v10 76, v11 80.
    if not (48 <= entry_size <= 96):
        raise ValueError(
            f'static prop lump v{ver}: implausible entry size {entry_size} '
            f'({len(d) - o} bytes for {ncount} props) - this game lump is in a '
            f'format the reader does not know')
    props = []
    for i in range(ncount):
        b = o + i * entry_size
        ox, oy, oz = struct.unpack_from('<3f', d, b)
        pit, yaw, rol = struct.unpack_from('<3f', d, b + 12)
        ptype, fleaf, lcount = struct.unpack_from('<3H', d, b + 24)
        solid, flags = d[b + 30], d[b + 31]
        skin, = struct.unpack_from('<i', d, b + 32)
        fmin, fmax = struct.unpack_from('<2f', d, b + 36)
        scale = 1.0
        if ver >= 11 and entry_size >= 80:
            try:
                scale, = struct.unpack_from('<f', d, b + entry_size - 4)
                if not (0.01 < scale < 100):
                    scale = 1.0
            except struct.error:
                scale = 1.0
        props.append(dict(origin=(ox, oy, oz), angles=(pit, yaw, rol),
                          model=names[ptype] if ptype < len(names) else '?',
                          skin=skin, solid=solid, flags=flags,
                          fade=(fmin, fmax), scale=scale))
    return props, names, dict(version=ver, entry_size=entry_size)
