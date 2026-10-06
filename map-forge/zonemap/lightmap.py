"""Bake Valve's radiosity solution into the albedo (`--bake-lightmaps`).

Why it has to go into the albedo
--------------------------------
`materials2/custom_material/custom_material.gdshader`, read out of
`thezone.pck`, samples every map with the same coordinate:

    ALBEDO      = texture(albedo_texture, UV).rgb
    NORMAL_MAP  = texture(normal_texture, UV).rgb
    ROUGHNESS   = texture(roughness_texture, UV).r

There is exactly one channel in that shader that takes a second UV set -

    if (shadow_map_index >= 0.0) {
        vec4 shadow = sample_shadow_map(UV2, shadow_map_bucket, ...);
        ...  // light(): DIFFUSE_LIGHT = diffuse_light

- and `shadow_map_index` is an instance uniform the custom-map loader never
sets (probed twice in game: `"shadow_maps": 0`, no `.dds` ever opened). The
shader reads no vertex colour either. So a lightmap cannot be a second texture
and cannot be vertex data: the only way in is to multiply it into the albedo,
which means every lit face needs its own patch of texture instead of a tiled
one.

What that costs, measured
-------------------------
Valve's bake for `gm_br_pitfalls` is 4.1 M luxels over 459,323 m2 - 33 cm per
luxel, small enough to fit in one 2048x2048 page. It is the *albedo* that
costs, because a tiled 512 px material is about 0.6 cm per texel and an atlas
has to store every square metre exactly once:

    flat  5 cm/texel   183.7 M texels    44 pages
    flat 10 cm/texel    45.9 M texels    11 pages
    adaptive (below)    46.0 M texels    11 pages, and small faces stay sharp

Adaptive density is the default: `texel = clip(sqrt(face_area) / 48, 3 cm,
30 cm)`. A 1 m2 doorframe gets 3 cm texels, a 400 m2 warehouse wall gets 30 cm,
and since the big faces hold most of the area that is where the savings are.
For scale, the same map's 279 tiled world materials already spend 73 M texels,
and the bake REPLACES them - on a CS-sized map baking is a net reduction.

What is baked
-------------
Worldspawn brush faces that have a lightmap and an opaque material. Not
baked, and left on the tiled path: displacements, cut-out and translucent
sheets (they need their alpha), water, `WorldVertexTransition` blends, brush
entities (they move), and the faces `--fill` rebuilds - vbsp deleted those, so
Valve never lit them and there are no luxels to read.

Gotchas that shaped the code
----------------------------
* Bumped faces store FOUR lightmaps per style (`SURF_BUMPLIGHT`); the first is
  the non-directional one and the only one we want.
* `lm_size` is the grid's *extent*, so the sample grid is `(w+1, h+1)`.
* Light is linear, an albedo texel is sRGB. Multiplying them directly darkens
  everything; the product is formed in linear light and re-encoded.
* A `$color` above 1 is a gain the mapper added *because* the lightmap was
  going to darken it. `MaterialBank` drops that gain for the unlit path and
  records it as `tint_gain`; here it is put back, which is what it was for.
* Tiles are packed in map order (by chunk cell), not face order. Pack a page
  with faces from all over the map and every 48 m cell ends up touching every
  page, which multiplies the mesh count by the page count.
"""
import collections, math
import numpy as np
from PIL import Image

from . import bsp as B
from . import build as BU
from .materials import _srgb_to_lin, _lin_to_srgb, _png, _jpg

L_LIGHTING = 8
L_LIGHTING_HDR = 53
SURF_BUMPLIGHT = 0x800

PAGE_PX = 2048
PAD = 2                  # gutter texels, edge-extended
TEXEL_MIN_M = 0.03
TEXEL_MAX_M = 0.30
TEXEL_K = 48.0           # texel = sqrt(area) / K
EXPOSURE_PCT = 98.0      # only reported now, not used to set exposure
LIGHT_FULL = 128.0       # the lightmap value that means "fully lit", as Source
                         # reads it: 255 with the engine's overbright of 2
