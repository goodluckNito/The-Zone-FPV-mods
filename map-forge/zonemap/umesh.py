"""Cooked UE4.25-4.27 StaticMesh -> per-LOD geometry (cm, Unreal's axes).

    m = static_mesh(pkg)
    m['lods'][0] = dict(pos, nrm, uv, idx, sections=[(material, first, tris)])
    m['materials'] = ['/Game/.../MI_Foo.MI_Foo', ...]   # by material index
"""
import numpy as np
from .uasset import object_guid, Reader
from . import utex


def _array(r):
    es = r.i32(); n = r.i32(); d = r.b[r.o:r.o + es * n]; r.o += es * n
    return es, n, d


def _index_buffer(r):
    b32 = r.i32()
    es, n, d = _array(r)
    r.o += 4                                     # bShouldExpandTo32Bit
    return np.frombuffer(d, '<u4' if b32 else '<u2').astype(np.uint32)


def _buffers(r, nsec, full=True):
    strip = r.b[r.o:r.o + 2]; r.o += 2
    cls = strip[1]
    r.i32(); r.i32()                             # stride, vertex count
    es, n, d = _array(r)
    pos = np.frombuffer(d, '<f4').reshape(n, -1)[:, :3].astype(np.float32)
    r.o += 2
    ntc = r.i32(); nv = r.i32(); full_uv = r.i32(); hi_tan = r.i32()
    es, n, d = _array(r)
    if hi_tan:
        nrm = np.frombuffer(d, '<i2').reshape(nv, 8)[:, 4:7].astype(np.float32) / 32767.0
    else:
        nrm = np.frombuffer(d, np.int8).reshape(nv, 8)[:, 4:7].astype(np.float32) / 127.0
    es, n, d = _array(r)
    uv = (np.frombuffer(d, '<f4') if full_uv else np.frombuffer(d, '<f2')
          ).astype(np.float32).reshape(nv, ntc, 2)
    r.o += 2
    r.i32(); cn = r.i32()
    col = None
    if cn > 0:
        es, n, d = _array(r)
        col = np.frombuffer(d, np.uint8).reshape(n, 4)[:, [2, 1, 0, 3]]
    idx = _index_buffer(r)
    l = np.linalg.norm(nrm, axis=1, keepdims=True)
    nrm = nrm / np.maximum(l, 1e-6)
    geo = dict(pos=pos, nrm=nrm, uv=uv, idx=idx, color=col)
    if not full:
        return geo
    # the rest is only skipped, to reach the next LOD
    if not cls & 4:
        _index_buffer(r)                         # reversed
    _index_buffer(r)                             # depth only
    if not cls & 4:
        _index_buffer(r)                         # reversed depth only
    if not strip[0] & 1:
        _index_buffer(r)                         # wireframe (editor data)
    if not cls & 1:
        _index_buffer(r)                         # adjacency
    for _ in range(nsec + 1):                    # area-weighted samplers
        n = r.i32(); r.o += 4 * n
        n = r.i32(); r.o += 4 * n
        r.o += 4
    return geo


def _lod(pkg, r):
    r.o += 2
    nsec = r.i32()
    if not 0 < nsec < 4096:
        raise ValueError('bad section count')
    secs = []
    for _ in range(nsec):
        m, first, ntri, vmin, vmax = r.fs(5, 'i'); r.o += 16
        secs.append((m, first, ntri))
    r.f32()
    cooked_out = r.i32(); inlined = r.i32()
    geo = None
    if cooked_out:
        return None                              # stripped (MinLOD): nothing follows
    if inlined:
        geo = _buffers(r, nsec)
    else:
        d = utex.bulk(pkg, r)
        if d:
            geo = _buffers(Reader(d, 0), nsec, full=False)
        r.o += 88                                # availability info
    r.o += 12                                    # buffer sizes
    if geo is not None:
        n = len(geo['idx'])
        for m, first, ntri in secs:
            if first + 3 * ntri > n:
                raise ValueError('section past the index buffer')
        geo['sections'] = secs
        geo['tris'] = sum(s[2] for s in secs)
    return geo


def static_mesh(pkg, exp=None, want_lods=None):
    """All LODs (or the first `want_lods`); a LOD that cannot be read is None."""
    exp = exp or pkg.find('StaticMesh')[0]
    props, r = pkg.export_props(exp)
    object_guid(r)
    r.o += 2                                     # strip flags
    r.i32(); r.i32(); r.i32()                    # bCooked, BodySetup, NavCollision
    r.o += 16                                    # lighting guid
    ns = r.i32(); r.o += 4 * ns                  # sockets
    nlod = r.i32()
    lods = []
    for li in range(nlod):
        if want_lods is not None and len(lods) >= want_lods:
            break
        try:
            geo = _lod(pkg, r)
        except Exception:
            # a layout this reader does not know: keep what was read so far
            break
        lods.append(geo)
    mats = [m.get('MaterialInterface', ('obj', 0, None))[2]
            for m in props.get('StaticMaterials', [])]
    slots = [m.get('MaterialSlotName') for m in props.get('StaticMaterials', [])]
    if not any(l is not None for l in lods):
        raise ValueError('no readable LOD')
    return dict(lods=lods, materials=mats, slots=slots, props=props)


def pick_lod(m, max_tris):
    """the most detailed LOD with at most max_tris triangles (else the smallest)"""
    ok = [l for l in m['lods'] if l is not None]
    for l in ok:
        if l['tris'] <= max_tris:
            return l
    return min(ok, key=lambda l: l['tris'])
