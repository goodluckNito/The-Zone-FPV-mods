"""de_inferno.bsp -> custom_maps/<name>/<name>.glb + manifest.json"""
import os, re, json, time, math, collections, numpy as np
from . import bsp as B, build as BU, manifest as MF, propbuild as PB
from .sourcefs import SourceFs
from .glb import Glb
from .materials import MaterialBank, is_light_effect

# An uploaded map has no manifest, so the engine drops the drone here.
ENGINE_DEFAULT_SPAWN_Y = 10.0


def mirror_faces(pos, nrm, uv, idx):
    """Append a back-facing copy of every triangle.

    The Zone's material shaders declare no `cull_disabled` and its glTF importer
    never copies `cull_mode`, so glTF `doubleSided` is silently dropped: a
    $nocull grate, railing or tree card is invisible AND non-collidable from one
    side (Godot's trimesh collision is front-face only too). Duplicating the
    triangles with reversed winding and flipped normals is the only way to get
    two-sided behaviour through that importer.
    """
    pos = np.asarray(pos); nrm = np.asarray(nrm)
    uv = np.asarray(uv); idx = np.asarray(idx).reshape(-1, 3)
    n = len(pos)
    back = idx[:, ::-1] + n
    return (np.concatenate([pos, pos]),
            np.concatenate([nrm, -nrm]),
            np.concatenate([uv, uv]),
            np.concatenate([idx, back]).astype(np.uint32))


def slug(s):
    # '#b2/5' (a blend band) has to survive as something distinct: the game's
    # asset loader caches converted materials by resource_name, so two glTF
    # materials with the same name collapse into one in game - which would
    # quietly undo the whole WorldVertexTransition blend.
    s = re.sub(r'#b(\d+)/(\d+)', r'__blend\1of\2', str(s))
    return re.sub(r'[^a-z0-9]+', '_', s.lower()).strip('_')


def playable_centre(bsp):
    pts = []
    for e in bsp.entities:
        cn = e.get('classname', '')
        if cn.startswith('info_player_') or cn in ('info_deathmatch_spawn',
                                                   'info_teleport_destination'):
            try:
                pts.append([float(x) for x in e['origin'].split()[:3]])
            except (KeyError, ValueError):
                pass
    return np.array(pts, np.float64) if pts else None


def sky_camera(bsp):
    for e in bsp.entities:
        if e.get('classname') == 'sky_camera':
            try:
                return np.array([float(x) for x in e['origin'].split()[:3]])
            except (KeyError, ValueError):
                return None
    return None


SKYBOX_BIAS = 0.5          # fallback cut when no clean split can be found
SKYBOX_SPLIT_JUMP = 1.7    # a separate room leaves at least this wide a gap
SKYBOX_SPLIT_CAP = 1.2     # the cut has to sit in the plausible range
SKYBOX_SPLIT_MAX_FRAC = 0.5   # the skybox is never half the map


def skybox_ratio(pts, sky_g, play_pts):
    """dist(point, sky_camera) / dist(point, NEAREST spawn), per point.

    Both distances are measured in the same frame, so the ratio does not care
    whether the caller has applied `origin_shift` - only that it applied it to
    all three.
    """
    p = np.atleast_2d(np.asarray(pts, np.float64))
    ds = np.linalg.norm(p - np.asarray(sky_g, np.float64), axis=1)
    dp = np.linalg.norm(p[:, None, :] - np.asarray(play_pts, np.float64)[None],
                        axis=2).min(axis=1)
    return ds / np.maximum(dp, 1e-9)