BRIGHTNESS = 1.0         # multiplier on that
KNEE_AT = 0.8            # where the soft top starts
TONE_KNEE = 2.0          # unused, kept so old callers do not break
KNEE_FLAT = 0.5          # the knee for a --flat-normals build. The game only
                         # multiplies a flat-normal surface by ~0.45, so the
                         # atlas has to carry 1/0.45 of the light and the top
                         # half of the range is shoulder either way - start
                         # rolling off early and gently rather than jamming
                         # everything above 45 % of "fully lit" into a corner
LIGHT_FLOOR = 0.04       # nothing goes fully black
MAT_PREFIX = '#lm'

# --- what the game does to a baked map on top of the bake -------------------
# Read out of thezone.pck, not guessed. custommaps/handler/custom_map_root.gd
# picks the environment with
#
#     if ZGamestate.lightmaps_enabled: env_scn = load(EnvBakedScene)
#     else:                            env_scn = load(EnvDynamicScene)
#
# and ingame_main.gd sets that flag with
#
#     ZGamestate.lightmaps_enabled = map_id in ['1','2','plaza','testmap'] \
#                                    and ZSettings.ENABLE_NEW_LIGHTING
#
# so the baked environment - no ambient, no shadows, DIFFUSE_LIGHT replaced by
# a shadow map - is hard-wired to the four official maps. A custom map ALWAYS
# gets env_dynamic.tscn, whatever its manifest says, and env_dynamic is:
#
#   * sky ambient at full energy, unoccluded, from SkyTexture5 (the manifest's
#     skybox block only rotates it; the energy line is inside the
#     lightmaps_enabled branch and never runs for a custom map)
#   * three DirectionalLight3Ds, all at 28.5 deg elevation, spread in azimuth:
#       L1 (-0.6397, 0.4775, 0.6022) energy 1.166, shadow_enabled = user setting
#       L2 ( 0.4556, 0.4775,-0.7513) energy 0.2,   no shadows
#       L3 ( 0.4708, 0.4775, 0.7418) energy 0.2,   no shadows
#   * ACES tonemapping, sky used as the reflection source
#
# The shader then renders ALBEDO * (DIFFUSE_LIGHT + AMBIENT_LIGHT) + SPECULAR,
# so whatever we bake is multiplied a second time by
#
#     g(N) = sum_i max(N.L_i, 0) * E_i * ATT_i  +  ambient(N)
#
# ATT_i being L1's realtime shadow. Pointing every normal straight up - what
# --flat-normals used to do - is the worst possible choice: it takes the most
# sun (g = 0.92), the most sky ambient, AND full dependence on that realtime
# shadow, which swings g down to 0.36 indoors and leaks through roofs because
# Godot offsets the shadow lookup along the normal, which now points at the
# sky through the roof. That is the "light coming through the walls" look.
#
# ZONE_FLAT_NORMAL is instead the direction that maximises g subject to
# N.L1 <= 0, so L1 drops out of the sum entirely and the realtime shadow - and
# its leak - cannot touch the map at all. It works out as roughly L2+L3. g is
# then constant everywhere: 0.40 to 0.52 depending on the manifest's sky
# rotation, 0.45 on average, which is what ZONE_FLAT_GAIN undoes.
ZONE_FLAT_NORMAL = (0.689, 0.725, -0.008)
ZONE_FLAT_GAIN = 2.2     # 1 / 0.45, fed to tonemap() BEFORE the knee, so the
                         # top rolls off instead of clipping
ZONE_BAKED_ROUGHNESS = 1.0

