#!/usr/bin/env python3
"""zone-map-forge - convert Source engine BSP maps, and Uncrashed map-editor
maps, into The Zone FPV custom maps."""
import re, argparse, os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zonemap import convert, build as BU, locate, gma as GMA, uncrashed
from zonemap.lightmap import (ZONE_FLAT_NORMAL, ZONE_FLAT_GAIN,
                              ZONE_BAKED_ROUGHNESS)


def _flat_normal(spec):
    """'auto' -> the direction the game lights flatly; else an x,y,z vector."""
    if not spec:
        return None
    if str(spec).strip().lower() in ('auto', '', 'default'):
        return list(ZONE_FLAT_NORMAL)
    v = [float(x) for x in str(spec).split(',')]
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v] if n > 1e-9 else list(ZONE_FLAT_NORMAL)


def _install_dir(a):
    if not a.install:
        return None
    if a.install == 'auto':
        d = locate.find_zone_custom_maps()
    elif re.search(r'[<>]', a.install):
        # a placeholder from the docs got pasted literally. On Windows '<'
        # and '>' are illegal in a path, so this would die inside makedirs
        # with an unhelpful WinError 123.
        print(f'--install {a.install!r} still contains a <placeholder>; '
              f'auto-detecting instead. Pass a real path to override.')
        d = locate.find_zone_custom_maps()
    else:
        d = a.install
    if not d:
        raise SystemExit(
            'FATAL: could not find The Zone FPV custom_maps folder.\n'
            '  Pass the real path, e.g.\n'
            '  --install "C:/Program Files (x86)/Steam/steamapps/common/'
            'The Zone FPV/custom_maps"')
    return d