def skybox_threshold(ratios, bias=SKYBOX_BIAS):
    """Where does the 3D skybox end and the map begin? (threshold, note)

    A fixed cut cannot work. The 3D skybox is a separate room whose distance
    from the sky_camera relative to the play area varies enormously with where
    the mapper put it, and the two populations overlap ACROSS maps even though
    they never overlap WITHIN one:

        ctf_2fort   skybox up to 0.576   map from 1.352
        de_dust     skybox up to 0.522   map from 1.543
        cs_italy    no skybox props      map from 0.687   <- sky_camera sits
                                                             inside the map
        de_aztec    no skybox props      map from 1.130

    So 0.5 misses ctf_2fort's `horizon_facade001` (0.505) and `sunnoon` (0.576)
    - the lone prop left hanging in the sky - while anything above 0.687 eats
    cs_italy's windows, awnings and lanterns.

    What IS reliable is the gap. Because the skybox is a physically separate
    room there is a wide empty band between the two populations, and where
    there is no skybox there is no band: measured multiplicative jumps at the
    boundary were x2.35 (ctf_2fort), x2.95 (de_dust), x5.94 (cp_dustbowl),
    x7.27 (de_dust2), x10.6 (pl_badwater), x15.5 (de_inferno), x40.7 (de_nuke)
    and x295 (cs_office), against a largest-anywhere jump of x1.14 on cs_italy
    and nothing under 1.2 on de_aztec.

    So: take the RIGHTMOST jump of at least `SKYBOX_SPLIT_JUMP` whose lower
    side is still plausibly skybox, and cut in the middle of it. The bar is
    1.7 rather than 2.0 because de_cache's is x1.77 (1.020 -> 1.807) - its
    sky_camera is only 66 m from the nearest spawn on a map barely wider than
    that, which squeezes both populations together. Swept over fifteen CS:S
    and TF2 maps, 1.7 differs from 2.0 on de_cache alone. Rightmost, not
    largest, because a lone prop sitting on the sky_camera itself can open a
    bigger gap inside the skybox cluster than the real boundary does (de_nuke's
    smokestack, x2.78, is one). With no qualifying jump, fall back to the
    strict fixed cut, which errs towards keeping geometry.
    """
    r = np.sort(np.asarray(ratios, np.float64).ravel())
    r = r[np.isfinite(r)]
    if len(r) < 8:
        return bias, None
    i = np.flatnonzero(r[:-1] < SKYBOX_SPLIT_CAP)
    if not len(i):
        return bias, None
    jump = r[i + 1] / np.maximum(r[i], 1e-6)
    ok = i[jump >= SKYBOX_SPLIT_JUMP]
    if not len(ok):
        return bias, None
    k = int(ok[-1])                      # rightmost qualifying gap
    if (k + 1) > SKYBOX_SPLIT_MAX_FRAC * len(r):
        return bias, None
    cut = float(math.sqrt(max(r[k], 1e-6) * r[k + 1]))
    if cut <= bias:
        # The gap we found sits BELOW the conservative fixed cut, so it is a
        # gap inside the skybox cluster rather than the boundary - de_aztec's
        # miniature has no clean edge and splits at 0.037, which would have
        # put 55 chunks / 7,761 tris of 3D skybox back into the map. Measuring
        # can only ever find MORE skybox than the fixed rule, never less.
        return bias, None
    return (cut,
            dict(lo=round(float(r[k]), 4), hi=round(float(r[k + 1]), 4),
                 jump=round(float(r[k + 1] / max(r[k], 1e-6)), 2),
                 n_skybox=k + 1, n_samples=int(len(r))))


def in_3d_skybox(t, sky_g, play_pts, bias=SKYBOX_BIAS):
    """Is this point part of the miniature 3D skybox rather than the map?

    The distance is compared against the NEAREST spawn point, not the centroid
    of them: on a long map the centroid plants a cutting plane straight through
    the far end, and ctf_2fort lost 11 real props that way - a security fence
    pole, a window, an oil drum, a sliding door, a grain elevator, a wooden
    rail. `bias` is the cut, normally the one `skybox_threshold` measured.
    """
    if sky_g is None or play_pts is None or not len(play_pts):
        return False
    near = float(np.min(np.linalg.norm(play_pts - t, axis=1)))
    return float(np.linalg.norm(t - sky_g)) < bias * near


def map_skybox_threshold(bsp, chunks, sky_src, play_src, scale):
    """Measure the cut from this map's own geometry AND props.

    Both go in: a 3D skybox built only from brushwork has no props to measure,
    and one built only from props has no chunks.

    This is a measurement, not a proof, and on a map where the two populations
    nearly touch it can flip: de_cache's boundary gap is x1.91, so closing
    378 m2 of its roof was enough to move it under the bar and put 763 m2 of
    miniature landscape back. `--skybox-cut` exists for exactly that case - the
    chosen value and the gap it came from are both in `convert_report.json`.
    """
    if sky_src is None or play_src is None or not len(play_src):
        return SKYBOX_BIAS, None
    sky_g = BU.to_gltf(sky_src[None, :], scale)[0]
    play_pts = BU.to_gltf(play_src, scale)
    pts = [c[2].mean(axis=0) for c in chunks]
    try:
        placements, _names, _meta = PB.collect(bsp)
        pts += [BU.to_gltf(np.asarray(o, np.float64), scale)
                for _m, _s, o, _a, _sc, _src, _p in placements]
    except Exception:
        pass
    if not pts:
        return SKYBOX_BIAS, None
    return skybox_threshold(skybox_ratio(np.array(pts), sky_g, play_pts))


