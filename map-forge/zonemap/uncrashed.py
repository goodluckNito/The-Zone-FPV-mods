"""Uncrashed: FPV Drone Simulator map-editor maps -> a The Zone custom map.

A map made in Uncrashed's editor, including one from its Steam Workshop
(app 1682970), is a small JSON file: the base level it is built on (one of
the game's landscapes, BaseMapRow) and, for each catalogue item, the
transform of every copy placed (S_AssetsTransform). None of the art is in
it: the catalogue, DT_MapEditorAssets, maps each item (NewRow_N) to a mesh
or Blueprint inside the game's .pak files. So converting needs the game
installed, and reads the meshes, textures and landscape straight out of its
paks (upak / uasset / umesh / utex / uland).

What comes across:
  * the base level's landscape, as an adaptive terrain (uland), textured
    from its landscape material's main layer, with its rock layer on slopes;
  * the base level's static meshes (its horizon backdrop);
  * every placed item: meshes, and the static meshes of Blueprint items;
  * the spawn (the map's start pad), the time of day and sun direction.
What does not: Blueprint behaviour (lights, moving parts, water volumes),
decals, foliage wind, and anything the graph of a material computes beyond
its main texture (world-aligned "triplanar" materials get box-projected
UVs instead).
"""
import os, re, glob, json, math, time, collections
import numpy as np
from . import upak, uasset, umesh, umat, uland, ugeo, ulevel, locate, manifest as MF
from .glb import Glb
from .convert import mirror_faces, slug, ENGINE_DEFAULT_SPAWN_Y
from .cutout import trim

APP_ID = '1682970'
CATALOGUE = '/Game/MapEditor/DataTables/DT_MapEditorAssets'
GATE_TABLE = '/Game/MapEditor/DataTables/DT_MapEditorGates'
LEVEL_TABLE = '/Game/AntizeMenu/Logics/LevelName/DT_LevelName'
SPAWNER = re.compile(r'BP_ME_Spawner', re.I)


# ---- finding things ---------------------------------------------------------
def _paks_under(d, depth=5):
    if not d or not os.path.isdir(d):
        return None
    for root, dirs, files in os.walk(d):
        if os.path.basename(root).lower() == 'paks' and \
                any(f.lower().startswith('pakchunk0') and f.lower().endswith('.pak') for f in files):
            return root
        if root[len(d):].count(os.sep) >= depth:
            dirs[:] = []
        else:
            dirs[:] = [x for x in dirs if x.lower() not in ('binaries', 'engine', 'saved')]
    return None


def find_paks(game_dir=None):
    """the game's Content/Paks folder: --game-dir, else the newest install
    found in any Steam library (Steam names the folder 'Uncrashed FPV Drone
    Sim')"""
    if game_dir:
        p = _paks_under(game_dir)
        if p:
            return p
        raise SystemExit(f'FATAL: no Uncrashed .pak files under {game_dir}')
    found = []
    for c in locate._commons(locate.steam_roots()):
        for d in glob.glob(os.path.join(c, '*ncrashed*')):
            p = _paks_under(d)
            if p:
                try:
                    t = max(os.path.getmtime(os.path.join(p, f)) for f in os.listdir(p)
                            if f.lower().endswith('.pak'))
                except ValueError:
                    continue
                found.append((t, p))
    if found:
        return max(found)[1]
    raise SystemExit(
        'FATAL: could not find Uncrashed\'s .pak files.\n'
        '  Pass the game folder, e.g.\n'
        '  --game-dir "C:/Program Files (x86)/Steam/steamapps/common/'
        'Uncrashed FPV Drone Sim"')


def is_uncrashed_map(path):
    """a map .json, a folder holding one (a Workshop item), or a Workshop id"""
    try:
        return _map_json(path) is not None
    except Exception:
        return False


def _workshop_dirs(item):
    out = []
    for r in locate.steam_roots():
        out.append(os.path.join(r, 'steamapps', 'workshop', 'content', APP_ID, item))
    return [d for d in out if os.path.isdir(d)]


def _map_json(arg):
    if os.path.isfile(arg) and arg.lower().endswith('.json'):
        with open(arg, 'rb') as f:
            head = f.read(4096)
        return arg if b'S_AssetsTransform' in head or b'BaseMapRow' in head else None
    dirs = [arg] if os.path.isdir(arg) else (_workshop_dirs(arg) if arg.isdigit() else [])
    for d in dirs:
        for j in sorted(glob.glob(os.path.join(d, '*.json'))):
            with open(j, 'rb') as f:
                head = f.read(4096)
            if b'S_AssetsTransform' in head or b'BaseMapRow' in head:
                return j
    return None


def load_map(arg):
    path = _map_json(arg)
    if path is None:
        raise SystemExit(f'not an Uncrashed map: {arg}')
    with open(path, encoding='utf-8-sig') as f:
        m = json.load(f)
    info = {}
    ip = os.path.splitext(path)[0] + '.info'
    if os.path.isfile(ip):
        try:
            with open(ip, encoding='utf-8-sig') as f:
                info = json.load(f)
        except ValueError:
            pass
    return path, m, info


# ---- the catalogue ------------------------------------------------------------
def _field(row, name):
    for k, v in row.items():
        if k == name or k.startswith(name + '_'):
            return v
    return None


def _obj(v):
    return v[2] if isinstance(v, tuple) and len(v) > 2 and v[0] == 'obj' else None


class Catalogue:
    def __init__(self, paks):
        self.paks = paks
        pkg = uasset.load_package(paks, CATALOGUE)
        if pkg is None:
            raise SystemExit(f'FATAL: {CATALOGUE} is not in the paks - is this Uncrashed?')
        self.rows = uasset.datatable_rows(pkg)
        self.levels = {}
        lt = uasset.load_package(paks, LEVEL_TABLE)
        if lt is not None:
            for rn, row in uasset.datatable_rows(lt).items():
                self.levels[rn.lower()] = (_field(row, 'WindowsName'),
                                           [str(x) for x in (_field(row, 'SubLevelName') or [])])
        self.gates = {}
        gt = uasset.load_package(paks, GATE_TABLE)
        if gt is not None:
            self.gates = uasset.datatable_rows(gt)
        self._umaps = None

    def find_level(self, name):
        """a level by its name ('L_BaseLandscape01', 'TheDock') -> /Game path"""
        if not name:
            return None
        if name.startswith('/'):
            return name if self.paks.exists(name + '.umap') else None
        if self._umaps is None:
            self._umaps = {}
            for k in self.paks.files():
                if k.endswith('.umap'):
                    self._umaps.setdefault(k.split('/')[-1][:-5], k)
        k = self._umaps.get(name.lower())
        if k is None:
            return None
        parts = k.split('/')
        if parts[1] == 'content':
            return ('/Game/' if parts[0] != 'engine' else '/Engine/') + '/'.join(parts[2:])[:-5]
        return None

    def level_paths(self, base_row):
        """BaseMapRow -> the level and its sublevels (DT_LevelName: a map can
        be built on any official level, not only the editor's landscapes)"""
        wn, subs = self.levels.get(str(base_row).lower(), (None, []))
        names = [wn] + subs if wn else ['L_' + str(base_row), str(base_row)]
        out = []
        for n in names:
            p = self.find_level(n)
            if p and p not in out:
                out.append(p)
            if not wn and out:
                break
        return out

    def gate(self, row_name):
        row = self.gates.get(row_name)
        if row is None:
            return None
        piv = _field(row, 'PivotOffset')
        return dict(mesh=_obj(_field(row, 'Mesh')),
                    pivot=tuple(piv) if isinstance(piv, tuple) else (0.0, 0.0, 0.0))

    def item(self, rname):
        row = self.rows.get(rname)
        if row is None:
            return None
        piv = _field(row, 'PivotPointOffset')
        tri = bool(_field(row, 'Triplanar?'))
        over = [_obj(x) for x in (_field(row, 'OverrideMaterial?') or [])]
        trim_ = [_obj(x) for x in (_field(row, 'TriplanarMaterial') or [])]
        bb = _field(row, 'BoundingBox')
        return dict(mesh=_obj(_field(row, 'Mesh')), blueprint=_obj(_field(row, 'Blueprint')),
                    pivot=tuple(piv) if isinstance(piv, tuple) else (0.0, 0.0, 0.0),
                    triplanar=tri, override=over, triplanar_mats=trim_,
                    bbox=tuple(bb) if isinstance(bb, tuple) and len(bb) == 3 else (1.0, 1.0, 1.0))


