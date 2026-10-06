# zone-map-forge

Converts **Source engine BSP maps** into **The Zone FPV** custom maps —
geometry, original textures, generated normal maps, static props, spawn point
and a `manifest.json`. Pure Python (numpy + Pillow); no Blender, no GPU.
It also converts **Uncrashed** map-editor and Workshop maps, reading the art
out of the game's Unreal paks ([below](#uncrashed-maps-its-map-editor-and-steam-workshop)).

```
python3 forge.py de_nuke --install            # finds Steam, the game and The Zone itself
python3 forge.py de_inferno -o ./out --install --exclude-prop elevatordoor
python3 forge.py "D:/maps/custom.bsp" -g css --install
python3 forge.py "<steamapps>/workshop/content/1682970/3570379009" --install   # Uncrashed
```

Steam libraries, game content roots and The Zone's `custom_maps` are all
auto-detected (Windows registry + `libraryfolders.vdf`, the usual Linux/macOS
paths, and this sandbox's `~/mnt`). Override with `--game-dir` and
`--install DIR`. **Do not hardcode content paths** - an earlier version had them
pinned to one machine's mount points, which produced a "successful" 3.4 MB
de_nuke with no props and no textures because `SourceFs` silently found zero
VPKs. Missing content is now a hard error unless you pass
`--allow-missing-content`.

Works on anything Source: CS:Source, HL2, **Vampire: The Masquerade – Bloodlines**
(Source 2004), Portal, TF2, Garry's Mod content.

---

## What The Zone's custom map format actually is

The wiki documents "export a .glb from Blender". The loader does considerably
more than that. Reverse-engineered from `thezone.pck` (Godot 4.5.2 —
`custommaps/handler/custom_map_root.gd`, `gdutil/z_asset_loader.gd`) and the
shipped `maps2/maps/*/manifest.json`.

### Folder layout

```
custom_maps/<name>/
    <name>.glb        # or map.glb
    manifest.json     # optional, undocumented, worth having
    occluder.occ      # optional, baked occlusion culling
    baked_<skybox>_<quality>/*.dds   # optional baked lightmaps
```

### manifest.json

```jsonc
{
  "spawn_point": [px,py,pz, rx,ry,rz, sx,sy,sz],   // "vec9": pos, euler RADIANS, scale
  "skybox":  { "skybox_name": "cloudy_sunny", "sky_rotation": 143.0, "energy": 1.0 },
  "lighting_variations": {                          // one is picked at load time
     "sunny": { "skybox": { "skybox_name": "sunny", "sky_rotation": 3.0, "energy": 1.0 } }
  },
  "assets": [ { "type": "custom", "custom_type": "spray_can",
                "transform": [ ...vec9... ] } ]
}
```

Built-in skyboxes (`materials2_compiled/skybox/<name>_<4k|8k>.hdr`):
`sunny`, `cloudy_sunny`, `dawn`, `sunset`, `industrial_sunset`.

Placeable `custom_type` assets: `spray_can`, `rock`, `brick`, `wood_plank_big`,
`lipo`, `propeller-cw`, `propeller-ccw`.

### Materials — the part that matters for how a map looks

`ZAssetLoader` treats every material one of two ways:

1. **Name matches a built-in** — a `z_`-prefixed name (382 of them, the
   freepbr.com library: `z_brick-wall`, `z_pebbled_asphalt`, `z_rusted-steel`…),
   or one of the legacy Blender-template names (`Poliigon_ConcreteWallCladding_7856`,
   `CityStreetAsphaltGenericClean`, `Concrete02`, `Glass`, …). The material is
   **replaced wholesale** by the game's own PBR set at the current texture
   quality. This is why the Blender template's textures look degraded in
   Blender but fine in game.

2. **Anything else** — the glTF `StandardMaterial3D` is **converted** into the
   game's `CustomMaterial` shader, carrying over:

   | glTF                      | CustomMaterial param |
   |---------------------------|----------------------|
   | `baseColorTexture`        | `albedo_texture`     |
   | `baseColorFactor`         | `albedo_color` + `use_albedo_color` |
   | `normalTexture`           | `normal_texture`     |
   | `roughnessFactor`         | `roughness_value` + `use_roughness_value` |
   | `metallicFactor`          | `metallic_value` + `use_metallic_value` |
   | `emissiveFactor`          | `emission` + `emission_energy_multiplier` |
   | alpha / `has_alpha()`     | picks `custom_material_alpha.tres` |

   **So imported materials do participate fully in the game's lighting.**
   Ripped maps look flat not because the engine is weak, but because rips ship
   albedo-only materials — no normals, no roughness. Supply those and they
   light like native geometry. There is no emission *texture* channel, so
   emissive is flat per-material.

### What the importer *drops* — and why it shapes the whole converter

The conversion is `gdutil/z_asset_loader.gdc` → `convert_custom_materials`,
read out of `thezone.pck`. Six things a normal glTF author would rely on are
never copied (or not as written), and each one caused a visible bug here:

| glTF / StandardMaterial3D | fate | consequence |
|---|---|---|
| `normalTexture.scale` | **dropped** | `custom_material.gdshader` does `NORMAL_MAP = texture(normal_texture, UV).rgb` with no `NORMAL_MAP_DEPTH`. A generated normal map is always applied at 1.0, so damping has to be baked into the pixels. |
| `doubleSided` | **dropped** | Neither shader declares `cull_disabled`. `$nocull` art (grates, railings, tree cards) is invisible *and* non-collidable from one side, since Godot's trimesh collision is front-face only. |
| `baseColorFactor` **with** a texture | **ignored** | The shader is `if (use_albedo_color) ALBEDO = albedo_color.rgb; else ALBEDO = texture(...)`. Either/or, never the product — a `$color` tint left in `baseColorFactor` silently vanishes. |
| `baseColorFactor` **without** a texture | **too bright** | The importer converts it linear -> sRGB, and the shader's `albedo_color` has no `source_color` hint, so a factor `f` shows as `srgb(f)`: a 0.78 white as 0.95. A colour belongs in a small texture (`albedo_texture` *is* `source_color`). |
| `metallicRoughnessTexture` | **mis-read** | The shader samples `.r` of both `roughness_texture` and `metallic_texture`, but Godot's glTF importer packs roughness in **G** and metallic in **B** of one ORM image. Per-pixel roughness is therefore not available; ship scalar factors only. |
| duplicate material names | **collapse** | Converted materials are cached by `resource_name`, so two glTF materials with the same name become one in game and the second one's textures are dropped. Every emitted name is kept unique (`material_names_deduped` in the report). |

### The black walls: `ALBEDO * DIFFUSE_LIGHT`, and a custom map has no ambient

The gloss is one half of the "meh" look; this is the other, and it is worse.
Every pixel is

    ALBEDO * (DIFFUSE_LIGHT + AMBIENT_LIGHT) + SPECULAR_LIGHT

`DIFFUSE_LIGHT` is Lambert - `NdotL * LIGHT_COLOR / PI` - and the game gives a
custom map next to no ambient (the shader declares no `render_mode`, so
nothing is disabled at that level; the environment simply provides none).
So a surface facing away from the sun multiplies whatever it has by zero.
de_inferno's T spawn is the proof: sunlit faces grey, the sky bright blue, and
the shaded side of every building **pure black**, with a lit prop door sitting
in the middle of it.

The part that took a while to accept: **baking does not fix this.** The light
goes into the albedo, and the albedo is the thing being multiplied by zero.

| baked albedo 0.6, ambient 0 | energy 1.0 | 2.0 | 3.14 |
|---|---|---|---|
| facing the sun | 121 | 166 | 203 |
| wall at 45 degrees | 102 | 141 | 173 |
| wall side-on | 47 | 68 | 85 |
| facing away / a ceiling | **0** | **0** | **0** |

Raising `--energy` scales the column, not the last row.

`--flat-normals` is the way out. It points every baked surface the same way
(up, by default), so `NdotL` is the same everywhere and the surface renders
the light that was baked into it. That is exactly what the official maps do -
their branch replaces `DIFFUSE_LIGHT` with the lightmap and never computes
`NdotL` at all - and it is why they have no black walls.

It wants a high `--energy`: at **3.14** the shader's own division by PI
cancels and a baked surface shows its baked value. Three caveats worth
knowing:

* Props keep their real normals (they are instanced and never baked), so
  their shaded sides stay dark. They are small; the walls are what matters.
* It assumes the game's sun casts no shadows on custom maps, which is what
  de_inferno's palace shows - an interior floor lit through a solid roof.
* `tools/bake_glb.py --flat-normals` covers far more of a map than
  `forge.py --bake-lightmaps --flat-normals` does, because the BSP bake only
  tiles lit world faces: on de_aztec that is 11,504 triangles out of 81,158,
  the rest being displacement terrain and rebuilt shell. The .glb bake takes
  all of it.

### Why converted maps look glossy and dim next to the official ones

Two separate things, both in `light()`, and neither is a texture problem.

**Official maps are never given a specular lobe.** The whole of the baked
branch is:

    void light() {
        if (shadow_map_index >= 0.0) {
            DIFFUSE_LIGHT = diffuse_light;      // the lightmap, and return
        } else {
            ... Lambert diffuse ...
            SPECULAR_LIGHT += specularBRDF * LIGHT_COLOR * ATTENUATION;
        }
    }

A custom map always takes the `else`, so it always gets the GGX lobe that
OG Bando never has. Simulating that BRDF at albedo 0.5 under one white sun,
the specular share of a pixel **at the mirror angle**:

| roughness | 0.25 | 0.40 | 0.55 | 0.75 | 0.90 |
|---|---|---|---|---|---|
| specular share | **74 %** | 29 % | 10 % | 3 % | 1 % |

Source surfaces land below 0.5 whenever `$surfaceprop` is tile or metal, or
the material samples an `$envmap`, or it carries a `$phongexponent` - about a
tenth of de_cpl_strike's 253 materials. Those are the wet-plastic patches.
`--roughness-min` puts a floor under all of it (a floor, not a scale: scaling
leaves the low end low), and `--metal-sheen 0` removes the other feed into the
same lobe - metallic pushes f0 from 0.01 to the albedo, taking a wall from 2 %
specular to 15 % at 0.15.

**Everything is dim because the diffuse is divided by PI.**
`lightColor = LIGHT_COLOR / PI` costs a factor of 3.14, so a mid-grey albedo
under a full white sun reaches 0.111 linear - **94/255** - before ambient.
Official maps do not pay it: their `DIFFUSE_LIGHT` is the lightmap itself.

That makes the early `--bake-lightmaps` default of `--energy 0.45` a mistake -
it was guarding against "double lighting" that the PI division had already
paid for, and it halved an already dim map. Baking now leaves `--energy` at
1.0, and with the light in the albedo it wants more, not less.

So the matte pairing, which `--bake-lightmaps` now sets up by itself:

    --bake-lightmaps            (light in the albedo)
    --roughness-min 0.9         (no lobe, like the official maps)
    --metal-sheen 0             (nothing else feeding it)
    --energy 1.0                (and up from there if it still reads dark)

### ROUGHNESS is the dominant lever, and it runs backwards — MEASURED

`custom_material.gdshader`'s `light()` adds a GGX lobe that is **not**
energy-conserving, and `DistributionGGX` peaks at `1/(PI * alpha^2)` at normal
incidence — 629 at roughness 0.15 against 0.39 at 0.95. The consequence is the
opposite of the usual intuition: **low roughness blows out toward white, high
roughness renders dark.**

Measured in game with `tools/make_material_probe.py` — 25 cubes sharing one
albedo, top-face luminance out of 255:

```
              metallic 0.00  0.15  0.35  0.60  0.85
    roughness 0.15     217   220   222   221   218
    roughness 0.35     207   210   214   215   209
    roughness 0.55     193   196   205   207   202
    roughness 0.75     171   176   191   198   192
    roughness 0.95     135   140   167   184   179
```

Roughness swings a **lit** surface by 60 % (135 → 217). Metallic moves it by at
most a few percent at low roughness, and at high roughness it *brightens*
(135 → 184), because raising f0 from the dielectric `0.04 * SPECULAR_AMOUNT^2`
= 0.01 towards albedo adds more specular than the engine's
`diffuse_light *= 1.0 - metallic` removes.

Source's world is mostly rough matte material — concrete 0.88, brick 0.89,
dirt 0.96 in the table above — which lands in the dark end of that curve and
so partly offsets the missing lightmap. That is a coincidence, not a design.
`--roughness-scale` is the lever for tuning it; scaling **down** brightens, at
the risk of the blowout.

### METALLIC: Source has no metalness channel, so don't invent one

The converter used to set `metallic` from `$surfaceprop`. That was a category
error: `$surfaceprop` is a physics-and-footstep-sound property — "this sounds
like metal when you shoot it" — not a statement about conductivity. It gave
**151 de_nuke materials metallic 0.85, covering 17.3 % of the map's surface
area**.

**The original diagnosis for this was wrong, and the probe above is what caught
it.** The claim was that metallic 0.85 is why de_nuke's doors render near-black,
reasoning from Godot's `diffuse_light *= 1.0 - metallic; ambient_light *= 1.0 -
metallic`. On a **lit** surface that is simply not what happens — metallic is
near-neutral there, and mildly brightening.

What survives is narrower. On a **shaded vertical** surface — which is what
those doors are — `NdotL ~ 0`, so both the Lambert term and the GGX lobe
vanish and sky ambient is the only light left. Ambient is exactly what
`(1 - metallic)` scales, with no specular gain to compensate. That case is
still untested. A roof cannot create it: **the game casts no directional
shadows for custom maps**, so an occluder changes nothing. With no shadow
casting, the only thing that varies a surface's direct light is its normal
against the sun - so a plate facing straight DOWN receives none, and that is
the ambient-only case reached without any occlusion. `tools/make_material_probe.py`
(v3) builds the 5x5 grid twice on that basis: once facing the sky, once as a
downward-facing canopy.

Either way, keeping metallic low is safe: measured as a wash on lit surfaces,
and, at worst, irrelevant on shaded ones - where the finding below says there
is hardly any light to lose in the first place. Source's own model supports it too — `LightmappedGeneric` with
`$envmap` draws a **full-strength** diffuse and *adds* a masked, tinted cubemap
reflection on top, which in PBR terms is a dielectric.

So `metallic` now defaults to 0 and is raised only when `$surfaceprop` says
metal **and** the material actually samples a cubemap, scaled by `$envmaptint`
and the mean of `$envmapmask`, capped at 0.35. `--metal-sheen` sets the ceiling
(default 0.15, `0` disables). For reference, the two best-looking community maps
— `skate3_downtown` (895 materials) and the community `de_dust2` — ship
metallic 0.0 and roughness 1.0 on *every* material.

### No directional shadows, and almost no ambient on unlit faces

Two things measured in game that bound what any material change can achieve:

* **Custom maps get no directional shadow casting.** A solid roof over one
  half of a test grid left it exactly as bright as the half in the open. The
  loader does call `set_shadows_enabled` from `ZSettings.SHADOWS`, but for this
  content nothing casts. So geometry never darkens geometry, and an occluder is
  not a way to create a shaded test case.
* **A surface the sun misses goes nearly black.** In the same screenshot, a
  `z_concrete2` roof slab read light grey on its top face and near-black on its
  underside, and `z_clean-concrete` pillars read RGB 7-17 out of 255 on their
  vertical faces while the pad's upward face read RGB 83/85/92. Same materials,
  different normals. Sky ambient here is weak and strongly biased upward - the
  HDR panorama's lower hemisphere contributes almost nothing.

The second point is the more important one for fidelity, and it reframes the
job: on a surface with no direct light, no roughness or metallic value will
rescue it, because there is barely any light to redistribute. That is a baked
lightmap problem (see below), not a material problem.

It also means `z_` builtin materials are useless as a visual reference on small
geometry - a 0.5-1 m box of `z_clean-concrete` renders flat black with no
visible texture at all.

### The material-name cache is real, and it was confirmed in the log

`gdutil/z_asset_loader.gdc` keys converted materials on `resource_name`. The
game log proves the cache hits across meshes:

```
Converted to CustomMaterial: src_wood_infceilingawood_infceilinga_0_0_-2
Used converted mat from cache: src_wood_infceilinga
Used converted mat from cache: src_wood_infceilinga
```

(the printed string is `mat_name + node.name`, hence the doubled look). So two
glTF materials sharing a name become **one** CustomMaterial in game and the
second one's textures are silently dropped. Before this was caught, all five
WorldVertexTransition bands slugged to the same name and would have collapsed
into one — quietly undoing the entire blend. Every emitted name is now unique,
reported as `material_names_deduped`.

### `$detail` — Valve's grain, and a ~10 % darkening

47 de_nuke materials (14.8 % of world area), including all the stock concrete
and brick, carry `$detail` with `$detailblendmode 0`
(`TCOMBINE_RGB_EQUALS_BASE_x_DETAILx2`):

```
result = base * lerp(1, 2 * detail, $detailblendfactor)
```

The bake is done on the **stored gamma-space bytes**, not in linear light, and
that is deliberate. `detail/noise_detail_01` averages 0.436, so ×2 lands at
0.872 — Valve tuned these sheets to be slightly darkening plus a lot of
authored grain. In linear light ×2 would land at 0.32 and crush every surface
that uses one, which is obviously not what the game looks like.

Measured on `brick/brickwall045a` at `$detailblendfactor .8`: mean 75.2 → 67.0,
**−10.9 %**, with relative contrast up from 0.360 to 0.384. That is most of why
the brick read too light and too flat.

`$detailscale` is a UV multiplier, so an exact bake needs a whole number of
detail tiles per albedo tile; it is rounded to the nearest one. Valve's scales
are ~4.3–7.7, where rounding shifts the grain frequency under 10 % and keeps
the sheet seamless. `--no-detail` disables it.

#### `$detailblendmode 4` is not a detail pass at all — it swaps the two textures

`TextureCombine()` in Valve's `common_ps_fxc.h` defines eleven modes. Modes
0/1/8 are grain overlays and were the only ones handled; everything else fell
back to mode 0. That is fine until mode 4 (`TCOMBINE_BASE_OVER_DETAIL`) turns
up, because **mode 4 reverses the roles of the two textures**. Valve says so in
their own VMT, `models/props_farm/building001.vmt`:

```
"$basetexture" "models/props_farm/building001_dirtmap"
                            // This is used as the detail texture in this blending mode.
"$detail"      "wood/grain_elevator_facade_14b"
                            // This is used as the base in this blending mode.
"$detailblendmode" "4"
```

The shader is `rgb = lerp(base, detail, f * (1 - base.a)); a = detail.a`, so
`$detail` is the surface and `$basetexture` is a dirt overlay masked by its own
alpha. `building001_dirtmap` measures **RGB exactly 0** with the dirt in its
alpha channel — so running it through mode 0 multiplied the wood by black and
produced a pure black albedo. ctf_2fort's big farm building rendered as a black
slab, and because all three `building001*` materials then hashed to the same
black image they collapsed onto one texture.

Modes 2 (`DETAIL_OVER_BASE`), 3 (`FADE`) and 4 are now transcribed properly.
Mode 4 also resamples to the detail sheet's own frequency —
`base_px * $detailscale`, capped at 1024 — instead of smearing a 4x-tiled wall
texture across a 512 px base, and takes its output alpha from the detail so the
dirtmap's alpha can never make the model translucent. Modes 5–7 and 9–11
(self-illum, two-pattern select, ssbump) still fall back to mode 0; none has
appeared on any material used by the maps tested.

Only 3 of the 321 detail materials across ctf_2fort, de_nuke, de_dust2,
de_inferno, de_aztec and de_cache use mode 4 — but they were 100 % of the
visible damage.

### `WorldVertexTransition` — a quarter of de_nuke was the wrong texture

`de_nuke/nukblenddirtgrass` mixes `nature/dirtfloor012a` with
`nature/dirtfloor006a` using **displacement vertex alpha**. That one material is
**20,892 m² of displaced surface, 24 % of the map's drawable area**, and its
vertex alpha averages 121/255 — so it should be roughly a half-and-half mix.
Using `$basetexture` alone showed the wrong ground over a quarter of the map.

`CustomMaterial` has exactly one albedo sampler and drops vertex colour, so a
live blend is impossible. Instead N mixes are pre-composited (in **linear**
light — this is a true lerp between two albedos, unlike the detail trick) and
one is chosen per triangle:

* `--blend-bands N` (default 5) pre-composited mixes per blend material.
* `--blend-cell M2` (default 1.5) subdivide first, to about this triangle area.

The subdivision matters: nuke's blend displacements are only power-2 (a 5×5
grid) and up to 65 m across, so a single triangle can exceed 100 m². Banding at
that size reads as flat patches; subdividing to ~1.5 m turns the same
quantisation into a soft mottle. Verified area-exact — 512 source triangles
become 12,661, and the per-band areas sum to the BSP's displaced area to within
1 m²:

```
src_de_nuke_nukblenddirtgrass_blend0of5   3661 m2    (was ALL 20,892 m2)
src_de_nuke_nukblenddirtgrass_blend1of5   4909 m2
src_de_nuke_nukblenddirtgrass_blend2of5   5050 m2
src_de_nuke_nukblenddirtgrass_blend3of5   3915 m2
src_de_nuke_nukblenddirtgrass_blend4of5   3358 m2
```

Band names must stay distinct (`..._blend2of5`) because of the
name-cache collapse above. de_dust2 and de_inferno use no blend materials;
de_train and cs_militia lean on them heavily.

### `$color` above 1 is a brightening tint, not a 0-255 colour

Source writes colours two ways and they are not interchangeable:

    $color "{255 255 255}"    integers, 0-255
    $color "[1.3 1.25 1.5]"   floats, and deliberately allowed above 1.0

The bracket form above 1 is a **gain**: the mapper brightens the albedo because
the baked lightmap is about to darken it again. The VMT parser used to decide
the form by magnitude - `'{' in raw or max(v) > 1.001` meant "divide by 255" -
which reads `[1.3 1.25 1.5]` as `(0.005, 0.005, 0.006)` and paints the surface
black.

No stock VMT is affected: 9,281 CS:S and 12,064 Garry's Mod materials parse
identically before and after. Custom content is another matter - **50 of
`gm_br_pitfalls`' materials use a float `$color` above 1**, and they are the
map's main wallpaper, carpet, plaster and ceiling, so most of the backrooms
rendered pure black while the props and the base-game textures beside them
looked fine.

Only a value with no delimiters at all is genuinely ambiguous, and only there
does magnitude decide (above 8, it is 0-255).

The gain itself is then **dropped, and only the hue kept**: `[5 5 5]` becomes
neutral, `[1.3 1.25 1.5]` becomes `(0.87, 0.83, 1.0)`. Applying a x5 multiply
to an LDR albedo with no lightmap to pull it back down gives a flat white wall.
The dropped factor is reported as `tint_gain`, and it is the right factor to
put back if the lightmap is ever baked in.

### Two-sided art needs real back faces

Because `doubleSided` is dropped, any `$nocull` material or cut-out sheet gets
its triangles duplicated with reversed winding and negated normals. This also
fixes collision, which was front-face-only for the same geometry. Cost:
de_inferno +72,813 prop triangles (the tree cards), de_nuke +21,851,
de_dust2 +1,556.

### Colour fidelity is not the problem

Worth recording because it was the obvious suspect and it is wrong: the
VTF → resize → JPEG q90 path is colour-exact. Measured per-channel means on six
de_nuke textures drift by at most **0.32/255**. There is no gamma or sRGB shift
anywhere in the albedo pipeline — the remaining washed-out look is the missing
lightmap (see below) plus, before this change, the missing `$detail` darkening.

### Other undocumented features

* **`-collider` mesh suffix** — a mesh whose name ends in `-collider` becomes
  invisible collision-only geometry. Ship cheap collision separate from
  detailed visuals.
* Collision is otherwise auto-generated (`create_trimesh_collision`) per mesh,
  so chunking the map into many meshes is free and helps culling.
* `lod_scale` is respected.
* Baked lightmaps are `BC6H` DDS named `*_zlms-<size>_comb.dds` in
  `baked_<skybox>_<quality>/`, bound as `Texture2DArray` via
  `set_instance_shader_parameter` (`shadow_map_bucket`, `shadow_map_index`).
  Custom maps *can* ship these — not implemented here yet.
* `zs_rainbow` is a special shader material.

---

## What the converter does

| Step | Detail |
|---|---|
| **Scale** | 1 Hammer unit = **1 inch = 0.0254 m**. Verified against HL2 eye height (64 u → 1.63 m) and door height (84 u → 2.13 m). The community `de_dust2-69.glb` is raw Hammer units — **52× oversized**. |
| **Axes** | Source Z-up → glTF Y-up: `(x, y, z) → (x, z, −y)`. |
| **Brush geometry** | Faces from planes/edges/surfedges, UVs from `texinfo` vectors, fan-triangulated. Tool textures (nodraw / skip / hint / clip / trigger / areaportal) dropped. |
| **Displacements** | Full `DISPINFO` + `DISP_VERTS` grid with corner rotation to `startPosition`, alternating diagonals. |
| **Brush entities** | Included; `origin` keys are *pivots* not offsets, so they are **not** applied. Invisible classes (triggers, buyzones, bomb targets) skipped. |
| **Static props** | `GAME_LUMP 'sprp'` + full `.mdl` / `.vvd` / `.vtx` reader (LOD 0, tri-strip aware, skin tables, VVD LOD fixups). Placed as **instanced glTF nodes** — one mesh per model, so 751 props cost 247 k unique triangles instead of 650 k. Also picks up `prop_dynamic` / `prop_physics` entities. |
| **Textures** | VPK v1/v2 reader + BSP `PAKFILE` zip (map-specific `_wvt_patch` blends resolve correctly) + VTF decoder (DXT1/3/5 via DDS-wrap, plus the uncompressed formats). |
| **Normal maps** | `$bumpmap` used where it exists (26 materials in inferno); **generated** from albedo luminance for the rest (434), with per-`$surfaceprop` relief strength and wrap-around edges so tiling stays seamless. |
| **Roughness / metallic** | Priors per `$surfaceprop`, tightened by `$envmap` presence and `$phongexponent`. |
| **Alpha** | Decided from the **alpha histogram**, not just the VMT flag: bimodal (> 85 % fully on/off) → `MASK` alpha-scissor, so cut-out foliage and fences write depth and never sort wrongly. Only genuine glass stays `BLEND`. |
| **Emission** | `$selfillum` → `emissiveFactor`, but only when most of the sheet glows (Source masks it by alpha, which the game can't reproduce). |
| **3D skybox** | The miniature `sky_camera` region is detected and dropped (nearest-centroid vs. player spawns). `--keep-3d-skybox` to keep it. |
| **Manifest** | Spawn from `info_player_*` with yaw converted to Godot Y-rotation; skybox chosen from `worldspawn.skyname`; `sky_rotation` derived from the `light_environment` sun azimuth; `energy` from `_light` brightness. |

## Layout

```
forge.py              CLI
zonemap/bsp.py        BSP lumps, faces, displacements, entities
zonemap/build.py      world geometry -> chunked, Y-up, metre-scale
zonemap/props.py      GAME_LUMP 'sprp' static prop lump
zonemap/mdl.py        .mdl + .vvd + .dx90.vtx StudioModel reader
zonemap/propbuild.py  instanced prop placement
zonemap/vpk.py        VPK v1/v2
zonemap/sourcefs.py   layered content: BSP pakfile > VPKs > loose
zonemap/vmt.py        KeyValues / VMT with $patch
zonemap/vtf.py        VTF -> RGBA
zonemap/materials.py  VMT -> glTF PBR (the hybrid path)
zonemap/glb.py        dependency-free GLB writer
zonemap/manifest.py   The Zone manifest.json
zonemap/convert.py    orchestration
zonemap/upak.py       Unreal .pak v10/v11 (Uncrashed)
zonemap/uasset.py     cooked Unreal packages, tagged properties, DataTables
zonemap/umesh.py      Unreal StaticMesh LODs
zonemap/utex.py       Unreal Texture2D -> RGBA
zonemap/umat.py       Unreal material instance -> glTF material
zonemap/uland.py      Unreal landscape -> adaptive terrain, painted layers
zonemap/ulevel.py     Unreal level -> static, instanced and spline meshes
zonemap/ugeo.py       Unreal -> glTF transforms, indexed chunks, box UVs, decals
zonemap/uncrashed.py  Uncrashed map -> glb + manifest
tools/render.py       numpy software rasteriser for previewing output
```

## Useful flags

```
--scale 0.0254      metres per Hammer unit
--cell 48           mesh chunk size (m); smaller = finer culling
--albedo-px 512     albedo texture size    --normal-px 256
--png-albedo        lossless albedo (bigger)   --jpeg-q 90
--no-gen-normals    skip synthesised normals
--flip-green        if normal-mapped surfaces light inside-out
--no-props          world brushes only
--sun-offset 30     rotate the sky to line the sun up by eye
--keep-3d-skybox    keep the miniature backdrop

--metal-sheen 0.15  ceiling on metallic for $envmap metal (0 = fully dielectric)
--no-detail         skip the $detail x2 bake
--normal-strength 1 multiplier on generated normal relief
--blend-bands 5     pre-composited mixes for $basetexture2 blends (0/1 = off)
--blend-cell 1.5    target triangle area (m2) before choosing a blend band
--roughness-scale 1 multiplier on all roughness (LOW = blown out, HIGH = dark)
--water-roughness .6 roughness for 'water' materials (0.04 blows out to white)
--water-value 0.28  target luminance for water's $fogcolor-derived tint
--min-exposed 0.10  how much of a hidden side must see open air to be rebuilt
--no-rebuild-culled skip faces vbsp deleted for facing the void
```

---

## Rebuilding hidden geometry (`--fill`)

CS mappers paint `tools/toolsnodraw` on every surface a 1.8 m player can never
see: the flat tops of roofs, the backs of parapets, ceilings above the playable
volume. **vbsp does not flag these faces - it deletes them from the FACES lump
outright**, keeping the brush solid only for collision. A player never notices.
A drone flies over the roofline and looks straight into the buildings.

The geometry survives in `BRUSHES` / `BRUSHSIDES`, where each side still
carries its `texinfo`. `zonemap/nodraw.py` rebuilds it:

1. Keep brushes with `CONTENTS_SOLID`; take each side's outward plane,
   discarding vbsp's collision-only `bevel` sides.
2. Intersect every triple of planes, keep the points satisfying all
   half-spaces, group them per plane and sort them counter-clockwise about
   that plane's normal - a convex brush back into polygons.
3. Keep only sides whose material is `nodraw`.
4. **Exposure test**: probe 1.5 units along the outward normal and check it
   against a spatial index of every solid brush. If the probe is inside one,
   the face is buried between abutting brushes and is skipped. On de_inferno
   this rejects 1585 of 3728 sides; on de_dust2, 3362 of 4742.
5. **Material donation**, so a fill matches the building it belongs to:
   a sibling side of the same brush facing the same way, else the nearest
   visible face within ~10 m whose normal aligns, else an orientation-keyed
   `z_` built-in. UVs come from the donor's own texture axes, so tiling and
   scale stay continuous with the surface it borrowed from. On de_inferno
   1051 fills come from a sibling, 791 from a neighbour, only 32 fall back.
6. **Degenerate-projection guard**: Source assigns texture axes per face, so
   axes borrowed from a donor that is edge-on to the fill smear into streaks.
   If `|normalize(u x v) . n| < 0.35` the fill uses a plain box projection
   instead. That catches 608 of 1874 fills on inferno, 404 of 1357 on dust2.

Modes: `--fill none` (original CS behaviour) | `up` (roofs and tops only) |
`exposed` (**default** - every hidden face open to air) | `all`.

Measured on de_inferno, viewed from directly above with backface culling:
**8.83 % of the map footprint was open holes, and all of it closed, with zero
geometry lost.** Cost: +3817 triangles (+0.6 % of the map's total), +0.5 MB,
+83 meshes - the fills mostly merge into existing material/cell chunks, so
they add very few new collision bodies.

## Non-solid props (`--nonsolid-props`) - a performance lever, NOT a fidelity fix

On de_inferno 192 of 547 static props are `solid == 0`. It is tempting to read
that as "these should not collide". **That reading is wrong for a flight sim.**
`solid == 0` is a first-person-shooter authoring convention: mappers mark window
frames, balcony railings and vines non-solid so players do not snag while
strafing, with a `playerclip` brush doing the real blocking. It says nothing
about whether the object is physically there. A railing you can fly through is
worse than one you have to pilot around.

So `--nonsolid-props keep` is the default and the right answer. `skip` exists
only as a performance escape hatch for a weak machine: it removes 198
placements and 199k effective triangles on inferno, at the cost of real
obstacles.

## Collision accuracy

The Zone calls `create_trimesh_collision` per mesh, which builds a
`ConcavePolygonShape3D` from the visible triangles - so the collider *is* the
mesh, exactly. That is stricter than CS:S itself, which collides props with
coarse convex `.phy` hulls (and gives foliage no collision at all, which is why
those props are flagged `solid == 0`).

The one real mismatch is **alpha cut-out sheets**. 23.4 % of de_inferno's
unique triangles sit on `MASK` materials that are only 13-17 % opaque: a tree is
two triangles forming a rectangle, you see a leafy silhouette but you collide
with the whole pane. About 25,000 triangles' worth of collider surface is fully
transparent pixels.

### `-collider` does nothing useful (tested in game)

`tools/make_collider_test.py` builds a probe map: three identical 4 m cubes, one
plain, one with a 1 m `-collider` core, one that is `-collider` only. Result:
**all three behave identically** - collision at the outer surface, and the
`-collider`-only cube is not even hidden. So a `-collider` mesh neither replaces
the automatic per-mesh collider nor makes itself invisible. **There is no way to
ship a visible mesh that does not collide.**

### So the collider has to become the silhouette (`--cutout-cell`)

`zonemap/cutout.py` subdivides big sparse cut-out triangles in barycentric space
and drops sub-triangles whose UV bounding box contains no opaque texel. Because
the test is "no opaque texel anywhere in the box", it can only remove fully
transparent area - the render is unchanged. Verified by sampling the original
surface and checking every opaque sample is still covered: **0 lost of 1620**
across 12 cut-out parts.

Only big sparse triangles qualify (`min_area_m2=4`). On de_inferno that is 76
unique triangles - the `tree_group` cards, whose triangles average 90-238 m2 at
14-18 % opacity - which expand to 6228 sub-triangles, +29,866 world triangles
(+4.4 %) and cut whole-map phantom collider area by 47 %. `tree_large`'s 73,720
triangles at 0.09 m2 each are already finer than the texel grid and are left
alone.

`--cutout-cell` tunes it (m2 per sub-triangle, default 0.75). The result is a
canopy-shaped blob with a trunk rather than a leaf-perfect cut-out, which is the
right physical answer - you should not fly through the middle of a canopy.
Smaller cells sharpen the outline: on the biggest card 0.75 -> 2184 tris,
0.15 -> 8352, 0.05 -> 21484.

### Preview-renderer caveats

`tools/render.py` is a numpy rasteriser for eyeballing output. It has **no
near-plane clipping** (it drops any triangle with a vertex behind the camera, so
close-ups of large cards are wrong) and, until recently, interpolated attributes
affinely rather than perspective-correctly. Both made trimmed and untrimmed
builds look different when the geometry was provably equivalent. Verify geometry
claims against the geometry, not against a render.

## LZMA-compressed lumps (TF2, L4D2, Portal 2, CS:GO)

CS:S maps are uncompressed, so this went unnoticed until a TF2 map:

```
ValueError: buffer size must be a multiple of element size
  at bsp.py  self.verts = self._arr(L_VERTEXES, '<3f4')
```

A VERTEXES lump whose length is not a multiple of 12 is the signature. Source
2009 onwards can LZMA-compress lumps individually; `lump_t.fourCC` then holds
the uncompressed size and the lump data begins with:

```c
struct lzma_header_t { uint id;         // 'LZMA' = 0x414D5A4C
                       uint actualSize;
                       uint lzmaSize;
                       uchar properties[5]; };   // 17 bytes, then raw LZMA1
```

Valve strips the standard 13-byte LZMA-alone header and stores the pieces
itself, so it has to be rebuilt as `properties[5]` + the uncompressed size as a
uint64. Two wrinkles:

* Valve's encoder **declares the size and writes no end-of-stream marker**, so
  the declared size is what terminates the stream. Other encoders (Python's
  own included) write the marker and leave the size unknown, and liblzma
  refuses a stream that claims both. `lump_decompress` tries Valve's way first
  and falls back.
* **The game lump is special.** Its sub-lump offsets are offsets into the whole
  file, not into the lump, and Valve compresses it *sub-lump by sub-lump*
  leaving the directory in the clear. So a lump-level "is this LZMA" test says
  no while the `sprp` payload inside is compressed anyway, and a compressed
  sub-lump's `filelen` is its UNCOMPRESSED size and cannot bound the read -
  only `lzma_header_t.lzmaSize` can. Both that layout and a wholly compressed
  game lump are handled.

Verified by recompressing real de_dust2 lumps (VERTEXES, FACES, EDGES,
SURFEDGES, PAKFILE, and the `sprp` sub-lump relocated with a rewritten absolute
offset) and checking that vertices, faces, displacements, entities, all 321
static props and all 91 pakfile entries come back identical.

## The game must be inferred when a .bsp path is passed

`-g` used to default to `css`. Running `forge.py <a TF2 map>` therefore walked
up from `Team Fortress 2/tf/maps` looking for CS:S content, found the sibling
`hl2/` but no `cstrike/`, and returned HL2 alone as the content root. Every TF2
material and model then resolved to nothing and the map converted
"successfully" while being empty - the same silent failure as the missing-VPK
bug, from a different direction.

`-g` now defaults to unset and `locate.guess_game()` reads the game off the
path (Steam folder name first, then which game's own content directory exists
beside the map), printing what it picked. An unrecognisable path is a fatal
error rather than a wrong guess.

Also fixed while here: `--install "<steam>/..."` with the placeholder pasted
literally used to die inside `makedirs` with `WinError 123`, since `<` and `>`
are illegal in Windows paths. It now warns and auto-detects.

## Garry's Mod Workshop maps (`.gma`)

A Workshop map is not a folder, it is one flat archive. `gm_br_pitfalls` ships
as a 1.6 GB `.gma` holding 11,621 files: two `.bsp`s, 1,595 models, 1,285
materials and the 1,415 `.vtf`s behind them. Nothing about it is compressed, so
`zonemap/gma.py` reads the table of contents and then seeks - **nothing is ever
unpacked to disk**, and pulling the 197 MB map out of the archive takes about a
second.

    forge.py "<workshop>/2821179466/gmpublisher.gma" -o out

The archive layers into `SourceFs` between the map's own pakfile and the game's
VPKs, which is the order Garry's Mod itself uses: an addon is expected to
override the base game, and the map's embedded pakfile overrides even the
addon. On `gm_br_pitfalls` that split matters - of its 386 world materials,
**207 come from the .gma, 110 from the map's pakfile and 69 from the base
game**, and of its 4,684 prop placements 4,122 are the addon's own models.
Drop any one layer and a chunk of the map turns purple.

Two smaller things this needed:

* **`Bsp` takes bytes.** `self.raw` is the whole file in memory either way, so
  extracting to a temp file first would only buy a second copy of 197 MB.
* **GMod mounts three content roots, not one.** Its own content is in
  `garrysmod/`, but HL2's and CS:S's live in `sourceengine/` and the shared UI
  content in `platform/`. With only `garrysmod/` on the list, every texture a
  Workshop map borrows from HL2 or CS:S silently resolves to nothing - 69
  materials on this map alone.

If the archive holds more than one map (this one holds `gm_br_pitfalls` and
`gm_br_complex`) the biggest wins and the rest are printed; name one to pick
it:

    forge.py gm_br_complex --gma "<workshop>/2821179466/gmpublisher.gma"

`--gma` is repeatable and can also be used alongside an ordinary map, for
Workshop content packs a map depends on. A missing Garry's Mod install is a
warning rather than a fatal error here, because an addon usually carries
everything it needs.

### What a backrooms map costs

`gm_br_pitfalls` converts, but it is not a CS map:

| | de\_nuke | ctf\_2fort | gm\_br\_pitfalls |
|---|---|---|---|
| world tris | ~100 k | ~200 k | 130 k |
| effective tris (props instanced out) | 604 k | 1.68 M | **5.9 M** |
| materials | 485 | 477 | **1,153** |
| glb | 79 MB | 82 MB | ~250 MB (estimated) |

The world brushwork is small; the props are the whole map. `.gma` props are
instanced properly - one glTF mesh per model+skin, one node per placement - so
1,271 distinct models are stored once (1.75 M triangles), but the game still
draws and collides all 5.9 M. Two thirds of that is a handful of models used
hundreds of times: `mirrorhallcolumn` alone is 384 copies of a 2,407-triangle
mesh, 16 % of the map's triangles. `--exclude-prop mirrorhall` is the
one-liner that buys most of it back.

## Uncrashed maps (its map editor and Steam Workshop)

Uncrashed: FPV Drone Simulator (Unreal Engine 4.27) has a map editor, and its
Workshop (app 1682970) is full of maps made with it. They convert too:

    forge.py "<steamapps>/workshop/content/1682970/3570379009" --install
    forge.py 3570379009 --install                 # the id, if it is in a Steam library's workshop folder
    forge.py "D:/maps/MyTrack_fpv.json" --game-dir "D:/Games/Uncrashed" --install

**The game has to be installed, and at least as new as the map.** A map is one
small JSON file (plus a `.info` with its title): the base level it is built
on (`BaseMapRow`) and, per catalogue item, the transform of every copy placed
(`S_AssetsTransform`: `NewRow_304` x 43, ...). None of the art is in it. The
catalogue, `/Game/MapEditor/DataTables/DT_MapEditorAssets`, maps each row to
a mesh or a Blueprint inside the game's `.pak` files, and the converter reads
them straight out of the paks - nothing is unpacked. The catalogue grows with
the game (663 rows in a May 2025 build, 802 in the October 2026 Steam one); a
map that uses rows the install lacks lists them in the report and skips them.
`--game-dir` takes the game folder (anything with `.../Content/Paks` under
it); otherwise every Steam library's `common/*ncrashed*` is searched - Steam
names the folder `Uncrashed FPV Drone Sim` - and the newest install wins.

What it reads, all in pure Python:

| module | reads |
|---|---|
| `upak.py` | `.pak` v10/v11 (4.25-4.27): the encoded entry index, zlib blocks |
| `uasset.py` | cooked `.uasset/.umap + .uexp`: names, imports, exports, tagged properties, DataTables; `Packages` merges an object's properties over its archetype's. Uncrashed cooks *unversioned* (a version of 0 in the header), read as 4.27 |
| `umesh.py` | `StaticMesh` render data, every LOD (positions, normals, UVs, sections) |
| `utex.py` | `Texture2D` mips from `.uexp`/`.ubulk`; BC1/3/4/5/7 through Pillow's decoder |
| `umat.py` | a material instance chain -> one glTF material; decal materials |
| `uland.py` | a landscape's heightmaps and weightmaps -> an adaptive terrain |
| `ulevel.py` | a level: static, instanced and spline meshes, landscapes, sublevels |
| `ugeo.py` | Unreal -> glTF transforms, the indexed chunker, box UVs, decal cutting |
| `uncrashed.py` | the map: catalogue, Blueprints, gates, decals, base level, budget, spawn, sky |

### Base levels

`BaseMapRow` names a row of `/Game/AntizeMenu/Logics/LevelName/DT_LevelName`,
whose `WindowsName` is the level and `SubLevelName` its sublevels. The map
editor's own bases are five: `BaseLandscape` (desert, `L_BaseLandscape01` -
the name has no number), `BaseLandscape02` (grass), `03` (asphalt), `04`
(the mountain valley) and `BaseBoard` (a 6 km measuring grid). But every row
with `CanBeMapEdited?` can be built on, which is 26 of the 28, the game's own
levels included: TheDock, Hangar, CityPark, Racetrack, MountainOpen and the
rest. So the base is converted as a whole Unreal level:

* **Every component, over its archetype.** A Blueprint actor placed in a
  level stores only what differs from the Blueprint; half of TheDock's 4,084
  static mesh components name no mesh of their own. Each component's
  properties are merged over its template's (`uasset.Packages`), its world
  transform composed up its `AttachParent` chain, and hidden ones
  (`bHiddenInGame`, a hidden or editor-only owner, HLOD proxies) left out.
* **Instances.** ISM, HISM and foliage components keep their instances after
  the tagged properties, as a bulk array of 4x4 matrices; it is found by its
  header and checked rather than parsed through the LOD data in front of it.
  Foliage painted **without collision** - grass, leaves, 2.7 million
  instances on CityPark - is left out, since The Zone would collide with all
  of it (`--all-foliage` keeps it). Trees and rocks are kept.
* **Spline meshes** (road edges, kerbs: 2,137 on Racetrack) are bent along
  their cubic Hermite segment the way `USplineMeshComponent` does it
  (forward axis, roll, scale, offset) and baked.
* **Sublevels** streamed in by the level are followed, except the lighting
  variants a `BP_sublevelSwitcher` lists (`_Sun`, `_After`, `_Rain`).
* **Landscapes**, every one, with each component read through its
  subsections (a subsection keeps its own edge row, so a 2-subsection
  component's window is 2 x (63 + 1) texels, not 127). The block steps are
  the component size's prime factors (63 gives 63, 9, 3, 1; 126 gives 126,
  18, 6, 2, 1). `--terrain-budget` (1 M triangles) loosens the tolerance
  until it fits - CityPark's 0.39 m quads need 26 cm.
* **Painted layers.** Each terrain triangle takes the layer painted most at
  its centre, from the components' weightmaps; the layer's texture is the
  material parameter that names it (`BaseColor Layer_3`,
  `MW_Layer4_TextureBasecolor`; `Layer_3_no_plants` falls back to `Layer_3`),
  with its colour adjustment baked in. A rock / cliff texture no painted
  layer claims is the material's automatic slope layer and goes on slopes
  over ~44 degrees.
* The three flat editor bases store **no landscape scale at all**, which
  reads as 1 cm a quad - a 20 m landscape in a 2.2 km flight box. They sit
  exactly where BaseLandscape04 does, whose scale (128) is stored, so 128 is
  assumed and the report says so (`terrain_scale_assumed`).

### Placing things

* **Axes.** Unreal is left-handed, Z up, in cm; glTF right-handed, Y up, in m.
  `(x, y, z) = (X, Z, Y) / 100` - the Y/Z swap *is* the change of
  handedness. It mirrors the winding, so each mesh's index order is checked
  against its own normals and reversed when they disagree.
* **The saved transform is the mesh's own; `PivotPointOffset` is
  editor-only.** Every row's offset marks its mesh's bottom (the editor
  cylinder spans z -50..50 with -50, the concrete slab -29.4..0.6 with -30),
  and the converter used to shift each mesh by minus it inside the item's
  transform. That is wrong, and it showed on Landslide Bando's walkway rail:
  its beam and posts are concrete slabs stood on edge, so the shift went
  *sideways*, 58 cm one way for the beam and 41 cm the other for the posts.
  The game's loader (`/Game/BP/MapEditor/LoadLevel`, `SpawnAssets`) reads
  twelve of `S_ME_Asset`'s fields - Mesh, Blueprint, Collision?, the cull
  distances, the material overrides, Triplanar?, SetUpRVT? - and never
  `PivotPointOffset`; only the editor pawn and its UI do. Placed at the saved
  transform, the posts sit under the beam to 2 cm, and the walkway reads as
  in Uncrashed (the old build had a slab wall across it).
* **Blueprint items** contribute the static meshes of their construction
  script (`SCS_Node` tree, relative transforms composed). Instanced-mesh
  components are skipped there: their templates hold no instances, the
  script adds them at run time. Their behaviour - lights, wind, water
  volumes - does not come across.
* **Editor helpers** stay out: a few items carry a gizmo collision section
  (`M_Axis_R_Collision`, on the neon tubes) and the decal item's selection
  box, preview icon and sphere are hidden by its script in game.
* **Triplanar rows** (`Triplanar?`: the editor's concrete floors and walls)
  use world-aligned materials that ignore the mesh's UVs. They are baked into
  the world with box-projected UVs, at the tile the material's own scalar
  gives (`Param` 0.001 = 10 m).
* **Race gates.** A track's `Race.CheckPoints` name rows of
  `DT_MapEditorGates`; each gate's mesh goes in at its saved transform (the
  row's `PivotOffset` is editor-only too: `BP_RaceBase` reads Mesh,
  BoxDetectTransform and OffsetIndicator). `Invisible` gates have no mesh.
  The Zone has no gate asset, so they are scenery, not checkpoints.
* **The spawn** is the map's start pad (`BP_ME_Spawner`), else a track's
  `Race.StartTransform`, else the base level's `PlayerStart`, else the
  editor camera. The start pad and the race start face along their **+Y**,
  not Unreal's usual +X: the pad's preview mesh (`SM_StartPreview`) has its
  arrow on +Y and its flag on -Y, and Temple of Serenity's race start has +Y
  pointing straight at gate 1. Its start pad then looks up the temple's axis
  of symmetry. A `PlayerStart` and the camera face +X.

### Decals

Graffiti, puddles, cracks, logos: 103 catalogue rows are decals (all one
Blueprint, `BP_ME_Decals`, with the row's material), and a map can carry its
own pictures - `decal_*.png` rows, the images in the Workshop item's
`Decals` folder. The Zone has no decals, so each one is **cut out of the
surfaces it covers**: every triangle inside its box (`DecalSize` 7.5 x 200 x
200 cm half extents, times the item's scale - the row's `BoundingBox` is only
the editor's selection box) facing one way along the projection axis is
clipped to the box, mapped, and lifted 12 mm off the surface. Which way: the
side that covers more of the box, since the editor points X into a floor but
walls come both ways. The image's down runs along local +Y (wall decals
stand with +Y pointing down) and its right along whichever of +-Z is the
right-hand side seen from in front, so lettering reads the right way round.

A decal material is mostly an opacity mask: the colour texture's alpha, else
an `Opacity` / `mask` / `AlphaTexture` parameter, else a referenced `*_msk` /
`*_a` texture; a mask wired in as the colour is taken as the mask. Puddles
and wet patches can only be a colour laid over the surface here, so they
become a dark pool at 60 % of their mask. *based on real bando* carries 5,005
decals (1,564 of them 7.6 m puddles); they add about 50 MB, and `--no-decals`
leaves them out.

### Materials

An Unreal material is a node graph, so there is no albedo slot to read. What
a cooked package keeps is each instance's parameter values and, on the base
material, its parameter defaults and the textures its graph samples. The
base colour is the texture parameter called Albedo / BaseColor / Diffuse / ...,
else a referenced texture named `*_D`, `*_BC`, `*_col`, `*Albedo*`, else the
only plain texture it samples (the drone pilots' `face_ncl1_1`); with no
texture, the colour parameter - the editor's plain walls are flat colours.
Two composites are rebuilt: ModularHouses' `M_Master_Generic` picks between
`Albedo_Color_1..3` by the channels of its `Mask`, and the horizon backdrops'
splat materials blend their layers' mean colours by the splat map.

The alpha channel is the trap. Most of this game's art uses one master
material (`M_base`) that is *always* Masked, and whose diffuse alpha is a
**paint mask**: the tower crane, the forklift and the scaffolding's metal
parts are grey in the texture and painted by `diffuse color` where alpha is
white. Treating that alpha as opacity punches the crane full of holes. The
static switches say which it is - `Use alpha as Color mask`, `add opacity` -
so: alpha is cut-out only for foliage-shaded materials, an `opacity` switch,
or a leaf / branch / grass / grid name; otherwise it is dropped, and where
the colour switches are on the paint colour is baked into the pixels (the
game's shader takes texture *or* colour, never both). Normal maps are real,
with green flipped (Unreal is DirectX-style).

**Flat colours go in as a 4 x 4 texture, never as `baseColorFactor`.** A
material with a colour parameter and no texture (Temple of Serenity's white
walls, `MI_WhiteSimplWall`, 0.78 / 0.71 / 0.65 linear) used to set the
factor, and came out blown to 0.95 white. The game's chain double-converts
it: Godot's glTF importer turns the factor linear -> sRGB into
`StandardMaterial3D.albedo_color` (correct so far), the loader copies that
into `CustomMaterial`'s `albedo_color`, and the shader declares
`uniform vec4 albedo_color;` *without* `source_color` - so the sRGB value is
used as linear. `albedo_texture` *is* `source_color`, so a texture of the
colour displays exactly. (Source maps were never affected: their materials
always carry a texture, which wins over the factor.)

**Coplanar faces are pulled 1 cm apart.** Mappers lay slabs flush on floors:
Temple of Serenity's white edging sits exactly in the plane of its pavement
(592 such pairs), based on real bando has 1,235. Unreal's TAA blends the fight
into a dither; The Zone shows faces flickering through the floor. Where two
overlapping, upright items that look different have top faces less than 1 cm
apart, the smaller one moves so they are 1 cm apart, keeping the order Unreal
draws (a tie puts the smaller one on top). Reported as `coplanar_lifted`.

### Water

The map editor's water (`BP_meWater`) is a box, 4 m a side before scaling,
whose top face is the surface; Landslide Bando stretches one to 1.2 x 1.0 km
for its lake. Its material (`MI_Water8_me`) has no colour texture at all:
Unreal draws it as sky reflection and refraction over a near-black colour
(0.010 / 0.015 / 0.013 linear), fading to clear in the last 50 cm before the
shore. The Zone's shader has none of that, so the flat colour alone came
through as a featureless grey-green sheet.

The look is now baked into one tile, mapped world-aligned (like the
triplanar items) so it never stretches with the box:

* **Normals** - the material's wave normal map (`T_Water_N`, or whichever
  normal it samples that is not foam, algae or leaves) at two scales: the
  fine one at the material's own world tiling (`tiles world`, 4 m), and the
  same map four times larger and transposed, so the repeat does not show.
* **Colour** - the water's colour parameter (`Color / opacity`,
  `WaterColor`, ...) keeps its hue but is lifted to a visible value, with
  pale sky-blue streaks where the waves tilt and a little relief shading
  from the same normals, so the ripples read even in flat light.
* **Roughness 0.6**, as for Source water: lower turns the whole sheet white
  in this shader.

The tile is 1024 px over 16 m (about 1.1 MB per water material), and every
water mesh is baked rather than instanced so it can take world UVs. Names
like `mi_WaterTank` or `mi_water_depot` are props, not water, and keep their
own textures. The shore is still a hard line where the surface meets the
terrain: Unreal's fade comes from the depth buffer, and a texture can't do
that and tile at the same time.

### The triangle budget

Uncrashed draws with LODs and The Zone does not, so the converter picks one
LOD per mesh. `--lod-tris` (4000) caps the starting choice; then, while the
placed meshes add up to more than `--tri-budget` (3 M), the mesh whose next
LOD saves the most (copies x triangles) steps down. A mesh placed 40 times
or more, or painted as foliage, may go down to 2 % of its full detail; a
one-off stops at 12 %, where it still has its shape. Racetrack's 3,950
alders take it from 17.4 M to 4.9 M. The terrain has its own budget.

Two more limits, because a busy map (based on real bando: 3.5 M placed
triangles that will not fit 3 M) used to walk *everything* down to its floor,
and the far LODs of simple parts are not their shapes any more:

* **No LOD under 64 triangles.** `SM_Plank_4m_01a` is 44 triangles at LOD0
  and 6 at LOD3 - six triangles cannot make a plank, so the roofs of the
  bando were warped strips. Stepping such parts down saves almost nothing
  (141 I-beams at 48 fewer triangles each is 7 k).
* **No LOD that leaves the full mesh's bounding box** (each side within 2 cm
  or 12 %). `sm_MetalBeam_01_01_me`'s 30-triangle LOD bends one end out at
  45 degrees; `SM_Construction_Pale_03`'s 22-triangle LOD is a twisted wedge.
  Vegetation is exempt (by name, or painted as foliage): its far LODs are
  meant to change outline, and trees are where the triangles are.

The report's `lod_changes` lists every mesh that moved: `[from, to, copies]`.

Meshes of up to `--merge-tris` (600) triangles are baked into `--cell`
chunks per material - thousands of beams, pallets and slabs as a few hundred
meshes - unless one mesh's copies would add up to more than 150 k triangles,
when storing every copy costs more than instancing them; bigger meshes are
glTF instances (one mesh, one node per copy). Mirrored or sheared
placements are always baked.

### What they cost

| map | base | items | tris | nodes | glb | time |
|---|---|---|---|---|---|---|
| Landslide Bando | BaseLandscape04 | 5,191 | 3.5 M | 1,311 | 115 MB | 80 s |
| Temple of Serenity (a track) | BaseLandscape | 21,262 | 4.6 M | 4,305 | 96 MB | 63 s |
| based on real bando | BaseLandscape02 | 24,630 + 5,005 decals | 4.8 M | 2,647 | 243 MB | 160 s |
| Racetrack, empty | Racetrack | 0 | 5.2 M | 5,185 | 109 MB | 51 s |
| CityPark, empty | CityPark | 0 | 11.2 M | 13,572 | 338 MB | 162 s |

(Times from a 2-core VM.) A map on one of the game's own levels carries the
whole level: CityPark alone is 50 M triangles of placed meshes at the LODs
the cap allows, and its bushes, lamp posts and elms run out of LODs above the
budget. `--lod-tris 1500`, `--tri-budget` and `--no-backdrop` (the base
level's meshes left out, its terrain kept) are the levers.

### Known gaps

* Blueprint behaviour: lights, moving parts and post-process volumes. Water
  is a textured surface (see above) with no reflection, shore fade or flow.
  The emissive neon materials keep their glow colour.
* Foliage without collision is left out by default (see above).
* The sky is approximated from `CustomWeather`: time of day picks dawn /
  sunny / cloudy / sunset, and the sun's bearing comes from the hour and
  `northyaw`. The bearing has not been checked in game; `--sun-offset` turns it.
* Race gates are scenery; The Zone has no checkpoint asset.

## Pitfall: .vvd vertices are already in model space

Three inferno models (`elevatordoor`, `tv_monitor01`, `grainbasket01c`) lack the
`$staticprop` flag and carry a bone 0 quaternion of `(.707, 0, 0, .707)` - a 90
degree turn about X. It is tempting to apply that bind pose. **Do not.** The
runtime skinning matrix is `boneToWorld * poseToBone`, and at rest those cancel
to identity, so .vvd vertices are already in model space. Applying bone 0 turns
a standing 104 x 2.4 x 116 unit door panel into one lying flat on the floor.
`bind_matrices()` is kept in `mdl.py` for a future animated-model path but is
deliberately not called.

## Uploading strips the manifest - so the map is moved AND turned to the spawn (`--recenter`)

Uploading through the in-game custom lobby stores **only the .glb**: the
round-tripped folder holds the glb byte-for-byte (same md5) and no
`manifest.json`. With no manifest there is no `spawn_point`, and the engine
drops the drone at a fixed **(0, 10, 0)**.

You cannot change that point, so `--recenter` (default **on**) moves the map to
it: the ground under the chosen spawn is placed at `y = 10 - spawn_height`, so
the engine's fixed spawn ends up `spawn_height` above the floor (default 1 m),
and the manifest is written with the same `(0, 10, 0)` so offline and uploaded
are identical. de_inferno shifts by [42.98, 10.52, 20.02]; both maps verify as
floor at y=9.00, spawn at y=10.00, nothing in between.

Getting this wrong is easy in two ways, both of which happened here:

* Putting the ground at the **origin** instead means the drone spawns 10 m up
  and falls.
* Recentring on the **first** `info_player_*` can land under a roof -
  de_dust2's T spawn has geometry at 4.6 m and 5.42 m over it. `pick_spawn()`
  therefore tests every player spawn's vertical column and takes the first with
  `spawn_height + 1.5` m of clear air, warning when none qualifies.

The facing has the same problem. The engine's spawn is `Transform3D()`
translated to (0, 10, 0) - identity basis, so the drone faces **-Z** - and
the manifest's spawn rotation never reaches other players either
(`menus/custom_map_upload.gd` sends the .glb's bytes and nothing else). So
`--recenter` also **turns** the whole map about the vertical axis through
the spawn, by minus the spawn's facing, as a rotation on the glTF's root
node; the manifest's spawn rotation is then 0 and a local test starts exactly
where an uploaded copy does. The manifest's `sky_rotation` turns by the same
angle so the sky keeps its place against the map offline (`map_turn_deg` in
the report). The game's sun light itself is fixed, so which walls it lights
changes with the turn, for everyone. Landslide Bando turns -105 degrees,
de_dust2 -165.

**Re-upload after rebuilding**, since the coordinates move.

## Baked lightmaps: supported by the shader, NOT wired up for custom maps

Worth recording so nobody repeats the investigation. Everything needed exists:

* `materials2/custom_material.gdshader` declares
  `uniform sampler2DArray shadow_maps[8]`, `instance uniform int
  shadow_map_bucket`, `instance uniform float shadow_map_index`, samples with
  `sample_shadow_map(UV2, ...)` and in `light()` does
  `DIFFUSE_LIGHT = diffuse_light` - a bound lightmap fully replaces dynamic
  diffuse.
* Official maps name nodes `<10-letter-id>_zlms-<size>` and load
  `<id>_zlms-<size>_comb.dds` (verified against 937 nodes of OG Bando), carry
  lightmap UVs in `TEXCOORD_1` normalised 0-1 with ~0.7 % padding, and store
  DX10 DDS at **DXGI format 95 = BC6H_UF16** with 8 mips. The folder's quality
  percentage scales the named tier (a `_zlms-256` file in `baked_*_75/` is
  192x192). HDR range measured 0 - 2.32.
* The source data is free: de_inferno's BSP carries 345,428 luxels of Valve's
  own bake across 10,663 faces, de_dust2 327,341.

**But the custom-map loader never looks.** Two probes, both negative: a map
whose nodes are correctly named `_zlms-<size>` with valid `TEXCOORD_1`, and then
the same map with four genuine BC6H lightmaps copied from an official map into
both `custom_maps/<name>/baked_sunny_50/` and `baked_cloudy_sunny_50/` (matching
the `texture_quality="50"` setting). Both loads reported `"shadow_maps": 0` with
**no** `No shadowmap:` line and no attempt to open any `.dds` - while the same
load did try `res://custom_maps/<name>/occluder.occ`, proving that folder is the
base path. The node loop never runs, i.e. `load_asset` is called with
`with_shadow_maps = false` for custom maps.

So this needs an engine change, not a converter change. The ask is small: pass
`with_shadow_maps = true` and set `lightmap_base_path` to
`custom_maps/<name>/baked_<skybox>_<quality>/`. Everything else on our side is
already understood and only needs a BC6H encoder written (no library available -
`imagecodecs.bcn_encode` is a stub, though `dds_decode` works and makes a good
round-trip oracle).

Until that happens, `--bake-lightmaps` (next section) gets the same lighting in
through the albedo instead.

## Baking the lightmap in anyway (`--bake-lightmaps`)

The section above is why the map's own lighting cannot be a texture the game
looks up: there is one UV, and the only slot that takes a second one is the
shadow-map path the custom-map loader never switches on. Re-read out of
`thezone.pck`, `materials2/custom_material/custom_material.gdshader` is
unambiguous:

    ALBEDO      = texture(albedo_texture, UV).rgb
    NORMAL_MAP  = texture(normal_texture, UV).rgb
    ROUGHNESS   = texture(roughness_texture, UV).r
    if (shadow_map_index >= 0.0)  { ... sample_shadow_map(UV2, ...) }

No AO texture, no vertex colour, no second coordinate. (Note `UV` raw - an
older copy of this shader still inside the pck divides by a
`texture_size_meters` uniform. That one is not the material the loader builds.)

So the light has to be multiplied into the albedo, and the moment it is, a
tiled texture will not do: every lit face needs its own patch of texture.
`--bake-lightmaps` gives it one.

### What it costs, and why adaptive density

Valve's bake is cheap - `gm_br_pitfalls` is 4.1 M luxels over 459,323 m2, one
luxel per 33 cm, small enough to fit in a single 2048 page. The albedo is what
costs, because an atlas stores every square metre exactly once while a tiled
512 px material gets to repeat:

    flat  5 cm/texel   183.7 M texels
    flat 10 cm/texel    45.9 M texels
    adaptive            85.8 M texels over 31 pages, small faces still sharp

The default is `texel = clip(sqrt(face_area) / 48, 3 cm, 30 cm)`: a 1 m2
doorframe gets 3 cm texels, a 400 m2 warehouse wall gets 30 cm, and since the
big faces hold most of a map's area that is where the saving is.
`--bake-texel CM` forces a flat density instead. For scale, the same map's 279
tiled world materials already spend 73 M texels.

de_aztec: 5,610 faces, 13.2 M texels, 5 pages, 6.8 s, +6.6 MB of glb.

### What is baked

Worldspawn brush faces with a lightmap and an opaque material. Left on the
tiled path: displacements, cut-out and translucent sheets (they need their
alpha), water, `WorldVertexTransition` blends, brush entities (they move), and
every face `--fill` rebuilds - vbsp deleted those, so Valve never lit them and
there are no luxels to read. Static props keep dynamic lighting; Source stores
their lighting per-vertex in a separate lump, and the game has nowhere to put
it.

### Four things that bit

* **Bumped faces store FOUR lightmaps per style** (`SURF_BUMPLIGHT`). The
  first is the non-directional one and the only one wanted.
* **`lm_size` is an extent, not a count** - the sample grid is `(w+1, h+1)`.
* **The mip footprint is already in texture pixels.** `tex_vecs` map world
  units straight to texels, so multiplying the footprint by the texture width
  again pins every face to the 1x1 mip: the first render came out as flat
  average-coloured rectangles.
* **Shelf-pack in map order and the page count triples.** Packing faces purely
  by position gave de_aztec 16 pages at 20 % full; sorting purely by height
  fills pages but scatters one 48 m cell across every page, and the world mesh
  count becomes cells x pages. Faces are cut into runs worth about one page
  (keeping locality) and only sorted tallest-first inside a run: 5 pages, 63 %.

### Exposure, and not lighting the map twice

Lightmap samples are `ColorRGBExp32`, linear light, `rgb * 2^exponent`.
de_aztec's spread is p25 = 5, p50 = 20, p90 = 208, p98 = 346 - sunlight sits
on a plateau around 350 and half the map is in shadow, so the 98th percentile
is what becomes 1.0 (`--bake-exposure` overrides; the factor is reported as
`light_scale`). The product is formed in linear light and re-encoded to sRGB,
since multiplying an sRGB albedo by linear light darkens everything. Nothing
is allowed below `LIGHT_FLOOR` (0.04), or a shadowed corner would be pure
black no matter what the game's lights do.

A `$color` gain above 1 is put back here. Dropping it is right for an unlit
map and wrong for a baked one - the mapper added it *because* the lightmap was
about to darken the surface.

The map still gets the game's dynamic sun on top of the bake, which would
light it twice, so `--energy` defaults to **0.45** when baking instead of 1.0.
Baked pages also ship a flat normal map: with the lighting already in the
albedo a per-texel normal only feeds the specular lobe, and baking a normal
atlas as well would double the texture budget.

## Brush entities are MODEL-LOCAL (the biggest bug in this converter's history)

vbsp recentres a brush entity's geometry around its `origin` when it has one,
so `VERTEXES` for that model are **model-local** and the entity's `origin` key
is where they belong. Entities without an origin brush keep world coordinates.
There is no flag saying which - compare the model's face-vertex bbox centre to
the origin: a door leaf whose faces centre on `[0, 22, 0]` while its origin is
`[240, -1025, -715]` is obviously local.

Getting this wrong piles every affected brush entity at the world origin:
**74 of 92 on de_nuke, 21 of 33 on de_inferno, 8 of 15 on de_dust2.**

It produced three symptoms that look unrelated:

1. Objects **missing** from where they belong (doors, breakables, illusionary
   geometry) - they are all stacked at the origin.
2. Those same objects **still collidable in the right place**, because the
   `BRUSHES`/`BRUSHSIDES` lump stores planes in WORLD space, so the nodraw
   fill rebuilt them correctly while their faces went to the origin. "Missing
   but you can collide with it" is the signature of this bug.
3. After `--recenter`, the pile lands on the spawn.

An earlier version of this converter concluded from de_inferno that the origin
was "a pivot, not an offset" because applying it appeared to make a roof float.
That was wrong, and the wrong conclusion was written down and believed for a
long time. Derive it per model.

### Consequences for the nodraw fill

Because brush-entity brushes ARE in the world-space `BRUSHES` lump, the fill
would double-generate them. `extract()` therefore passes exclusion volumes -
but only for entities whose geometry it actually places. Excluding volumes for
entities it skips is catastrophic: de_dust2's seven `trigger_soundscape`
brushes total **337,000 m3** (one is 134 x 50 x 25 m) and wiped out 782 of
1357 legitimate world fills before that was caught.

## Doors (`--doors`)

`func_door_rotating` leaves are stored closed. Since the geometry is
model-local, the hinge is at the local origin, so opening one is just a
rotation of `distance` degrees about the local Z axis before adding the entity
origin - respecting `Starts Open` (spawnflag 1) and `Reverse Dir` (2), and the
X-axis flag (128). `func_door` slides along `movedir` by its extent minus
`lip`. Default `--doors open`; `closed` keeps CS's state, `remove` deletes the
leaves. Opening them also puts the door *handles* back on the door, which
otherwise float in an empty doorway.

### Carrying attachments (`parentname`)

Opening a door leaves its handles hanging in the empty doorway, because each
handle is its own `prop_dynamic` at an absolute world position. Source links
attachments with **`parentname` -> the mover's `targetname`**, and that link is
authoritative: on de_nuke every rotating door has exactly two handle props and
one `func_breakable` glass pane parented to it.

`door_carriers()` collects the brush entities we move; `find_carrier()` resolves
an attachment by `parentname`, and `carry_point()` / `apply_carrier()` apply the
same transform to a prop's origin *and* its orientation, or compose it onto
another brush entity's transform.

**Do not match attachments by bounding box.** The first implementation did, and
de_nuke's doors *47 and *48 are only 7 units apart: with an 8-unit pad, *48's
handles were carried by *47's swing, so one door got four handles and the other
none. A box is kept only as a fallback for props with no `parentname`, resolved
to the nearest carrier. A prop parented to something else is never guessed at.

Verified on de_nuke: 2 handles on each of the 5 swung leaves, 0 left at the
closed position, plus 4 glass panes carried.

## Water (`--water-roughness`, `--water-value`)

ctf_2fort's water rendered pure WHITE, and it had two independent causes.

**No albedo at all.** Source's `water` shader has no `$basetexture` - it is
reflection plus refraction, tinted by `$fogcolor`:

```
$refracttexture _rt_WaterRefraction     $reflecttexture _rt_WaterReflection
$normalmap dev/water_normal             $bumpmap   dev/water_dudv
$fogcolor  {22 20 10}                   $surfaceprop water
```

With no `baseColorTexture` the game's importer takes the `use_albedo_color`
branch, and the converter was leaving `baseColorFactor` at its default - so the
water came through as pure white. This affected **every** material without a
`$basetexture`, not just water; they all now get a small solid-colour texture
*and* a matching factor, so the colour survives whichever branch the importer
takes.

**A roughness that saturates.** Water was being given the physical ~0.04. In
this shader `DistributionGGX` peaks at `1/(PI * alpha^2)`, which is about
**124,000** at roughness 0.04, so a smooth horizontal sheet blows out to white
on its own. Measured sunlit response is 219 / 193 / 135 out of 255 at roughness
0.15 / 0.55 / 0.95, so `--water-roughness` defaults to **0.6** - deliberately
unphysical, because it is the only lever this shader gives. Water materials
also skip the `$envmap` roughness reduction, which was quietly putting them
back at 0.43.

**Colour.** `$fogcolor` is the only colour Valve authored, so it sets the hue,
but it is a fog *density* - de_aztec's is `[.15 .1 0]`, militia's
`[.07 .14 .12]` - far too dark to use directly. Its luminance is rescaled to
`--water-value` (default 0.28) with the hue left alone. Lerping towards white
instead was tried first and washes the hue out, turning aztec's murky brown
into pale tan. Results: aztec `[0.39, 0.27, 0.03]`, militia `[0.17, 0.31, 0.27]`.

**`$bumpmap` on water is not a normal map.** It is a DU/DV refraction
distortion map (`dev/water_dudv`). The generic path prefers `$bumpmap` over
`$normalmap`, which fed that straight into `NORMAL_MAP`. Water now prefers
`$normalmap`.

## Sliding doors, and doors with no faces at all

Two separate reasons a door stays shut.

**1. Sliding doors were gated on the wrong condition.** Opening only ran when
the brush geometry was model-local:

```python
if doors == 'open' and local:      # WRONG for sliding doors
```

A *rotating* door genuinely needs its origin brush as a pivot. A *sliding* one
does not - it is a pure translation along `movedir`, valid either way. Across
the CS:S maps this left three doors welded shut (two on de_inferno, one on
cs_militia) out of 932 brush-entity transforms, and in TF2 it sealed the spawn
room. A `func_door_rotating` with no usable pivot now falls back to sliding
rather than staying shut.

**2. The mover often has no drawn faces.** de_inferno's `ele_door_l` and
`ele_door_r` have `numfaces == 0`, and `door_carriers` skipped anything it
could not build a bounding box from. But a faceless mover is the *normal*
modern pattern: a nodraw `func_door` supplies motion and collision while a
`prop_dynamic` is the door you actually see, parented to it by
`parentname` -> `targetname`. Skipping the mover left the prop with nothing to
ride, so the visible door never moved - which is how TF2 builds spawn doors.
Faceless movers now fall back to the model's `mins`/`maxs` for their box.

Verified: a point on de_inferno's `ele_door_r` carries by exactly its 48-unit
delta, through both the `parentname` path and the position fallback.

The report now separates `doors_rotated` from `doors_slid`. `doors_opened` only
ever counted rotations, so a sliding door that stayed shut was indistinguishable
in the report from one that worked - which is precisely how this went unnoticed.

## Breakables are treated as already smashed (`--breakables`)

A CS player would have shot out the vent covers and roof skylights, so a drone
should be able to fly those lines. `--breakables remove` (the **default**) drops
`func_breakable`, `func_breakable_surf` and `func_physbox` brush entities.

On de_nuke that is 59 entities for only **234 visible triangles**:
32 roof skylight panes, 13 breakable door windows, 4 glass panes
(`func_breakable_surf`), 4 light covers, and 3 `prodventb` **vent covers**.
de_inferno has 2, de_dust2 none. `--breakables keep` leaves them intact.

Frames and housings are props, not breakables, so they stay - the 654
`skylight01_top` triangles inside the skylight volumes are the metal housing,
which is exactly right with the glass gone.

**A removed brush entity must still be excluded from the nodraw fill.** Its
brushes live in the world-space `BRUSHES` lump, so the fill will happily rebuild
its hidden sides and hand you invisible collision precisely where the thing you
deleted used to be. `brush_entity_policy()` returns `place` / `remove` /
`ignore`, and exclusion volumes are emitted for both `place` and `remove` -
never for `ignore`, whose huge trigger volumes would wipe out real world fills.
Verified after removal: 0 triangles left inside the vent and window volumes.

Physics props (`prop_physics`, `prop_physics_multiplayer` - crates, barrels,
pallets) are **not** removed. They are movable in CS rather than scenery to
shoot away, and they make good obstacles to fly around.

## Light effects are not matter

Source draws light shafts and glows as cards. `$additive` blends them into the
frame; some are UnlitGeneric sheets only 1-2 % opaque. Neither has physical
presence, but The Zone collides every mesh, so they become invisible walls -
de_nuke's `emergency_lightb_glow` cones cross a doorway, and
`skylight_effects` is a single 19.6 x 17.2 x 10.5 m invisible volume.

Dropped by default. The test is `$additive`, or UnlitGeneric + `$translucent`
with mean alpha < 6 %. That last threshold matters: **foliage has the same
shader and flags** - de_inferno's tree cards average 14-18 % alpha against
1-2 % for light shafts - so a blanket rule on shader+flags would delete every
tree. `--keep-light-effects` disables it.

Also treated as non-geometry: `func_dustmotes`, `func_dustcloud`,
`func_precipitation`, `func_smokevolume` particle volumes.

## vbsp deletes faces for TWO reasons, and the name test only finds one

The fill used to rebuild a brush side only when its material name contained
`nodraw`. That misses most of what is actually missing.

vbsp removes a renderable face when:

1. the mapper painted `tools/toolsnodraw` on it - the name says so; **or**
2. the face points into the **void** outside the sealed map, so nothing in a
   1.8 m player's world can ever see it. vbsp drops those as well, and the
   brush side **keeps its real material**, so no name test will ever find them.

Kind 2 is a building's entire outer shell and the top of every roof box. It is
why a converted map looks hollow from outside, and why de_nuke's blue warehouse
had no roof at all - the roof brush is there, its top side carries
`de_nuke/nukmetwallab`, and the face was simply never compiled.

Measured, on exposed sides only:

```
de_nuke     1,519 sides  29,523 m2  had a real material and NO drawn face
ctf_2fort   fill goes 1,859 -> 4,515 faces, 45,225 -> 100,459 m2
```

`DrawnFaces` decides it. FACES and BRUSHSIDES both store a `planenum`, and vbsp
may use either of a plane pair, so sides are matched to faces by `planenum >> 1`
and then by point-in-polygon. vbsp also SPLITS one brush side into several
faces, so a lone centroid test can land on a seam - several sample points are
tried and any hit counts as drawn. The bias is deliberate: a false "drawn"
costs one fill, a false "missing" duplicates geometry and z-fights. Measured
duplicate rate on de_nuke: **9 of 2,603 fills, 0.35 %**.

A void-culled side needs no material donation - it still carries its own
texinfo, so both the original material and its UV axes come straight off the
side, which is better than borrowing from a sibling.

Tool brushes are still excluded, and must be: `tools/toolsskybox` alone is
111,926 m2 on de_nuke - the sealing shell, which must never become geometry.

`--no-rebuild-culled` turns it off. Counted as `void-culled` in the fill line.

## Baking a .glb you have already edited (`tools/bake_glb.py`)

`--bake-lightmaps` works off BSP faces. Once geometry exists only in the .glb -
a roof closed by hand, a pillar modelled from scratch - there is no face to
read luxels from, and the .bsp on disk no longer matches what you fly. This
bakes the .glb instead:

    python tools/bake_glb.py edited.glb --bsp maps/de_cache.bsp -o baked.glb

Every world mesh is cut into near-planar charts and given its own patch of a
shared atlas. Each texel samples that mesh's **own** material texture through
its **own** UVs, so hand-unwrapped geometry bakes exactly as it currently
looks; the light comes from the original .bsp, looked up in world space.
Props and any mesh used by more than one node are passed through untouched -
they are instanced, and baking would make every copy unique.

The two coordinate systems are related by `scale_m_per_unit` and
`origin_shift` in `convert_report.json`, picked up automatically from beside
the input .glb (Blender round-trips positions unchanged). Without it the shift
is estimated from the bounding boxes. Either way, watch the reported **exact**
percentage - that is how much of the map found a real BSP face underneath.

### Two unit bugs that made the Cycles bake binary

Looking at a baked light page settled an argument that three rounds of
exposure tuning could not. It was **bimodal**: charts either solid white
(clipped, direct sun) or solid black (nothing at all), with almost no gradient
anywhere. No soft shadow, no falloff, no fill. Both causes were in
`srclights.py`, and both are unit errors.

**1. Point lights were 75,000 times too weak.** VRAD normalises a point light
at 100 units - its irradiance is `B * 100^2 / d^2` with d in units, not
`B / d^2`. Missing that factor of 10,000 turned a 900-brightness lamp into
0.5 W. Measured on de_cpl_strike, the median lamp delivered 0.011 against the
sun's 829, a ratio of 1:75,189; the 65 lights the bake had carefully rebuilt
contributed nothing at all, which is exactly what "the palace has fixtures but
no light around them" looks like.

    POINT_W_PER_B = 4*pi * UNIT^2 * 100^2   =  81.07   (was 0.0081)

**2. The sky's ambient was being read as minus a million.** The HDR keys use
`"-1 -1 -1 1"` to mean "not set". `_light_value` honours that sentinel, but
the ambient path copied `_ambientHDR` into `_light` and cleared `_lightHDR`,
so the check never ran on it. de_cpl_strike carries `_ambient "164 164 164
200"` - a real sky fill - and it was arriving as 0. That is why every surface
the sun did not hit came back black.

After both fixes, against Valve's own solve for the same map (p25 13.5, p50
36.6, p90 308, p98 673):

| | sun | sky ambient | median lamp at 2 m | sun : lamp |
|---|---|---|---|---|
| de_cpl_strike | 829 | 129 | 110 | 1 : 8 |
| de_inferno | 737 | 234 | 115 | 1 : 6 |

The lesson for the next unit conversion: **look at the bake**. Three rounds of
reasoning about percentiles and tone curves moved numbers around; one look at
a page showed the light itself was wrong.

### Exposure: a lightmap value is absolute, not relative

Two wrong answers before the right one, and the measurements are the reason.

**Attempt 1, linear with p98 at 1.0.** Every sunlit surface clipped to white
and the interiors sat at 2-6 %. In game: a blown, bloomed, hazy map where the
65 rebuilt interior lights could not be seen at all.

**Attempt 2, a percentile anchor with a gamma lift and a shoulder.** No
clipping (2.1 % -> 0.0 %), but the map looked the same in game. Measuring the
output said why: the baked atlas came out at **p50 19/255 against the map's
own textures at p50 112**, six times too dark, and the game's exposure pulls
that back up until the highlights blow. A dark input was producing a bright
wrong-looking output.

**What is actually true:** a lightmap value is not relative to the rest of the
map. 255 is "fully lit" and Source applies an overbright of 2, so a surface at
**128** displays its albedo unchanged and anything brighter is deliberately
clipped. Valve's de_cpl_strike solve runs p50 36, p90 308, p98 673 - most of a
map is well under fully lit, and the sunlit parts are far over it. Anchoring
on a percentile destroys exactly that information.

So the curve is Source's: linear to 128, then a knee from 0.8 that approaches
1.0 without ever clipping.

| light | 5 | 15 | 36 | 60 | 128 | 240 | 673 |
|---|---|---|---|---|---|---|---|
| displayed | 0.04 | 0.12 | 0.28 | 0.47 | 0.93 | 1.00 | 1.00 |

The check that matters is against the map's own textures, because an unbaked
map is exposed correctly in game:

| de_aztec | p10 | p50 | p90 | p99 |
|---|---|---|---|---|
| its source textures | 36 | 93 | 169 | 217 |
| atlas, linear p98 | 4 | 44 | 94 | 251 |
| atlas, lift + shoulder | 4 | 35 | 96 | 185 |
| **atlas, Source-style** | 4 | **54** | **136** | 254 |

Sunlit surfaces now land on the texture's own brightness and shadows fall
below it, which is what baking is supposed to do. `--brightness` scales the
light before the curve; `--exposure` moves what counts as fully lit.

### Three things the first real `--cycles` run found

* **The game loads `custom_maps/<folder>/<folder>.glb`.** A file whose name
  does not match its folder loads as an empty map - correct file size, no
  geometry, no error. `--install` copies the result in under the right name
  with the manifest beside it.
* **A baked .glb must not be baked again.** A `forge.py --bake-lightmaps`
  build already carries the lightmap in its albedo (its atlas materials are
  named `src_lm0`, `src_lm1`, ...), and baking that multiplies the two light
  solutions together. bake_glb refuses it now and says what to run instead;
  `--force` overrides.
* **Do not read a subprocess as text on Windows.** Blender writes bytes that
  cp1252 cannot decode, and `subprocess.run(..., text=True)` raises inside its
  reader *thread*: the bake runs to completion, `stdout` comes back empty, and
  the user gets a traceback that looks like a crash but is not one.

Output materials also go through the same `src_` + slug + dedupe pass
`forge.py` ends with, or the atlas pages arrive in game as `#lm0` - a name
with a character Godot uses in resource paths, and outside the convention
every other material in the file follows.

### `--cycles`: path-trace the light instead of reading Valve's

`--cycles` swaps the light source. Instead of sampling the BSP's luxels, the
map's own light entities are rebuilt in Blender and the irradiance is baked
with Cycles - which brings the ambient occlusion, soft shadows and colour
bleed a 2004 radiosity solve does not have, and costs a long bake.

    python tools/bake_glb.py map.glb --bsp map.bsp --cycles --samples 256

It works on any converter output, edited or not, so "rebuild this map with a
better bake" and "bake the map I fixed in Blender" are the same command.

`zonemap/srclights.py` converts the entities. `light` and `light_spot` become
point and spot lamps, `light_environment` becomes a sun plus a world
background, and `_lightHDR` / `_lightscaleHDR` win where the map has them.
The unit conversion keeps the two families in the same relative balance -
Source gives a point light `B / d^2` with d in units and a sun `B` flat, so
`P_watts = 4*pi*0.0254^2*B` against `sun = B` - and a global factor cancels
when the result is normalised. `--point-scale` and `--sun-scale` tune the
balance by eye.

Not carried over: **texture lights**. `lights.rad` turns named materials into
emitters and it is not in the .bsp, so a room lit entirely by a glowing
texture will come out dark. Materials with `$selfillum` do survive as glTF
`emissiveFactor` and become emission shaders, which covers most lamps.

The scene is handed to Blender as a .glb with one object per atlas page
(`bakepage_<n>`), the material's own UVs in TEXCOORD_0 and the atlas UVs in
TEXCOORD_1. Baking one page at a time is what lets a single UV set address a
single image; props and instanced meshes ride along as occluders so their
shadows land. Blender writes each page back as a float `.npy`, which sidesteps
every question about who can read an EXR.

**The gotcha that cost an afternoon:** Cycles bakes *nothing* - not even
ambient occlusion - where the shading normal opposes the triangle winding. A
test scene whose `NORMAL` said up while its winding said down baked to solid
zero with the operator reporting `FINISHED`. The page meshes therefore take
their normals from the winding itself.

### Light for geometry the BSP never had

Three tiers, in order:

1. **A same-facing face on the same plane.** Exact: an extended roof matches
   its neighbours seam for seam.
2. **Displacements**, which need their own tier. A displacement's geometry is
   nowhere near its face plane, so a plane lookup never finds it - and de_aztec
   is mostly terrain, which is why the first version reported only 26 % exact.
   Its lightmap axes are the *texture* axes, horizontal for a ground quad, so
   the displaced point still maps to the right luxel; only the plane test has
   to go, replaced by a 512-unit cell index. That alone took de_aztec from
   26 % to 68 % exact.
3. **Nearest lit surface, then a 128-unit grid** of the map's own luxels, so a
   new pillar in a dim room comes out dim and one in a lit atrium bright.

### What it costs, and the three knobs

A .glb bake is dearer than a BSP one, because it covers everything: terrain,
`--fill` shell, brush entities, and whatever you modelled. de_aztec's world is
**228,162 m2** of surface against the 5,610 lit faces the BSP bake tiles, so
at the default 4 cm per texel it wants about 140 M texels where the BSP path
spent 13 M.

* `--texel CM` (default 4) is the sharpness dial. It is a flat density, not
  the BSP bake's `sqrt(area)/48` - that heuristic suits face-sized tiles and
  goes coarse here, where region growing can make one chart out of a whole
  wall. 4 cm is about a third of the detail of a tiled 512 px material; 8 cm
  is visibly soft.
* `--unlit-texel CM` (default 16) is the saving. Charts bigger than
  `--unlit-area` that find no lightmap at all are the rebuilt outer shell and
  the ground skirt: their light is one smooth grid value however many texels
  they get, so they are baked coarse.
* `--budget M` (default 128 M texels, roughly 1 MB of JPEG per 4 M) coarsens
  everything proportionally if the atlas would still be larger.

Expect minutes, not seconds - de_aztec at the defaults is 34 pages and several
minutes of rasterising. Cut `--budget` for a faster, softer bake.

### Two bugs worth remembering

* **Charts must be grown, not hashed.** Bucketing (normal, distance) splits a
  floor wherever it crosses a bucket boundary: 28,397 two-triangle charts out
  of de_aztec's 57,000 triangles. Strict coplanarity is no better, because
  displacement terrain is subdivided per blend band and no two triangles are
  exactly coplanar. Region growing with a 20-degree angle bound and a 0.25 m
  thickness bound gives 8,345 charts.
* **The mip footprint comes from the chart's Jacobian**, not from differencing
  the tile. Differencing walks over the uncovered texels, reads a huge gradient
  at every chart edge and pins everything to the 1x1 mip - the first render was
  coloured mush.

And one in `Glb`: `image()` appends an image *and* a texture and returns the
**texture** index. Copying image bytes by hand has to do the same, or every
copied material points at a texture that does not exist.

## Z-fighting: rebuilt faces landing on faces that are already drawn

`--fill` rebuilds sides vbsp deleted, and some of those sides are flush
against a neighbouring brush's *visible* face - ordinary mapping, nodraw
painted where nothing could see it. Rebuild one and there are now two skins on
the same surface, flickering against each other.

Measured on gm_br_pitfalls by projecting every emitted triangle onto its plane
and testing centroids for containment: **1,412 of 130,042 triangles overlapped
another, covering 12,519 m2**, and 783 of those were a rebuilt face on a drawn
one - coplanar to within 0.2 mm, normals identical to four decimals.

### The bug that hid it

There was already a `DrawnFaces.covers()` test, and it found almost none of
them, for two reasons:

* **The facing was backwards.** Source stores a face's vertex loop *clockwise*
  about its plane normal - 10,610 of 10,617 sampled faces on this map - and
  `extract()` rewinds every one (`rewound` in the stats) so the emitted
  triangle faces the plane normal. Deriving "which way does this face point"
  from the loop as stored therefore gives the opposite answer, and the test
  compared each side against the faces *behind* it.
* **Sample points are not enough.** The test asked whether a few points of the
  side fall inside a drawn face. vbsp splits one side into several faces, so
  the drawn face is often a small patch of a big side and every sample misses.

### What it does now

Both polygons are convex - a brush side by construction, a BSP face because
vbsp makes it so - which makes the exact answer cheap: Sutherland-Hodgman
clip, shoelace area, and a real covered *fraction*.

* 90 % or more already drawn -> do not rebuild the side at all.
* anything above 2 % -> rebuild it, but sink it 0.25 units (6.4 mm) along its
  normal so the real face wins the depth test everywhere they meet. Rebuilt
  faces also test against each other, and each additional skin sinks one step
  deeper, or two fills that were both sunk behind the same drawn face would
  end up level with each other again.

The candidate lookup is bucketed by `(dominant axis, sign, distance / 4
units)` and rejected by bounding box, not by centroid radius - two 30 m2 fills
can overlap with their centres 25 m apart, which a radius test skips.

### Result

Strictly coplanar (within 2 mm) overlapping area on gm_br_pitfalls:

| | before | after |
|---|---|---|
| rebuilt face on a drawn face | 10,731 m2 | **19 m2** |
| rebuilt face on another rebuilt face | 1,345 m2 | **155 m2** |
| two drawn faces (the map's own brushwork) | 110 m2 | 110 m2 |

The last row is not ours to fix: those are duplicate brushes the mapper left
in, and they z-fight in Garry's Mod too.

de_nuke's fills go 3,037 -> 3,035 and its 1,783 void-culled rebuilds are
untouched, so nothing the fill exists for was lost.

## Zero-area triangles: 7 % of every map

Source faces carry a vertex at every T-junction along an edge, so fanning a
face from vertex 0 walks straight through runs of collinear points and emits
degenerate triangles: **9,339 of gm_br_pitfalls' 106,233**, 1,568 of
de_aztec's, 2,663 of de_nuke's. They draw nothing and collide with nothing,
but they are still vertices in the buffer and triangles in the collision mesh.
`Chunker.add` drops them, which is the one point every world path goes
through.

## One probe point is not enough to call a face buried

The "is this side exposed?" test probed a SINGLE point: the polygon centroid,
lifted 1.5 units along the normal. On de_nuke's roof slabs that polygon is
31 x 23 m, and the centroid says nothing about the other 700 m2 - one pipe,
vent or overhang above the middle condemned the whole roof as buried.

`exposed_fraction()` samples a 4x4 grid of points inside the polygon plus the
centroid, keeps the ones actually inside the outline, and fills when at least
`--min-exposed` of them have open air in front. Sides under 2 m2 still use the
centroid alone - same answer, a fraction of the cost.

**The threshold matters more than it looks.** Exposure is strongly bimodal:

```
de_nuke, 5713 candidate sides > 2 m2
    0 % (fully buried)   2065        25-60 %    370
    0-10 %                 41        60-99 %    513
    10-25 %               182        100 %     2542
```

Almost everything is either wholly buried or wholly open, and the thin middle
is exactly the partly-covered roofs. The first cut at 0.25 was too high and
rejected a 1,142 m2 roof next to de_nuke's spawn that measures **24 % exposed**
- missed by one sample. The default is 0.10, which still rejects all 2,065
sides that are exactly 0 % and picks up the middle band.

Cost on de_nuke: 2,603 filled faces before any of this, 2,830 with sampling at
0.25, 2,981 at 0.10. Duplicate rate against existing drawn faces stays flat at
12 of 2,981, 0.40 %.

## The 3D-skybox cull: measured per map, not a magic number

Two separate mistakes here, found a fortnight apart.

**First, it compared against the wrong point.** `drop_3d_skybox` and the prop
version of the same test measured the distance to the sky_camera against the
distance to the **centroid** of the spawn points. On a long map that plants a
cutting plane straight through the far end, and ctf_2fort lost 11 real props to
it: a security fence pole, a window, an oil drum, a sliding door, a grain
elevator, a wooden rail. Comparing against the **nearest** spawn point removes
the length bias.

**Second, no single ratio works for every map.** The cut has to be
`dist(sky_camera) < k * dist(nearest spawn)`, and `k` depends entirely on where
the mapper parked the skybox room. The two populations never overlap *within* a
map but they overlap badly *across* maps:

| map | skybox props up to | real props from |
|---|---|---|
| ctf_2fort | 0.576 | 1.352 |
| de_dust   | 0.522 | 1.543 |
| cs_italy  | *(none)* | 0.687 — its sky_camera sits inside the map |
| de_aztec  | *(none)* | 1.130 |

A fixed `k = 0.5` therefore left ctf_2fort's `horizon_facade001` (0.505) and
`sunnoon` (0.576) in the map — the latter being the lone prop the user kept
seeing hanging in the sky — while anything above 0.687 eats cs_italy's windows,
awnings and lanterns.

What *is* reliable is the **gap**. The 3D skybox is a physically separate room,
so there is a wide empty band between the two populations, and where there is
no skybox there is no band. Measured multiplicative jumps at the boundary:

```
x1.77 de_cache    x2.35 ctf_2fort  x2.95 de_dust      x4.05 de_inferno
x4.60 de_dust2    x5.94 cp_dustbowl x10.6 pl_badwater x12.4 de_nuke
x14.9 cp_gorge    x19.0 cp_granary  x295  cs_office
```

against a largest-anywhere jump of **x1.14** on cs_italy and nothing under 1.2
on de_aztec. So `skybox_threshold()` sorts the ratios of every world chunk
centroid *and* every prop origin, takes the **rightmost** jump of at least
x1.7 whose lower side is still plausibly skybox, and cuts in the middle of it.
The bar is 1.7 rather than 2.0 for de_cache, whose sky_camera is only 66 m from
the nearest spawn on a map barely wider than that; swept over fifteen CS:S and
TF2 maps, 1.7 and 2.0 differ on de_cache alone.

Rightmost, not largest: a lone prop sitting on the sky_camera itself can open a
bigger gap *inside* the skybox cluster than the real boundary does (de_nuke's
smokestack, x2.78, is one).

And the measured cut is clamped to be **no smaller than the old fixed 0.5**.
de_aztec's miniature has no clean edge at all and splits at 0.037, which would
have put 55 chunks / 7,761 tris of 3D skybox back into the map. Measuring can
only ever find *more* skybox than the fixed rule, never less.

Net effect against the old fixed rule, nothing lost anywhere:

```
ctf_2fort  props 37 -> 39   chunks unchanged   (sunnoon + horizon_facade001)
de_dust    props 30 -> 32   chunks 32 -> 33
de_dust2   props unchanged  chunks 40 -> 41
de_inferno props unchanged  chunks 22 -> 27
cp_dustbowl/cp_gorge        chunks +3 / +12
de_nuke, de_aztec, cs_italy, cs_office, pl_badwater   unchanged
```

The chosen cut and the gap it came from are reported as `skybox_cut` and
`skybox_split` in `convert_report.json`.

## The sealing shell is not a roof — de_cache had a lid over the whole map

Every Source map is sealed against the void by a hollow box of brushes. The
faces of that box that point INWARD are `tools/toolsskybox`, which is what
draws the 2D sky; the faces that point outward can never be seen by a 1.8 m
player, so mappers paint them nodraw.

Which is a problem, because "nodraw face on a solid brush" is exactly what the
fill exists to rebuild. So the fill quietly reconstructed the shell: a solid
slab sitting just outside the sky, **invisible from below because it faces
away, opaque from above** — and a drone that climbs out of the map flies up
through where the sky should be and meets it. Seen from underneath it reads as
a back-culled roof over an area that looked open.

de_cache is the worst case, and it is why this surfaced at all: its mapper
named the texture `tools/toolsnodraw_roof` and used 1,003 brushes of it. 141 of
their sides, **29,014 m²**, were being rebuilt as ceiling slabs 20–30 m over the
entire playable area — more than half of de_cache's total fill area, and 60 %
of everything you could see looking straight down at the map. de_aztec has one
of the same thing pointing the other way: a single **81,624 m²** plate 84 m
*below* the map, which alone stretched its world bounding box from 265 m wide
to 507 m.

The test has to be narrow, and the obvious version is wrong. "Every side of the
brush is a tool material" is what an ordinary nodraw roof brush looks like too,
and cutting on that would delete **89,340 of de_nuke's 107,395 m²** of
legitimate fill and 32,875 of ctf_2fort's 53,887. Requiring a `toolsskybox`
side **as well** is exact — only the sky shell has both:

| map | fillable nodraw sides | sky-shell sides removed |
|---|---|---|
| de_cache   |   675 / 57,073 m² | **141 / 29,014 m²** |
| de_aztec   |   763 / 185,553 m² | **7 / 81,800 m²** |
| de_nuke    |   707 / 107,395 m² | 0 |
| de_dust2   |   962 / 22,612 m² | 0 |
| de_inferno | 1,198 / 35,937 m² | 0 |
| ctf_2fort  | 1,625 / 53,887 m² | 0 |

Verified rather than assumed: de_nuke rebuilt **byte-identical**, and ctf_2fort,
de_dust2 and de_inferno produce a byte-identical chunk set with the test forced
off. de_dust2's two brushes that touch the sky are real walls carrying
`de_dust/templewall02a`, and they keep their fill.

Knock-on effect: with the shell gone, de_cache's `z_clean-concrete` fallback
fills dropped from 82 to 3, and the 3D-skybox cull — which had been measuring
its gap against a chunk set full of shell — found a clean x1.77 split and
removed the miniature landscape as well.

### If we will not draw it, it cannot bury anything either

Removing the sealing shell from the fill was only half the fix, and the other
half was worse on de_cache than the original bug.

`exposed_fraction` decides whether a rebuilt face is worth keeping by sampling
points just above it and asking whether they sit inside a solid brush. It asked
that of *every* solid brush — including the shell we had just decided never to
draw. de_cache's sky ceiling is low, 18.6–20.5 m, sitting more or less directly
on the warehouse roofs, so every roof panel under it measured `exposed 0.000`
and was thrown out as buried. The result was a map that had lost its lid and
had holes where the real roofs should have been: fly up out of spawn and you
looked straight down into a building through a roof that was not there.

Excluding shell brushes from the containment test brought back **18 up-facing
sides, 378 m²** on de_cache — including the whole row of roof panels at
y = 18.6 m across the middle of the map — and closed 257 m² of the 316 m² a
drone could still see through from above, leaving 59 m² in 17 patches, the
largest 25 m². de_nuke gained 58 filled faces and ctf_2fort 78, all donating a
material from a sibling side, i.e. all real roofs.

The remaining rejections were checked one by one and are correct: what sits
above them is a genuine roof slab whose own top face we already draw.

## Putting the horizon back: `--expand-3d-skybox`

A Source map has no outside. de_cache stops at its perimeter wall, and in
Counter-Strike everything past it was painted in by the 3D skybox — so once we
stopped drawing the sealing shell, flying out over the wall showed the unlit
lower half of the HDRI and nothing else.

The 3D skybox is a 1/N-scale model of the distant world, built in a sealed room
off the map, and `sky_camera` carries both halves of the transform: its
`origin` is the point in that room corresponding to the map's world origin, and
its `scale` key is N. The engine draws a skybox point p at

```
p_world = (p - sky_camera.origin) * N
```

so `--expand-3d-skybox` reproduces it exactly rather than guessing: the hills
end up at the distance and size the mapper composed them for, from geometry
already in the file. Measured N: **16** on de_cache, de_nuke and ctf_2fort,
**4** on de_dust2 and de_aztec. Props are moved by the same transform and given
a node scale of N — a 1/16-scale barn placed without that is a doll's house on
a real hillside.

On de_cache it costs 3,348 triangles and turns a grey void into a valley.
Note the cost side: the expanded landscape spans about 1.5 km, and The Zone
builds a collider from every mesh.

### `--skybox-cut`, because the measurement is a measurement

The gap the threshold is measured from is only x1.91 wide on de_cache, so
closing those 378 m² of roof was enough to move it under the bar: the
measurement fell back to the fixed cut and 763 m² of miniature landscape
reappeared inside the map. A map's 3D skybox does not move when a roof is
fixed, but the sample set it is measured from does.

Rather than pile another heuristic on top, `--skybox-cut F` forces the value.
The measured one is always reported as `skybox_cut` in `convert_report.json`,
with the gap it came from in `skybox_split`, so the override is a number you
can read off a build rather than guess. de_cache wants `--skybox-cut 1.4`.

## `tools/toolsblack`: kept on world brushes, dropped as a portal hack

Source uses `tools/toolsblack` for two unrelated jobs, and they need opposite
treatment. Getting this wrong in either direction is visible in game.

It is not a tool texture in the usual sense - it is an ordinary
`LightmappedGeneric` with a real 64x64 black `$basetexture`, and every face
carrying it compiles with **surface flags == 0**, i.e. vbsp kept it as drawn.

**Job 1, on WORLD brushwork: keep it.** It seals off voids you can see into
but should never see *through* - the flat black backing behind a vent grate, a
window, a doorway to nowhere. Deleting it (which the old `tools/` name filter
did) leaves a rectangular hole straight through the wall, which reads in game
as a smashed vent. ctf_2fort has 92 of these, 476 m2, median 0.9 m2.

**Job 2, as a whole BRUSH ENTITY: drop it.** A `func_brush` made *entirely* of
toolsblack is an areaportal visibility hack - a flat black panel in a doorway
so the engine can hide what is beyond. They are named for it
(`portal_brush01`..`04` on de_nuke, `portal01`..`portal14` on de_inferno,
`Portalwindow01`.. on de_train) and most carry `Solidity 1`, "Never Solid", so
a CS:S player walks straight through. Render one and you get a black pane
sealing a doorway that you then collide with, because the game makes every mesh
solid.

`occlusion_only_models()` separates them: a brush entity whose every drawn face
is toolsblack is a hack, anything else is scenery. The split turns out to be
total rather than a judgement call:

```
de_nuke     100 % of its toolsblack in 4 portal entities   world: 0
de_inferno  100 % in 14 portal entities                    world: 0
de_train    100 % in 12 portal entities                    world: 0
ctf_2fort     0 entities                                   world: 92
```

So only 2fort ever needed the keep, and de_nuke/de_inferno/de_train only ever
needed the drop. An earlier note here claimed inferno and nuke "have had these
holes since the first build" - that was wrong. They had no world toolsblack at
all; the name filter was doing the right thing there by accident, and lifting
it blindly put black panes across their doorways.

## `STATIC_PROP_NO_DRAW` is a runtime bit — reading it deleted a third of TF2

The single worst prop bug in this converter, and it hid for a long time because
it is **invisible on every CS:S map**.

`collect()` skipped any static prop whose `m_Flags` had `0x4` set, on the
reasonable-looking grounds that the enum in Valve's `bspfile.h` calls it
`STATIC_PROP_NO_DRAW`. The comment right next to it is the whole story:

```c
STATIC_PROP_NO_DRAW = 0x4,   // computed at run time based on dx level
```

It is not an authoring flag. The engine sets it while loading, from the DX
level; what the compiler leaves in the file means nothing. Honouring it threw
away **845 of ctf_2fort's 2,265 static props — 37 %**.

The pair that proves it: the two big fences at either end of 2fort's yard are
the same prop mirrored. `security_fence_big01` carries flags `191`,
`security_fence_big02` carries flags `1`. Both are plainly drawn in game; only
one survived the filter. The fence lights that sit *on* big01 are flagged `1`
and `190`, so one of them stayed — a lamp hanging in mid-air over a fence that
was no longer there. That was the "random floating geometry" in the bug report.

Why CS:S never showed it — the flag byte at offset 31 for every prop in four
maps:

| map | lump ver | props | flags values seen | `& 0x4` |
|---|---|---|---|---|
| de_dust2   | v6  | 321  | 0, 16, 18 | 0 |
| de_nuke    | v5  | 680  | 0, 1, 2, 16, 17, 18, 19 | 0 |
| de_inferno | v6  | 547  | 0, 1, 2, 3, 16, 17, 19 | 0 |
| ctf_2fort  | v10 | 2265 | **29 distinct values** incl. 7, 29, 52, 84, 99, 126, 143, 179, 202, 210, 230, 248 | **845** |

CS:S's values are all legal combinations of the eight authoring bits. TF2's
v10 lump writes bits the enum does not define at all. The test was a no-op on
CS:S and pure damage on TF2, so it is gone.

The per-model counts on ctf_2fort line up exactly with the flag - this is what
made it certain rather than likely:

```
                                BSP   before   after
fence001_reference               17      15      17
fence003_reference                7       6       7
security_fence256                 7       4       7
security_fence_light01            5       2       5
security_fence_pole01             4       3       4
wooden_rail01                     4       1       4
spytech_railing02                88      32      88
security_fence128 / big01 /
  section01 / fence_metal01a /
  barbedfence_set01          1/1/2/2/1  0 each  all
```

Cost: ctf_2fort goes from 1,435 to 2,266 placed props, 954,785 to 1,607,093
effective prop triangles, and the .glb from 69.4 MB to 85.0 MB. That is the
real map; the old one was a third empty.

## Two bugs ctf_2fort exposed

**Every game that ships an `hl2/` folder looked like Half-Life 2.** The
path-based game guess fell back to "which game's own content directory sits
beside the map", checked in dict order - and TF2, CS:S and Portal all contain
an `hl2/`, which is checked before `tf/`. So a TF2 map was detected as HL2,
the content roots came back without `tf/`, and **328 of 318 prop models failed
to load, losing 1461 placements**: 61k triangles instead of a million. The
guess now tries the maps directory first (`.../tf/maps` is decisive and
unambiguous), then the Steam folder name, and only then the content layout -
with `hl2`, `episodic` and `ep2` demoted to last resort.

That is the second silently-empty map this project has produced, so a mass
prop-load failure is now **fatal** rather than a warning. The previous run
printed a warning and exited 0, which looks exactly like success.

**The spawn-door carriers were anchored at the world origin.** `model_centre`
(then `model_face_centre`) returns None for a model with no drawn faces, so
`local` defaulted to False for every nodraw mover and its vertices were treated
as world-space when vbsp had in fact recentred them on the entity origin. All
six of 2fort's faceless spawn doors therefore got carrier boxes at (0, 0, 0) -
which in 2fort is the middle of the bridge. The position fallback then lifted
`bridgesupports001`, `bridge_cover001` and `bridge_cover_sides001` 124 units
into the air: the "floating parts" and the "separated bridge".

Two fixes. The dmodel bbox is now the stand-in when there are no faces (vbsp
computes it from the same vertices), so locality is detected correctly. And
only carriers with real drawn geometry may claim a prop **by position** - a
nodraw mover's box is just a doorway volume, and the door you actually see is a
`prop_dynamic` naming it through `parentname`, so the fallback bought nothing
there and risked dragging anything standing in the doorway. Result on 2fort:
props swept by position went 3 -> 0, and all 15 parented door props are still
carried.

## Editing a map in Blender (`tools/zone_blender.py`)

Install it as an add-on (Edit > Preferences > Add-ons > Install...) and use the
**Zone Map** tab in the 3D view sidebar (press N), or open it in the Scripting
tab and press Run. Import, edit, Check Scene, Export.

Four things a plain File > Import gets wrong, and what the add-on does instead:

**Textures.** The images live packed inside the .glb's binary chunk, so a plain
import leaves nothing on disk to edit - and the viewport stays flat grey
because Solid shading ignores materials entirely. Import writes every image to
`<map>_textures/` and switches the viewport to Material Preview. The bytes come
straight from `image.packed_file.data`, so it is the original JPEG or PNG with
no decode/re-encode round trip.

(Watch out: a freshly imported image reports `has_data == False` until
something touches it, so that is not a usable test for "is there an image
here". The packed block is.)

**The spawn.** Nothing actually needs moving. `--recenter` already places the
map so the drone starts at the engine's fixed spawn - glTF (0, 10, 0), which is
Blender (0, 0, 10). What was missing was any way to SEE it, so the add-on drops
a `DRONE_SPAWN` empty there and a `DRONE_SPAWN_GROUND` marker below it. Leave
the map where it is and the spawn survives; if you move geometry, move it
relative to that empty.

**Material names.** Two game behaviours key off them, and Blender breaks both
by appending `.001` to any repeat. `z_` names are substitution keys matched
exactly, so `z_brick-wall.001` matches nothing and loses the game's PBR set;
and converted materials are cached by `resource_name`, so a repeat collapses
into one material and the second one's textures are dropped. Export strips the
suffixes, lets `z_` names collide (they are meant to), and gives every other
repeat a `_2` style suffix instead.

**Helpers.** `DRONE_SPAWN` and friends live in a `ZONE_HELPERS` collection that
export never includes.

Export straight over `custom_maps/<name>/<name>.glb` to reinstall in place;
`manifest.json` is copied through so the folder stays loadable. (The uploader
keeps only the .glb, so the manifest only matters for local play.)

Verified end to end against de_aztec on Blender 5.0: 905 meshes and 65,529
triangles in, 203 textures written (10.4 MB), a test face added, and the export
re-read as 906 meshes / 65,531 triangles with no helper nodes, no `.001`
suffixes, no duplicate material names, and JPEG still JPEG.

## What the game does to a baked map (read out of thezone.pck, not guessed)

A baked map is never the last word on its own lighting: the game lights it a
second time. Decompiling `custommaps/handler/custom_map_root.gd` settles how.

```gdscript
func load_env():
    var env_scn
    if ZGamestate.lightmaps_enabled:  env_scn = load(EnvBakedScene)
    else:                             env_scn = load(EnvDynamicScene)
```

and, in `ingame_main.gd` and `editor.gd`:

```gdscript
ZGamestate.lightmaps_enabled = map_id in ['1','2','plaza','testmap'] \
                               and ZSettings.ENABLE_NEW_LIGHTING
```

So the good environment is hard-wired to the four official maps. `env_baked`
has **no ambient** (`ambient_light_energy = 0`), no shadows, reflections off,
and two opposed ±Y suns that exist only to make the custom `light()` function
run at all — the actual light comes from `DIFFUSE_LIGHT = diffuse_light`, the
per-mesh shadow map that `z_asset_loader.load_shadow_maps()` uploads. That
path is closed to a custom map: `load_shadow_maps` is behind the same flag,
`shadow_map_index` stays −1, and nothing in a manifest turns it on.

A custom map always gets `env_dynamic` instead:

* the sky (`SkyTexture5`) as **unoccluded ambient at full energy** — the
  manifest's `skybox` block only rotates it, because the line that sets
  `background_energy_multiplier` is inside the `lightmaps_enabled` branch
* three `DirectionalLight3D`s, all at 28.5° elevation, spread in azimuth:
  `L1 (-0.640, 0.478, 0.602)` energy 1.166 **with realtime shadows**,
  `L2 (0.456, 0.478, -0.751)` and `L3 (0.471, 0.478, 0.742)` at 0.2, no shadows
* ACES tonemapping, sky as the reflection source

The shader renders `ALBEDO * (DIFFUSE_LIGHT + AMBIENT_LIGHT) + SPECULAR`, so
the atlas is multiplied by

```
g(N) = sum_i max(N.L_i, 0) * E_i * ATT_i  +  ambient(N)
```

`ambient(N)` is the cosine-convolved SkyTexture5 panorama: 0.168 straight up,
0.010 straight down (the panorama's lower half is black).

### Why `--flat-normals 0,1,0` was the worst possible choice

Straight up takes the most sun (`g = 0.92`), the most sky, **and** full
dependence on L1's realtime shadow, which swings `g` down to 0.36 indoors.
Worse, Godot offsets the shadow lookup along the normal — and every normal now
points at the sky *through the roof*, so interiors sample unshadowed. That is
the "light coming through the walls of the map" look exactly: a second set of
shadows, from the wrong sun, leaking through every ceiling.

`ZONE_FLAT_NORMAL = (0.689, 0.725, -0.008)` is the direction that maximises
`g` subject to `N·L1 <= 0`, so L1 drops out of the sum entirely and neither its
shadow nor its leak can touch the map. It works out as roughly `L2 + L3`. `g`
is then **constant everywhere**, 0.40–0.52 depending on sky rotation, 0.45 on
average.

Roughness goes to **1.0** on a baked build for the same reason the gloss
looked wrong: `env_dynamic` leaves the sky as the reflection source, so any
smoothness left turns a dark baked albedo into a mirror of the sky. That was
the "glossy dark areas" in T spawn and palace.

### The exposure bug: a Cycles bake is not a Source lightmap

A Source lightmap value is absolute — 128 is "fully lit", because the engine's
overbright is 2 — and `LIGHT_FULL = 128` is right for `--bake-lightmaps`. A
Cycles `DIFFUSE` pass with `use_pass_color` off is something else entirely:
irradiance/π in the scene's own watts. On de_cpl_strike that is sky 129 plus
sun 829/π, so **"fully lit" is 393, not 128**.

Exposing one as the other is why every `--cycles` build came out blown. At 128
the *median* texel of page 0 already tonemapped to 0.92 and 71 % of the page
sat above it — the albedo was erased under a white sheet. Dumping page 0 as an
image showed it immediately: a blank white rectangle where there should have
been brickwork. `cycles_reference()` now anchors on `env.energy/π + ambient`,
measured against the bake itself (page 0 peaks at 366.6, and 129 + 829/π = 393).

### The gain goes on the pixel, not on the light

Undoing the game's 0.45 with `--brightness` does not work, and the reason is
worth keeping: `--brightness` scales the light *before* the tone curve, so all
it does is drive the curve into its shoulder — the lighting washes out and the
map stays exactly as dark. What has to come back up is `albedo * light`, after
the curve. That is `--flat-gain` (default `ZONE_FLAT_GAIN = 2.2 = 1/0.45`),
applied through the same soft knee so the brightest albedo rolls off toward
white instead of clipping.

With all four in place, for a mid albedo (0.18): sunlit ground renders at
124/255 on screen, sky-lit wall 61, shade 23, interior 3 — instead of a flat
white sheet.

### Tuning it without re-baking

`--reuse-bake` skips Blender entirely, so dialling `--flat-gain` in is a
60-second loop rather than a 7-minute one:

```
python tools\bake_glb.py out\MAP\MAP.glb --bsp "...\MAP.bsp" --cycles ^
  --reuse-bake out\MAP\MAP_flat_cycles --flat-normals --flat-gain 3.0 ^
  -o out\MAP\MAP_flat.glb --install
```

## The floating light blobs: measured, not reasoned about

`SPECULAR_LIGHT` is **added** after `ALBEDO` is multiplied, so nothing the bake
puts in the albedo can darken it. `tools/make_spec_probe.py` builds eight
panels with a pure black albedo — whatever you can see on them is specular and
nothing else. Read off the screenshots, luminance out of 255:

| panel | config | reading |
|---|---|---|
| 1 | roughness 1.0, metallic 0, flat normal | blob peaks **108** |
| 2 | + noise normal map | sparkle, mean **54** |
| 3 | roughness 1.0, **metallic 1** | **0.0** |
| 4 | **roughness 2.0**, metallic 0 | 19.4 |
| 5 | roughness 1.0, metallic 0, **real face normal** | 15.8 |
| 6 | roughness 1.0, metallic 0, **normal straight down** | **0.0** |
| 7 | **roughness 0.2**, metallic 0 | 1.6 here, mirror elsewhere |
| 8 | **white albedo**, roughness 1.0 | **216.8** |

Four things fall out of that table.

**Roughness above 1 is clamped on import.** Panel 4 is no darker than panel 1,
so widening the lobe past `alpha = 1` is not available.

**A noise normal map is worse, not better.** Panel 2 trades one soft blob for
per-texel sparkle whose *mean* (54) is brighter than the non-blob part of
panel 1 (24–38), and it mips back to flat at distance anyway.

**Only two things actually zero it.** Panel 3 works because
`f0 = mix(0.04 * spec * spec, ALBEDO, METALLIC)` collapses to `ALBEDO = 0` —
which is useless on a real map, where an albedo of 0.2 makes `f0` twenty times
*larger* than metallic 0 does, and pushes `f90 = clamp(50 * f0.g, 0, 1)` from
0.5 to 1.0. Panel 6 works because `specularBRDF = max(NdotL * D * G * F, 0)`
and `NdotL` is zero: a normal that faces away from every sun cannot reflect
one. That is the only cure that generalises.

**Panel 8 is the exposure anchor.** A white surface on the flat normal renders
at 216.8/255, while the baked atlas's median texel (86/255) renders near 69.
The blob at 108 is *brighter than the map it sits on*. That is precisely why it
reads as a light source shining through the walls rather than as a sheen.

### The trade, stated honestly

A flat normal makes the game's multiplier uniform, which is what lets the bake
show through — but it also makes every specular lobe line up into one map-wide
gradient instead of a per-face highlight. There is no setting that keeps both.

| build | normal | multiplier | specular | white tops out at |
|---|---|---|---|---|
| `--flat-normals` | (0.689, 0.725, −0.008) | 0.45, uniform | blob, 108 | 217 |
| `--flat-normals --normal-blend 0.35` | per face, 35 % real | 0.38, ±1.9x | per surface | ~200 |
| `--flat-normals nospec` | (−0.748, −0.279, −0.603) | 0.127, uniform | **zero** | ~122 |
| no flat normals | real | 0.01–1.0, 100x | weakest per face | 217 |

`nospec` is the direction that maximises sky ambient subject to `N·L <= 0` for
all three suns. It is the only configuration with no specular at all, and it
pays for that with a ceiling: the sky ambient is all the light there is.

`--normal-blend T` keeps T of each face's real normal, so surfaces stop sharing
one lobe. T=0.25 swings the multiplier 1.4x across orientations, T=0.5 swings
it 5x, T=1 swings it 100x — because a ceiling normal sees none of the sky
panorama, whose lower half is black.

## Props: the other half of the map

`SPECULAR_LIGHT` was only one of the two things making a baked map look wrong.
The other: props were never baked at all, so they render at the game's own
multiplier — up to 1.0 — while the baked world beside them renders at 0.127.
Measured off an in-game shot of the `nospec` build:

| surface | luminance |
|---|---|
| crate stack (**prop, unbaked**) | 147.6 |
| roof tiles (baked world, brightest) | 107.3 |
| shaded stone wall (baked) | 43.3 |
| wooden beam (baked) | 2.6 |

That is roughly 12x in linear terms, which is why an unbaked crate reads as a
lamp. Props were skipped because a mesh used by several nodes cannot share one
atlas region — so the bake now **de-instances** first: every node gets its own
mesh entry, the copies sharing accessors. On de_cpl_strike that turns 54,650
unique prop triangles into 188,495, which costs nothing at 120 fps.

Foliage stays dynamic (`--bake-foliage` to override), but **only prop
foliage**. Every leaf card is its own disconnected chart island, so baking
trees, vines and hay takes the chart count from 9k to about 60k and the
rasterise from one minute to fifteen — for geometry that reads as foliage
catching the light either way.

Alpha-tested *world* geometry must stay baked, and skipping it once by mistake
cost an afternoon. de_cpl_strike hangs **1,588 m² of alpha-blended ivy canopy**
over its courtyards — six primitives, horizontal sheets at y ≈ 16 m spanning up
to 36 × 44 m, averaging 87 % opaque. Left dynamically lit it renders at the
game's own multiplier while everything under it renders at 0.19, so it becomes
a bright translucent veil laid over the whole map, with hard straight brush
edges cutting across walls and ground alike. It reads exactly like a cone of
light shining through the geometry, and it is not lighting at all — it is a
roof. The giveaway was that the brightness step (2.4x in linear) continued in a
straight line across surfaces that were not coplanar, which no shadow can do. Alpha-tested
charts that *are* baked get pages of their own, written as RGBA PNG with
`alphaMode: MASK`, because a cut-out cannot survive JPEG and the game's loader
picks `CustomMaterialAlpha` off `has_alpha()`.

One gotcha worth recording: in the Cycles scene every page object now shares a
single opaque material. The bake runs with `use_pass_color` off so albedo is
never read — but *alpha* is, and an alpha-blended bake target comes back empty,
which would have blacked out every tree.

### Picking a normal

`--flat-normals` takes a preset. Each is the direction that maximises the
game's multiplier subject to a budget on `sum(E_i * NdotL_i)`, which is what
drives the blob; blob figures are scaled from the probe's measured 108.

| preset | multiplier | white tops out at | blob |
|---|---|---|---|
| `nospec` | 0.129 | 123 | **0** |
| `low` | 0.187 | 145 | 16 |
| `mid` | 0.230 | 160 | 28 |
| `auto` | 0.452 | 217 | 108 — unusable |

Bake once with `--keep-scene`, then A/B the presets with `--reuse-bake`: the
choice of normal does not touch the charts, so it costs a rasterise, not a
Blender run.

## The sky was PI times too strong, and that is why lamps never projected

`srclights` returns the sun and the sky through the same `_light_value()`, so
on de_cpl_strike they arrive as **829.4** and **128.6** — a ratio of 0.155, and
Source means both as irradiance-like quantities.

But the Blender side fed the sky straight into a Background node, and a
Background node's Strength is **radiance**: a surface open to a uniform
environment of radiance L receives `PI * L`. A Sun lamp's Strength, meanwhile,
already *is* the irradiance. So the sky arrived at `PI * 128.6 = 404` against
the sun's 829 — a ratio of 0.487, exactly PI too strong.

```
                        before      after
  world strength         128.6       40.9
  sky irradiance         404.0      128.6     (sun 829)
  sky : sun               0.487      0.155     <- what the entity asks for
  sunlit ground          367.8      280.1
  shade (sky only)       128.6       40.9
  sun:shade contrast      2.86x      6.84x
```

This is the bug behind every "the bake looks flat" complaint. An inflated sky
drowns the sun — 2.9:1 between sunlight and shade is overcast, not a Mediterranean
afternoon — and it drowns the map's own lights: 65 point and spot lights whose
pools were sitting on an ambient floor three times higher than it should be,
which is why lamps never appeared to project anything.

The exposure anchor moves with it. `cycles_reference` now divides **both**
terms by PI — the sun because the DIFFUSE pass is irradiance/PI, and the sky
because the world is fed as `amb / PI`, so a fully open surface reads `amb / PI`
in the pass. 393 becomes 305; leaving it at 393 would have handed back a third
of the brightness the fix just bought.

With the ambient floor gone, interiors are lit by lamps and bounce instead, so
`sample_clamp_indirect` is now set (default 10): a stray bright path that used
to hide under the ambient shows up as a white speckle on black otherwise. More
bounces matter more for the same reason — 4, not 2.

## What survives when the game enables true lightmaps

Decompiled out of `z_asset_loader.gd`, so the pipeline can target it now:

```gdscript
func get_bucket_from_name(object_name):     # the NODE NAME carries the size
    if object_name.contains('_zlms-64'):  return 0
    ... 128, 256, 512, 1024, 2048, 3072, 4096 -> buckets 1..7
    return -1

func lightmap_base_path():
    return base + 'maps2/maps/%s/baked_%s_%s/' % [map_id, variation, quality]

var path = lightmap_base_path() + ('%s_comb.dds' % child.name)
var img := load_dds_bc6(path)               # DDS, DX10 header, BC6H UF16/SF16
```

So the durable asset is **one HDR light-only image per mesh node**, BC6H, named
`<node>_comb.dds`, with the node named `..._zlms-<N>`, sampled at **UV2**, and
it replaces `DIFFUSE_LIGHT` outright (`shadow.rgb + 0.01`). BC6H is HDR, which
confirms it stores radiance and not albedo x light.

That is exactly what the Cycles bake already computes. Everything built on top
of it to survive the albedo-only shader — flat normals, flat gain, the gamma
lift, sky-rotation hacks, normal blending — is compensation that gets deleted
the day the flag flips. Improve the light solution; treat the albedo composite
as an export step.

## Performance notes

Roughly 1500 `MeshInstance3D` nodes become ~1500 trimesh colliders, since the
game generates collision per mesh. If physics cost is a problem:

* `--cell 96` quarters the world mesh count (coarser culling granularity).
* `--no-prop-ents` drops `prop_dynamic`/`prop_physics` (~200 nodes on inferno).
* `--albedo-px 256 --normal-px 128` roughly quarters texture memory.

The `-collider` suffix looks like the intended lever for cheap collision, but
it is not confirmed whether it *suppresses* the automatic per-mesh collider or
merely adds to it - worth testing before relying on it.

## Known gaps

* Building interiors are unlit - no baked lightmaps, so `env_dynamic` only
  gives sun plus sky ambient. This is the largest remaining fidelity gap: it is
  what makes pale surfaces read washed-out next to the original.
* `$basetexture2` blends are quantised to `--blend-bands` fixed mixes, not a
  continuous per-vertex blend - the game shader has one albedo sampler.
* `$envmap` cubemap reflections are approximated by a small `--metal-sheen`
  metallic value; the actual per-pixel `$envmapmask` is used only as a scalar.
* `$detail` is baked at `round($detailscale)` tiles, so the grain frequency can
  be off by up to ~10 %.
* `total_effective_tris` in the report understates the mirrored back faces
  added for two-sided materials; the glb's real triangle count is higher.
* No baked lightmaps or `occluder.occ` — the map runs on `env_dynamic`.
* Detail props (`GAME_LUMP 'dprp'`, grass sprites) not placed.
* MDL bone transforms ignored — fine for static props, not for animated models.
* TF2 now converts: ctf_2fort builds to 1,008,601 triangles with 327 prop
  models and 1422 placements, and its 14 spawn doors slide open.
* Water is a flat tinted surface with a normal map. There is no reflection,
  refraction, flow or depth fog, because the game's shader offers none of them.
* VTMB needs BSP v17 and Troika's own .vpk format; neither is supported.
* `sky_rotation` is derived, not matched to the HDR's actual sun; nudge with `--sun-offset`.