def sky_camera_scale(bsp, default=16.0):
    """`sky_camera`'s `scale` key - how many times bigger the real thing is."""
    for e in bsp.entities:
        if e.get('classname') == 'sky_camera':
            try:
                v = float(e.get('scale', default) or default)
            except (TypeError, ValueError):
                return default
            return v if 1.0 < v <= 256.0 else default
    return default


def expand_3d_skybox(pos, sky_src, scale_factor, scale=BU.UNIT):
    """Move 3D-skybox geometry out to where the engine actually draws it.

    Source's 3D skybox is a 1/N-scale model of the distant world built in a
    sealed room somewhere off the map, and `sky_camera` carries both halves of
    the transform: its `origin` is the point in that room that corresponds to
    the map's world origin, and its `scale` key is N (16 on de_cache, de_nuke
    and ctf_2fort; 4 on de_dust2 and de_aztec). The engine draws a skybox point
    p at

        p_world = (p - sky_camera.origin) * N

    so reproducing it is exact rather than a guess - the hills end up at the
    distance and size the mapper composed them for. Doing this instead of
    deleting the miniature is what puts a horizon back behind a map whose
    world simply stops at the perimeter wall.
    """
    o = BU.to_gltf(np.asarray(sky_src, np.float64)[None, :], scale)[0]
    return (np.asarray(pos, np.float64) - o) * float(scale_factor)


SKYBOX_CEILING_M = 15.0     # how far above the map a skybox piece may land


def expand_3d_skybox_chunks(chunks, sky_src, play_src, scale,
                            bias=SKYBOX_BIAS, factor=16.0):
    """Blow the miniature up in place instead of deleting it.

    Returns (chunks, expanded, tris, ceiling) - `ceiling` is the height above
    which an expanded piece is dropped instead. A 3D skybox contains clouds as
    well as landscape, and multiplying a cloud card by 16 makes it real: on
    de_cache `props_cs_office/clouds` came out as a 201,746 m2 plane 85 m over
    the middle of the map, which The Zone would collide with. Hills and distant
    buildings have their FEET on the ground, so testing a piece's lowest point
    against the map's own top separates the two without needing to know what
    the material is.
    """
    if sky_src is None or play_src is None or not len(play_src):
        return chunks, 0, 0, None
    sky_g = BU.to_gltf(sky_src[None, :], scale)[0]
    play_pts = BU.to_gltf(play_src, scale)
    sky_flag = [in_3d_skybox(c[2].mean(axis=0), sky_g, play_pts, bias)
                for c in chunks]
    kept = [c for c, f in zip(chunks, sky_flag) if not f]
    top = (max(float(c[2][:, 1].max()) for c in kept) if kept
           else float(play_pts[:, 1].max()))
    ceiling = top + SKYBOX_CEILING_M
    out, n, ntris = [], 0, 0
    for c, f in zip(chunks, sky_flag):
        if not f:
            out.append(c)
            continue
        pos = expand_3d_skybox(c[2], sky_src, factor, scale).astype(np.float32)
        if float(pos[:, 1].min()) > ceiling:
            continue                      # a cloud card, not scenery
        out.append((c[0], c[1], pos, c[3], c[4], c[5]))
        n += 1
        ntris += len(c[5])
    return out, n, ntris, ceiling


def drop_3d_skybox(chunks, sky_src, play_src, scale, bias=SKYBOX_BIAS):
    """Discard chunks that belong to the miniature 3D skybox."""
    if sky_src is None or play_src is None or not len(play_src):
        return chunks, 0, 0
    sky_g = BU.to_gltf(sky_src[None, :], scale)[0]
    play_pts = BU.to_gltf(play_src, scale)
    keep, dropped, dtris = [], 0, 0
    for c in chunks:
        if in_3d_skybox(c[2].mean(axis=0), sky_g, play_pts, bias):
            dropped += 1; dtris += len(c[5])
        else:
            keep.append(c)
    return keep, dropped, dtris



