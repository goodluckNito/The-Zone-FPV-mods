"""Source VMT/VTF -> glTF PBR material (the 'hybrid' path).

The Zone converts any non-builtin glTF StandardMaterial3D into its own
CustomMaterial shader, carrying over albedo_texture, normal_texture,
roughness/metallic values and emission. So we keep the original Source art as
albedo and supply the normal + roughness data Source never had, which is what
makes surfaces respond to the game's lighting.

What the game's importer actually copies (read out of thezone.pck,
gdutil/z_asset_loader.gdc -> convert_custom_materials):

    albedo_texture, albedo_color/use_albedo_color, normal_texture,
    roughness_texture/roughness_value, metallic_texture/metallic_value,
    emission_enabled/emission/emission_energy_multiplier

Everything else on the StandardMaterial3D is dropped, and that shapes this
module:

  * `normal_scale` is NOT copied, and materials2/custom_material.gdshader does
    `NORMAL_MAP = texture(normal_texture, UV).rgb` with no NORMAL_MAP_DEPTH.
    A generated normal map has to be damped in the pixels, not by a factor.
  * `cull_mode` is NOT copied and neither shader declares `cull_disabled`, so
    glTF doubleSided does nothing. Two-sided surfaces need mirrored triangles
    (see build.py / propbuild.py).
  * albedo_color and albedo_texture are EITHER/OR in the shader
    (`if (use_albedo_color) ALBEDO = albedo_color.rgb; else ALBEDO = tex...`),
    so a $color tint has to be baked into the image.
  * roughness/metallic come from the RED channel when a texture is bound, but
    Godot's glTF importer packs roughness in G and metallic in B of one ORM
    image. Supplying a metallicRoughnessTexture therefore reads the wrong
    channel for both - we only ever ship scalar factors.

METALLIC deserves its own note. Source has no metalness channel at all;
`$surfaceprop` is a physics/footstep-sound property. Deriving metallic from it
gave 17 % of de_nuke's surface area metallic 0.85, and Godot scales both
diffuse and ambient by (1 - metallic), so every "metal" wall and door rendered
at 15 % brightness. Metal in Source is a full-strength diffuse surface plus an
additive, masked cubemap reflection - closer to metallic 0 than to metallic 1.
"""
import io, math, re, numpy as np
from PIL import Image, ImageFilter
from . import vmt as V, vtf as T
from .cutout import OpaqueMask

# roughness priors by $surfaceprop, plus a 0..1 "is this really bare metal?"
# score. The score only ever drives a small optional sheen (see metal_sheen);
# it is NOT a metalness value, because Source never stored one.
SURFACE = {
    'metal': (0.38, 1.00), 'metalgrate': (0.45, 1.00), 'metalvent': (0.42, 0.90),
    'metalpanel': (0.35, 1.00), 'metal_box': (0.40, 0.85), 'metalvehicle': (0.30, 1.0),
    'slipperymetal': (0.25, 1.0), 'solidmetal': (0.35, 1.0), 'weapon': (0.35, 0.9),
    'canister': (0.35, 1.00), 'chainlink': (0.45, 0.90), 'grenade': (0.4, 0.9),
    'popcan': (0.3, 1.0),
    'glass': (0.08, 0.0), 'glassbottle': (0.08, 0.0), 'combine_glass': (0.1, 0.0),
    'water': (0.04, 0.0), 'slime': (0.2, 0.0),
    'concrete': (0.88, 0.0), 'concrete_block': (0.90, 0.0), 'rock': (0.92, 0.0),
    'boulder': (0.93, 0.0), 'stone': (0.87, 0.0), 'brick': (0.89, 0.0),
    'plaster': (0.90, 0.0), 'drywall': (0.92, 0.0), 'tile': (0.55, 0.0),
    'ceramic': (0.45, 0.0), 'porcelain': (0.35, 0.0), 'marble': (0.30, 0.0),
    'wood': (0.78, 0.0), 'wood_box': (0.82, 0.0), 'wood_crate': (0.85, 0.0),
    'wood_plank': (0.80, 0.0), 'wood_solid': (0.75, 0.0), 'wood_furniture': (0.55, 0.0),
    'wood_panel': (0.72, 0.0), 'wood_lowdensity': (0.88, 0.0),
    'dirt': (0.96, 0.0), 'sand': (0.97, 0.0), 'gravel': (0.95, 0.0),
    'mud': (0.90, 0.0), 'grass': (0.95, 0.0), 'snow': (0.90, 0.0),
    'plastic': (0.45, 0.0), 'plastic_box': (0.50, 0.0), 'rubber': (0.85, 0.0),
    'carpet': (0.97, 0.0), 'cloth': (0.95, 0.0), 'paper': (0.92, 0.0),
    'cardboard': (0.93, 0.0), 'flesh': (0.80, 0.0), 'panel': (0.55, 0.15),
    'ceiling_tile': (0.92, 0.0), 'default': (0.86, 0.0),
}