# --- the specular problem, measured with tools/make_spec_probe.py -----------
# SPECULAR_LIGHT is ADDED after ALBEDO is multiplied, so it does not care what
# the bake put in the albedo. A probe of eight panels with a PURE BLACK albedo,
# read straight off the screenshots (luminance out of 255):
#
#   panel 1  roughness 1.0 metallic 0  flat normal      blob peaks at 108
#   panel 2  ... + noise normal map                     sparkle, mean 54
#   panel 3  roughness 1.0 metallic 1  flat normal      0.0   <- exactly zero
#   panel 4  roughness 2.0 metallic 0  flat normal      19.4  <- >1 is clamped
#   panel 5  roughness 1.0 metallic 0  real face normal 15.8
#   panel 6  roughness 1.0 metallic 0  normal DOWN      0.0   <- exactly zero
#   panel 7  roughness 0.2 metallic 0  flat normal      1.6 here, mirror elsewhere
#   panel 8  WHITE albedo, roughness 1.0                216.8 <- exposure anchor
#
# Two cures, and only two. Panel 3 works because f0 = mix(0.04*spec*spec,
# ALBEDO, METALLIC) collapses to ALBEDO = 0 - useless on a real map, where a
# 0.2 albedo would make f0 twenty times LARGER than metallic 0 does. Panel 6
# works because specularBRDF = max(NdotL * D * G * F, 0) and NdotL is zero: a
# normal that faces away from every sun cannot reflect one. Roughness above 1
# is clamped on import, and a noise normal map trades the blob for sparkle
# that is brighter on average than the blob it replaced.
#
# So the only real lever is the normal, and it is a straight trade. The blob
# is 108/255 against a baked map whose median surface renders near 69, which
# is why it reads as a light source shining through the walls.
ZONE_NOSPEC_NORMAL = (-0.748, -0.279, -0.603)
ZONE_NOSPEC_GAIN = 7.9   # 1 / 0.127. Faces away from all three suns, so the
                         # specular is exactly zero and the sky ambient is all
                         # that is left - a clean map with a low ceiling: white
                         # tops out near 122/255 instead of 217.

# There is NO useful point between zero specular and full specular, and the
# 'low' / 'mid' presets that used to live here were built on a wrong model.
# They assumed the highlight scales with sum(E_i * NdotL_i). It does not. From
# the game's own shader:
#
#   G = 0.5 / mix(2*NdotL*NdotV, NdotL+NdotV, alpha)   alpha = ROUGHNESS^2 = 1
#   specularBRDF = NdotL * D * G * F                   D = 1/PI when alpha = 1
#
# so at a grazing view, where NdotV -> 0:
#
#   NdotL * (1/PI) * (0.5 / NdotL) * F  =  0.5 * D * F  =  0.159 * F
#
# The NdotL cancels. Measured across view angles:
#
#   NdotL    NdotV .6   NdotV .2   NdotV .02
#   0.665      0.0837     0.1224     0.1545
#   0.193      0.0387     0.0782     0.1442   <- the old 'low' preset
#   0.010      0.0026     0.0076     0.0531
#
# Dropping NdotL from 0.665 to 0.193 buys 7 % at grazing angles, not the 7x the
# old table claimed. And because every baked surface shares one normal, the
# highlight is a function of the VIEW direction alone - identical on every
# surface in the map at once. Turn one way and the whole world lights up; turn
# back and it goes out. A half-dome of light from one side of the map, through
# the walls, which is exactly what it looks like in game.
#
# Only NdotL == 0 for all three suns gives max(NdotL * D * G * F, 0) == 0. It
# is a cliff, not a curve: nospec, or live with it.
ZONE_LOW_NORMAL = ZONE_NOSPEC_NORMAL       # kept so old commands still run
ZONE_LOW_GAIN = ZONE_NOSPEC_GAIN
ZONE_MID_NORMAL = ZONE_NOSPEC_NORMAL
ZONE_MID_GAIN = ZONE_NOSPEC_GAIN

# The sky rotation is the one brightness lever that costs nothing. It is the
# only skybox field custom_map_root.gd applies to a custom map (the energy line
# sits inside the lightmaps_enabled branch), and rotating the panorama rotates
# the ambient with it. With the zero-specular normal, on de_cpl_strike:
#
#   sky_rotation    multiplier    white tops out at
#      45 deg          0.200            150
#      30 deg          0.198            149
#     143 deg (what the converter picked)  ~0.11        ~115
#     180 deg          0.094            106
#
# 45 deg is worth nearly double 143 deg, for free, with the specular still
# exactly zero. The cost is cosmetic: the visible sun no longer lines up with
# the direction the baked shadows were solved for.
ZONE_BEST_SKY_ROTATION = 45.0

