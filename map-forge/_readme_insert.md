### What the importer *drops* — and why it shapes the whole converter

The conversion is `gdutil/z_asset_loader.gdc` → `convert_custom_materials`,
read out of `thezone.pck`. Five things a normal glTF author would rely on are
never copied, and each one caused a visible bug here:

| glTF / StandardMaterial3D | fate | consequence |
|---|---|---|
| `normalTexture.scale` | **dropped** | `custom_material.gdshader` does `NORMAL_MAP = texture(normal_texture, UV).rgb` with no `NORMAL_MAP_DEPTH`. A generated normal map is always applied at 1.0, so damping has to be baked into the pixels. |
| `doubleSided` | **dropped** | Neither shader declares `cull_disabled`. `$nocull` art (grates, railings, tree cards) is invisible *and* non-collidable from one side, since Godot's trimesh collision is front-face only. |
| `baseColorFactor` **with** a texture | **ignored** | The shader is `if (use_albedo_color) ALBEDO = albedo_color.rgb; else ALBEDO = texture(...)`. Either/or, never the product — a `$color` tint left in `baseColorFactor` silently vanishes. |
| `metallicRoughnessTexture` | **mis-read** | The shader samples `.r` of both `roughness_texture` and `metallic_texture`, but Godot's glTF importer packs roughness in **G** and metallic in **B** of one ORM image. Per-pixel roughness is therefore not available; ship scalar factors only. |
| duplicate material names | **collapse** | Converted materials are cached by `resource_name`, so two glTF materials with the same name become one in game and the second one's textures are dropped. Every emitted name is kept unique (`material_names_deduped` in the report). |

### METALLIC: Source has no metalness channel, and guessing one turns metal black

The shader's `light()` adds a direct GGX term and nothing else, while Godot's
own fragment code applies:

```glsl
diffuse_light *= 1.0 - metallic;
ambient_light *= 1.0 - metallic;
```

So `metallic` **removes** diffuse and ambient rather than adding shine.

The converter used to set `metallic` from `$surfaceprop`. That was a category
error: `$surfaceprop` is a physics-and-footstep-sound property — "this sounds
like metal when you shoot it" — not a statement about conductivity. It gave
**151 de_nuke materials metallic 0.85, covering 17.3 % of the map's surface
area**, and every one of them rendered at 15 % brightness. `nukdoorsa`'s
texture averages RGB 167/114/42, a tan metal door; in game it was nearly black.

Source's own model is the opposite of metallic: `LightmappedGeneric` with
`$envmap` draws a **full-strength** diffuse and *adds* a masked, tinted cubemap
reflection on top. In PBR terms that is a dielectric.

Now `metallic` defaults to 0 and is raised only when `$surfaceprop` says metal
**and** the material actually samples a cubemap, scaled by `$envmaptint` and
the mean of `$envmapmask`, capped at 0.35. `--metal-sheen` sets the ceiling
(default 0.15, `0` disables). For reference, the two best-looking community maps
— `skate3_downtown` (895 materials) and the community `de_dust2` — ship
metallic 0.0 and roughness 1.0 on *every* material.

`tools/make_material_probe.py` builds a 5×5 grid of cubes sweeping metallic
0→0.85 against roughness 0.15→0.95, all sharing one albedo, so this is
measurable in game rather than inferred from engine source.

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