# ---- Blueprints: their static mesh components -------------------------------
DECAL_SIZE = (7.5, 200.0, 200.0)   # BP_ME_Decals' DecalComponent (half extents, cm)
MERGE_TOTAL = 150000                # triangles of one mesh worth baking copies of
# The far LODs of simple parts are not shapes any more: SM_Construction_Pale_03
# (an I-beam, 96 tris) is a twisted wedge at 22, sm_MetalBeam's 30-tri LOD
# bends its end out at 45 degrees, a 44-tri plank is 6 triangles at LOD3. A
# drone flies close to all of it, and stepping these down saves nothing worth
# having (141 I-beams at 48 tris less = 7k), so no LOD under this is used.
MIN_LOD_TRIS = 64
# ...but vegetation's far LODs are meant to change outline (cards, a thinner
# crown), and trees are where the triangles are: they skip the shape test
_VEGETATION = re.compile(r'(tree|pine|oak|elm|maple|birch|alder|willow|bush|shrub|grass|'
                         r'fern|foliage|plant|cork|spruce|fir_|palm|hedge|ivy|flower|weed)', re.I)


def blueprint_parts(paks, bp_path):
    """a Blueprint's construction script -> {'meshes': [(mesh, 4x4, overrides)],
    'decals': [(4x4, half size (cm), material)]}, relative to the actor.

    Instanced-mesh components are left out: their instances are added by the
    Blueprint's script at run time, so the template holds none. A Blueprint
    with a decal is the editor's decal item, and its static meshes are the
    editor's selection box and preview icon, hidden in game."""
    pkg = uasset.load_package(paks, bp_path)
    if pkg is None:
        return None
    exports = {i + 1: e for i, e in enumerate(pkg.exports)}
    props = {}

    def P(i):
        if i not in props:
            props[i] = pkg.export_props(exports[i])[0]
        return props[i]
    nodes = [i for i, e in exports.items() if pkg.class_name(e) == 'SCS_Node']
    children = set()
    for i in nodes:
        for c in P(i).get('ChildNodes', []) or []:
            if isinstance(c, tuple) and c[1] > 0:
                children.add(c[1])
    out = {'meshes': [], 'decals': []}

    def walk(i, parent):
        pr = P(i)
        tmpl = pr.get('ComponentTemplate')
        m = parent
        if isinstance(tmpl, tuple) and tmpl[1] > 0:
            ti = tmpl[1]
            tp = P(ti)
            m = parent @ ugeo.relative(tp)
            cls = pkg.class_name(exports[ti])
            shown = not tp.get('bHiddenInGame') and tp.get('bVisible', True) is not False
            if cls == 'StaticMeshComponent' and shown:
                mesh = _obj(tp.get('StaticMesh'))
                if mesh:
                    over = [_obj(x) for x in (tp.get('OverrideMaterials') or [])]
                    out['meshes'].append((mesh, m, over))
            elif cls == 'DecalComponent':
                size = tp.get('DecalSize')
                size = tuple(size) if isinstance(size, tuple) and len(size) == 3 else (128.0, 256.0, 256.0)
                out['decals'].append((m, size, _obj(tp.get('DecalMaterial'))))
        for c in pr.get('ChildNodes', []) or []:
            if isinstance(c, tuple) and c[1] > 0:
                walk(c[1], m)
    for i in nodes:
        if i not in children:
            walk(i, np.eye(4))
    if out['decals']:
        out['meshes'] = []
    return out


