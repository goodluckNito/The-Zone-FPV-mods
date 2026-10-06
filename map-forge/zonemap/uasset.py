"""Unreal Engine 4.25-4.27 cooked packages (.uasset/.umap + .uexp + .ubulk).

The name, import and export maps, and tagged properties (a cooked pak
package that is not an IoStore container keeps its property tags, so
nothing about the classes needs to be known up front). Unversioned
packages - a version of 0 in the header, as -unversioned cooks write - are
read as 4.27.
"""
import struct

PKG_FilterEditorOnly = 0x80000000


class Reader:
    def __init__(self, b, o=0):
        self.b = b; self.o = o
    def u8(self): v = self.b[self.o]; self.o += 1; return v
    def i32(self): v, = struct.unpack_from('<i', self.b, self.o); self.o += 4; return v
    def u32(self): v, = struct.unpack_from('<I', self.b, self.o); self.o += 4; return v
    def i64(self): v, = struct.unpack_from('<q', self.b, self.o); self.o += 8; return v
    def u16(self): v, = struct.unpack_from('<H', self.b, self.o); self.o += 2; return v
    def f32(self): v, = struct.unpack_from('<f', self.b, self.o); self.o += 4; return v
    def f64(self): v, = struct.unpack_from('<d', self.b, self.o); self.o += 8; return v
    def fs(self, n, fmt): v = struct.unpack_from('<' + fmt * n, self.b, self.o); self.o += 4 * n; return v
    def bytes(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v
    def guid(self): return self.bytes(16)
    def fstring(self):
        n = self.i32()
        if n == 0: return ''
        if n < 0:
            s = self.b[self.o:self.o - 2 * n].decode('utf-16-le', 'replace'); self.o -= 2 * n
        else:
            s = self.b[self.o:self.o + n].decode('utf-8', 'replace'); self.o += n
        return s.rstrip('\0')


class Package:
    """pkg = Package(uasset_bytes, uexp_bytes, path='/Game/...')"""
    def __init__(self, uasset, uexp=b'', path='', ubulk=None, loader=None):
        self.path = path
        self.loader = loader
        self.ubulk = ubulk
        r = Reader(uasset)
        tag = r.u32(); assert tag == 0x9E2A83C1, 'not a uasset'
        legacy = r.i32()
        if legacy != -4: r.i32()
        self.ue4ver = r.i32(); self.licensee = r.i32()
        self.unversioned = self.ue4ver == 0
        if self.unversioned: self.ue4ver = 522     # cooked -unversioned: 4.27
        if legacy <= -8: r.i32()      # UE5 version
        n = r.i32()
        self.custom = {}
        for _ in range(n):
            g = r.guid(); v = r.i32(); self.custom[g] = v
        self.header_size = r.i32()
        r.fstring()
        self.flags = r.u32()
        name_n = r.i32(); name_off = r.i32()
        if not (self.flags & PKG_FilterEditorOnly) and self.ue4ver >= 516: r.fstring()
        if self.ue4ver >= 459: r.i32(); r.i32()
        exp_n = r.i32(); exp_off = r.i32()
        imp_n = r.i32(); imp_off = r.i32()
        r.i32()
        if self.ue4ver >= 384: r.i32(); r.i32()
        if self.ue4ver >= 510: r.i32()
        r.i32(); r.guid()
        if not (self.flags & PKG_FilterEditorOnly):
            if self.ue4ver >= 518: r.guid()
        gn = r.i32(); r.o += 8 * gn
        for _ in range(2):           # saved-by / compatible-with engine versions
            r.o += 2 * 3 + 4; r.fstring()
        r.u32()
        cn = r.i32(); r.o += 16 * cn
        r.u32()
        an = r.i32()
        for _ in range(an): r.fstring()
        if legacy > -7: r.i32()
        r.i32()
        self.bulk_start = r.i64()
        # names
        r.o = name_off; self.names = []
        for _ in range(name_n):
            self.names.append(r.fstring())
            if self.ue4ver >= 504: r.o += 4
        # imports
        r.o = imp_off; self.imports = []
        for _ in range(imp_n):
            cp = self.name(r); cn_ = self.name(r); outer = r.i32(); on = self.name(r)
            self.imports.append(dict(class_package=cp, class_name=cn_, outer=outer, name=on))
        # exports
        r.o = exp_off; self.exports = []
        for _ in range(exp_n):
            cls = r.i32(); sup = r.i32()
            tmpl = r.i32() if self.ue4ver >= 508 else 0
            outer = r.i32(); on = self.name(r); oflags = r.u32()
            if self.ue4ver >= 511: size = r.i64(); off = r.i64()
            else: size = r.i32(); off = r.i32()
            r.o += 4 * 3 + 16 + 4
            if self.ue4ver >= 365: r.o += 4
            if self.ue4ver >= 465: r.o += 4
            if self.ue4ver >= 507: r.o += 20
            self.exports.append(dict(cls=cls, super=sup, template=tmpl, outer=outer,
                                     name=on, flags=oflags, size=size, offset=off))
        self.data = uasset + uexp

    def load_ubulk(self):
        if self.ubulk is None and self.loader is not None:
            self.ubulk = self.loader(self.path + '.ubulk') or b''
        return self.ubulk or None

    def name(self, r):
        i = r.i32(); n = r.i32()
        s = self.names[i] if 0 <= i < len(self.names) else f'?{i}'
        return s if n == 0 else f'{s}_{n - 1}'

    def ref(self, idx):
        """FPackageIndex -> ('import'|'export', entry) or None"""
        if idx < 0: return ('import', self.imports[-idx - 1])
        if idx > 0: return ('export', self.exports[idx - 1])
        return None

    def ref_path(self, idx):
        """an import's full object path, e.g. /Game/Foo/Bar.Bar"""
        if idx == 0: return None
        parts = []
        while idx != 0:
            if idx < 0:
                e = self.imports[-idx - 1]; parts.append(e['name']); idx = e['outer']
            else:
                e = self.exports[idx - 1]; parts.append(e['name']); idx = e['outer']
                if idx == 0: parts.append(self.path)
        parts.reverse()
        return parts[0] + ('.' + '.'.join(parts[1:]) if len(parts) > 1 else '')

    def class_name(self, exp):
        c = exp['cls']
        if c < 0: return self.imports[-c - 1]['name']
        if c > 0: return self.exports[c - 1]['name']
        return 'Class'

    def export_reader(self, exp):
        # no slicing: a big level's data is hundreds of MB, and a copy per
        # export made reading Racetrack take minutes
        return Reader(self.data, exp['offset'])

    def find(self, cls=None, name=None):
        return [e for e in self.exports
                if (cls is None or self.class_name(e) == cls) and (name is None or e['name'] == name)]

    # ---- tagged properties ---------------------------------------------
    def props(self, r, end=None):
        out = {}
        while True:
            name = self.name(r)
            if name == 'None': break
            typ = self.name(r); size = r.i32(); aidx = r.i32()
            extra = {}
            if typ == 'StructProperty':
                extra['struct'] = self.name(r)
                if self.ue4ver >= 441: r.o += 16
            elif typ == 'BoolProperty': extra['bool'] = r.u8()
            elif typ in ('ByteProperty', 'EnumProperty'): extra['enum'] = self.name(r)
            elif typ == 'ArrayProperty':
                if self.ue4ver >= 282: extra['inner'] = self.name(r)
            elif typ == 'SetProperty': extra['inner'] = self.name(r)
            elif typ == 'MapProperty': extra['inner'] = self.name(r); extra['value'] = self.name(r)
            if self.ue4ver >= 503 and r.u8(): r.o += 16
            start = r.o
            try:
                v = self.value(r, typ, size, extra)
            except Exception as ex:
                v = ('<error>', typ, str(ex))
            r.o = start + size
            key = name if aidx == 0 else f'{name}[{aidx}]'
            out[key] = v
        return out

    def value(self, r, typ, size, extra, inner=False):
        if typ == 'BoolProperty': return bool(extra.get('bool')) if not inner else bool(r.u8())
        if typ == 'IntProperty': return r.i32()
        if typ == 'UInt32Property': return r.u32()
        if typ == 'Int64Property': return r.i64()
        if typ == 'UInt64Property': v, = struct.unpack_from('<Q', r.b, r.o); r.o += 8; return v
        if typ == 'Int16Property': v, = struct.unpack_from('<h', r.b, r.o); r.o += 2; return v
        if typ == 'UInt16Property': return r.u16()
        if typ == 'Int8Property': v, = struct.unpack_from('<b', r.b, r.o); r.o += 1; return v
        if typ == 'FloatProperty': return r.f32()
        if typ == 'DoubleProperty': return r.f64()
        if typ == 'NameProperty': return self.name(r)
        if typ == 'StrProperty': return r.fstring()
        if typ == 'EnumProperty': return self.name(r)
        if typ == 'ByteProperty':
            if inner: return r.u8()
            if extra.get('enum', 'None') == 'None' or size == 1: return r.u8()
            return self.name(r)
        if typ == 'LazyObjectProperty': return ('lazy', r.guid().hex())
        if typ in ('ObjectProperty', 'ClassProperty', 'InterfaceProperty', 'WeakObjectProperty'):
            i = r.i32(); return ('obj', i, self.ref_path(i))
        if typ in ('SoftObjectProperty', 'SoftClassProperty'):
            a = self.name(r); s = r.fstring(); return ('soft', a, s)
        if typ == 'TextProperty': return self.text(r)
        if typ == 'StructProperty': return self.struct(r, extra.get('struct'), size)
        if typ in ('ArrayProperty', 'SetProperty'):
            if typ == 'SetProperty': r.i32()
            n = r.i32(); it = extra.get('inner')
            if it == 'StructProperty':
                # an inner tag describes the elements
                self.name(r); self.name(r); r.i32(); r.i32(); sn = self.name(r)
                if self.ue4ver >= 441: r.o += 16
                if self.ue4ver >= 503 and r.u8(): r.o += 16
                return [self.struct(r, sn, None) for _ in range(n)]
            return [self.value(r, it, 0, {}, inner=True) for _ in range(n)]
        if typ == 'MapProperty':
            r.i32(); n = r.i32(); kt = extra['inner']; vt = extra['value']; out = []
            for _ in range(n):
                k = self.struct(r, None, None) if kt == 'StructProperty' else self.value(r, kt, 0, {}, inner=True)
                v = self.struct(r, None, None) if vt == 'StructProperty' else self.value(r, vt, 0, {}, inner=True)
                out.append((k, v))
            return out
        raise ValueError('unknown type ' + typ)

    NATIVE = {
        'Vector': ('fff',), 'Vector4': ('ffff',), 'Vector2D': ('ff',), 'Rotator': ('fff',),
        'Quat': ('ffff',), 'LinearColor': ('ffff',), 'IntPoint': ('ii',), 'IntVector': ('iii',),
    }

    def struct(self, r, sn, size):
        if sn in self.NATIVE:
            f = self.NATIVE[sn][0]; v = struct.unpack_from('<' + f, r.b, r.o); r.o += 4 * len(f); return v
        if sn == 'Color':
            b, g, rr, a = r.bytes(4); return (rr, g, b, a)
        if sn == 'Guid': return r.guid().hex()
        if sn == 'Box':
            v = struct.unpack_from('<6f', r.b, r.o); r.o += 24; valid = r.u8(); return v
        if sn == 'SoftObjectPath' or sn == 'SoftClassPath':
            a = self.name(r); s = r.fstring(); return ('soft', a, s)
        if sn == 'DateTime' or sn == 'Timespan': return r.i64()
        if sn == 'PerPlatformFloat': r.u8(); return r.f32()
        if sn == 'PerPlatformInt': r.u8(); return r.i32()
        if sn == 'PerPlatformBool': r.u8(); return bool(r.u8())
        if sn == 'FrameNumber': return r.i32()
        if sn == 'GameplayTagContainer':
            n = r.i32(); return [self.name(r) for _ in range(n)]
        return self.props(r)

    def text(self, r):
        flags = r.u32(); ht = struct.unpack_from('<b', r.b, r.o)[0]; r.o += 1
        if ht == -1:
            if r.i32(): return r.fstring()
            return ''
        if ht == 0:
            ns = r.fstring(); key = r.fstring(); src = r.fstring(); return src
        return ('<text>', ht)

    def export_props(self, exp):
        r = self.export_reader(exp)
        return self.props(r), r


def object_guid(r):
    if r.i32(): r.o += 16


def datatable_rows(pkg, exp=None):
    exp = exp or pkg.find('DataTable')[0]
    props, r = pkg.export_props(exp)
    object_guid(r)
    n = r.i32(); rows = {}
    for _ in range(n):
        rn = pkg.name(r); rows[rn] = pkg.props(r)
    return rows


def load_package(paks, path):
    """'/Game/Foo/Bar' (or '/Game/Foo/Bar.Bar') -> Package, or None"""
    path = path.split('.')[0]
    head = paks.read(path + '.uasset')
    if head is None:
        head = paks.read(path + '.umap')
    if head is None:
        return None
    return Package(head, paks.read(path + '.uexp') or b'', path,
                   loader=paks.read)


class Packages:
    """load_package with a cache, and properties merged with their archetype:
    a cooked object stores only what differs from its template (a Blueprint
    component's template, a class default object), so a component in a level
    often names no mesh of its own - the Blueprint's template has it."""

    def __init__(self, paks):
        self.paks = paks
        self.c = {}
        self._chains = {}
        self._full = {}

    def get(self, path):
        path = path.split('.')[0]
        key = path.lower()
        if key not in self.c:
            try:
                self.c[key] = load_package(self.paks, path)
            except Exception:
                self.c[key] = None
        return self.c[key]

    def _chain(self, pkg, i):
        names = []
        while i > 0:
            e = pkg.exports[i - 1]
            names.append(e['name'])
            i = e['outer']
        return tuple(reversed(names))

    def _index(self, pkg):
        k = id(pkg)
        if k not in self._chains:
            self._chains[k] = {self._chain(pkg, i + 1): i + 1 for i in range(len(pkg.exports))}
        return self._chains[k]

    def resolve(self, pkg, idx):
        """an FPackageIndex -> (package, export index) wherever it lives"""
        if idx > 0:
            return pkg, idx
        if idx == 0:
            return None
        names = []
        i = idx
        while i < 0:
            imp = pkg.imports[-i - 1]
            if imp['class_name'] == 'Package' and imp['outer'] == 0:
                break
            names.append(imp['name'])
            i = imp['outer']
        if i >= 0:
            return None
        path = pkg.imports[-i - 1]['name']
        if path.startswith('/Script/'):
            return None
        p2 = self.get(path)
        if p2 is None:
            return None
        j = self._index(p2).get(tuple(reversed(names)))
        return (p2, j) if j else None

    def props(self, pkg, i, depth=0):
        """export i's tagged properties over its archetype's, recursively"""
        key = (id(pkg), i)
        if key in self._full:
            return self._full[key]
        e = pkg.exports[i - 1]
        base = {}
        if depth < 8 and e['template']:
            r = self.resolve(pkg, e['template'])
            if r is not None and not (r[0] is pkg and r[1] == i):
                base = self.props(r[0], r[1], depth + 1)
        try:
            own = pkg.export_props(e)[0]
        except Exception:
            own = {}
        merged = dict(base)
        merged.update(own)
        self._full[key] = merged
        return merged