# how much relief to fake into a generated normal map, by surface family
RELIEF = {
    'brick': 2.6, 'concrete_block': 2.2, 'rock': 2.4, 'boulder': 2.6, 'gravel': 2.4,
    'stone': 2.2, 'concrete': 1.7, 'plaster': 1.2, 'dirt': 1.9, 'sand': 1.5,
    'grass': 2.0, 'mud': 1.6, 'wood': 1.6, 'wood_plank': 1.9, 'wood_crate': 2.0,
    'tile': 1.5, 'carpet': 1.2, 'cloth': 1.0, 'metal': 1.0, 'metalgrate': 1.6,
    'chainlink': 1.6, 'glass': 0.0, 'water': 0.0, 'default': 1.5,
}


def _png(img, optimize=True):
    b = io.BytesIO()
    img.save(b, 'PNG', optimize=optimize)
    return b.getvalue()


def _jpg(img, q=90):
    b = io.BytesIO()
    img.convert('RGB').save(b, 'JPEG', quality=q, subsampling=1, optimize=True)
    return b.getvalue()


def _fit(arr, max_px):
    h, w = arr.shape[:2]
    if max(h, w) <= max_px:
        return Image.fromarray(arr)
    s = max_px / max(h, w)
    return Image.fromarray(arr).resize(
        (max(1, int(w * s)), max(1, int(h * s))), Image.LANCZOS)


# Sobel gain. The game's importer never copies normal_scale and its shader has
# no NORMAL_MAP_DEPTH, so a generated map is applied at exactly 1.0 whatever we
# put in the glTF. The damping we used to ask for with normal_scale=0.85 has to
# live in this constant instead - at the old 8.0 a brick wall ran at an
# effective gain of 20.8 and read as badly over-contrasted.
GEN_NORMAL_GAIN = 3.4


def normal_from_albedo(rgba, strength=1.5, max_px=256, gain=GEN_NORMAL_GAIN):
    """Sobel height-from-luminance -> tangent-space normal map (green up)."""
    img = _fit(rgba, max_px).convert('L')
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    h = np.asarray(img, np.float32) / 255.0
    # wrap edges so tiling textures stay seamless
    hp = np.pad(h, 1, mode='wrap')
    dx = (hp[1:-1, 2:] - hp[1:-1, :-2]) * 0.5
    dy = (hp[2:, 1:-1] - hp[:-2, 1:-1]) * 0.5
    nx = -dx * strength * gain
    ny = -dy * strength * gain
    nz = np.ones_like(nx)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx / ln, ny / ln, nz / ln], axis=-1)
    return Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8), 'RGB')


def _tile_alpha(arr, h, w, reps):
    """`_tile_to` for a single channel - PIL cannot take an (h, w, 1) array."""
    return _tile_to(np.repeat(arr[:, :, 3:4], 3, axis=2), h, w, reps)[:, :, :1]


def _tile_to(arr, h, w, reps):
    """Resample `arr` so that `reps` copies of it span an h x w image."""
    th = max(1, int(round(h / max(reps, 1e-6))))
    tw = max(1, int(round(w / max(reps, 1e-6))))
    t = np.asarray(Image.fromarray(arr).resize((tw, th), Image.LANCZOS), np.float32)
    ry = int(np.ceil(h / th)); rx = int(np.ceil(w / tw))
    return np.tile(t, (ry, rx, 1))[:h, :w]


# Mode 4 swaps the roles of the two textures, so the bake has to resolve the
# DETAIL sheet, not the base. Cap how far we will supersample for that.
DETAIL_OVER_PX = 1024