def column_hits(chunks, x, z, up_min=None):
    """All surface heights on the vertical line through (x, z).

    up_min filters to roughly upward-facing surfaces (floors); None keeps
    everything, which is what you want when asking 'is the airspace clear?'.
    """
    hits = []
    for _m, _cell, pos, nrm, _uv, idx in chunks:
        tp = pos[idx]                       # (T,3,3)
        ax, ay, az = tp[:, 0, 0], tp[:, 0, 1], tp[:, 0, 2]
        bx, by, bz = tp[:, 1, 0], tp[:, 1, 1], tp[:, 1, 2]
        cx, cy, cz = tp[:, 2, 0], tp[:, 2, 1], tp[:, 2, 2]
        # quick reject on the XZ bounding box
        lox = np.minimum(np.minimum(ax, bx), cx); hix = np.maximum(np.maximum(ax, bx), cx)
        loz = np.minimum(np.minimum(az, bz), cz); hiz = np.maximum(np.maximum(az, bz), cz)
        cand = (lox <= x) & (x <= hix) & (loz <= z) & (z <= hiz)
        if not cand.any():
            continue
        ax, ay, az = ax[cand], ay[cand], az[cand]
        bx, by, bz = bx[cand], by[cand], bz[cand]
        cx, cy, cz = cx[cand], cy[cand], cz[cand]
        # barycentric point-in-triangle in the XZ plane
        d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        ok = np.abs(d) > 1e-12
        if not ok.any():
            continue
        w0 = np.where(ok, ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / np.where(ok, d, 1), -1)
        w1 = np.where(ok, ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / np.where(ok, d, 1), -1)
        w2 = 1.0 - w0 - w1
        inside = ok & (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not inside.any():
            continue
        yy = w0[inside] * ay[inside] + w1[inside] * by[inside] + w2[inside] * cy[inside]
        if up_min is not None:
            nn = nrm[idx][cand][inside][:, 0, :]
            yy = yy[nn[:, 1] > up_min]
        hits.append(yy)
    return np.sort(np.concatenate(hits)) if hits else np.array([])


def floor_below(chunks, x, z, y_hint, up_min=0.45):
    """Ground height under (x, z), or None."""
    y = column_hits(chunks, x, z, up_min=up_min)
    if len(y) == 0:
        return None
    below = y[y <= y_hint + 0.5]
    return float(below.max()) if len(below) else float(y.min())


def clearance_at(chunks, x, z, ground, need):
    """Free height above `ground` on the line through (x, z)."""
    y = column_hits(chunks, x, z, up_min=None)
    above = y[y > ground + 0.6]
    return float(above.min() - ground) if len(above) else float('inf')


def pick_spawn(bsp, chunks, scale, need, verbose=True):
    """First player spawn whose airspace is clear to `need` metres.

    An uploaded map always spawns the drone at (0, 10, 0), so the point we move
    to the origin has to have 10 m of sky over it - otherwise the drone appears
    on whatever roof is above the spawn, which is exactly the bug this avoids.
    """
    cands = []
    for e in bsp.entities:
        cn = e.get('classname', '')
        if cn in ('info_player_terrorist', 'info_player_counterterrorist',
                  'info_player_start', 'info_deathmatch_spawn'):
            try:
                o = np.array([float(v) for v in e['origin'].split()[:3]])
            except (KeyError, ValueError):
                continue
            try:
                yaw = float((e.get('angles') or '0 0 0').split()[1])
            except (IndexError, ValueError):
                yaw = 0.0
            cands.append((o, yaw))
    if not cands:
        return None, None, 0.0, 0.0
    best = None
    for so, yaw in cands:
        sp = BU.to_gltf(so[None, :], scale)[0].astype(float)
        g = floor_below(chunks, sp[0], sp[2], sp[1])
        if g is None:
            continue
        c = clearance_at(chunks, sp[0], sp[2], g, need)
        if best is None or c > best[2]:
            best = (sp, g, c, yaw)
        if c >= need:
            if verbose:
                print(f'[3/5] spawn point has {c:.1f} m of clearance '
                      f'(needed {need:.1f})')
            return sp, g, c, yaw
    if best is not None and verbose:
        print(f'[3/5] WARNING: no spawn with {need:.1f} m clearance; '
              f'best is {best[2]:.1f} m - lower --spawn-height or expect a roof')
    return best if best else (None, None, 0.0, 0.0)


def convert(bsp_path, out_dir, name=None, game_dirs=None, scale=BU.UNIT,
            cell_m=48.0, albedo_px=512, normal_px=256, albedo_jpeg=True,
            jpeg_q=90, gen_normals=True, flip_green=False, emissive=True,
            keep_3d_skybox=False, sun_offset=0.0, brush_ents=True,
            spawn_height=2.0, props=True, prop_ents=True,
            fill_mode='exposed', nonsolid_props='keep', exclude_props=(),
            trim_cutouts=True, cutout_cell=0.75, sky_energy=1.0,
            variations=(), recenter=True, require_content=True,
            doors='open', breakables='remove', light_effects=False,
            metal_sheen=0.15, detail=True, normal_strength=1.0,
            blend_bands=5, blend_cell=1.5, roughness_scale=1.0,
            roughness_min=0.0,
            water_roughness=0.6, water_value=0.28, rebuild_culled=True,
            min_exposed=0.10, skybox_cut=None, expand_skybox=False,
            bsp_bytes=None, archives=(), bake_lightmaps=False,
            bake_texel_cm=0.0, bake_page=2048, bake_exposure=None,
            flat_normals=None, bake_brightness=None,
            verbose=True):
    t0 = time.time()
    mapname = os.path.splitext(os.path.basename(bsp_path))[0]
    name = name or mapname
    bsp = B.Bsp(bsp_path, data=bsp_bytes)
    game_dirs = game_dirs or []
    fs = SourceFs(game_dirs, pakfile_bytes=bsp.lump(B.L_PAKFILE),
                  archives=archives)
    st = fs.stats()
    if verbose:
        print(f'[1/5] {mapname}  bsp v{bsp.version}  faces={len(bsp.faces)} '
              f'disp={len(bsp.dispinfo)} models={len(bsp.models)} ents={len(bsp.entities)}')
        print(f'      content: {st}')
    if st['vpk_entries'] == 0 and st['roots'] == 0 and not st.get('gma_entries'):
        msg = ('game content not found - no VPK archives and no content roots.\n'
               '  Without it every prop and almost every texture resolves to\n'
               '  nothing: you get a near-empty, untextured map.\n'
               f'  Tried: {game_dirs or "(none)"}\n'
               '  Pass --game-dir "<path to the game folder>".')
        if require_content:
            raise SystemExit('FATAL: ' + msg)
        print('WARNING: ' + msg)

    from .materials import blend_band_count
    _bb_cache = {}

    def _blend_bands(mat):
        if mat not in _bb_cache:
            _bb_cache[mat] = blend_band_count(fs, mat, mapname, blend_bands)
        return _bb_cache[mat]

    glb = Glb(generator='zone-map-forge (Source BSP -> The Zone FPV)')
    bank = MaterialBank(glb, fs, mapname, albedo_px=albedo_px, normal_px=normal_px,
                        albedo_jpeg=albedo_jpeg, jpeg_q=jpeg_q,
                        gen_normals=gen_normals, flip_green=flip_green,
                        emissive=emissive, metal_sheen=metal_sheen,
                        detail=detail, normal_strength=normal_strength,
                        roughness_scale=roughness_scale,
                        roughness_min=roughness_min,
                        water_roughness=water_roughness,
                        water_value=water_value)

    bake = None
    if bake_lightmaps:
        from .lightmap import Bake
        from .lightmap import BRIGHTNESS as _BR
        from .lightmap import ZONE_FLAT_GAIN as _ZFG
        bake = Bake(bsp, bank, scale=scale, cell_m=cell_m,
                    texel_cm=bake_texel_cm, page_px=bake_page,
                    brightness=(_BR if bake_brightness is None else bake_brightness),
                    flat_gain=(_ZFG if flat_normals is not None else 1.0),
                    verbose=verbose)
        bake.plan(disp_faces={int(d['mapface']) for d in bsp.dispinfo},
                  blend_test=_blend_bands)

    chunks, stats = BU.extract(bsp, scale=scale, cell_m=cell_m, bake=bake,
                               include_brush_ents=brush_ents,
                               fill_mode=fill_mode, doors=doors,
                               breakables=breakables,
                               blend_bands=_blend_bands,
                               blend_cell=blend_cell,
                               rebuild_culled=rebuild_culled,
                               min_exposed=min_exposed, verbose=verbose)
    if not light_effects:
        before = len(chunks)
        def _fx(c):
            return (not c[0].startswith('#lm')
                    and is_light_effect(fs, c[0], mapname))
        dropped_tris = sum(len(c[5]) for c in chunks if _fx(c))
        chunks = [c for c in chunks if not _fx(c)]
        if verbose and before != len(chunks):
            print(f'[2/5] dropped {before - len(chunks)} light-effect chunks '
                  f'({dropped_tris} tris) - additive/glow cards are not matter')
    play = playable_centre(bsp)
    sky_cut, sky_note = SKYBOX_BIAS, None
    sky_ceiling = None
    sky_factor = sky_camera_scale(bsp)
    if not keep_3d_skybox:
        sky_cut, sky_note = map_skybox_threshold(bsp, chunks, sky_camera(bsp),
                                                 play, scale)
        if skybox_cut is not None:
            sky_cut, sky_note = float(skybox_cut), None
        if expand_skybox:
            chunks, nd, ndt, sky_ceiling = expand_3d_skybox_chunks(
                chunks, sky_camera(bsp), play, scale, bias=sky_cut,
                factor=sky_factor)
            stats['skybox_expanded_chunks'] = nd
            stats['skybox_scale'] = sky_factor
            if sky_ceiling is not None:
                stats['skybox_ceiling_m'] = round(float(sky_ceiling), 2)
        else:
            chunks, nd, ndt = drop_3d_skybox(chunks, sky_camera(bsp), play,
                                             scale, bias=sky_cut)
        stats['skybox_cut'] = round(sky_cut, 4)
        if sky_note:
            stats['skybox_split'] = sky_note
        if verbose and nd:
            print(f'[2/5] 3D skybox: '
                  + (f'expanded x{sky_factor:g}' if expand_skybox else 'dropped')
                  + f' {nd} chunks / {ndt} tris (cut at {sky_cut:.3f}'
                  + (f', gap x{sky_note["jump"]}' if sky_note
                     else ', forced' if skybox_cut is not None else ', fixed')
                  + ')')
    tris = sum(len(c[5]) for c in chunks)
    mats = sorted({c[0] for c in chunks})
    if verbose:
        print(f'[2/5] geometry: {tris:,} tris in {len(chunks)} chunks, '
              f'{len(mats)} materials')

    # ---- where should the world origin be? -------------------------------
    # Uploading a map to the server keeps ONLY the .glb - manifest.json is a
    # local file and is not round-tripped - so an uploaded map has no
    # spawn_point and the drone appears at the engine default (0, 10, 0).
    # Translating the map so the intended spawn ground sits at the origin makes
    # the offline and uploaded spawns identical.
    sp0, g0, clear0, spawn_yaw = pick_spawn(bsp, chunks, scale,
                                            need=float(spawn_height) + 1.5, verbose=verbose)
    if sp0 is None:
        sp0 = (BU.to_gltf(play, scale).mean(axis=0).astype(float)
               if play is not None and len(play) else np.zeros(3))
        g0 = floor_below(chunks, sp0[0], sp0[2], sp0[1])
    origin_shift = np.zeros(3)
    if recenter:
        # Put the spawn's ground directly under the engine's fixed spawn point,
        # spawn_height below it. Then (0, 10, 0) - which is where an uploaded
        # map always starts - is spawn_height above the floor, and the offline
        # manifest spawn is the same point. No long fall either way.
        ground_y = ENGINE_DEFAULT_SPAWN_Y - float(spawn_height)
        gy = g0 if g0 is not None else sp0[1]
        origin_shift = np.array([-sp0[0], ground_y - gy, -sp0[2]])
        chunks = [(m, cell, pos + origin_shift.astype(np.float32), nrm, uv, idx)
                  for (m, cell, pos, nrm, uv, idx) in chunks]
        if verbose:
            print(f'[3/5] recentring: spawn ground -> y={ground_y:.2f} so the '
                  f'drone starts {spawn_height:.2f} m up '
                  f'(shift {origin_shift.round(2).tolist()})')

    if bake is not None:
        t_bake = time.time()
        pages = bake.render(exposure=bake_exposure, verbose=verbose)
        bake.build_materials(glb, pages, jpeg_q=jpeg_q)
        bake.stats['seconds'] = round(time.time() - t_bake, 1)
        if verbose:
            print(f'[3/5] lightmap bake: drew {bake.stats["tiles_drawn"]} tiles '
                  f'into {len(pages)} pages in {bake.stats["seconds"]}s '
                  f'(full light = {bake.stats["light_full"]}, '
                  f'brightness {bake.stats["brightness"]})')

    if verbose:
        print(f'[3/5] building {len(mats)} materials (albedo+normal+roughness)...')
    mat_idx = {}
    for i, m in enumerate(mats):
        if bake is not None and m in bake.materials:
            mat_idx[m] = bake.materials[m]          # an atlas page
        elif m.startswith('z_'):
            # a built-in name: ship it bare so the game swaps in its own PBR set
            mat_idx[m] = glb.material(m, roughness=0.9)
        else:
            mat_idx[m] = bank.get(m)
        if verbose and (i + 1) % 50 == 0:
            print(f'      {i + 1}/{len(mats)}')

    if verbose:
        print(f'[4/5] writing {len(chunks)} world meshes...')
    kids = []
    from .lightmap import MAT_PREFIX as _LM
    for m, cell, pos, nrm, uv, idx in chunks:
        nm = f'{slug(m)}_{cell[0]}_{cell[1]}_{cell[2]}'
        mid = mat_idx[m]
        if flat_normals is not None and m.startswith(_LM):
            # The pixel is ALBEDO * (DIFFUSE_LIGHT + AMBIENT), the game gives a
            # custom map almost no ambient, and DIFFUSE_LIGHT is Lambert - so a
            # wall facing away from the sun is BLACK however much light was
            # baked into its albedo. Point every baked normal the same way and
            # NdotL is the same everywhere: the surface then shows the bake,
            # which is what the official maps do by replacing DIFFUSE_LIGHT
            # with the lightmap outright.
            nrm = np.tile(np.asarray(flat_normals, np.float32),
                          (len(pos), 1)).astype(np.float32)
        if mid in bank.two_sided:
            pos, nrm, uv, idx = mirror_faces(pos, nrm, uv, idx)
            stats['two_sided_tris_added'] += len(idx) // 2
        mi = glb.mesh(nm, [(pos, nrm, uv, idx, mid)])
        kids.append(glb.node(nm, mesh=mi))

    prop_stats = {}
    skybox_expand = None
    carriers = BU.door_carriers(bsp, doors=doors, include_brush_ents=brush_ents)
    if verbose and carriers:
        print(f'[4/5] {len(carriers)} moved brush entities can carry props')
    if props:
        skyc = sky_camera(bsp)
        region = None
        if skyc is not None and play is not None and len(play) and not keep_3d_skybox:
            sky_g = BU.to_gltf(skyc[None, :], scale)[0] + origin_shift
            play_pts = BU.to_gltf(play, scale) + origin_shift

            def region(t, _s=sky_g, _p=play_pts, _b=sky_cut):
                return not in_3d_skybox(np.asarray(t, np.float64), _s, _p, _b)
            if expand_skybox:
                # placed, not dropped: the loop needs the pre-shift frame
                usky = BU.to_gltf(skyc[None, :], scale)[0]
                uplay = BU.to_gltf(play, scale)
                skybox_expand = (
                    (lambda t, _s=usky, _p=uplay, _b=sky_cut:
                     in_3d_skybox(np.asarray(t, np.float64), _s, _p, _b)),
                    usky, sky_factor,
                    (None if sky_ceiling is None
                     else sky_ceiling - float(origin_shift[1])))
                region = None
        if verbose:
            print('[4/5] placing static props...')
        pnodes, prop_stats = PB.add_props(glb, fs, bank, bsp, scale=scale,
                                          include_entities=prop_ents,
                                          keep_region=region,
                                          nonsolid=nonsolid_props,
                                          exclude=exclude_props,
                                          trim_cutouts=trim_cutouts,
                                          cutout_cell=cutout_cell,
                                          light_effects=light_effects,
                                          carriers=carriers,
                                          skybox_expand=skybox_expand,
                                          offset=origin_shift, verbose=verbose)
        kids += pnodes
        pf = prop_stats.get('model_failed', 0)
        pl = prop_stats.get('models', 0)
        lost = prop_stats.get('instances_lost', 0)
        if pf and pf > max(2, pl):
            msg = (f'{pf} prop models failed to load and only {pl} succeeded, '
                   f'losing {lost} placements.\n'
                   f'  The content roots are almost certainly wrong for this '
                   f'game:\n    ' + '\n    '.join(game_dirs or ['(none)']) +
                   '\n  Pass -g explicitly, or --game-dir "<the game folder>".')
            # This has now produced a silently empty map twice - once from
            # missing VPKs, once from a TF2 map detected as HL2 because TF2
            # ships an hl2/ folder. A warning was not enough: the run exited 0
            # and looked like a success.
            if require_content:
                raise SystemExit('FATAL: ' + msg)
            print('WARNING: ' + msg)
        if verbose:
            print(f"      {prop_stats.get('placed', 0)} props placed "
                  f"({prop_stats.get('models', 0)} unique models, "
                  f"{prop_stats.get('unique_tris', 0):,} unique tris, "
                  f"{prop_stats.get('placed_tris', 0):,} effective tris)")
    # 'src_' prefix keeps every imported material clear of the game's z_/builtin
    # name-substitution table.
    seen = {}
    dupes = 0
    for mm in glb.j['materials']:
        if mm['name'].startswith('z_'):
            continue        # built-in substitution matches on the exact name
        if not mm['name'].startswith('src_'):
            mm['name'] = 'src_' + slug(mm['name'])
        # The game caches converted materials by resource_name, so two glTF
        # materials sharing a name become ONE CustomMaterial in game and the
        # second one's textures are silently dropped. Keep every name unique.
        if mm['name'] in seen:
            seen[mm['name']] += 1
            mm['name'] = f"{mm['name']}_{seen[mm['name']]}"
            dupes += 1
        else:
            seen[mm['name']] = 0
    if dupes:
        stats['material_names_deduped'] = dupes
        if verbose:
            print(f'[4/5] {dupes} material names were duplicates and got '
                  f'suffixed (the game caches by name)')

    # an uploaded map has no manifest, so the game spawns facing -Z: turn the
    # whole map about the spawn (recentring put it on the Y axis) so the
    # chosen spawn's own facing is -Z (MF.spawn_turn)
    turn, turn_q = (MF.spawn_turn(MF.source_yaw_to_y_rotation(spawn_yaw))
                    if recenter and sp0 is not None else (0.0, None))
    root = glb.node(name, children=kids, rotation=turn_q if turn else None)
    glb.root(root)

    os.makedirs(out_dir, exist_ok=True)
    glb_path = os.path.join(out_dir, f'{name}.glb')
    size = glb.save(glb_path)

    # ---- manifest --------------------------------------------------------
    ws = bsp.worldspawn()
    le = next((e for e in bsp.entities
               if e.get('classname') == 'light_environment'), {})
    sun_yaw = None
    if le.get('angles'):
        try:
            sun_yaw = float(le['angles'].split()[1])
        except (IndexError, ValueError):
            pass
    # Source's _light brightness is on its own scale with no meaningful mapping
    # to Godot sun energy, and dividing by 800 just dimmed maps arbitrarily
    # (dust2's 700 -> 0.875). Use 1.0 and let --energy override.
    energy = float(sky_energy)

    spawn_ent = next((e for e in bsp.entities
                      if e.get('classname') in ('info_player_terrorist',
                                                'info_player_counterterrorist',
                                                'info_player_start')), None)
    if spawn_ent:
        so = np.array([float(x) for x in spawn_ent['origin'].split()[:3]])
        yaw = 0.0
        if spawn_ent.get('angles'):
            try:
                yaw = float(spawn_ent['angles'].split()[1])
            except (IndexError, ValueError):
                pass
    else:
        so = play.mean(axis=0) if play is not None and len(play) else np.zeros(3)
        yaw = 0.0
    if recenter:
        sp = np.array([0.0, ENGINE_DEFAULT_SPAWN_Y, 0.0])
        ground = ENGINE_DEFAULT_SPAWN_Y - float(spawn_height)
        if verbose:
            print(f'[5/5] spawn: (0, {ENGINE_DEFAULT_SPAWN_Y}, 0), floor at '
                  f'y={ground:.2f} -> {spawn_height:.2f} m drop, offline == uploaded')
    else:
        sp = BU.to_gltf(so[None, :], scale)[0].astype(float)
        ground = floor_below(chunks, sp[0], sp[2], sp[1])
        if ground is not None:
            sp[1] = ground + spawn_height
        else:
            sp[1] += spawn_height
        if verbose:
            print(f'[5/5] spawn: y={sp[1]:.2f}')

    man = MF.build(spawn_pos=sp,
                   spawn_yaw_rad=0.0 if recenter else MF.source_yaw_to_y_rotation(yaw),
                   skyname=ws.get('skyname'), sun_yaw=sun_yaw,
                   sun_offset=sun_offset, energy=energy,
                   variations=list(variations), turn_deg=math.degrees(turn))
    MF.write(os.path.join(out_dir, 'manifest.json'), man)

    rep = {
        'map': mapname, 'name': name, 'bsp_version': int(bsp.version),
        'scale_m_per_unit': scale, 'triangles': int(tris),
        'meshes': len(chunks), 'materials': len(glb.j['materials']),
        'world_materials': len(mats), 'props': prop_stats,
        'total_effective_tris': int(tris) + int(prop_stats.get('placed_tris', 0)),
        'glb_bytes': size, 'geometry_stats': dict(stats),
        'skyname': ws.get('skyname'), 'sun_yaw': sun_yaw,
        'sun_energy': round(energy, 3), 'manifest': man,
        'spawn_ground': ground, 'origin_shift': origin_shift.tolist(),
        'map_turn_deg': round(math.degrees(turn), 2),
        'spawn_clearance_m': round(float(clear0), 2) if sp0 is not None else None,
        'lightmap_bake': (dict(bake.stats) if bake is not None else None),
        'materials_detail': bank.report,
        'seconds': round(time.time() - t0, 1),
    }
    with open(os.path.join(out_dir, 'convert_report.json'), 'w') as f:
        json.dump(rep, f, indent=1)
    if verbose:
        print(f'[5/5] {glb_path}  {size/1e6:.1f} MB  in {rep["seconds"]}s')
    return rep