# Even at its best the zero-specular normal only passes 0.200 of the light, and
# Godot tonemaps with ACES, whose toe is steep. The whole map therefore lives in
# that toe and gets crushed. Measured on de_cpl_strike's shipped atlas
# (p10 26, p50 79, p90 182 out of 255), what reaches the screen is:
#
#   gamma   p10  p25  p50  p75  p90
#   1.00      0    3   17   48   87     <- the map reads as "too dark"
#   0.75      4   13   33   66  100
#   0.60     13   25   47   79  107
#   0.45     29   43   65   93  116
#
# The lift is nearly free at the top: p90 moves 87 -> 107 because the highlights
# are already against the 0.200 ceiling, while the midtones go up three to four
# times. It is a cheat, but so is every other number here - the game gives a
# custom map a fifth of its light and then applies a filmic curve built for a
# full-range image.
ZONE_NOSPEC_GAMMA = 0.6


def tonemap(L, full=None, gain=1.0, knee=KNEE_AT):
    """Source's own mapping, with a soft top instead of a hard clip.

    A lightmap value is not relative, it is absolute: 255 is "fully lit" and
    the engine applies an overbright of 2, so a surface at 128 displays its
    albedo unchanged and anything above that is deliberately clipped. Valve's
    de_cpl_strike solve sits at p50 36, p90 308, p98 673 - most of the map is
    well under "fully lit" and the sunlit parts are far over it.

    Anchoring on a percentile instead (p98 -> 0.5, which is what the first
    version did) throws that away: the baked atlas came out at p50 19/255
    against the map's own textures at p50 112, six times too dark, and the
    game's exposure pulled the whole thing back up until the sunlit faces
    blew out and bloomed. Dark input, bright wrong-looking output.

    So: linear to LIGHT_FULL, exactly as Source, then a knee from 0.8 that
    approaches 1.0 without ever clipping.
    """
    u = np.maximum(np.asarray(L, np.float64), 0.0) * gain / float(full or LIGHT_FULL)
    at = float(knee) if 0.0 < float(knee) < 1.0 else KNEE_AT
    k = 1.0 - at
    return np.where(u <= at,
                    u, at + k * (1.0 - np.exp(-(u - at) / max(k, 1e-6))))


def _decode(raw, n):
    """n ColorRGBExp32 samples -> (n, 3) float linear light."""
    a = np.frombuffer(raw, dtype=np.uint8, count=n * 4).reshape(n, 4)
    e = a[:, 3].view(np.int8).astype(np.float32)
    return a[:, :3].astype(np.float32) * np.exp2(e)[:, None]


class Tile:
    __slots__ = ('fi', 'mat', 'lw', 'lh', 'tw', 'th', 'page', 'x', 'y',
                 'inv', 'mins', 'texel_m')