def apply_detail(alb, det, scale, factor, mode=0, tint=(1., 1., 1.)):
    """Bake Source's $detail pass into the albedo.

    Transcribed from `TextureCombine()` in Valve's common_ps_fxc.h:

    0 = base *= lerp(1, 2*detail, f)              RGB_EQUALS_BASE_x_DETAILx2
    1 = base += f * detail                        RGB_ADDITIVE
    2 = base  = lerp(base, detail, f * detail.a)  DETAIL_OVER_BASE
    3 = base  = lerp(base, detail, f)             FADE
    4 = base  = lerp(base, detail, f * (1-base.a)); base.a = detail.a
                                                  BASE_OVER_DETAIL
    8 = base *= lerp(1, detail, f)                MULTIPLY

    Anything else falls back to mode 0. Modes 5-7 and 9-11 are self-illum,
    two-pattern select and ssbump variants; none appeared on any material used
    by the maps tested, and mode 0 is the neutral guess if one turns up.

    **Mode 4 is not a detail pass at all.** Valve's own comment in
    `models/props_farm/building001.vmt` says it outright:

        "$basetexture" "models/props_farm/building001_dirtmap"
                                    // This is used as the detail texture ...
        "$detail"      "wood/grain_elevator_facade_14b"
                                    // This is used as the base ...

    The roles are swapped: `$detail` is the surface, `$basetexture` is a dirt
    overlay masked by its own alpha. Treating it as mode 0 multiplied the wood
    by a near-black dirtmap and produced a PURE BLACK albedo - 2fort's big farm
    building rendered as a black slab, and because the three building001
    materials then hashed to the same black image they collapsed onto one
    texture. So mode 4 resamples to the detail sheet's own frequency
    (base_px * $detailscale, capped at DETAIL_OVER_PX) rather than smearing a
    4x-tiled wall texture across a 512 px base, and takes its output alpha from
    the detail, never from the dirtmap.

    The multiply in modes 0/8 is done on the stored (gamma-space) bytes rather
    than in linear light. That is what makes Valve's detail sheets neutral: they
    average around 0.44, so 2x lands at 0.87 - a slight darken plus the grain
    they authored. Doing it in linear would put 2x at 0.32 and crush every
    surface that uses one.

    $detailscale is a UV multiplier, so an exact bake needs an integer number of
    detail tiles per albedo tile; we round to the nearest one. Valve's scales are
    ~4.3-7.7, where rounding shifts the grain frequency by under 10 % and keeps
    the sheet seamless.
    """
    h, w = alb.shape[:2]
    reps = max(1, int(round(float(scale) or 1.0)))
    f = float(np.clip(factor, 0.0, 1.0))
    tint = np.asarray(tint, np.float32)

    if mode == 4:
        oh = min(h * reps, DETAIL_OVER_PX)
        ow = min(w * reps, DETAIL_OVER_PX)
        if (oh, ow) != (h, w):
            alb = np.asarray(Image.fromarray(alb).resize((ow, oh),
                                                         Image.LANCZOS))
        base = alb[:, :, :3].astype(np.float32)
        ba = (alb[:, :, 3].astype(np.float32) / 255.0
              if alb.shape[2] == 4 else np.ones((oh, ow), np.float32))
        d = _tile_to(det[:, :, :3], oh, ow, reps) * tint
        blend = (f * (1.0 - ba))[:, :, None]
        out = np.clip(base * (1.0 - blend) + d * blend, 0, 255).astype(np.uint8)
        if det.shape[2] == 4:
            da = _tile_alpha(det, oh, ow, reps)
        else:
            da = np.full((oh, ow, 1), 255.0, np.float32)
        return np.dstack([out, np.clip(da, 0, 255).astype(np.uint8)])

    d = _tile_to(det[:, :, :3], h, w, reps) / 255.0
    d = d * tint
    base = alb[:, :, :3].astype(np.float32)
    if mode == 1:
        out = base + d * 255.0 * f
    elif mode == 2:
        da = (_tile_alpha(det, h, w, reps) / 255.0
              if det.shape[2] == 4 else np.ones((h, w, 1), np.float32))
        out = base + (d * 255.0 - base) * (f * da)
    elif mode == 3:
        out = base + (d * 255.0 - base) * f
    elif mode == 8:
        out = base * (1.0 + (d - 1.0) * f)
    else:
        out = base * (1.0 + (2.0 * d - 1.0) * f)
    out = np.clip(out, 0, 255).astype(np.uint8)
    return np.dstack([out, alb[:, :, 3:4]]) if alb.shape[2] == 4 else out


