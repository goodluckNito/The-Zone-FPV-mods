"""Rebuild the faces vbsp deleted.

CS mappers paint `tools/toolsnodraw` on surfaces a 1.8 m player can never see -
the flat tops of roofs, the backs of parapets, ceilings above the playable
volume. vbsp keeps the brush solid for collision but *removes* the renderable
face, so a drone flying above the map looks straight into the buildings.

The brush geometry survives in the BRUSHES / BRUSHSIDES lumps, where each side
still carries its texinfo. This module reconstructs those polygons, keeps only
the ones actually exposed to open air, and borrows a material from a sibling
side of the same brush so the fill matches the building it belongs to.
"""
import itertools, collections, numpy as np
from . import bsp as B, build as BU

L_BRUSHES, L_BRUSHSIDES = 18, 19
CONTENTS_SOLID = 0x1

BRUSH_DT = np.dtype([('firstside', '<i4'), ('numsides', '<i4'), ('contents', '<i4')])
SIDE_DT = np.dtype([('planenum', '<u2'), ('texinfo', '<i2'),
                    ('dispinfo', '<i2'), ('bevel', '<i2')])

# fallback built-in materials, by which way the surface faces. These are the
# game's own PBR set, so they cost nothing in file size and light natively.
Z_FALLBACK = {'up': 'z_clean-concrete', 'down': 'z_concrete2',
              'vertical': 'z_grainy-concrete'}

TOOL_MAT = ('nodraw', 'skybox', 'skip', 'hint', 'clip', 'areaportal', 'trigger',
            'origin', 'blocklight', 'block_los', 'blockbullets', 'invisible',
            'playerclip', 'npcclip', 'occluder', 'fog', 'nodrawroof')


def _is_tool(name):
    n = name.lower()
    return n.startswith('tools/') or any(t in n for t in TOOL_MAT)


def is_sky_shell(br, polys):
    """Is this brush part of the map's sealing shell rather than scenery?

    The shell is the hollow box of brushes that seals a Source map against the
    void. Its INNER faces are `tools/toolsskybox` (which is what draws the 2D
    sky) and its outer faces, which nothing in a 1.8 m game can ever see, are
    painted nodraw. The fill therefore rebuilds them - and a rebuilt shell is a
    solid lid sitting just outside the sky, invisible from below because it
    faces away, which is exactly what a drone hits when it climbs out of the
    map.

    de_cache is the worst case because its mapper named the texture
    `tools/toolsnodraw_roof`: 141 sides, 29,014 m2, ceiling slabs at 20-30 m
    over the whole playable area. de_aztec has one 81,624 m2 plate 84 m *below*
    the map for the same reason.

    The test has to be narrow. "Every side is a tool material" alone is not
    usable - that is what an ordinary nodraw roof brush looks like, and it
    would delete 89,340 of de_nuke's 107,395 m2 of legitimate fill and 32,875
    of ctf_2fort's 53,887. Requiring a `toolsskybox` side as well is exact:
    it removes 141 sides on de_cache and 7 on de_aztec and changes nothing at
    all on de_nuke, de_dust2, de_inferno or ctf_2fort. de_dust2's two brushes
    that touch the sky are real walls carrying `de_dust/templewall02a`, so
    they keep their fill.
    """
    names = [(br.side_material(si) or '') for si in polys]
    if not any('toolsskybox' in n.lower() for n in names):
        return False
    return all(_is_tool(n) for n in names if n)


def orient_of(n):
    if n[2] > 0.7:
        return 'up'
    if n[2] < -0.7:
        return 'down'
    return 'vertical'