# ---- meshes in glTF space ----------------------------------------------------
class MeshCache:
    """meshes in glTF space, one LOD each: the most detailed under
    lod_tris, unless budget() has stepped it down"""

    def __init__(self, paks, lod_tris):
        self.paks = paks; self.lod_tris = lod_tris
        self.raw = {}
        self.c = {}
        self.choice = {}
        self.errors = {}
        self._shape = {}
        self.loose = set()          # foliage a level paints: no shape test

    def _raw(self, path):
        if path not in self.raw:
            m = None
            try:
                pkg = uasset.load_package(self.paks, path)
                if pkg is not None:
                    m = umesh.static_mesh(pkg)
            except Exception as ex:
                self.errors[path] = str(ex)
            self.raw[path] = m
        return self.raw[path]

    def lod_tris_list(self, path):
        m = self._raw(path)
        return None if m is None else [l['tris'] if l else None for l in m['lods']]

    def lod_shape_ok(self, path):
        """per LOD: does it still fill the most detailed LOD's bounding box
        (each side within 2 cm or 12 %)? A far LOD that bulges or bends out
        of it - sm_MetalBeam's last, SM_Construction_Pale_03's - has stopped
        being the shape, whatever its triangle count."""
        if path in self._shape:
            return self._shape[path]
        m = self._raw(path)
        out = []
        if m is not None and (path in self.loose or _VEGETATION.search(path.split('/')[-1])):
            out = [l is not None for l in m['lods']]
        elif m is not None:
            ref = None
            for l in m['lods']:
                if l is None or not len(l['pos']):
                    out.append(False)
                    continue
                lo, hi = l['pos'].min(axis=0), l['pos'].max(axis=0)
                if ref is None:
                    ref = (lo, hi, np.maximum(2.0, 0.12 * (hi - lo)))
                    out.append(True)
                    continue
                tol = ref[2]
                out.append(bool(np.all(np.abs(lo - ref[0]) <= tol)
                                and np.all(np.abs(hi - ref[1]) <= tol)))
        self._shape[path] = out
        return out

    def default_lod(self, path):
        tl = self.lod_tris_list(path) or []
        ok = [i for i, t in enumerate(tl) if t is not None]
        shape = self.lod_shape_ok(path)
        cap = self.lod_tris if self.lod_tris > 0 else 1 << 30
        for i in ok:
            if tl[i] <= cap and (i >= len(shape) or shape[i]):
                return i
        return min(ok, key=lambda i: tl[i]) if ok else 0

    def get(self, path):
        m = self._raw(path)
        if m is None:
            return None
        li = self.choice.get(path)
        if li is None:
            li = self.choice[path] = self.default_lod(path)
        key = (path, li)
        if key not in self.c:
            l = m['lods'][li]
            pos = ugeo.to_gltf_points(l['pos']).astype(np.float32)
            nrm = ugeo.to_gltf_dirs(l['nrm']).astype(np.float32)
            uv = l['uv'][:, 0, :].astype(np.float32)
            idx = l['idx'].astype(np.uint32)
            # the axis swap mirrors: put the winding back so that the front
            # face agrees with the stored normals
            t = idx[:len(idx) // 3 * 3].reshape(-1, 3)
            fn = np.cross(pos[t[:, 1]] - pos[t[:, 0]], pos[t[:, 2]] - pos[t[:, 0]])
            vn = nrm[t[:, 0]] + nrm[t[:, 1]] + nrm[t[:, 2]]
            if (np.einsum('ij,ij->i', fn, vn) < 0).mean() > 0.5:
                idx = t[:, ::-1].reshape(-1).copy()
            self.c[key] = dict(pos=pos, nrm=nrm, uv=uv, idx=idx, sections=l['sections'],
                               materials=m['materials'], tris=l['tris'], lod=li,
                               lods=[x['tris'] if x else None for x in m['lods']])
        return self.c[key]

    def budget(self, counts, budget, floor=0.12, floors=None):
        """Step the most expensive meshes down their LOD chain until the
        placed triangles fit the budget. A LOD under `floor` of the mesh's
        full detail is never used - by then it has lost its shape.
        -> (triangles before, after, {mesh: (from LOD, to LOD)})"""
        tl = {p: self.lod_tris_list(p) for p in counts}
        tl = {p: v for p, v in tl.items() if v}
        shape = {p: self.lod_shape_ok(p) + [False] * len(tl[p]) for p in tl}
        cur = {p: self.default_lod(p) for p in tl}
        first = dict(cur)
        total = sum(counts[p] * tl[p][cur[p]] for p in tl)
        before = total
        if budget > 0:
            while total > budget:
                best, gain = None, 0
                for p, i in cur.items():
                    lst = tl[p]
                    j = i + 1
                    while j < len(lst) and lst[j] is None:
                        j += 1
                    fl = (floors or {}).get(p, floor)
                    if (j >= len(lst) or lst[j] < fl * max(x for x in lst if x)
                            or lst[j] < MIN_LOD_TRIS or not shape[p][j]):
                        continue
                    g = counts[p] * (lst[i] - lst[j])
                    if g > gain:
                        best, gain = (p, j), g
                if best is None:
                    break
                cur[best[0]] = best[1]
                total -= gain
        self.choice.update(cur)
        changed = {p: (first[p], cur[p]) for p in cur if cur[p] != first[p]}
        return before, total, changed
    # foliage a level paints by the thousand may go down to its far LODs


def separate_coplanar(requests, meshes, mats_for, gap=1.0, tol=0.3):
    """Two overlapping, upright items that look different and whose top
    faces are less than `gap` cm apart: move the smaller one so they are
    `gap` apart. Mappers lay strips and slabs flush on floors (Temple of
    Serenity's white edging on its pavement); Unreal's TAA blends the fight
    away, The Zone shows it as faces flickering through the floor. The order
    Unreal draws is kept - a top already above stays above, one below goes
    further below - and a tie (within `tol`) puts the smaller one on top.
    -> (new requests, number moved)"""
    info = []
    for n, r in enumerate(requests):
        kind, path, W, over = r[0], r[1], r[2], r[3]
        m = meshes._raw(path) if kind == 'm' else None
        l = next((x for x in m['lods'] if x is not None), None) if m else None
        if l is None or not len(l['pos']):
            continue
        sc = np.linalg.norm(W[:3, :3], axis=0)
        if np.any(sc < 1e-9):
            continue
        R = W[:3, :3] / sc
        up = np.abs(R[2])
        if up.max() < 0.999:
            continue                               # tilted: its top is not a face
        lo, hi = l['pos'].min(axis=0), l['pos'].max(axis=0)
        corners = np.array([[x, y, z] for x in (lo[0], hi[0]) for y in (lo[1], hi[1])
                            for z in (lo[2], hi[2])])
        wc = corners @ W[:3, :3].T + W[:3, 3]
        a, b = wc.min(axis=0), wc.max(axis=0)
        k = int(np.argmax(up))
        h = [i for i in range(3) if i != k]
        area = float((hi[h[0]] - lo[h[0]]) * sc[h[0]] * (hi[h[1]] - lo[h[1]]) * sc[h[1]])
        info.append((n, a, b, area, tuple(mats_for({'materials': m['materials']}, over))))
    if not info:
        return requests, 0
    cell = 500.0
    grid = collections.defaultdict(list)
    big = []                                    # spans too many cells: compared with all
    for j, (n, a, b, area, mk) in enumerate(info):
        x0, x1 = int(np.floor(a[0] / cell)), int(np.floor(b[0] / cell))
        y0, y1 = int(np.floor(a[1] / cell)), int(np.floor(b[1] / cell))
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 64:
            big.append(j)
            continue
        for gx in range(x0, x1 + 1):
            for gy in range(y0, y1 + 1):
                grid[(gx, gy)].append(j)
    tops = np.array([x[2][2] for x in info])
    lows = np.array([x[1][:2] for x in info]); highs = np.array([x[2][:2] for x in info])
    areas = np.array([x[3] for x in info])
    mid = {}
    mats = np.array([mid.setdefault(x[4], len(mid)) for x in info])
    lift = {}
    seen = set()
    groups = list(grid.values())
    allj = np.arange(len(info))
    for j in big:
        near = allj[(np.abs(tops - tops[j]) < gap) & (mats != mats[j])]
        if len(near):
            groups.append([j] + near.tolist())
    for js in groups:
        if len(js) < 2:
            continue
        js = np.array(js)
        if len(set(mats[js].tolist())) < 2:
            continue
        bins = collections.defaultdict(list)
        for j in js:
            bins[int(np.floor(tops[j] / gap))].append(j)
        for bk, bj in bins.items():
            w = np.array(bj + bins.get(bk + 1, []))
            if len(w) < 2 or len(set(mats[w].tolist())) < 2:
                continue
            t, m = tops[w], mats[w]
            ok = (np.abs(t[:, None] - t[None, :]) < gap) & (m[:, None] != m[None, :])
            ok &= (np.minimum(highs[w, None, 0], highs[None, w, 0])
                   - np.maximum(lows[w, None, 0], lows[None, w, 0])) > 1.0
            ok &= (np.minimum(highs[w, None, 1], highs[None, w, 1])
                   - np.maximum(lows[w, None, 1], lows[None, w, 1])) > 1.0
            for x, y in np.argwhere(np.triu(ok, 1)):
                jx, jy = int(w[x]), int(w[y])
                key = (min(jx, jy), max(jx, jy))
                if key in seen:
                    continue
                seen.add(key)
                small, big = (jx, jy) if areas[jx] <= areas[jy] else (jy, jx)
                d = tops[small] - tops[big]
                shift = gap - d if (abs(d) < tol or d > 0) else -gap - d
                n = info[small][0]
                if abs(shift) > abs(lift.get(n, 0.0)):
                    lift[n] = shift
    if not lift:
        return requests, 0
    out = list(requests)
    for n, dz in lift.items():
        r = out[n]
        W = r[2].copy()
        W[2, 3] += dz
        out[n] = (r[0], r[1], W) + tuple(r[3:])
    return out, len(lift)


def _section(g, s):
    m, first, ntri = s
    return g['idx'][first:first + 3 * ntri]


def _sub(pos, nrm, uv, idx):
    used, inv = np.unique(idx, return_inverse=True)
    return pos[used], nrm[used], uv[used], inv.astype(np.uint32)


# ---- sky ------------------------------------------------------------------------
def sky_for(weather, sun_offset=0.0):
    """CustomWeather {timeOfDay (h), northyaw (deg), Cloud (0-1)} -> (skybox, rotation)"""
    tod = float(weather.get('timeOfDay', 12.0)) % 24.0
    cloud = float(weather.get('Cloud', 0.0))
    north = float(weather.get('northyaw', 0.0))
    if 5.0 <= tod < 7.5:
        sky = 'dawn'
    elif 17.5 <= tod < 20.5:
        sky = 'sunset'
    elif tod < 5.0 or tod >= 20.5:
        sky = 'dawn'
    elif cloud > 0.5:
        sky = 'cloudy_sunny'
    else:
        sky = 'sunny'
    # the sun's bearing, clockwise from north: east at 6, south at noon, west
    # at 18; Unreal's yaw is clockwise seen from above, so it adds to north.
    yaw_sun = north + 180.0 + (tod - 12.0) * 15.0
    rot = ((yaw_sun - 90.0 + sun_offset) + 180.0) % 360.0 - 180.0
    return sky, rot


# ---- the conversion -----------------------------------------------------------
def convert(map_arg, out_dir=None, name=None, out_root='./out', game_dir=None,
            lod_tris=4000, merge_tris=600, cell_m=48.0, albedo_px=512, normal_px=256,
            normals=True, jpeg_q=90, terrain=True, terrain_tol=10.0,
            terrain_falloff=0.01, backdrop=True, spawn_height=1.0,
            sky_energy=1.0, sun_offset=0.0, recenter=True, all_foliage=False,
            tri_budget=3000000, terrain_budget=1000000, with_decals=True, verbose=True):
    t0 = time.time()
    path, mp, info = load_map(map_arg)
    title = info.get('Name') or os.path.splitext(os.path.basename(path))[0]
    if not name:
        name = re.sub(r'_+', '_', slug(info.get('Name') or
                                       os.path.splitext(os.path.basename(path))[0])).strip('_')
        name = name or 'uncrashed_map'
    if out_dir is None:
        out_dir = os.path.join(out_root, name)
    paks_dir = find_paks(game_dir)
    paks = upak.PakSet(paks_dir)
    if verbose:
        print(f'[1/5] {title!r}: base {mp.get("BaseMapRow")}, '
              f'{sum(len(e.get("Transform", [])) for e in mp.get("S_AssetsTransform", []))} '
              f'placed items\n      game content: {paks_dir} ({len(paks.paks)} paks, '
              f'{len(paks.index)} files)')
    cat = Catalogue(paks)
    pc = uasset.Packages(paks)
    base_start = None
    glb = Glb(generator='zone-map-forge (Uncrashed)')
    bank = umat.UMaterialBank(glb, paks, albedo_px=albedo_px, normal_px=normal_px,
                              normals=normals, jpeg_q=jpeg_q)
    meshes = MeshCache(paks, lod_tris)
    chunks = ugeo.Chunks(cell_m, keep_pieces=with_decals)
    inst = collections.defaultdict(list)          # (mesh, mats) -> [glTF 4x4]
    stats = collections.Counter()
    missing_rows = collections.Counter()
    failed_meshes = collections.Counter()
    spawn = None

    def mats_for(g, over):
        ms = list(g['materials'])
        for i, o in enumerate(over or []):
            if o and i < len(ms):
                ms[i] = o
            elif o and i >= len(ms):
                ms.append(o)
        return tuple(ms)

    tiles = {}

    def tile_of(mpath):
        if mpath not in tiles:
            tiles[mpath] = _tile_of(mpath)
        return tiles[mpath]

    def _tile_of(mpath):
        ch = bank.chain(mpath) if mpath else None
        if ch:
            for k, v in ch['scal'].items():
                if re.match(r'^(param|tiles?|tiling|uv ?scale|world ?scale|scale)$', k.strip(), re.I) \
                        and 0 < v < 0.05:
                    return 0.01 / v
        return 4.0

    requests = []
    counts = collections.Counter()

    foliage = set()

    def place(mesh_path, W, over, triplanar=False, label='', is_foliage=False):
        requests.append(('m', mesh_path, W, over, triplanar, None))
        if is_foliage:
            foliage.add(mesh_path)

    def place_spline(mesh_path, W, pr, over):
        requests.append(('s', mesh_path, W, over, False, pr))

    def _place(mesh_path, W, over, triplanar=False, label='', geo=None):
        g = meshes.get(mesh_path)
        if g is None:
            failed_meshes[mesh_path] += 1
            return
        ms = mats_for(g, over)
        G = ugeo.gltf_matrix(W)
        stats['placed'] += 1
        stats['placed_tris'] += g['tris']
        # merge small meshes into the chunks, unless there are so many copies
        # that storing each one would cost more than instancing them
        small = g['tris'] <= merge_tris and counts[mesh_path] * g['tris'] <= MERGE_TOTAL
        # water is mapped world-aligned, so every copy is baked
        water = any(bank.get(m).water for m in ms if m)
        dec = None if (triplanar or geo is not None or small or water) else ugeo.decompose(G)
        if dec is not None:
            inst[(mesh_path, ms)].append(G)
            return
        # bake into the world chunks
        gp, gn = geo if geo is not None else (g['pos'], g['nrm'])
        pos, nrm, mirrored = ugeo.apply(G, gp.astype(np.float64), gn.astype(np.float64))
        centre = pos.mean(axis=0)
        for s in g['sections']:
            if s[2] <= 0:
                continue
            mp_ = ms[s[0]] if s[0] < len(ms) else None
            mi = bank.get(mp_)
            if mi.skip:
                continue
            idx = _section(g, s)
            if mirrored:
                idx = idx.reshape(-1, 3)[:, ::-1].reshape(-1)
            p, n, uv, ii = _sub(pos, nrm, g['uv'], idx)
            if triplanar:
                p, n, uv, ii = ugeo.box_uv(p, n, ii, tile_of(mp_))
            elif mi.water:
                p, n, uv, ii = ugeo.box_uv(p, n, ii, mi.water)
            if mi.two_sided:
                p, n, uv, ii = mirror_faces(p, n, uv, ii)
            chunks.add(mi.index, p, n, uv, ii, centre)
        stats['baked'] += 1

    def _place_spline(mesh_path, W, pr, over):
        """a spline mesh: the mesh bent along its curve, then baked"""
        g = meshes.get(mesh_path)
        if g is None:
            failed_meshes[mesh_path] += 1
            return
        # back to Unreal space (the Y/Z swap is its own inverse)
        ue_p = np.stack([g['pos'][:, 0], g['pos'][:, 2], g['pos'][:, 1]], axis=1) / ugeo.CM
        ue_n = np.stack([g['nrm'][:, 0], g['nrm'][:, 2], g['nrm'][:, 1]], axis=1)
        try:
            p2, n2 = ulevel.deform_spline(ue_p, ue_n, pr)
        except Exception:
            stats['splines_failed'] += 1
            return
        _place(mesh_path, W, over, geo=(ugeo.to_gltf_points(p2), ugeo.to_gltf_dirs(n2)))
        stats['spline_meshes'] += 1

    # ---- the placed items --------------------------------------------------------
    if verbose:
        print('[2/5] placing items...')
    bp_cache = {}
    decals = []
    for entry in mp.get('S_AssetsTransform', []):
        rn = entry.get('Rname')
        xs = entry.get('Transform', [])
        it = cat.item(rn)
        if it is None:
            img = _custom_decal(path, rn)
            if img is not None:
                mi = bank.decal_image(img, slug(os.path.splitext(rn)[0])[:40])
                for tr in xs:
                    decals.append((ugeo.ftransform(tr), DECAL_SIZE, mi, rn))
            elif re.match(r'^decal_', str(rn), re.I):
                stats['decals_missing_image'] += len(xs)
            else:
                missing_rows[rn] += len(xs)
            continue
        for tr in xs:
            W = ugeo.ftransform(tr)
            if it['mesh']:
                # the saved transform is the mesh's own: the row's
                # PivotPointOffset only steers the editor's gizmo. The game's
                # loader (LoadLevel.SpawnAssets) reads twelve of S_ME_Asset's
                # fields and never that one
                over = it['override'] or ([] if not it['triplanar'] else it['triplanar_mats'])
                place(it['mesh'], W, over, triplanar=it['triplanar'], label=rn)
            elif it['blueprint']:
                bp = it['blueprint'].split('.')[0]
                if SPAWNER.search(bp):
                    if spawn is None:
                        spawn = W
                    continue
                if bp not in bp_cache:
                    try:
                        bp_cache[bp] = blueprint_parts(paks, bp)
                    except Exception:
                        bp_cache[bp] = None
                parts = bp_cache[bp]
                if not parts or not (parts['meshes'] or parts['decals']):
                    stats['blueprints_without_meshes'] += 1
                    continue
                for mesh, rel, over in parts['meshes']:
                    place(mesh, W @ rel, over, label=rn)
                for rel, size, dmat in parts['decals']:
                    dmat = (it['override'] or [None])[0] or dmat
                    if not dmat:
                        continue
                    # (the row's BoundingBox is the editor's selection box: the
                    # decal Blueprint never resizes its decal)
                    decals.append((W @ rel, size, bank.decal(dmat), rn))
    if verbose:
        print(f"      {len(requests)} meshes to place")
        if missing_rows:
            print(f'      {sum(missing_rows.values())} items of {len(missing_rows)} catalogue '
                  f'rows this install does not have (the map is newer than the game files): '
                  + ', '.join(sorted(missing_rows)[:8]) + (' ...' if len(missing_rows) > 8 else ''))

    # ---- the base level ----------------------------------------------------------------
    base = mp.get('BaseMapRow') or ''
    terrains = []                   # (chunks, flat MatInfo, steep MatInfo, tiles)
    focus = None
    pts = [ugeo.ftransform(t)[:3, 3] for e in mp.get('S_AssetsTransform', [])
           for t in e.get('Transform', [])]
    if pts:
        a = np.array(pts)
        lo = np.percentile(a, 5, axis=0); hi = np.percentile(a, 95, axis=0)
        focus = (lo[0] - 3000, lo[1] - 3000, hi[0] + 3000, hi[1] + 3000)
    levels = cat.level_paths(base) if base else []
    if base and not levels:
        print(f'      base level {base!r} not found - no terrain')
    if levels and verbose:
        print(f'[3/5] base level {base}: {", ".join(p.split("/")[-1] for p in levels)}...')
    queue, seen, first = list(levels), set(), True
    land_mat = None

    def layer_name(info_path):
        p = pc.get(info_path)
        if p is None:
            return None
        for i, e in enumerate(p.exports, 1):
            if p.class_name(e) == 'LandscapeLayerInfoObject':
                return str(p.export_props(e)[0].get('LayerName') or '') or None
        return None
    while queue:
        lp = queue.pop(0)
        if lp.lower() in seen:
            continue
        seen.add(lp.lower())
        lv = ulevel.level_contents(pc, lp, keep_uncollidable_foliage=all_foliage)
        if lv is None:
            print(f'      level {lp} not in the paks')
            continue
        for k, v in lv['stats'].items():
            stats['level_' + k] += v
        queue += [cat.find_level(x) or x for x in lv['sublevels']]
        if backdrop:
            for mesh, W, over, nm, fol in lv['meshes']:
                place(mesh, W, over, label=nm, is_foliage=fol)
            for mesh, W, pr, over, nm in lv['splines']:
                place_spline(mesh, W, pr, over)
        if spawn is None and first and lv['player_start'] is not None:
            base_start = lv['player_start']
        first = False
        if not terrain:
            continue
        for lpkg, lexp in lv['landscapes']:
            try:
                L = uland.landscape_heights(lpkg, lexp, layer_name=layer_name)
            except Exception as ex:
                stats['landscapes_failed'] += 1
                continue
            if focus is None:
                cx = L['x0'] + L['z'].shape[1] * L['dx'] / 2
                cy = L['y0'] + L['z'].shape[0] * L['dy'] / 2
                focus = (cx - 10000, cy - 10000, cx + 10000, cy + 10000)
            tol, fall = terrain_tol, terrain_falloff
            while True:
                lc, steps = uland.build(L, focus, tol_near=tol, tol_slope=fall)
                n = int(sum(len(c[3]) // 3 for c in lc))
                if terrain_budget <= 0 or n <= terrain_budget or tol > 5000:
                    break
                # a fine landscape (CityPark's is 0.39 m a quad) blows past
                # the budget at 10 cm: loosen until it fits
                tol *= 1.6; fall *= 1.6
            if tol != terrain_tol:
                stats['terrain_tol_used_cm'] = round(tol, 1)
            mats = landscape_materials(bank, lpkg, lexp)
            if mats is None:
                mats = land_mat
            land_mat = land_mat or mats
            lmats, auto_rock = layer_materials(bank, lpkg, lexp, list(L['weights']))
            if lmats:
                stats['terrain_layers'] = max(stats['terrain_layers'], len(lmats))
            terrains.append((lc,) + tuple(mats) + (L, lmats, auto_rock))
            n = int(sum(len(c[3]) // 3 for c in lc))
            stats['terrain_tris'] += n
            if L.get('scale_assumed'):
                stats['terrain_scale_assumed'] += 1
            if verbose:
                print(f"      terrain {L['z'].shape[1] - 1}x{L['z'].shape[0] - 1} quads of "
                      f"{L['dx'] / 100:.2f} m -> {n:,} tris"
                      + (f' (tolerance raised to {tol:.0f} cm to fit)' if tol != terrain_tol else ''))
    land_chunks = [c for t in terrains for c in t[0]]

    # ---- race gates --------------------------------------------------------------------
    race = mp.get('Race') or {}
    for cp in race.get('CheckPoints', []) or []:
        g = cat.gate(cp.get('RowName'))
        tr = cp.get('Transform')
        if g is None or not tr:
            stats['gates_unknown'] += 1
            continue
        if not g['mesh']:
            stats['gates_invisible'] += 1
            continue
        # (as for items, the gate row's PivotOffset is editor-only: BP_RaceBase
        # reads Mesh, BoxDetectTransform and OffsetIndicator, not it)
        place(g['mesh'], ugeo.ftransform(tr), [])
        stats['gates'] += 1
    if verbose and (race.get('CheckPoints')):
        print(f"      race: {stats['gates']} gates placed, {stats['gates_invisible']} invisible")
    # ---- fit the triangle budget, then build ------------------------------------------
    counts.update(r[1] for r in requests)
    meshes.loose |= foliage
    meshes._shape.clear()
    # anything placed by the dozen (foliage, lamp posts, fence runs) may go
    # down to its far LODs; a one-off keeps its shape
    before, after, changed = meshes.budget(
        counts, tri_budget, floors={p: 0.02 for p in counts if p in foliage or counts[p] >= 40})
    stats['tris_before_budget'] = before
    stats['tris_after_budget'] = after
    stats['lods_stepped_down'] = len(changed)
    lod_changes = {k.split('.')[-1]: [int(a), int(b), int(counts[k])]
                   for k, (a, b) in sorted(changed.items(), key=lambda kv: -counts[kv[0]])}
    if verbose and changed:
        print(f'      {before:,} placed triangles over the {tri_budget:,} budget: '
              f'{len(changed)} meshes stepped down a LOD -> {after:,}')
    requests, n_lift = separate_coplanar(requests, meshes, mats_for)
    stats['coplanar_lifted'] = n_lift
    if verbose and n_lift:
        print(f'      {n_lift} items moved up to 1 cm off a different-looking surface in their plane')
    # surfaces are only kept for decals to land on when there are decals
    chunks.keep_pieces = bool(decals) and with_decals
    for kind, mesh_path, W, over, tri, pr in requests:
        if kind == 's':
            _place_spline(mesh_path, W, pr, over)
        else:
            _place(mesh_path, W, over, triplanar=tri)
    if verbose:
        print(f"      {stats['placed']} meshes placed ({stats['baked']} merged into "
              f"{cell_m:.0f} m chunks, {sum(len(v) for v in inst.values())} instanced)")

    if spawn is None and (info.get('Track') or race.get('CheckPoints')) and race.get('StartTransform'):
        st = ugeo.ftransform(race['StartTransform'])
        if np.abs(st[:3, 3]).max() > 1e-3:
            spawn = st
            stats['spawn_from'] = 'race start'
    if spawn is None and base_start is not None:
        spawn = base_start
        stats['spawn_from'] = 'base level start'

    if spawn is None:
        cl = mp.get('CamLoc')
        spawn = ugeo.ftransform(cl) if cl else np.eye(4)
        stats['spawn_from'] = 'camera'
    sp_g = ugeo.to_gltf_points(spawn[:3, 3][None, :])[0]
    # which way the spawn faces. The editor's start pad and a race's
    # StartTransform point along their +Y: SM_StartPreview's arrow is on +Y
    # (its flag on -Y), and Temple of Serenity's race start has +Y pointing at
    # gate 1 (cos 1.00). A level's PlayerStart and the editor camera are
    # ordinary Unreal actors, forward on +X.
    on_y = stats.get('spawn_from', 'start pad') in ('start pad', 'race start')
    fwd = spawn[:3, 1] if on_y else spawn[:3, 0]
    yaw = math.degrees(math.atan2(fwd[1], fwd[0]))
    shift = np.zeros(3)
    if recenter:
        shift = np.array([-sp_g[0], (ENGINE_DEFAULT_SPAWN_Y - spawn_height) - sp_g[1], -sp_g[2]])

    # ---- decals: cut out of the surfaces they cover ----------------------------------
    if decals and with_decals:
        n_ok = project_decals(decals, chunks, inst, meshes, land_chunks, bank)
        stats['decals'] = n_ok
        stats['decals_on_nothing'] = len(decals) - n_ok
        if verbose:
            print(f'      {n_ok} of {len(decals)} decals projected')

    # ---- emit ---------------------------------------------------------------------------
    if verbose:
        print('[4/5] building the glTF...')
    kids = []
    for ti, (lc, flat_mi, steep_mi, flat_tile, steep_tile, L, lmats, auto_rock) in enumerate(terrains):
        names = [n for n in L['weights'] if n in lmats]
        Wst = np.stack([L['weights'][n] for n in names]) if names else None
        zh, zw = L['z'].shape
        for ci, (cell, pos, nrm, idx) in enumerate(lc):
            t = idx.reshape(-1, 3)
            # the smooth (full-resolution) normals, so slopes split into whole
            # patches rather than a speckle of single triangles
            fn = nrm[t[:, 0]] + nrm[t[:, 1]] + nrm[t[:, 2]]
            fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
            steep = fn[:, 1] < 0.72
            groups = []
            if Wst is not None:
                # each triangle takes the layer painted most at its centre
                c = pos[t].mean(axis=1)
                col = np.clip(np.rint((c[:, 0] / ugeo.CM - L['x0']) / L['dx']), 0, zw - 1).astype(int)
                row = np.clip(np.rint((c[:, 2] / ugeo.CM - L['y0']) / L['dy']), 0, zh - 1).astype(int)
                w = Wst[:, row, col]
                dom = np.where(w.max(axis=0) > 0, w.argmax(axis=0), -1)
                if auto_rock is not None:
                    dom = np.where(steep, -2, dom)
                for k in np.unique(dom):
                    if k == -2:
                        mi, tile = auto_rock
                    elif k == -1:
                        mi, tile = flat_mi, flat_tile
                    else:
                        mi, tile = lmats[names[k]]
                    groups.append((dom == k, mi, tile))
            else:
                groups = [(~steep, flat_mi, flat_tile), (steep, steep_mi, steep_tile)]
            prims = []
            for sel, mi, tile in groups:
                if not sel.any():
                    continue
                p, n, _, ii = _sub(pos, nrm, pos[:, :2], t[sel].reshape(-1))
                uv = np.stack([p[:, 0], p[:, 2]], axis=1) / tile
                prims.append(((p + shift).astype(np.float32), n, uv.astype(np.float32), ii, mi.index))
            mi_ = glb.mesh(f'terrain{ti}_{cell[0]}_{cell[1]}', prims)
            kids.append(glb.node(f'terrain{ti}_{cell[0]}_{cell[1]}', mesh=mi_))
    for k, (mat, cell, pos, nrm, uv, idx) in enumerate(chunks.finish()):
        nm = f'chunk_{k}'
        mi_ = glb.mesh(nm, [((pos + shift).astype(np.float32), nrm, uv, idx, mat)])
        kids.append(glb.node(nm, mesh=mi_))
    stats['chunk_tris'] = chunks.tris()
    for (mesh_path, ms), Gs in inst.items():
        g = meshes.get(mesh_path)
        prims = []
        for s in g['sections']:
            if s[2] <= 0:
                continue
            mp_ = ms[s[0]] if s[0] < len(ms) else None
            mi = bank.get(mp_)
            if mi.skip:
                continue
            p, n, uv, ii = _sub(g['pos'], g['nrm'], g['uv'], _section(g, s))
            if mi.mask is not None:
                p, n, uv, tt, _, _ = trim(p, n, uv, ii.reshape(-1, 3), mi.mask, unit=1.0)
                ii = tt.reshape(-1)
            if mi.two_sided:
                p, n, uv, ii = mirror_faces(p, n, uv, ii)
            prims.append((p, n, uv, ii, mi.index))
        if not prims:
            continue
        leaf = mesh_path.split('.')[-1]
        mi_ = glb.mesh(leaf, prims)
        for G in Gs:
            t, q, s = ugeo.decompose(G)
            kids.append(glb.node(leaf, mesh=mi_, translation=t + shift, rotation=q, scale=s))
            stats['instanced_tris'] += g['tris']
    # material names: unique, and clear of the game's z_ substitution table
    seen = {}
    for mm in glb.j['materials']:
        nm = 'src_' + slug(mm['name'])
        if nm in seen:
            seen[nm] += 1
            nm = f'{nm}_{seen[nm]}'
        else:
            seen[nm] = 0
        mm['name'] = nm
    # the spawn's facing, as a Godot Y rotation; with recentring the whole map
    # turns about the spawn so that facing is the game's default (-Z) - an
    # uploaded map has no manifest to carry it
    th = math.radians(yaw)
    face = math.atan2(-math.cos(th), -math.sin(th))
    turn, turn_q = MF.spawn_turn(face) if recenter else (0.0, None)
    root = glb.node(name, children=kids, rotation=turn_q if turn else None)
    glb.root(root)
    os.makedirs(out_dir, exist_ok=True)
    glb_path = os.path.join(out_dir, f'{name}.glb')
    size = glb.save(glb_path)

    sky, rot = sky_for(mp.get('CustomWeather') or {}, sun_offset)
    rot = MF.wrap_deg(rot + math.degrees(turn))
    sp = sp_g + shift
    sp[1] += spawn_height if not recenter else 0.0
    if recenter:
        sp = np.array([0.0, ENGINE_DEFAULT_SPAWN_Y, 0.0])
    man = MF.build(spawn_pos=sp, spawn_yaw_rad=0.0 if recenter else face,
                   energy=sky_energy)
    man['skybox'] = {'skybox_name': sky, 'sky_rotation': round(rot, 2), 'energy': round(sky_energy, 3)}
    man['lighting_variations'] = {sky: {'skybox': dict(man['skybox'])}}
    MF.write(os.path.join(out_dir, 'manifest.json'), man)
    rep = {
        'map': title, 'name': name, 'out_dir': out_dir, 'source': path, 'base_level': base,
        'game_paks': paks_dir, 'meshes_placed': stats['placed'],
        'merged': stats['baked'], 'instanced': sum(len(v) for v in inst.values()),
        'unique_instanced_meshes': len(inst),
        'terrain_tris': stats['terrain_tris'], 'chunk_tris': int(stats['chunk_tris']),
        'instanced_tris': int(stats['instanced_tris']),
        'materials': len(glb.j['materials']), 'glb_bytes': size,
        'missing_catalogue_rows': dict(missing_rows),
        'failed_meshes': dict(failed_meshes),
        'blueprints_without_meshes': stats['blueprints_without_meshes'],
        'decals': stats['decals'], 'decals_on_nothing': stats['decals_on_nothing'],
        'gates': stats['gates'], 'gates_invisible': stats['gates_invisible'],
        'tris_before_budget': int(stats['tris_before_budget']),
        'tris_after_budget': int(stats['tris_after_budget']),
        'lods_stepped_down': stats['lods_stepped_down'],
        'lod_changes': lod_changes,           # mesh: [from LOD, to LOD, copies]
        'coplanar_lifted': stats['coplanar_lifted'],
        'spline_meshes': stats['spline_meshes'], 'spawn_from': stats.get('spawn_from', 'start pad'),
        'level': {k[6:]: v for k, v in stats.items() if k.startswith('level_')},
        'terrain_scale_assumed': bool(stats['terrain_scale_assumed']),
        'decals_missing_image': stats['decals_missing_image'],
        'spawn_ue_cm': [round(float(x), 1) for x in spawn[:3, 3]],
        'origin_shift': [round(float(x), 3) for x in shift], 'sky': sky,
        'map_turn_deg': round(math.degrees(turn), 2),
        'sky_rotation': round(rot, 2), 'manifest': man,
        'materials_detail': bank.report, 'seconds': round(time.time() - t0, 1),
    }
    with open(os.path.join(out_dir, 'convert_report.json'), 'w') as f:
        json.dump(rep, f, indent=1, default=str)
    if verbose:
        print(f'[5/5] {glb_path}  {size / 1e6:.1f} MB, '
              f'{rep["terrain_tris"] + rep["chunk_tris"] + rep["instanced_tris"]:,} tris, '
              f'{len(kids)} nodes, in {rep["seconds"]}s')
    return rep


def _custom_decal(map_json, rname):
    """a decal the map's author added: an image in the map's Decals folder"""
    if not re.match(r'^decal_.*\.(png|jpe?g|tga|bmp)$', str(rname), re.I):
        return None
    for d in ('Decals', 'decals', ''):
        p = os.path.join(os.path.dirname(map_json), d, rname)
        if os.path.isfile(p):
            from PIL import Image
            try:
                return np.asarray(Image.open(p).convert('RGBA'))
            except Exception:
                return None
    return None


def project_decals(decals, chunks, inst, meshes, land_chunks, bank):
    """-> how many decals landed on something"""
    # every surface, with its world bounding box
    srcs = [(p, i) for p, i in chunks.pieces]
    for (mesh_path, ms), Gs in inst.items():
        g = meshes.get(mesh_path)
        keep = []
        for s in g['sections']:
            mp_ = ms[s[0]] if s[0] < len(ms) else None
            if s[2] > 0 and not bank.get(mp_).skip:
                keep.append(_section(g, s))
        if not keep:
            continue
        idx = np.concatenate(keep)
        for G in Gs:
            srcs.append(((g['pos'] @ G[:3, :3].T + G[:3, 3]).astype(np.float32), idx))
    for cell, pos, nrm, idx in land_chunks:
        srcs.append((pos, idx))
    lo = np.array([p.min(axis=0) for p, _ in srcs]); hi = np.array([p.max(axis=0) for p, _ in srcs])
    n_ok = 0
    corners = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], float)
    for W, size, mi, rn in decals:
        G = ugeo.gltf_matrix(W)
        # decal box [-1,1]^3 -> Unreal local (cm) -> glTF local (m) -> world
        M = G[:3, :3] @ ugeo.P @ np.diag(np.asarray(size, float) * ugeo.CM)
        t = G[:3, 3]
        if abs(np.linalg.det(M)) < 1e-12:
            continue
        wc = corners @ M.T + t
        blo, bhi = wc.min(axis=0), wc.max(axis=0)
        near = np.flatnonzero((lo <= bhi).all(axis=1) & (hi >= blo).all(axis=1))
        got = ugeo.project_decal(M, t, [srcs[k] for k in near])
        if got is None:
            # nothing within the box: these meshes are not quite the game's
            # (a lower LOD, a merged copy), so look a little deeper
            M2 = M.copy(); M2[:, 0] *= 4.0
            wc = corners @ M2.T + t
            blo, bhi = wc.min(axis=0), wc.max(axis=0)
            near = np.flatnonzero((lo <= bhi).all(axis=1) & (hi >= blo).all(axis=1))
            got = ugeo.project_decal(M2, t, [srcs[k] for k in near])
        if got is None:
            continue
        p, n, uv, ii = got
        chunks.add(mi.index, p, n, uv, ii, surface=False)
        n_ok += 1
    return n_ok


def landscape_materials(bank, lvl, land_exp):
    """(flat MatInfo, steep MatInfo, flat tile m, steep tile m) from the
    landscape material: its first painted layer's base colour on the flat,
    its rock / cliff layer on slopes"""
    lp, _ = lvl.export_props(land_exp)
    lm = _obj(lp.get('LandscapeMaterial'))
    if not lm:
        return None
    ch = bank.chain(lm) if lm else {'tex': {}, 'vec': {}, 'scal': {}}
    cols = [(k, v) for k, v in ch['tex'].items()
            if re.search(r'(base ?colou?r|albedo|diffuse|_col$)', k, re.I)]
    rock = [kv for kv in cols if re.search(r'(rock|cliff|stone|slope)', kv[0], re.I)]
    flat = [kv for kv in cols if kv not in rock]
    # the layer the components actually paint, if it has a texture
    used = collections.Counter()
    for c in lp.get('LandscapeComponents', []):
        try:
            cp = lvl.export_props(lvl.ref(c[1])[1])[0]
        except Exception:
            continue
        for a in cp.get('WeightmapLayerAllocations', []) or []:
            li = a.get('LayerInfo') if isinstance(a, dict) else None
            if isinstance(li, tuple) and li[2]:
                used[li[2].split('.')[-1].replace('_LayerInfo', '')] += 1
        if sum(used.values()) > 64:
            break
    for layer, _ in used.most_common():
        hit = [kv for kv in flat if re.search(r'(^|_)' + re.escape(layer) + r'(_|$)', kv[0], re.I)]
        if hit:
            flat = hit + [kv for kv in flat if kv not in hit]
            break

    def tint_for(k):
        pre = k.split('_Texture')[0] if '_Texture' in k else k.rsplit('_', 1)[0]
        for vk, vv in ch['vec'].items():
            if vk.startswith(pre) and re.search(r'colou?r ?correction|tint', vk, re.I):
                return vv[:3]
        return None
    if not flat and not rock and lm:
        # not a layered landscape material: one surface everywhere, read like
        # any other material, at its own world tiling (the asphalt's 'tiles'
        # 0.002 = 5 m), or the editor's measuring board
        tile = 4.0
        for k, v in ch['scal'].items():
            if re.match(r'^(tiles?|tiling|uv ?scale|world ?scale)$', k.strip(), re.I) and 0 < v < 0.05:
                tile = 0.01 / v
        if re.search(r'baseboard', lm, re.I):
            mi = board_material(bank, ch)
            tile = 2.0
        else:
            mi = bank.get(lm)
        return mi, mi, tile, tile
    out = []
    for lst, tile, nm in ((flat, 4.0, 'terrain'), (rock or flat, 16.0, 'terrain_rock')):
        if lst:
            k, v = lst[0]
            nk = k.replace('Basecolor', 'Normal').replace('BaseColor', 'Normal')
            mi = bank.from_texture(nm, v, tint_for(k), ch['tex'].get(nk), roughness=0.95)
        else:
            mi = bank.from_texture(nm, None, (0.25, 0.3, 0.2), None, roughness=0.95)
        out.append((mi, tile))
    return out[0][0], out[1][0], out[0][1], out[1][1]


def _token_re(tok):
    return re.compile(r'(^|[^a-z0-9])' + re.escape(tok.lower()) + r'([^a-z0-9]|$)')


def layer_materials(bank, lvl, land_exp, layers):
    """{layer name: (MatInfo, tile m)} for the painted layers whose texture the
    landscape material names ('BaseColor Layer_3', 'MW_Layer4_TextureBasecolor'),
    and the rock / cliff texture no painted layer claims - an auto material's
    slope layer - or None for it"""
    lp, _ = lvl.export_props(land_exp)
    lm = _obj(lp.get('LandscapeMaterial'))
    if not lm or not layers:
        return {}, None
    ch = bank.chain(lm)
    cols = [(k, v) for k, v in ch['tex'].items()
            if re.search(r'(base ?colou?r|albedo|diffuse|_col$|colou?r texture)', k, re.I)
            and not v.startswith('/Engine/')]
    out, claimed = {}, set()
    for name in layers:
        parts = name.split('_')
        hit = None
        for n in range(len(parts), 0, -1):
            tok = '_'.join(parts[:n])
            if len(tok) < 3:
                break
            rx = _token_re(tok)
            cand = [kv for kv in cols if rx.search(kv[0].lower())]
            if cand:
                cand.sort(key=lambda kv: 'triplanar' in kv[0].lower())
                hit = (tok, cand[0])
                break
        if hit is None:
            continue
        tok, (k, v) = hit
        claimed.add(k)
        rx = _token_re(tok)
        tint = next((vv[:3] for vk, vv in ch['vec'].items() if rx.search(vk.lower())
                     and re.search(r'(colou?r ?(adjust|correction)|tint)', vk, re.I)), None)
        nrm = next((vv for vk, vv in ch['tex'].items() if rx.search(vk.lower())
                    and re.search(r'normal', vk, re.I) and 'triplanar' not in vk.lower()), None)
        out[name] = (bank.from_texture(slug('terrain_' + name)[:40], v, tint, nrm, roughness=0.95), 4.0)
    rock = [kv for kv in cols if kv[0] not in claimed
            and re.search(r'(rock|cliff|slope)', kv[0] + ' ' + kv[1], re.I)]
    auto = None
    if rock and out:
        k, v = rock[0]
        pre = re.split(r'_?texture', k, flags=re.I)[0]
        tint = next((vv[:3] for vk, vv in ch['vec'].items() if vk.startswith(pre)
                     and re.search(r'(colou?r ?(adjust|correction)|tint)', vk, re.I)), None)
        auto = (bank.from_texture('terrain_slope', v, tint, None, roughness=0.95), 16.0)
    return out, auto


def board_material(bank, ch):
    """BaseBoard's grid: its square texture is a white border on black - the
    lines - drawn dark on a pale grey board, as the level selector shows it"""
    sq = next((r for r in ch['refs'] if r.startswith('/') and 'square' in r.lower()), None)
    t = bank.texture(sq, 256) if sq else None
    if t is None:
        t = np.zeros((256, 256, 4), np.uint8)
        t[:6] = t[-6:] = t[:, :6] = t[:, -6:] = 255
    w = t[..., 0].astype(np.float32)[..., None] / 255.0
    cell = np.array([182, 189, 197], np.float32); line = np.array([92, 97, 104], np.float32)
    rgba = np.empty(t.shape[:2] + (4,), np.uint8)
    rgba[..., :3] = (cell * (1 - w) + line * w).astype(np.uint8)
    rgba[..., 3] = 255
    return bank.from_image('terrain_board', rgba, roughness=0.9)