def solid_rgba(rgb, px=8):
    """A tiny flat-colour albedo.

    Needed because a material with no baseColorTexture comes through the game's
    importer as `use_albedo_color`, and the converter used to leave
    baseColorFactor at its default - so anything without a $basetexture
    rendered PURE WHITE. Source's `water` shader has no $basetexture at all,
    which is most of a map like ctf_2fort.

    Binding a real (if tiny) texture as well as setting the factor means the
    colour survives either branch of the importer.
    """
    a = np.zeros((px, px, 4), np.uint8)
    a[:, :, :3] = np.clip(np.asarray(rgb, np.float32) * 255.0, 0, 255).astype(np.uint8)
    a[:, :, 3] = 255
    return a


def water_colour(m, value=0.28):
    """A single stand-in colour for Source water.

    Source water is reflection + refraction blended by Fresnel and tinted by
    $fogcolor; none of that exists here. $fogcolor is the only colour Valve
    actually authored for the water, so it decides the HUE. But it is a fog
    density colour, not a surface colour - de_aztec's is [.15 .1 0] and
    militia's [.07 .14 .12], far too dark to use directly - so its luminance is
    rescaled to `value` and the hue is left alone.

    Lerping towards white instead (an earlier attempt) washes the hue out: it
    turned aztec's murky brown into pale tan. $reflecttint is applied as what
    it is, a multiplicative tint. A little grey is mixed back so a channel
    Valve wrote as 0 does not stay at exactly 0.
    """
    fog = np.asarray(m.vec('$fogcolor', (0.09, 0.08, 0.04)), np.float64)
    refl = np.asarray(m.vec('$reflecttint', (1.0, 1.0, 1.0)), np.float64)
    lum = float(0.2126 * fog[0] + 0.7152 * fog[1] + 0.0722 * fog[2])
    if lum < 1e-4:
        fog, lum = np.array([0.07, 0.11, 0.10]), 0.0937
    col = fog * (float(value) / lum) * refl
    col = col * 0.88 + float(value) * 0.12          # slight desaturation floor
    return tuple(float(x) for x in np.clip(col, 0.0, 1.0))


def apply_tint(alb, tint):
    """Bake a $color / $color2 tint into the image.

    The game's shader picks albedo_color OR albedo_texture, never the product,
    so a tint left in baseColorFactor is silently dropped.
    """
    t = np.asarray(tint, np.float32)
    if np.allclose(t, 1.0, atol=1e-3):
        return alb
    out = np.clip(alb[:, :, :3].astype(np.float32) * t, 0, 255).astype(np.uint8)
    return np.dstack([out, alb[:, :, 3:4]]) if alb.shape[2] == 4 else out


_TX_SCALE = re.compile(r'scale\s+([-\d.]+)\s+([-\d.]+)', re.I)


def transform_scale(raw, default=1.0):
    """Pull the scale out of a $basetextureNtransform string."""
    if not raw:
        return default, default
    m = _TX_SCALE.search(str(raw))
    if not m:
        return default, default
    try:
        return float(m.group(1)), float(m.group(2))
    except ValueError:
        return default, default


def _srgb_to_lin(x):
    x = x.astype(np.float32) / 255.0
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def _lin_to_srgb(x):
    y = np.where(x <= 0.0031308, x * 12.92, 1.055 * np.clip(x, 0, None) ** (1 / 2.4) - 0.055)
    return np.clip(y * 255.0, 0, 255).astype(np.uint8)


BLEND_SHADERS = ('worldvertextransition', 'lightmappedtwotexture')


def blend_band_count(fs, matname, mapname=None, bands=5):
    """How many pre-composited bands this material needs (0 = not a blend).

    WorldVertexTransition mixes $basetexture and $basetexture2 per vertex, using
    the displacement vertex alpha. The Zone's CustomMaterial has exactly one
    albedo sampler and drops vertex colour, so a live blend is impossible. What
    we can do is pre-composite a handful of fixed mixes and pick one per
    triangle. Displacement triangles are small (a power-3 face is an 8x8 grid
    over ~128-256 units, so roughly 0.5 m a side), which makes the quantisation
    read as patchiness rather than banding.

    de_nuke needs this badly: nukblenddirtgrass alone is 21,655 m2, 24.7 % of
    the map's drawable area, and its vertex alpha averages 121/255 - so using
    $basetexture alone shows the wrong ground over a quarter of the map.
    """
    if bands < 2:
        return 0
    try:
        m = V.load_vmt(fs, matname, mapname)
    except Exception:
        return 0
    if m is None or m.shader not in BLEND_SHADERS:
        return 0
    return bands if m.tex('$basetexture2') else 0


def band_name(matname, k, n):
    return f'{matname}#b{k}/{n}'