class Brushes:
    def __init__(self, bsp):
        self.bsp = bsp
        self.brushes = np.frombuffer(bsp.lump(L_BRUSHES), dtype=BRUSH_DT)
        self.sides = np.frombuffer(bsp.lump(L_BRUSHSIDES), dtype=SIDE_DT)
        self.solid = np.flatnonzero(self.brushes['contents'] & CONTENTS_SOLID)
        self._planes = {}
        self._grid = None
        self._cell = 256.0
        self._shell = set()     # filled by build_index; see is_sky_shell

    def side_material(self, si):
        ti = int(self.sides[si]['texinfo'])
        if ti < 0:
            return None
        td = self.bsp.texdata[self.bsp.texinfo[ti]['texdata']]
        return self.bsp.tex_names[td['name_id']]

    def brush_planes(self, bi):
        """(normals, dists, side_indices) for the brush's real (non-bevel) sides."""
        if bi in self._planes:
            return self._planes[bi]
        b = self.brushes[bi]
        f, n = int(b['firstside']), int(b['numsides'])
        N, D, S = [], [], []
        for si in range(f, f + n):
            s = self.sides[si]
            if s['bevel']:
                continue
            pl = self.bsp.planes[int(s['planenum'])]
            N.append(pl['normal']); D.append(float(pl['dist'])); S.append(si)
        out = (np.array(N, np.float64).reshape(-1, 3), np.array(D, np.float64),
               np.array(S, np.int64))
        self._planes[bi] = out
        return out

    def polygons(self, bi, eps=0.06):
        """Convex-hull the brush's half-spaces -> {side_index: ordered verts}."""
        N, D, S = self.brush_planes(bi)
        m = len(N)
        if m < 4:
            return {}
        tri = np.array(list(itertools.combinations(range(m), 3)), np.int64)
        if len(tri) == 0:
            return {}
        A = N[tri]                                   # (T,3,3)
        rhs = D[tri]                                 # (T,3)
        det = np.linalg.det(A)
        ok = np.abs(det) > 1e-6
        if not ok.any():
            return {}
        pts = np.full((len(tri), 3), np.nan)
        pts[ok] = np.linalg.solve(A[ok], rhs[ok][:, :, None])[:, :, 0]
        good = ok & np.isfinite(pts).all(1)
        if not good.any():
            return {}
        P = pts[good]
        # keep only points inside every half-space (normals point outward)
        inside = ((P @ N.T) <= (D[None, :] + eps)).all(1)
        P = P[inside]
        if len(P) < 4:
            return {}
        out = {}
        for k in range(m):
            on = np.abs(P @ N[k] - D[k]) < eps
            q = P[on]
            if len(q) < 3:
                continue
            q = np.unique(np.round(q, 2), axis=0)
            if len(q) < 3:
                continue
            c = q.mean(0)
            nk = N[k]
            u = np.array([1.0, 0, 0]) if abs(nk[0]) < 0.9 else np.array([0, 1.0, 0])
            u = u - nk * (u @ nk); u /= np.linalg.norm(u)
            v = np.cross(nk, u)
            ang = np.arctan2((q - c) @ v, (q - c) @ u)
            q = q[np.argsort(ang)]                  # CCW about the outward normal
            out[int(S[k])] = q
        return out

    # ---- spatial index for the "is it buried?" test ---------------------
    def build_index(self):
        if self._grid is not None:
            return
        self._grid = collections.defaultdict(list)
        self._aabb = {}
        for bi in self.solid:
            N, D, S = self.brush_planes(int(bi))
            if len(N) < 4:
                continue
            polys = self.polygons(int(bi))
            if not polys:
                continue
            if is_sky_shell(self, polys):
                self._shell.add(int(bi))
            allp = np.concatenate(list(polys.values()))
            lo, hi = allp.min(0), allp.max(0)
            self._aabb[int(bi)] = (lo, hi, N, D)
            for ix in range(int(lo[0] // self._cell), int(hi[0] // self._cell) + 1):
                for iy in range(int(lo[1] // self._cell), int(hi[1] // self._cell) + 1):
                    for iz in range(int(lo[2] // self._cell), int(hi[2] // self._cell) + 1):
                        self._grid[(ix, iy, iz)].append(int(bi))

    def point_in_solid(self, p, skip=None, margin=0.2):
        """Is this point inside a solid brush we would actually DRAW?

        The sky shell is excluded, and that is not a detail. Refusing to draw
        the shell while still letting it occlude was a half-fix: de_cache's sky
        ceiling sits at only 18.6-20.5 m, directly on top of the warehouse
        roofs, so every roof panel under it measured `exposed 0.000` and was
        thrown away as buried. 18 up-facing sides, 378 m2, came back the moment
        the shell stopped counting - including the whole row of panels at
        y = 18.6 m across the middle of the map. If we will not render it, it
        cannot bury anything either.
        """
        return self._in_solid(p, skip, margin, self._shell)

    def point_in_any_solid(self, p, margin=0.2):
        """Containment against EVERY solid brush, shell included.

        Only for working out the shape of the sealed room the sky_camera sits
        in - that room's walls ARE the shell.
        """
        return self._in_solid(p, None, margin, ())

    def _in_solid(self, p, skip, margin, ignore):
        self.build_index()
        key = (int(p[0] // self._cell), int(p[1] // self._cell),
               int(p[2] // self._cell))
        for bi in self._grid.get(key, ()):
            if bi == skip or bi in ignore:
                continue
            lo, hi, N, D = self._aabb[bi]
            if (p < lo - 1).any() or (p > hi + 1).any():
                continue
            if bool(((N @ p) <= (D - margin)).all()):
                return True
        return False


GEOM_D = 4.0          # units per distance bucket


def _geom_key(n, d):
    ax = int(np.argmax(np.abs(n)))
    return (ax, 1 if n[ax] >= 0 else -1, int(round(d / GEOM_D)))


class DrawnFaces:
    """Which brush sides already have a rendered face, and which do not.

    vbsp deletes a face for two different reasons, and only one of them leaves
    a clue in the material name:

      * the mapper painted `tools/toolsnodraw` on it - caught by name;
      * the face points into the VOID outside the sealed map, so nothing can
        ever see it. vbsp drops those too, and the brush side keeps its REAL
        material, so a name test never finds them.

    The second kind is most of a building's outer shell and the top of any
    roof box, which is why a converted map looks hollow from outside and why
    de_nuke's blue warehouse had no roof: 1,519 sides and 29,523 m2 on de_nuke
    alone.

    A side is matched to a face by plane: FACES store `planenum`, BRUSHSIDES
    store the same index, and vbsp may use either of a plane pair - hence
    `>> 1`. vbsp also SPLITS one brush side into several faces, so a single
    centroid test can fall on a seam; several sample points are tried and any
    hit counts as drawn. That bias is deliberate - a false "drawn" loses a
    fill, a false "missing" duplicates geometry and z-fights.
    """

    def __init__(self, bsp):
        self.by_plane = collections.defaultdict(list)
        self.by_geom = collections.defaultdict(list)
        ments = BU.model_entities(bsp)
        for mi, m in enumerate(bsp.models):
            if mi and mi not in ments:
                continue          # model nothing references is never emitted
            f0, fn = int(m['firstface']), int(m['numfaces'])
            for fi in range(f0, f0 + fn):
                loop = bsp.face_loop(fi)
                if len(loop) < 3:
                    continue
                q = bsp.verts[loop].astype(np.float64)
                # The face's TRUE facing is the PLANE normal. Source stores
                # the loop clockwise about it - 10,610 of 10,617 sampled faces
                # on this map - and extract() rewinds every one of them to
                # match (`rewound` in the stats). Deriving the facing from the
                # loop as stored therefore gets it exactly backwards, which is
                # how the first version of this test came to compare each side
                # against the faces behind it instead of the ones on it.
                pn = np.array(bsp.planes[int(bsp.faces[fi]['planenum'])]['normal'],
                              np.float64)
                self.by_plane[int(bsp.faces[fi]['planenum']) >> 1].append(
                    (q, q.mean(0), pn))
                # ALSO index by geometry. vbsp's plane list is deduplicated
                # with a tolerance, so two brushes on what is visibly the same
                # surface can hold different plane indices - and then a
                # planenum lookup finds nothing and the side is rebuilt on top
                # of a face that is already there.
                self.by_geom[_geom_key(pn, float(pn @ q[0]))].append(
                    (q, q.mean(0), pn, float(pn @ q[0])))

    @staticmethod
    def _inside(poly, px, py, u, v):
        x, y = poly[:, u], poly[:, v]
        hit = False
        n = len(poly)
        for i in range(n):
            j = i - 1
            if (y[i] > py) != (y[j] > py):
                t = (y[j] - y[i])
                if t and px < (x[j] - x[i]) * (py - y[i]) / t + x[i]:
                    hit = not hit
        return hit

    def covers(self, planenum, poly, normal, pad=600.0, facing=False):
        """Is this brush side already covered by a face we draw?

        `facing` restricts the test to faces pointing the SAME way. Without
        it the `>> 1` plane pairing also matches the far side of a wall, which
        is a different surface and must still be rebuilt. With it, the test
        answers the narrower question this needs: would rebuilding put a
        second skin exactly where one is already drawn?
        """
        cands = self.by_plane.get(int(planenum) >> 1)
        if not cands:
            return False
        c = poly.mean(0)
        ax = int(np.argmax(np.abs(normal)))
        u, v = ([1, 2], [0, 2], [0, 1])[ax]
        samples = [c] + [c + (p - c) * 0.5 for p in poly]
        for q, qc, qn in cands:
            if np.linalg.norm(qc - c) > pad:
                continue
            if facing and qn @ normal < 0.99:
                continue
            for sp in samples:
                if self._inside(q, sp[u], sp[v], u, v):
                    return True
        return False



COVER_DROP = 0.90      # this much of a side already drawn -> do not rebuild it
COVER_SINK = 0.02      # any less, and the rebuilt side is nudged behind
SINK_UNITS = 0.25      # 6.4 mm: enough to lose every depth test, invisible


def _ccw(p):
    return p if (np.cross(p[1] - p[0], p[2] - p[0]) if p.shape[1] == 3
                 else (p[1, 0] - p[0, 0]) * (p[2, 1] - p[0, 1])
                 - (p[2, 0] - p[0, 0]) * (p[1, 1] - p[0, 1])) >= 0 else p[::-1]


def _shoelace(p):
    return 0.5 * abs(float(np.dot(p[:, 0], np.roll(p[:, 1], -1))
                           - np.dot(p[:, 1], np.roll(p[:, 0], -1))))


def _clip_area(subject, clip):
    """Area of the intersection of two convex polygons (Sutherland-Hodgman).

    Both a brush side and a BSP face are convex, which is what makes the exact
    answer this cheap.
    """
    out = subject
    for i in range(len(clip)):
        if len(out) < 3:
            return 0.0
        a, b = clip[i - 1], clip[i]
        ex, ey = b[0] - a[0], b[1] - a[1]
        cur, out = out, []
        sp = ex * (cur[-1][1] - a[1]) - ey * (cur[-1][0] - a[0])
        prev = cur[-1]
        for q in cur:
            sq = ex * (q[1] - a[1]) - ey * (q[0] - a[0])
            if sq >= 0:
                if sp < 0:
                    t = sp / (sp - sq)
                    out.append(prev + (q - prev) * t)
                out.append(q)
            elif sp >= 0:
                t = sp / (sp - sq)
                out.append(prev + (q - prev) * t)
            prev, sp = q, sq
        out = np.array(out) if len(out) >= 3 else []
    return _shoelace(out) if len(out) >= 3 else 0.0


def cov_index(index, poly, normal, dtol=0.6, pad=900.0):
    """Fraction of `poly` already covered by a same-facing polygon in `index`.

    `index` maps _geom_key -> [(poly, centroid, normal, plane distance)].
    """
    n = np.asarray(normal, np.float64)
    d = float(n @ poly[0])
    c = poly.mean(0)
    ax = int(np.argmax(np.abs(n)))
    u, v = ([1, 2], [0, 2], [0, 1])[ax]
    sub = _ccw(poly[:, [u, v]].astype(np.float64))
    area = _shoelace(sub)
    if area <= 0:
        return 0.0, 0
    lo, hi = poly.min(0) - 0.5, poly.max(0) + 0.5
    k0 = _geom_key(n, d)
    got = 0.0
    deep = 0
    for dk in (k0[2] - 1, k0[2], k0[2] + 1):
        for e in index.get((k0[0], k0[1], dk), ()):
            q, qc, qn, qd = e[0], e[1], e[2], e[3]
            if abs(qd - d) > dtol or qn @ n < 0.999:
                continue
            # a bounding-box reject, not a centroid radius: two 30 m2 fills
            # can overlap with their centres 25 m apart, and a radius test
            # quietly skipped exactly those
            if (q.min(0) > hi).any() or (q.max(0) < lo).any():
                continue
            a = _clip_area(sub, _ccw(q[:, [u, v]].astype(np.float64)))
            if a > 0:
                got += a
                # how far back the thing already there was pushed, so a third
                # skin on the same surface goes behind the second and not
                # level with it
                deep = max(deep, e[4] if len(e) > 4 else 0)
            if got >= area:
                break
    return min(got / area, 1.0), deep


def _coverage(self, poly, normal, dtol=0.6, pad=900.0):
    """Fraction of this brush side that a same-facing drawn face already covers."""
    return cov_index(self.by_geom, poly, normal, dtol, pad)[0]


DrawnFaces.coverage = _coverage



def exposed_fraction(br, bi, q, n, min_samples_area_m2=2.0, k=4,
                     scale=BU.UNIT, lift=1.5):
    """How much of this brush side has open air in front of it.

    The old test probed a SINGLE point, the polygon centroid. On a roof slab
    that is 31 x 23 m the centroid says nothing about the other 700 m2: one
    pipe, vent or overhang above the middle condemned the whole roof as
    "buried" and it was never rebuilt.

    Small sides still use the centroid alone - it is the same answer for a
    fraction of the cost.
    """
    c = q.mean(0)
    a = np.linalg.norm(np.cross(q - c, np.roll(q, -1, axis=0) - c).sum(0)) / 2
    if a * scale * scale < min_samples_area_m2:
        return 0.0 if br.point_in_solid(c + n * lift, skip=bi) else 1.0
    ax = int(np.argmax(np.abs(n)))
    u, v = ([1, 2], [0, 2], [0, 1])[ax]
    lo, hi = q.min(0), q.max(0)
    pts = [c]
    for i in range(k):
        for j in range(k):
            p = c.copy()
            p[u] = lo[u] + (hi[u] - lo[u]) * (i + 0.5) / k
            p[v] = lo[v] + (hi[v] - lo[v]) * (j + 0.5) / k
            if DrawnFaces._inside(q, p[u], p[v], u, v):
                pts.append(p)
    open_ = sum(0 if br.point_in_solid(p + n * lift, skip=bi) else 1 for p in pts)
    return open_ / float(len(pts))


def donate(brushes, bi, side_idx, normal):
    """Pick a real material from this brush's other sides."""
    N, D, S = brushes.brush_planes(bi)
    want = orient_of(normal)
    best = None
    for k, si in enumerate(S):
        if int(si) == side_idx:
            continue
        nm = brushes.side_material(int(si))
        if nm is None or _is_tool(nm):
            continue
        o = orient_of(N[k])
        # prefer a sibling facing the same way, then anything real
        score = (0 if o == want else 1 if o == 'vertical' or want == 'vertical' else 2)
        if best is None or score < best[0]:
            best = (score, nm, int(si))
    return best[1:] if best else (None, None)


class NeighbourIndex:
    """Rendered faces, bucketed spatially, so a fully-nodraw brush can borrow
    the material of whatever real surface sits next to it."""

    def __init__(self, bsp, cell=256.0):
        self.bsp, self.cell = bsp, cell
        self.grid = collections.defaultdict(list)
        for fi in range(len(bsp.faces)):
            nm, flags, w, h = bsp.face_material(fi)
            if nm is None or _is_tool(nm) or (flags & B.SKIP_FLAGS):
                continue
            loop = bsp.face_loop(fi)
            if len(loop) < 3:
                continue
            vs = bsp.verts[loop].astype(np.float64)
            c = vs.mean(0)
            n = np.array(bsp.planes[int(bsp.faces[fi]['planenum'])]['normal'], np.float64)
            ti = int(bsp.faces[fi]['texinfo'])
            area = np.linalg.norm(np.cross(vs - c, np.roll(vs, -1, axis=0) - c).sum(0)) / 2
            key = (int(c[0] // cell), int(c[1] // cell), int(c[2] // cell))
            self.grid[key].append((c, n, nm, ti, area))

    def nearest(self, point, normal, radius=420.0, align=0.80):
        best = None
        r = int(radius // self.cell) + 1
        k0 = (int(point[0] // self.cell), int(point[1] // self.cell),
              int(point[2] // self.cell))
        for dx in range(-r, r + 1):
            for dy in range(-r, r + 1):
                for dz in range(-r, r + 1):
                    for (c, n, nm, ti, area) in self.grid.get(
                            (k0[0] + dx, k0[1] + dy, k0[2] + dz), ()):
                        if abs(float(n @ normal)) < align:
                            continue
                        d = float(np.linalg.norm(c - point))
                        if d > radius:
                            continue
                        # closest wins, with a nudge toward bigger surfaces
                        score = d - min(area, 40000.0) ** 0.5 * 0.35
                        if best is None or score < best[0]:
                            best = (score, nm, ti)
        return (best[1], best[2]) if best else (None, None)


def collect(bsp, mode='exposed', min_area_m2=0.05, scale=BU.UNIT,
            exclude_volumes=(), rebuild_culled=True, min_exposed=0.10,
            verbose=True):
    """-> list of (material, donor_side_or_None, verts_src, normal) to add."""
    br = Brushes(bsp)
    br.build_index()          # also works out which brushes are the sky shell
    nb = None
    drawn = None
    stats = collections.Counter()
    out = []
    # rebuilt sides can also land on each other: two stacked brushes both
    # painted nodraw give two rebuilds of the same surface facing the same
    # way. 1,345 m2 of gm_br_pitfalls.
    emitted = collections.defaultdict(list)

    def emit(mat, ti, q, n, depth):
        cov, deep = cov_index(emitted, q, n)
        if cov >= COVER_DROP:
            stats['skipped_dup_fill'] += 1
            return False
        if cov > COVER_SINK:
            depth = max(depth, deep + 1)
            stats['sunk_behind_fill'] += 1
        emitted[_geom_key(n, float(n @ q[0]))].append(
            (q, q.mean(0), np.asarray(n, np.float64), float(n @ q[0]), depth))
        out.append((mat, ti, q - n * (SINK_UNITS * depth) if depth else q, n))
        stats['filled'] += 1
        return True
    for bi in br.solid:
        bi = int(bi)
        if bi in br._shell:
            stats['skipped_sky_shell'] += 1
            continue
        polys = br.polygons(bi)
        if not polys:
            continue
        N, D, S = br.brush_planes(bi)
        s2k = {int(s): k for k, s in enumerate(S)}
        for si, q in polys.items():
            nm = br.side_material(si)
            if nm is None:
                continue
            low = nm.lower()
            culled = False
            n0 = N[s2k[si]]

            # Is a face we already draw sitting on this exact surface, facing
            # the same way? Measured on gm_br_pitfalls, 778 of 783 rebuilt-on-
            # drawn triangle overlaps were coplanar to within 0.2 mm with the
            # normals identical to 4 decimals - a nodraw side painted flush
            # against a neighbouring brush's visible face, which is ordinary
            # mapping. A sample-point test is not enough: the drawn face is
            # often a small patch of a big side, so the overlap is measured as
            # real intersected AREA.
            sink = 0
            if 'nodraw' in low or (rebuild_culled and not _is_tool(nm)):
                if drawn is None:
                    drawn = DrawnFaces(bsp)
                cov = drawn.coverage(q, n0)
                if cov >= COVER_DROP:
                    stats['skipped_already_drawn'] += 1
                    continue
                if cov > COVER_SINK:
                    # partly covered: keep the rest of the side, but let the
                    # real face win the depth test everywhere they meet
                    sink = 1
                    stats['sunk_behind_drawn'] += 1
            if 'nodraw' not in low:
                # Not nodraw-painted. It is still worth rebuilding if vbsp
                # culled it for facing the void - but never a tool brush
                # (toolsskybox alone is 111,926 m2 on de_nuke, the sealing
                # shell, which must not become geometry).
                if not rebuild_culled or _is_tool(nm):
                    continue
                if drawn is None:
                    drawn = DrawnFaces(bsp)
                if drawn.covers(br.sides[si]['planenum'], q, N[s2k[si]]):
                    continue
                culled = True
            stats['culled_sides' if culled else 'nodraw_sides'] += 1
            n = N[s2k[si]]
            if exclude_volumes:
                c0 = q.mean(0)
                if any((c0 >= lo).all() and (c0 <= hi).all()
                       for lo, hi in exclude_volumes):
                    # belongs to a brush entity, whose own faces we place
                    # ourselves (and may have moved, e.g. an opened door)
                    stats['skipped_brush_entity'] += 1
                    continue
            o = orient_of(n)
            if mode == 'up' and o != 'up':
                stats['skipped_orientation'] += 1
                continue
            # area
            a = np.linalg.norm(np.cross(q - q.mean(0),
                                        np.roll(q, -1, axis=0) - q.mean(0)).sum(0)) / 2
            if a * scale * scale < min_area_m2:
                stats['skipped_tiny'] += 1
                continue
            if mode in ('exposed', 'up'):
                if exposed_fraction(br, bi, q, n, scale=scale) < min_exposed:
                    stats['skipped_buried'] += 1
                    continue
            if culled:
                # it kept its own texinfo, so the original material AND its
                # UV axes come straight off the side - better than donating
                if emit(nm, int(br.sides[si]['texinfo']), q, n, sink):
                    stats['rebuilt_own_material'] += 1
                continue
            mat, donor_side = donate(br, bi, si, n)
            donor_ti = None
            if mat is not None:
                donor_ti = int(br.sides[donor_side]['texinfo'])
                stats['donated_sibling'] += 1
            else:
                if nb is None:
                    nb = NeighbourIndex(bsp)
                mat, donor_ti = nb.nearest(q.mean(0), n)
                if mat is not None:
                    stats['donated_neighbour'] += 1
                else:
                    mat, donor_ti = Z_FALLBACK[o], None
                    stats['fallback_builtin'] += 1
            emit(mat, donor_ti, q, n, sink)
    if verbose:
        print(f"      nodraw sides {stats['nodraw_sides']}, filled {stats['filled']} "
              f"(sibling {stats['donated_sibling']}, neighbour "
              f"{stats['donated_neighbour']}, builtin {stats['fallback_builtin']}, "
              f"buried {stats['skipped_buried']}, tiny {stats['skipped_tiny']}, "
              f"void-culled {stats['rebuilt_own_material']}"
              + (f", wrong-facing {stats['skipped_orientation']}" if mode == 'up' else "")
              + (f", sky-shell brushes {stats['skipped_sky_shell']}"
                 if stats['skipped_sky_shell'] else "")
              + ")")
    return out, dict(stats)


def box_uv(verts, normal, metres_per_tile=2.0, scale=BU.UNIT):
    """World-aligned projection, for fills with no donor texinfo to borrow."""
    ax = int(np.argmax(np.abs(normal)))
    u_ax, v_ax = ([1, 2], [0, 2], [0, 1])[ax]
    k = 1.0 / (metres_per_tile / scale)
    return np.stack([verts[:, u_ax] * k, verts[:, v_ax] * k], axis=1).astype(np.float32)


def donor_axes_ok(bsp, texinfo_idx, normal, min_align=0.35):
    """Is the donor's texture projection usable on a face with this normal?

    Source picks texture axes per face. Borrowing axes that are nearly edge-on
    to the fill face smears the texture into streaks, so fall back to a plain
    box projection in that case.
    """
    tv = bsp.texinfo[texinfo_idx]['tex_vecs'].astype(np.float64)
    u, v = tv[0, :3], tv[1, :3]
    c = np.cross(u, v)
    n = np.linalg.norm(c)
    if n < 1e-12:
        return False
    return abs(float((c / n) @ normal)) >= min_align


def donor_uv(bsp, donor_side_texinfo, verts):
    """UVs using the donor material's own texture axes, so scale matches."""
    t = bsp.texinfo[donor_side_texinfo]
    td = bsp.texdata[t['texdata']]
    w = float(td['view_width']) or 1.0
    h = float(td['view_height']) or 1.0
    tv = t['tex_vecs'].astype(np.float64)
    u = (verts @ tv[0, :3] + tv[0, 3]) / w
    v = (verts @ tv[1, :3] + tv[1, 3]) / h
    return np.stack([u, v], axis=1).astype(np.float32)