class Bake:
    def __init__(self, bsp, bank, scale=BU.UNIT, cell_m=48.0, texel_cm=0.0,
                 page_px=PAGE_PX, brightness=BRIGHTNESS, flat_gain=1.0,
                 verbose=True):
        self.bsp, self.bank, self.scale = bsp, bank, scale
        self.cell_m, self.page_px, self.verbose = cell_m, page_px, verbose
        self.texel_m = (texel_cm / 100.0) if texel_cm > 0 else 0.0
        self.tiles = {}            # face index -> Tile
        self.pages = []            # [(w, h)] once packed
        self.page_props = []       # [(roughness, metallic)]
        self.materials = {}        # '#lm3' -> glTF material index
        self.stats = collections.Counter()
        self._light = None
        self._scale_light = 1.0
        self.brightness = float(brightness)
        self.flat_gain = float(flat_gain)

    # ---------------------------------------------------------------- data
    def _lighting(self):
        if self._light is None:
            raw = self.bsp.lump(L_LIGHTING)
            if not len(raw):
                raw = self.bsp.lump(L_LIGHTING_HDR)
            self._light = raw
        return self._light

    def luxels(self, fi):
        """The face's base lightmap as (h, w, 3) linear light, or None."""
        f = self.bsp.faces[fi]
        off = int(f['lightofs'])
        if off < 0:
            return None
        w = int(f['lm_size'][0]) + 1
        h = int(f['lm_size'][1]) + 1
        if w < 1 or h < 1 or w * h > 1 << 20:
            return None
        raw = self._lighting()
        need = off + w * h * 4
        if need > len(raw):
            return None
        try:
            v = _decode(raw[off:need], w * h)
        except ValueError:
            return None
        return v.reshape(h, w, 3)

    # ---------------------------------------------------------------- plan
    def _eligible(self, fi):
        bsp = self.bsp
        name, flags, _w, _h = bsp.face_material(fi)
        if name is None or (flags & B.SKIP_FLAGS):
            return None
        if BU.TOOL_RE.match(name) and not BU.tool_material_is_drawn(name, flags):
            return None
        if flags & B.SURF_TRANS:
            self.stats['skip_translucent'] += 1
            return None
        if int(bsp.faces[fi]['lightofs']) < 0:
            self.stats['skip_no_lightmap'] += 1
            return None
        return name.lower()

    def plan(self, disp_faces=(), blend_test=None):
        """Choose faces, size their tiles and pack them into pages."""
        bsp = self.bsp
        disp = set(disp_faces)
        mdl = bsp.models[0]
        f0, fn = int(mdl['firstface']), int(mdl['numfaces'])

        cand = []
        for fi in range(f0, f0 + fn):
            if fi in disp:
                self.stats['skip_displacement'] += 1
                continue
            name = self._eligible(fi)
            if name is None:
                continue
            if blend_test is not None and blend_test(name) >= 2:
                self.stats['skip_blend'] += 1
                continue
            loop = bsp.face_loop(fi)
            if len(loop) < 3:
                continue
            lm = self.luxels(fi)
            if lm is None:
                self.stats['skip_no_lightmap'] += 1
                continue
            vs = bsp.verts[loop].astype(np.float64)
            area = sum(0.5 * np.linalg.norm(np.cross(vs[k] - vs[0], vs[k + 1] - vs[0]))
                       for k in range(1, len(vs) - 1)) * self.scale ** 2
            cand.append((fi, name, area, lm.shape[1], lm.shape[0],
                         vs.mean(axis=0)))

        # materials: one pass through the bank gives roughness / metallic /
        # alpha / tint_gain. OPAQUE only - a cut-out sheet needs its alpha and
        # an atlas page is a single opaque JPEG.
        props = {}
        for _fi, name, _a, _w, _h, _c in cand:
            if name in props:
                continue
            before = len(self.bank.report)
            self.bank.get(name)
            info = self.bank.report[before] if len(self.bank.report) > before \
                else {'roughness': 0.85, 'metallic': 0.0, 'alpha': 'OPAQUE'}
            props[name] = info
        self.props = props

        keep = []
        for rec in cand:
            info = props[rec[1]]
            if info.get('alpha', 'OPAQUE') != 'OPAQUE':
                self.stats['skip_alpha'] += 1
                continue
            if info.get('shader') == 'water':
                self.stats['skip_water'] += 1
                continue
            keep.append(rec)

        # sort by chunk cell so a page holds one neighbourhood of the map
        def cellkey(rec):
            c = BU.to_gltf(rec[5][None, :], self.scale)[0] / self.cell_m
            return (int(np.floor(c[1])), int(np.floor(c[0])), int(np.floor(c[2])))
        keep.sort(key=cellkey)

        # ---- tile sizes, then pack
        # Two rules fight here. Locality: a page holding faces from all over
        # the map makes every 48 m cell touch every page, and the mesh count
        # becomes cells x pages. Efficiency: a shelf packer fed random heights
        # wastes most of the sheet - packing in pure map order gave de_aztec
        # 16 pages for 13 M texels, about 20 %% full. So faces are cut into
        # runs worth roughly one page, and only inside a run are they sorted
        # tallest-first before shelving.
        P = self.page_px
        recs = []
        for fi, name, area, lw, lh, _c in keep:
            texel = self.texel_m or float(np.clip(math.sqrt(max(area, 1e-6)) / TEXEL_K,
                                                  TEXEL_MIN_M, TEXEL_MAX_M))
            lux_m = self._luxel_metres(fi)
            k = float(np.clip(lux_m / max(texel, 1e-4), 1.0, 32.0))
            tw = int(min(P - 2 * PAD, max(2, round((lw - 1) * k) + 1)))
            th = int(min(P - 2 * PAD, max(2, round((lh - 1) * k) + 1)))
            recs.append((fi, name, tw, th, lux_m / k, lw, lh))

        state = {'page': 0, 'x': 0, 'y': 0, 'shelf': 0}
        used = set()

        def place(rec):
            fi, name, tw, th, texel_m, lw, lh = rec
            bw, bh = tw + 2 * PAD, th + 2 * PAD
            if state['x'] + bw > P:
                state['x'] = 0
                state['y'] += state['shelf']
                state['shelf'] = 0
            if state['y'] + bh > P:
                state['page'] += 1
                state['x'] = state['y'] = state['shelf'] = 0
            t = Tile()
            t.fi, t.mat, t.lw, t.lh = fi, name, lw, lh
            t.tw, t.th, t.texel_m = tw, th, texel_m
            t.page, t.x, t.y = state['page'], state['x'] + PAD, state['y'] + PAD
            state['x'] += bw
            state['shelf'] = max(state['shelf'], bh)
            self.tiles[fi] = t
            used.add(t.page)

        budget = 0.92 * P * P
        group, gsum = [], 0.0
        for rec in recs:
            group.append(rec)
            gsum += (rec[2] + 2 * PAD) * (rec[3] + 2 * PAD)
            if gsum >= budget:
                for r in sorted(group, key=lambda r: -r[3]):
                    place(r)
                group, gsum = [], 0.0
        for r in sorted(group, key=lambda r: -r[3]):
            place(r)
        self.pages = sorted(used)

        # one roughness / metallic per page: area-weighted, since a page is a
        # single glTF material and the game reads scalars, not maps
        acc = collections.defaultdict(lambda: [0.0, 0.0, 0.0])
        for fi, name, area, _lw, _lh, _c in keep:
            t = self.tiles.get(fi)
            if t is None:
                continue
            a = acc[t.page]
            info = props[name]
            a[0] += area
            a[1] += area * float(info.get('roughness', 0.85))
            a[2] += area * float(info.get('metallic', 0.0))
        self.page_props = []
        for p in self.pages:
            a = acc[p]
            w = a[0] or 1.0
            self.page_props.append((a[1] / w, a[2] / w))
        self.stats['faces'] = len(self.tiles)
        self.stats['pages'] = len(self.pages)
        self.stats['texels'] = sum(t.tw * t.th for t in self.tiles.values())
        self.stats['page_fill'] = round(
            self.stats['texels'] / max(len(self.pages) * self.page_px ** 2, 1), 3)
        if self.verbose:
            print(f'[2/5] lightmap bake: {len(self.tiles)} faces -> '
                  f'{len(self.pages)} x {P}px pages '
                  f'({self.stats["texels"]/1e6:.1f} M texels), '
                  f'skipped {sum(v for k, v in self.stats.items() if k.startswith("skip_"))}')
        return self.tiles

    def _luxel_metres(self, fi):
        t = self.bsp.texinfo[int(self.bsp.faces[fi]['texinfo'])]
        v = np.asarray(t['lm_vecs'], np.float64)[0, :3]
        n = np.linalg.norm(v)
        return (1.0 / n) * self.scale if n > 1e-12 else 0.4

    # ------------------------------------------------------------------ uv
    def uv(self, fi, pts_src):
        """Atlas UVs for world (Hammer-space) points on face `fi`."""
        t = self.tiles.get(fi)
        if t is None:
            return None
        ti = self.bsp.texinfo[int(self.bsp.faces[fi]['texinfo'])]
        lv = np.asarray(ti['lm_vecs'], np.float64)
        f = self.bsp.faces[fi]
        mins = np.asarray(f['lm_mins'], np.float64)
        s = pts_src @ lv[0, :3] + lv[0, 3] - mins[0]
        q = pts_src @ lv[1, :3] + lv[1, 3] - mins[1]
        fs = s / max(t.lw - 1, 1)
        fq = q / max(t.lh - 1, 1)
        u = (t.x + 0.5 + fs * (t.tw - 1)) / self.page_px
        v = (t.y + 0.5 + fq * (t.th - 1)) / self.page_px
        return np.stack([u, v], axis=1).astype(np.float32)

    # -------------------------------------------------------------- render
    def _reference(self):
        lum = []
        for fi in self.tiles:
            lm = self.luxels(fi)
            if lm is None:
                continue
            v = lm.reshape(-1, 3)
            if len(v) > 64:
                v = v[::max(1, len(v) // 64)]
            lum.append(v @ np.array([0.2126, 0.7152, 0.0722], np.float32))
        if not lum:
            return 1.0
        all_l = np.concatenate(lum)
        return max(float(np.percentile(all_l, EXPOSURE_PCT)), 1e-4)

    def render(self, exposure=None, verbose=True):
        """Draw every tile. Returns a list of PIL images, one per page."""
        # `exposure`, when given, is the old linear scale: keep it working by
        # turning it into the reference level it implies
        self._scale_light = float(exposure) if exposure else LIGHT_FULL
        self.stats['light_full'] = round(float(self._scale_light), 2)
        self.stats['brightness'] = self.brightness
        P = self.page_px
        imgs = [np.zeros((P, P, 3), np.uint8) for _ in self.pages]
        pageno = {p: i for i, p in enumerate(self.pages)}

        by_mat = collections.defaultdict(list)
        for fi, t in self.tiles.items():
            by_mat[t.mat].append(t)

        done = 0
        for mat, tiles in sorted(by_mat.items()):
            alb, gain = self._albedo(mat)
            if alb is None:
                self.stats['albedo_missing'] += 1
                continue
            mips = _mips(alb)
            for t in tiles:
                px = self._tile(t, mips, gain)
                if px is None:
                    continue
                img = imgs[pageno[t.page]]
                _blit(img, px, t.x, t.y)
                done += 1
            if verbose and done and len(by_mat) > 20:
                pass
        self.stats['tiles_drawn'] = done
        return [Image.fromarray(a, 'RGB') for a in imgs]

    def _albedo(self, mat):
        try:
            alb, info = self.bank.composite(mat)
        except Exception:
            return None, 1.0
        if alb is None:
            return None, 1.0
        return alb[:, :, :3].astype(np.float32), float(info.get('tint_gain', 1.0))

    def _tile(self, t, mips, gain):
        bsp = self.bsp
        fi = t.fi
        f = bsp.faces[fi]
        ti = bsp.texinfo[int(f['texinfo'])]
        lv = np.asarray(ti['lm_vecs'], np.float64)
        tv = np.asarray(ti['tex_vecs'], np.float64)
        td = bsp.texdata[ti['texdata']]
        tw = float(td['view_width']) or 1.0
        th = float(td['view_height']) or 1.0
        pl = bsp.planes[int(f['planenum'])]
        n = np.asarray(pl['normal'], np.float64)
        d = float(pl['dist'])
        mins = np.asarray(f['lm_mins'], np.float64)

        # (luxel s, luxel t, plane) -> world. Solve once per face.
        M = np.stack([lv[0, :3], lv[1, :3], n])
        try:
            inv = np.linalg.inv(M)
        except np.linalg.LinAlgError:
            return None

        js = np.arange(t.tw, dtype=np.float64) * (t.lw - 1) / max(t.tw - 1, 1)
        is_ = np.arange(t.th, dtype=np.float64) * (t.lh - 1) / max(t.th - 1, 1)
        S, T = np.meshgrid(js, is_)
        rhs = np.stack([(S + mins[0] - lv[0, 3]).ravel(),
                        (T + mins[1] - lv[1, 3]).ravel(),
                        np.full(S.size, d)])
        pts = (inv @ rhs).T                     # (n, 3) world positions

        # albedo, at the mip that matches this tile's texel footprint
        u = (pts @ tv[0, :3] + tv[0, 3]) / tw
        v = (pts @ tv[1, :3] + tv[1, 3]) / th
        # how many source texels one atlas texel covers, so the bake reads a
        # mip instead of aliasing a 1024 px wallpaper through 10 cm texels.
        # tex_vecs map world units straight to texture PIXELS, so the
        # footprint is already in pixels - multiplying by the width again
        # (the first version did) pins every face to the 1x1 mip and the
        # albedo collapses to its average colour.
        u_per = abs(t.texel_m / self.scale) * float(np.linalg.norm(tv[0, :3]))
        v_per = abs(t.texel_m / self.scale) * float(np.linalg.norm(tv[1, :3]))
        foot = max(u_per, v_per) * (mips[0].shape[1] / max(tw, 1.0))
        lvl = int(np.clip(round(math.log2(max(foot, 1.0))), 0, len(mips) - 1))
        a = _sample(mips[lvl], u, v).reshape(t.th, t.tw, 3)

        # light, bilinear over the luxel grid
        lm = self.luxels(fi)
        if lm is None:
            return None
        light = tonemap(_bilinear(lm, S, T), self._scale_light, self.brightness)
        light = np.maximum(light, LIGHT_FLOOR)

        out = _srgb_to_lin(a) * light * gain
        if self.flat_gain != 1.0:
            # A flat-normal build is multiplied by a constant ~0.45 in the
            # game (see ZONE_FLAT_NORMAL), and what has to come back up is the
            # finished albedo x light, not the light on its own - gaining the
            # light instead just drives the tone curve into its shoulder and
            # leaves the map exactly as dark.
            out = tonemap(out, 1.0, self.flat_gain, KNEE_AT)
        return _lin_to_srgb(np.clip(out, 0.0, 1.0))

    # ----------------------------------------------------------- materials
    def build_materials(self, glb, imgs, jpeg_q=88):
        flat = np.zeros((4, 4, 3), np.uint8)
        flat[:, :, 0] = 128; flat[:, :, 1] = 128; flat[:, :, 2] = 255
        ntex = glb.image(_png(Image.fromarray(flat, 'RGB')), 'lm_flat_normal')
        for i, p in enumerate(self.pages):
            rough, metal = self.page_props[i]
            name = f'{MAT_PREFIX}{p}'
            tex = glb.image(_jpg(imgs[i], jpeg_q), name)
            self.materials[name] = glb.material(
                name, albedo_tex=tex, normal_tex=ntex,
                roughness=float(np.clip(rough, 0.04, 1.0)),
                metallic=float(np.clip(metal, 0.0, 0.35)))
        return self.materials

    def material_name(self, fi):
        t = self.tiles.get(fi)
        return None if t is None else f'{MAT_PREFIX}{t.page}'


# -------------------------------------------------------------- helpers
def _mips(a):
    out = [a]
    cur = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), 'RGB')
    while min(cur.size) > 1:
        cur = cur.resize((max(1, cur.width // 2), max(1, cur.height // 2)),
                         Image.BOX)
        out.append(np.asarray(cur, np.float32))
    return out


def _sample(tex, u, v):
    h, w = tex.shape[:2]
    x = np.mod((u * w).astype(np.int64), w)
    y = np.mod((v * h).astype(np.int64), h)
    return tex[y, x]


def _bilinear(lm, S, T):
    h, w = lm.shape[:2]
    s = np.clip(S, 0, w - 1); t = np.clip(T, 0, h - 1)
    x0 = np.floor(s).astype(np.int64); y0 = np.floor(t).astype(np.int64)
    x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
    fx = (s - x0)[:, :, None]; fy = (t - y0)[:, :, None]
    a = lm[y0, x0] * (1 - fx) + lm[y0, x1] * fx
    b = lm[y1, x0] * (1 - fx) + lm[y1, x1] * fx
    return a * (1 - fy) + b * fy


def _blit(page, px, x, y):
    h, w = px.shape[:2]
    page[y:y + h, x:x + w] = px
    # edge-extend into the gutter so bilinear filtering never pulls in a
    # neighbouring tile
    for k in range(1, PAD + 1):
        if y - k >= 0:
            page[y - k, x:x + w] = px[0]
        if y + h + k - 1 < page.shape[0]:
            page[y + h + k - 1, x:x + w] = px[-1]
        if x - k >= 0:
            page[y - PAD:y + h + PAD, x - k] = page[y - PAD:y + h + PAD, x]
        if x + w + k - 1 < page.shape[1]:
            page[y - PAD:y + h + PAD, x + w + k - 1] = page[y - PAD:y + h + PAD,
                                                            x + w - 1]