def split_band(name):
    """'mat#b2/5' -> ('mat', 2, 5); a bare name -> (name, None, None)."""
    if '#b' not in name:
        return name, None, None
    base, tail = name.rsplit('#b', 1)
    try:
        k, n = tail.split('/')
        return base, int(k), int(n)
    except ValueError:
        return name, None, None


_LIGHT_FX_CACHE = {}


def is_light_effect(fs, matname, mapname=None, max_mean_alpha=0.06):
    """Is this material a light shaft / glow card rather than matter?

    Source draws light beams as cards: `$additive` blends them into the frame,
    or an UnlitGeneric sheet that is a couple of percent opaque. Either way
    there is nothing physically there - but The Zone collides every mesh, so
    they become invisible walls across doorways.

    Foliage looks similar on paper (also UnlitGeneric + $translucent) and must
    NOT be caught: de_inferno's tree cards average 14-18 % alpha against
    1-2 % for de_nuke's skylight_effects, so the mean-alpha test separates them.
    """
    key = (id(fs), str(matname).lower(), mapname)
    if key in _LIGHT_FX_CACHE:
        return _LIGHT_FX_CACHE[key]
    verdict = False
    try:
        m = V.load_vmt(fs, matname, mapname)
        if m is not None:
            if m.get('$additive') in ('1', 1):
                verdict = True
            elif (m.shader == 'unlitgeneric'
                  and m.get('$translucent') in ('1', 1)):
                bt = m.tex('$basetexture')
                v = T.load_vtf(fs, bt) if bt else None
                if v is not None:
                    a = v.mip0()[:, :, 3]
                    verdict = float(a.mean()) / 255.0 < max_mean_alpha
    except Exception:
        verdict = False
    _LIGHT_FX_CACHE[key] = verdict
    return verdict