def _uncrashed(a):
    install_dir = _install_dir(a)
    rep = uncrashed.convert(
        a.map, None, name=a.name, out_root=a.out, game_dir=a.game_dir,
        lod_tris=a.lod_tris, merge_tris=a.merge_tris, cell_m=a.cell,
        albedo_px=a.albedo_px, normal_px=a.normal_px,
        normals=not a.no_normal_maps, jpeg_q=a.jpeg_q,
        terrain=not a.no_terrain, terrain_tol=a.terrain_tol,
        terrain_falloff=a.terrain_falloff, backdrop=not a.no_backdrop,
        spawn_height=a.spawn_height,
        sky_energy=1.0 if a.energy is None else a.energy,
        sun_offset=a.sun_offset, recenter=not a.no_recenter,
        all_foliage=a.all_foliage, tri_budget=a.tri_budget,
        terrain_budget=a.terrain_budget,
        with_decals=not a.no_decals)
    if install_dir:
        import shutil
        name = rep['name']
        dest = os.path.join(install_dir, name)
        os.makedirs(dest, exist_ok=True)
        for f in (f'{name}.glb', 'manifest.json'):
            shutil.copy2(os.path.join(rep['out_dir'], f), os.path.join(dest, f))
        print(f'installed -> {dest}')
    print(json.dumps({k: v for k, v in rep.items()
                      if k not in ('materials_detail', 'manifest')}, indent=1))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('map', help='map name (de_nuke), a path to a .bsp, a '
                               "path to a Garry's Mod .gma addon archive, or an "
                               "Uncrashed map: its .json, its Workshop folder, or "
                               'its Workshop item id')
    p.add_argument('-g', '--game', default=None,
                   choices=sorted(locate.GAMES) + ['uncrashed'],
                   help='which Source game the map is from. Inferred from the '
                        'path when a .bsp is given; defaults to css for a '
                        'bare map name.')
    p.add_argument('--game-dir', metavar='DIR',
                   help='the game folder, if it is not auto-detected '
                        '(e.g. ".../steamapps/common/Counter-Strike Source")')
    p.add_argument('-o', '--out', default='./out', help='output directory')
    p.add_argument('-n', '--name', help='custom map name (default: bsp name)')
    p.add_argument('--install', nargs='?', const='auto', metavar='DIR',
                   help="copy into The Zone's custom_maps. Bare --install "
                        'auto-detects it')
    p.add_argument('--scale', type=float, default=BU.UNIT,
                   help='metres per Hammer unit (default %(default)s = 1 inch)')
    p.add_argument('--cell', type=float, default=48.0, help='mesh chunk size in m')
    p.add_argument('--albedo-px', type=int, default=512)
    p.add_argument('--normal-px', type=int, default=256)
    p.add_argument('--png-albedo', action='store_true', help='PNG instead of JPEG albedo')
    p.add_argument('--jpeg-q', type=int, default=90)
    p.add_argument('--no-gen-normals', action='store_true',
                   help='do not synthesise normal maps from albedo')
    p.add_argument('--flip-green', action='store_true',
                   help='flip normal-map green channel (DirectX-style source maps)')
    p.add_argument('--no-emissive', action='store_true')
    p.add_argument('--keep-3d-skybox', action='store_true')
    p.add_argument('--no-brush-ents', action='store_true')
    p.add_argument('--sun-offset', type=float, default=0.0,
                   help='degrees to rotate the sky, to line the sun up by eye')
    p.add_argument('--energy', type=float, default=None, metavar='F',
                   help='sky/ambient energy in the manifest (default 1.0). Source '
                        'maps carry a baked ambient this cannot reproduce, so a '
                        'sunny map like dust2 may want 1.3-1.5. Defaults to '
                        '1.0, or to 0.45 with --bake-lightmaps, where the sun '
                        'would otherwise light the map a second time on top '
                        'of the bake')
    p.add_argument('--variations', default='', metavar='A,B',
                   help='extra skybox variations. The game picks one AT RANDOM '
                        'per load, so leave empty unless you want that')
    p.add_argument('--spawn-height', type=float, default=1.0,
                   help='how far above the floor the drone starts (default 1 m)')
    p.add_argument('--no-recenter', action='store_true',
                   help="keep Hammer's world origin. Uploading strips "
                        'manifest.json and always spawns at (0,10,0), so '
                        'recentring is what makes that land on the real spawn')
    p.add_argument('--fill', default='exposed',
                   choices=['none', 'up', 'exposed', 'all'],
                   help='rebuild faces vbsp deleted because a 1.8 m player could '
                        'never see them (default exposed)')
    p.add_argument('--nonsolid-props', default='keep', choices=['keep', 'skip'],
                   help='PERFORMANCE LEVER, not a fidelity fix. Source marks '
                        'props solid=0 so PLAYERS do not snag; they are still '
                        'physically there. Default keep')
    p.add_argument('--exclude-prop', action='append', default=[], metavar='TEXT',
                   help='drop props whose model path contains TEXT (repeatable)')
    p.add_argument('--no-trim-cutouts', action='store_true',
                   help='keep alpha cut-out cards as full rectangles')
    p.add_argument('--cutout-cell', type=float, default=0.75, metavar='M2',
                   help='target sub-triangle area when trimming cut-outs')
    p.add_argument('--doors', default='open', choices=['open', 'closed', 'remove'],
                   help='func_door / func_door_rotating leaves: swung open '
                        '(default), left as CS spawns them, or removed')
    p.add_argument('--breakables', default='remove', choices=['keep', 'remove'],
                   help='func_breakable / func_breakable_surf / func_physbox: '
                        'removed by default, i.e. treated as already smashed, '
                        'so vents, roof skylights and breakable windows are '
                        'open lines to fly. keep leaves them intact')
    p.add_argument('--keep-light-effects', action='store_true',
                   help='keep additive glow cards and light shafts. They have '
                        'no physical presence but The Zone collides every mesh, '
                        'so by default they are dropped')
    p.add_argument('--metal-sheen', type=float, default=0.15, metavar='F',
                   help='metallic to give $surfaceprop-metal materials that '
                        'actually sample a cubemap, scaled by $envmaptint and '
                        'the envmap mask and capped at 0.35 (default 0.15; 0 '
                        'disables). Source has no metalness channel, and the '
                        'game scales BOTH diffuse and ambient by (1-metallic), '
                        'so high values render metal near-black.')
    p.add_argument('--no-detail', action='store_true',
                   help="don't bake $detail (base x detail x2) into the albedo")
    p.add_argument('--normal-strength', type=float, default=1.0, metavar='F',
                   help='multiplier on generated normal-map relief (default 1.0)')
    p.add_argument('--blend-bands', type=int, default=5, metavar='N',
                   help='pre-composited mixes for WorldVertexTransition '
                        'materials, chosen per triangle from displacement '
                        'vertex alpha (default 5; 0 or 1 = use $basetexture '
                        'only, which is what every earlier build did)')
    p.add_argument('--blend-cell', type=float, default=1.5, metavar='M2',
                   help='subdivide blend-material ground to about this area in '
                        'm2 before picking a band, so the quantisation reads '
                        'as mottle rather than patches (default 1.5)')
    p.add_argument('--roughness-scale', type=float, default=1.0, metavar='F',
                   help='multiplier on every roughness value, clamped to '
                        '0.04..1.0. Measured in game, this shader is the '
                        'dominant lever on brightness and runs backwards: LOW '
                        'roughness blows out toward white, HIGH renders dark '
                        '(sunlit luminance 217/207/193/171/135 at roughness '
                        '0.15/0.35/0.55/0.75/0.95). Scaling down brightens.')
    p.add_argument('--roughness-min', type=float, default=None, metavar='F',
                   help='floor on every roughness value. The game shader adds '
                        'a GGX lobe that official maps never get - their baked '
                        'branch sets DIFFUSE_LIGHT and returns without '
                        'touching SPECULAR_LIGHT - and it is what makes tile, '
                        'metal and $envmap surfaces read as wet plastic. At '
                        'albedo 0.5 under one white sun the specular share of '
                        'a pixel at the mirror angle is 74%% at roughness '
                        '0.25, 29%% at 0.40, 10%% at 0.55 and 1%% at 0.90. '
                        'Defaults to 0.9 with --bake-lightmaps, off otherwise')
    p.add_argument('--water-roughness', type=float, default=0.6, metavar='F',
                   help="roughness for Source 'water' materials (default 0.6). "
                        'Deliberately not the physical ~0.04: the game shader '
                        'has a non-normalised GGX lobe, so a smooth horizontal '
                        'surface saturates to pure white.')
    p.add_argument('--water-value', type=float, default=0.28, metavar='F',
                   help="target luminance for water's stand-in colour "
                        '(default 0.28). $fogcolor sets the hue but is a fog '
                        'density, far too dark to use as a surface colour, so '
                        'its luminance is rescaled to this.')
    p.add_argument('--no-rebuild-culled', action='store_true',
                   help="don't rebuild brush sides vbsp deleted for facing the "
                        'void. Those keep their real material, so the nodraw '
                        'name test never finds them - they are most of a '
                        "building's outer shell and the top of every roof box, "
                        'and without them the map is hollow from outside.')
    p.add_argument('--min-exposed', type=float, default=0.10, metavar='F',
                   help='fraction of a hidden brush side that must have open '
                        'air in front of it before it is rebuilt (default '
                        '0.10). Exposure is strongly bimodal - on de_nuke 2065 '
                        'sides are 0 %% and 2542 are 100 %% - so this mainly '
                        'decides whether partly-covered roofs get closed.')
    p.add_argument('--expand-3d-skybox', action='store_true',
                   help="keep the map's 3D skybox and blow it up to full size "
                        "instead of deleting it, using sky_camera's own "
                        "origin and scale - puts a horizon behind maps whose "
                        "world just stops at the perimeter wall")
    p.add_argument('--skybox-cut', type=float, default=None, metavar='F',
                   help='force the 3D-skybox threshold instead of measuring '
                        'it (dist-to-sky_camera / dist-to-nearest-spawn; the '
                        'measured value is reported as skybox_cut)')
    p.add_argument('--gma', action='append', default=[], metavar='FILE',
                   help="a Garry's Mod .gma addon archive to read content "
                        'from (repeatable). A Workshop map ships as one of '
                        'these, holding the .bsp and every model and material '
                        'it needs: pass the .gma as the map argument to '
                        'convert the map inside it, or pass it alongside a '
                        'map name to layer its content in. Nothing is '
                        'unpacked to disk')
    p.add_argument('--bake-lightmaps', action='store_true',
                   help="bake Valve's own radiosity into the albedo. The "
                        'game shader has no second texture and no vertex '
                        'colour, so every lit world face gets its own patch '
                        'of a shared atlas holding albedo x lightmap. Real '
                        'shadows and light pools at no runtime cost; texture '
                        'detail is capped by the atlas density. Pair it with '
                        'a lower --energy so the dynamic sun does not light '
                        'the map a second time on top of the bake')
    p.add_argument('--flat-normals', nargs='?', const='auto', default=None,
                   metavar='X,Y,Z',
                   help='point every baked surface the same way, so the light '
                        'baked into it is what you see instead of the game '
                        'lighting the map a second time. The pixel is ALBEDO '
                        '* (DIFFUSE_LIGHT + AMBIENT) + SPECULAR and a custom '
                        'map always gets env_dynamic: three suns, unoccluded '
                        'sky ambient and a realtime shadow. Default "auto" '
                        'faces away from the only shadow-casting sun, so that '
                        'shadow drops out of the product entirely and the '
                        'game applies a flat 0.45 the bake compensates for. '
                        'Only sensible with --bake-lightmaps')
    p.add_argument('--bake-texel', type=float, default=0.0, metavar='CM',
                   help='force a flat atlas density in cm per texel. The '
                        'default (0) is adaptive - clip(sqrt(face area)/48, '
                        '3 cm, 30 cm) - which keeps small faces sharp and '
                        'spends little on the big flat walls that hold most '
                        'of a map\'s area')
    p.add_argument('--bake-brightness', type=float, default=None, metavar='F',
                   help='multiplier on the baked light (default 1.0). The '
                        'curve is Source\'s own: linear up to a lightmap '
                        'value of 128 - what Source calls fully lit, 255 with '
                        'its overbright of 2 - then a soft top that never '
                        'clips. Raise it for a brighter map')
    p.add_argument('--bake-page', type=int, default=2048, metavar='PX',
                   help='atlas page size (default 2048)')
    p.add_argument('--bake-exposure', type=float, default=None, metavar='F',
                   help='multiplier from Source light units to 0-1. The '
                        'default puts the 98th percentile of the map\'s own '
                        'luminance at 1.0; it is reported as light_scale')
    p.add_argument('--no-props', action='store_true', help='skip static props')
    p.add_argument('--no-prop-ents', action='store_true',
                   help='skip prop_dynamic / prop_physics entities')
    p.add_argument('--allow-missing-content', action='store_true',
                   help='build even when the game content cannot be found '
                        '(produces an untextured, prop-less map)')
    u = p.add_argument_group(
        'Uncrashed maps', 'A map from Uncrashed\'s editor or its Steam Workshop. '
        'Its art lives in the game\'s .pak files, so Uncrashed must be installed '
        '(--game-dir if it is not under Steam). --albedo-px, --normal-px, '
        '--jpeg-q, --cell, --spawn-height, --energy, --sun-offset and '
        '--no-recenter apply too.')
    u.add_argument('--lod-tris', type=int, default=4000, metavar='N',
                   help='use the most detailed LOD of each mesh with at most N '
                        'triangles (default 4000; 0 = always the full mesh). '
                        'Trees and machines are 13-16 k triangles at full detail')
    u.add_argument('--tri-budget', type=int, default=3000000, metavar='N',
                   help='placed-mesh triangles to aim for (default 3,000,000; 0 = '
                        'no limit). Over it, the meshes costing the most (count x '
                        'triangles) step down their LOD chain, never below 12%% of '
                        'full detail. The terrain is not counted')
    u.add_argument('--terrain-budget', type=int, default=1000000, metavar='N',
                   help='terrain triangles to aim for, per landscape (default '
                        '1,000,000; 0 = no limit): --terrain-tol is loosened until '
                        'it fits')
    u.add_argument('--no-decals', action='store_true',
                   help='leave out decals (graffiti, puddles, cracks). Each one is '
                        'cut out of the surfaces under it, so a map with thousands '
                        'of them gets much bigger')
    u.add_argument('--merge-tris', type=int, default=600, metavar='N',
                   help='meshes of up to N triangles are merged into the map\'s '
                        '--cell chunks; bigger ones are instanced (default 600)')
    u.add_argument('--no-terrain', action='store_true',
                   help='leave out the base level\'s landscape')
    u.add_argument('--no-backdrop', action='store_true',
                   help='leave out the base level\'s own meshes (its horizon)')
    u.add_argument('--terrain-tol', type=float, default=10.0, metavar='CM',
                   help='terrain height error allowed where the map is flown '
                        '(default 10 cm)')
    u.add_argument('--terrain-falloff', type=float, default=0.01, metavar='F',
                   help='extra terrain error allowed per cm of distance from '
                        'there (default 0.01: 1 m at 100 m)')
    u.add_argument('--all-foliage', action='store_true',
                   help='keep foliage the level paints without collision (grass, '
                        'leaves: hundreds of thousands of instances on the official '
                        'levels). The Zone collides with everything, so they are '
                        'left out by default; trees and rocks are kept')
    u.add_argument('--no-normal-maps', action='store_true',
                   help='leave out the meshes\' normal maps (smaller file)')
    a = p.parse_args()
    if a.game == 'uncrashed' or (a.game is None and uncrashed.is_uncrashed_map(a.map)):
        return _uncrashed(a)
    if a.energy is None:
        # A baked map is NOT lit twice in any meaningful sense: the shader's
        # own diffuse is LIGHT_COLOR / PI, so a mid-grey albedo under a full
        # white sun only reaches 94/255 before anything else happens. Dimming
        # that to 0.45 as an earlier build did is what made the first baked
        # maps come out nearly black. Full energy, and raise it further if the
        # map still reads dark.
        a.energy = 1.0
    if a.roughness_min is None:
        # the baked look wants the official look: matte, no lobe. 1.0, not
        # 0.9: env_dynamic leaves the sky as the reflection source, so any
        # smoothness left turns a dark baked albedo into a mirror of the sky,
        # which is what the glossy dark areas were.
        a.roughness_min = ZONE_BAKED_ROUGHNESS if a.bake_lightmaps else 0.0
    if a.bake_lightmaps and a.metal_sheen == 0.15:
        # metallic feeds f0 straight into that same lobe (2 % of the pixel at
        # metallic 0, 15 % at 0.15) and buys nothing on a baked map
        a.metal_sheen = 0.0

    # ---- open any .gma archives -----------------------------------------
    # A Workshop addon is one flat archive holding the map AND its content, so
    # the same file can be both the map source and a content root.
    archives, bsp_bytes = [], None
    gma_paths = list(a.gma)
    map_is_gma = a.map.lower().endswith('.gma') and os.path.isfile(a.map)
    if map_is_gma:
        gma_paths.insert(0, a.map)
    for gp in gma_paths:
        if not os.path.isfile(gp):
            sys.exit(f'not found: {gp}')
        try:
            arc = GMA.Gma(gp)
        except Exception as ex:
            sys.exit(f'{gp}: {ex}')
        archives.append(arc)
        print(f'[0/5] gma {os.path.basename(gp)}: {arc.name!r} - '
              f'{len(arc.entries)} files, {len(arc.maps())} maps')

    # ---- resolve the map and the game content ---------------------------
    if a.map.lower().endswith('.bsp') and os.path.isfile(a.map):
        bsp_path = os.path.abspath(a.map)
        game = a.game
        if game is None:
            # Infer it. Defaulting to css here is actively harmful: a TF2 map
            # under 'Team Fortress 2/tf/maps' finds a sibling hl2/ but no
            # cstrike/, so the content roots come back as HL2 alone and every
            # TF2 material and model silently resolves to nothing.
            game = locate.guess_game(bsp_path)
            if game is None:
                sys.exit(f'could not tell which game this map belongs to:\n'
                         f'  {bsp_path}\n'
                         f'  pass -g one of: {", ".join(sorted(locate.GAMES))}')
            print(f'[0/5] game inferred from the path: -g {game}')
        dirs = locate.content_roots_for_bsp(bsp_path, game, a.game_dir)
    elif archives:
        # the map lives inside one of the archives
        want = None if map_is_gma else \
            os.path.splitext(os.path.basename(a.map))[0].lower()
        pick = None
        for arc in archives:
            got = arc.maps()
            if want is not None:
                got = [m for m in got
                       if os.path.splitext(os.path.basename(m[0]))[0] == want]
            if got:
                pick = (arc, got)
                break
        if not pick:
            listing = '\n'.join(f'    {n}  ({sz/1e6:.0f} MB)'
                                 for arc in archives for n, sz in arc.maps())
            sys.exit(f'no map named {want!r} in the archive(s). Found:\n'
                     + (listing or '    (no .bsp inside)'))
        arc, got = pick
        inner = got[0][0]
        if len(got) > 1:
            print(f'[0/5] {len(got)} maps in the archive, taking the biggest. '
                  f'Name another with the map argument:')
            for n, sz in got:
                print(f'        {os.path.splitext(os.path.basename(n))[0]}'
                      f'  ({sz/1e6:.0f} MB)')
        print(f'[0/5] reading {inner} ({got[0][1]/1e6:.0f} MB) from the archive')
        bsp_bytes = arc.read(inner)
        # a label, not a real file: convert() takes the name from it
        bsp_path = os.path.join(os.path.dirname(os.path.abspath(arc.path)),
                                os.path.basename(inner))
        game = a.game or 'gmod'
        try:
            dirs = locate.find_game(game, a.game_dir)[1]
        except SystemExit as ex:
            # An addon usually carries everything it needs, so a missing game
            # install is a warning, not a stop - only content the map borrows
            # from the base game goes missing.
            print(f'[0/5] no {game} install found, using the archive alone.\n'
                  f'      {str(ex).splitlines()[0]}')
            dirs = []
    else:
        game = a.game or 'css'
        maps_dir, dirs = locate.find_game(game, a.game_dir)
        bsp_path = os.path.join(maps_dir,
                                a.map if a.map.lower().endswith('.bsp') else a.map + '.bsp')
    if bsp_bytes is None and not os.path.isfile(bsp_path):
        sys.exit(f'not found: {bsp_path}')

    install_dir = _install_dir(a)

    name = a.name or os.path.splitext(os.path.basename(bsp_path))[0]
    out = os.path.join(a.out, name)
    rep = convert.convert(
        bsp_path, out, name=name, game_dirs=dirs, scale=a.scale, cell_m=a.cell,
        albedo_px=a.albedo_px, normal_px=a.normal_px,
        albedo_jpeg=not a.png_albedo, jpeg_q=a.jpeg_q,
        gen_normals=not a.no_gen_normals, flip_green=a.flip_green,
        emissive=not a.no_emissive, keep_3d_skybox=a.keep_3d_skybox,
        brush_ents=not a.no_brush_ents, sun_offset=a.sun_offset,
        spawn_height=a.spawn_height, props=not a.no_props,
        prop_ents=not a.no_prop_ents, fill_mode=a.fill,
        nonsolid_props=a.nonsolid_props, exclude_props=tuple(a.exclude_prop),
        trim_cutouts=not a.no_trim_cutouts, cutout_cell=a.cutout_cell,
        sky_energy=a.energy, recenter=not a.no_recenter,
        variations=tuple(x.strip() for x in a.variations.split(',') if x.strip()),
        require_content=not a.allow_missing_content,
        doors=a.doors, breakables=a.breakables,
        light_effects=a.keep_light_effects,
        metal_sheen=a.metal_sheen, detail=not a.no_detail,
        normal_strength=a.normal_strength, blend_bands=a.blend_bands,
        blend_cell=a.blend_cell, roughness_scale=a.roughness_scale,
        water_roughness=a.water_roughness, water_value=a.water_value,
        rebuild_culled=not a.no_rebuild_culled, min_exposed=a.min_exposed,
        roughness_min=a.roughness_min,
        skybox_cut=a.skybox_cut, expand_skybox=a.expand_3d_skybox,
        bsp_bytes=bsp_bytes, archives=archives,
        bake_lightmaps=a.bake_lightmaps, bake_texel_cm=a.bake_texel,
        flat_normals=_flat_normal(a.flat_normals),
        bake_page=a.bake_page, bake_exposure=a.bake_exposure,
        bake_brightness=a.bake_brightness)

    if install_dir:
        import shutil
        dest = os.path.join(install_dir, name)
        os.makedirs(dest, exist_ok=True)
        for f in (f'{name}.glb', 'manifest.json'):
            shutil.copy2(os.path.join(out, f), os.path.join(dest, f))
        print(f'installed -> {dest}')
    print(json.dumps({k: v for k, v in rep.items()
                      if k not in ('materials_detail', 'manifest')}, indent=1))


if __name__ == '__main__':
    main()