class MaterialBank:
    """Resolves Source material names to glTF material indices in a Glb."""

    def __init__(self, glb, fs, mapname, albedo_px=512, normal_px=256,
                 albedo_jpeg=True, jpeg_q=90, gen_normals=True,
                 flip_green=False, emissive=True, metal_sheen=0.15,
                 detail=True, normal_strength=1.0, roughness_scale=1.0,
                 roughness_min=0.0, water_roughness=0.6, water_value=0.28):
        self.glb, self.fs, self.mapname = glb, fs, mapname
        self.albedo_px, self.normal_px = albedo_px, normal_px
        self.albedo_jpeg, self.jpeg_q = albedo_jpeg, jpeg_q
        self.gen_normals, self.flip_green, self.emissive = gen_normals, flip_green, emissive
        self.metal_sheen = float(metal_sheen)
        self.detail = detail
        self.normal_strength = float(normal_strength)
        self.roughness_scale = float(roughness_scale)
        self.roughness_min = float(roughness_min)
        self.water_roughness = float(water_roughness)
        self.water_value = float(water_value)
        self.cache = {}
        self.report = []
        self.cutouts = {}      # material index -> OpaqueMask, for MASK sheets
        self.two_sided = set()  # material indices that need mirrored triangles

    def _tex_rgba(self, name):
        try:
            v = T.load_vtf(self.fs, name)
            return v.mip0() if v else None
        except Exception:
            return None

    def get(self, matname):
        if matname in self.cache:
            return self.cache[matname]
        base, k, n = split_band(matname)
        idx = self._build(base, band=(k, n) if k is not None else None)
        self.cache[matname] = idx
        return idx

    def _blend_albedo(self, m, alb, weight, info):
        """lerp($basetexture, $basetexture2) at `weight`, honouring each one's
        $basetextureNtransform scale.

        Done in linear light, because this is a true mix of two albedos rather
        than Source's gamma-space detail trick. $detailscale-style tiling is
        handled by repeating texture 2 the nearest whole number of times across
        texture 1's footprint, which keeps the sheet seamless."""
        b2 = m.tex('$basetexture2')
        t2 = self._tex_rgba(b2) if b2 else None
        if t2 is None:
            return alb
        s1 = transform_scale(m.get('$basetexturetransform'))[0]
        s2 = transform_scale(m.get('$basetexturetransform2'))[0]
        h, w = alb.shape[:2]
        reps = max(1, int(round((s2 or 1.0) / (s1 or 1.0))))
        t2r = _tile_to(t2[:, :, :3], h, w, reps).astype(np.uint8)
        a = _srgb_to_lin(alb[:, :, :3])
        b = _srgb_to_lin(t2r)
        out = _lin_to_srgb(a * (1.0 - weight) + b * weight)
        info['blend'] = {'tex2': b2, 'reps': reps, 'w': round(float(weight), 3)}
        return np.dstack([out, alb[:, :, 3:4]]) if alb.shape[2] == 4 else out


    def _compose_albedo(self, m, matname, band, info, is_water=False,
                        rough=0.85):
        """Everything that happens to a base texture before it is resized.

        Split out of _build so the lightmap bake can ask for the same finished
        array (see lightmap.Bake._albedo) instead of re-implementing $color,
        $detail and the WorldVertexTransition mix and drifting out of sync.
        """
        # ---- albedo -----------------------------------------------------
        base = m.tex('$basetexture')
        alb = self._tex_rgba(base) if base else None
        forced_col = None
        if alb is None and is_water:
            forced_col = water_colour(m, self.water_value)
            alb = solid_rgba(forced_col)
            base = (base or matname) + '_water'
            info['water'] = {'rgb': [round(c, 4) for c in forced_col],
                             'roughness': round(rough, 3)}
        elif alb is None:
            # never leave it to the default: that is pure white
            forced_col = (0.55, 0.55, 0.55)
            alb = solid_rgba(forced_col)
            base = (base or matname) + '_notex'
            info['no_basetexture'] = True
        alpha_mode, dbl = 'OPAQUE', False
        atest = m.get('$alphatest') in ('1', 1)
        translucent = m.get('$translucent') in ('1', 1)
        if alb is not None and (atest or translucent):
            a = alb[:, :, 3]
            if int(a.min()) >= 250:
                alpha_mode = 'OPAQUE'
            else:
                # bimodal alpha == a cut-out sheet (foliage, fences, grates).
                # Use alpha scissor so it writes depth and never sorts wrongly.
                bimodal = float(((a < 16) | (a > 239)).mean())
                alpha_mode = 'MASK' if (atest or bimodal > 0.85) else 'BLEND'
                dbl = True
            info['alpha_bimodality'] = round(
                float(((a < 16) | (a > 239)).mean()), 3)

        # bake the passes the game's shader cannot express
        fit_px = self.albedo_px
        if alb is not None and band is not None and band[1] > 1:
            alb = self._blend_albedo(m, alb, band[0] / (band[1] - 1.0), info)
        if alb is not None:
            tint = m.vec('$color2', (1., 1., 1.)) if m.get('$color2') else \
                   (m.vec('$color', (1., 1., 1.)) if m.get('$color') else (1., 1., 1.))
            mx = max(tint)
            if mx > 1.0:
                # A $color above 1 is an exposure knob, not a colour: the
                # mapper brightened the albedo because the baked lightmap was
                # about to darken it again. We have no lightmap, so applying
                # the gain blows a x5 wall to flat white. Keep the hue, drop
                # the gain. (If the lightmap is ever baked in, this is the
                # line to reconsider.)
                info['tint_gain'] = round(mx, 3)
                tint = tuple(c / mx for c in tint)
            if not np.allclose(tint, 1.0, atol=1e-3):
                alb = apply_tint(alb, tint)
                info['tint'] = [round(c, 3) for c in tint]
            dt = m.tex('$detail') if self.detail else None
            if dt:
                dv = self._tex_rgba(dt)
                if dv is not None:
                    dscale = m.flt('$detailscale', 1.0) or 1.0
                    dfac = m.flt('$detailblendfactor', 1.0)
                    dmode = m.intv('$detailblendmode', 0)
                    alb = apply_detail(alb, dv, dscale, dfac, dmode,
                                       m.vec('$detailtint', (1., 1., 1.)))
                    info['detail'] = {'tex': dt, 'scale': round(dscale, 3),
                                      'factor': round(dfac, 3), 'mode': dmode}
                    if dmode == 4:
                        # $detail IS the surface here, tiled $detailscale
                        # times: shrinking back to albedo_px would throw the
                        # supersample away and leave a mush of wood grain.
                        fit_px = max(fit_px, min(max(alb.shape[:2]),
                                                 DETAIL_OVER_PX))

        return base, alb, forced_col, alpha_mode, dbl, fit_px

    def composite(self, matname):
        """The finished albedo for a material, before resizing, plus its info.

        `info['tint_gain']` is the $color gain _build deliberately drops - with
        a lightmap to darken it again, that gain is correct and the bake puts
        it back.
        """
        base_name, k, n = split_band(matname)
        m = V.load_vmt(self.fs, base_name, self.mapname)
        if m is None:
            return None, {}
        info = {}
        is_water = (m.shader == 'water' or m.get('%compilewater') in ('1', 1))
        _b, alb, _f, _a, _d, _p = self._compose_albedo(
            m, base_name, (k, n) if k is not None else None, info, is_water)
        return alb, info

    def _build(self, matname, band=None):
        m = V.load_vmt(self.fs, matname, self.mapname)
        # the glTF material has to carry the BANDED name: the game caches
        # converted materials by resource_name, so all five bands sharing the
        # base name would collapse into one CustomMaterial in game.
        label = matname if band is None else band_name(matname, band[0], band[1])
        info = {'material': label, 'shader': m.shader if m else None}
        if m is None:
            info['status'] = 'vmt-missing'
            self.report.append(info)
            return self.glb.material(label, roughness=0.86,
                                     albedo_tex=self.glb.image(
                                         _png(Image.fromarray(
                                             solid_rgba((0.55, 0.55, 0.55)))),
                                         'missing_vmt'),
                                     base_color=(0.55, 0.55, 0.55, 1.0))

        sprop = str(m.get('$surfaceprop', 'default')).strip('"').lower()
        rough, sheen_score = SURFACE.get(sprop, SURFACE['default'])
        relief = RELIEF.get(sprop, RELIEF['default'])

        # water / unlit special-cases
        is_water = (m.shader == 'water' or m.get('%compilewater') in ('1', 1))
        if is_water:
            # NOT the physical 0.04. This shader's GGX lobe is not
            # energy-conserving - D peaks at 1/(PI*alpha^2), which is ~124,000
            # at roughness 0.04 - so a smooth horizontal surface saturates to
            # pure white across the whole sheet. Measured sunlit response:
            # roughness 0.15 -> 219, 0.55 -> 193, 0.95 -> 135 out of 255, so
            # keeping a glint without blowing out needs roughness around 0.6.
            rough, sheen_score = self.water_roughness, 0.0
        if m.shader == 'unlitgeneric':
            rough = 1.0

        # shinier when the material samples a cubemap
        has_env = bool(m.get('$envmap'))
        if has_env and not is_water:
            rough *= 0.72
        pe = m.flt('$phongexponent', 0.0)
        if pe > 0 and not is_water:
            rough = min(rough, max(0.08, 1.0 / math.sqrt(max(1.0, pe / 4.0))))
        if is_water:
            # every water material carries $envmap env_cubemap; letting that
            # divide the roughness put it back in the blow-out zone
            rough = self.water_roughness

        # ---- metallic ---------------------------------------------------
        # Source has no metalness channel, so there is nothing here to read.
        # The only honest signal that a surface behaves like bare metal is
        # "$surfaceprop says metal AND the material actually samples a
        # cubemap", and even then Source adds the reflection on top of a
        # full-strength diffuse rather than replacing it. Godot removes
        # (1 - metallic) of both diffuse and ambient, so anything above a
        # token value turns the surface black under this game's lighting.
        metal = 0.0
        if self.metal_sheen > 0 and sheen_score > 0 and has_env:
            metal = self.metal_sheen * sheen_score
            # $envmaptint / an envmap mask say how much of the sheet reflects
            et = m.vec('$envmaptint', (1., 1., 1.))
            metal *= float(np.clip(np.mean(et), 0.0, 1.0))
            mask = m.tex('$envmapmask')
            if mask:
                mv = self._tex_rgba(mask)
                if mv is not None:
                    metal *= float(mv[:, :, :3].astype(np.float32).mean() / 255.0)
            metal = float(np.clip(metal, 0.0, 0.35))

        base, alb, forced_col, alpha_mode, dbl, fit_px = self._compose_albedo(
            m, matname, band, info, is_water, rough)

        alb_tex = None
        if alb is not None:
            img = _fit(alb, fit_px)
            if alpha_mode == 'OPAQUE' and self.albedo_jpeg:
                data = _jpg(img, self.jpeg_q)
                alb_tex = self._image_jpeg(data, base)
            else:
                alb_tex = self.glb.image(_png(img), base)
            info['albedo'] = f'{img.width}x{img.height}'

        # ---- normal -----------------------------------------------------
        nrm_tex, nsrc = None, None
        if is_water:
            # $bumpmap on a water material is a DU/DV refraction-distortion
            # map, not a tangent normal map - feeding it to NORMAL_MAP gives
            # garbage. $normalmap is the real one.
            bump = m.tex('$normalmap') or m.tex('$bumpmap')
        else:
            bump = m.tex('$bumpmap') or m.tex('$normalmap')
        if bump:
            nb = self._tex_rgba(bump)
            if nb is not None:
                nimg = _fit(nb[:, :, :3], self.normal_px).convert('RGB')
                if self.flip_green:
                    a = np.asarray(nimg).copy(); a[:, :, 1] = 255 - a[:, :, 1]
                    nimg = Image.fromarray(a, 'RGB')
                nrm_tex = self.glb.image(_png(nimg), bump)
                nsrc = 'source'
        if (nrm_tex is None and self.gen_normals and alb is not None
                and relief > 0 and forced_col is None):
            nimg = normal_from_albedo(alb, relief * self.normal_strength,
                                      self.normal_px)
            nrm_tex = self.glb.image(_png(nimg), (base or matname) + '_gen_n')
            nsrc = 'generated'
        info['normal'] = nsrc

        # ---- emission ---------------------------------------------------
        emis = None
        if self.emissive and m.get('$selfillum') in ('1', 1) and alb is not None:
            mean_a = float(alb[:, :, 3].mean()) / 255.0
            # Source masks selfillum by basetexture alpha; The Zone has no
            # emission *texture*, so only emit when most of the sheet glows.
            if mean_a > 0.55:
                tint = m.vec('$selfillumtint', (1., 1., 1.))
                emis = tuple(min(1.0, c * 0.45) for c in tint)
                info['emissive'] = [round(c, 3) for c in emis]

        # Measured in game (tools/make_material_probe.py): this shader's GGX
        # lobe is not energy-conserving, so ROUGHNESS is the dominant lever and
        # it runs backwards from intuition - LOW roughness blows out toward
        # white, HIGH roughness renders dark. Sunlit top-face luminance at
        # metallic 0 went 217 / 207 / 193 / 171 / 135 for roughness
        # 0.15 / 0.35 / 0.55 / 0.75 / 0.95. Source's world is mostly rough
        # matte material, which lands in the dark end of that curve and
        # partly offsets the missing lightmap. --roughness-scale is the lever
        # for tuning it; scaling DOWN brightens but risks the blowout.
        if abs(self.roughness_scale - 1.0) > 1e-6:
            rough = float(np.clip(rough * self.roughness_scale, 0.04, 1.0))
        if self.roughness_min > 0:
            # A floor, not a scale. The gloss is a narrow GGX lobe and it only
            # bites below about 0.5: simulating this shader at albedo 0.5 under
            # one white sun, the specular share of the pixel at the mirror
            # angle is 74 % at roughness 0.25, 29 % at 0.40, 10 % at 0.55 and
            # 1 % at 0.90. Scaling leaves the low end low; a floor removes it.
            if rough < self.roughness_min:
                info['roughness_floored'] = round(rough, 3)
            rough = max(rough, self.roughness_min)

        # $nocull, and any cut-out sheet, has to be two-sided. The game drops
        # cull_mode, so record it for the mesh builders to mirror instead.
        if m.get('$nocull') in ('1', 1):
            dbl = True
        info.update(surfaceprop=sprop, roughness=round(rough, 3),
                    metallic=round(metal, 3), alpha=alpha_mode,
                    two_sided=bool(dbl), status='ok')
        self.report.append(info)

        idx = self.glb.material(
            label, albedo_tex=alb_tex, normal_tex=nrm_tex,
            roughness=rough, metallic=metal,
            base_color=(*(forced_col or (1.0, 1.0, 1.0)), 1.0),
            alpha_mode=alpha_mode, double_sided=dbl, emissive=emis)
        if dbl:
            self.two_sided.add(idx)
        if alpha_mode == 'MASK' and alb is not None:
            # remember the silhouette so big sparse cards can be trimmed to it
            self.cutouts[idx] = OpaqueMask(alb[:, :, 3])
        return idx

    def _image_jpeg(self, data, name):
        key = hash(bytes(data))
        if key in self.glb._img_cache:
            return self.glb._img_cache[key]
        v = self.glb._view(data)
        self.glb.j['images'].append({'bufferView': v, 'mimeType': 'image/jpeg',
                                     **({'name': name} if name else {})})
        self.glb.j['textures'].append({'sampler': 0,
                                       'source': len(self.glb.j['images']) - 1})
        idx = len(self.glb.j['textures']) - 1
        self.glb._img_cache[key] = idx
        return idx
