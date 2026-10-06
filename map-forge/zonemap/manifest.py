"""Build The Zone's custom-map manifest.json.

Schema (reverse-engineered from maps2/maps/*/manifest.json and the game's
custommaps/handler/custom_map_root.gd):

  spawn_point        vec9  [px,py,pz, rx,ry,rz (radians), sx,sy,sz]
  skybox             {skybox_name, sky_rotation (deg), energy}
  lighting_variations {name: {skybox: {...}}}   -- one is chosen at load
  assets             [{type, custom_type, transform(vec9)}]
"""
import math, json

SKYBOXES = ['sunny', 'cloudy_sunny', 'dawn', 'sunset', 'industrial_sunset']

# Source skyname -> nearest Zone skybox
SKY_MAP = {
    'tides': 'cloudy_sunny', 'sky_day01_01': 'sunny', 'sky_day01_04': 'cloudy_sunny',
    'sky_day01_05': 'cloudy_sunny', 'sky_day02_01': 'sunny', 'sky_day02_05': 'sunny',
    'sky_day03_01': 'cloudy_sunny', 'sky_dust': 'sunny', 'dust': 'sunny',
    'italy': 'sunny', 'cs_italy': 'sunny', 'office': 'cloudy_sunny',
    'sky_borealis01': 'dawn', 'sky_wasteland02': 'industrial_sunset',
    'sky_urb01': 'industrial_sunset', 'sky_urb03': 'industrial_sunset',
    'militia': 'cloudy_sunny', 'havana': 'sunny', 'prodigy': 'industrial_sunset',
    'nukeblank': 'cloudy_sunny', 'sky_l4d_rural02_hdr': 'sunset',
    # --- Team Fortress 2 -------------------------------------------------
    'sky_tf2_04': 'cloudy_sunny', 'sky_gravel_01': 'sunny',
    'sky_granary_01': 'sunny', 'sky_well_01': 'sunny',
    'sky_dustbowl_01': 'sunny', 'sky_badlands_01': 'sunny',
    'sky_goldrush_01': 'sunny', 'sky_island_01': 'sunny',
    'sky_rainbow_01': 'sunny', 'sky_hydro_01': 'cloudy_sunny',
    'sky_trainyard_01': 'cloudy_sunny', 'sky_coastal_01': 'cloudy_sunny',
    'sky_harvest_01': 'cloudy_sunny', 'sky_alpinestorm_01': 'cloudy_sunny',
    'sky_stormfront_01': 'cloudy_sunny', 'sky_morningsnow_01': 'cloudy_sunny',
    'sky_upward': 'sunset', 'sky_nightfall_01': 'dawn',
    'sky_harvest_night_01': 'dawn', 'sky_halloween': 'dawn',
    'sky_halloween_night_01': 'dawn', 'sky_night_01': 'dawn',
}


def source_yaw_to_sky_rotation(yaw_deg, offset=0.0):
    """Source sun azimuth (CCW from +X) -> Zone sky_rotation in degrees."""
    return ((90.0 - float(yaw_deg) + offset) + 180.0) % 360.0 - 180.0


def source_yaw_to_y_rotation(yaw_deg):
    """Source entity yaw -> Godot/glTF Y rotation in radians."""
    t = math.radians(float(yaw_deg))
    return math.atan2(-math.cos(t), math.sin(t))


def wrap_deg(a):
    return ((float(a) + 180.0) % 360.0) - 180.0


def spawn_turn(face_rad):
    """The map's rotation about the vertical axis through the spawn that
    makes the spawn's facing the game's default.

    An uploaded map is ONLY its .glb (custom_map_upload.gd sends that file and
    nothing else), so other players never see manifest.json: they spawn at
    (0, 10, 0) with an identity basis, facing -Z. Recentring already puts the
    spawn at that point; turning the whole map by -face puts the original
    facing on -Z too, and the manifest then carries no rotation, so a local
    test starts exactly where an uploaded copy does.

    face_rad: the spawn's Godot Y rotation (what spawn_point[4] used to hold).
    -> (turn_rad, glTF quaternion [x, y, z, w] for the root node)"""
    t = -float(face_rad)
    t = math.atan2(math.sin(t), math.cos(t))
    return t, [0.0, math.sin(t / 2.0), 0.0, math.cos(t / 2.0)]


def vec9(pos, rot=(0, 0, 0), scale=(1, 1, 1)):
    return [float(pos[0]), float(pos[1]), float(pos[2]),
            float(rot[0]), float(rot[1]), float(rot[2]),
            float(scale[0]), float(scale[1]), float(scale[2])]


def build(spawn_pos, spawn_yaw_rad=0.0, skyname=None, sun_yaw=None,
          sun_offset=0.0, energy=1.0, variations=None, assets=None, turn_deg=0.0):
    """Assemble the manifest.

    NOTE on `variations`: the game picks one lighting variation AT RANDOM on
    load (custom_map_root -> randi_range over the keys). So never add a
    variation the map did not ask for - an invented 'industrial_sunset' at
    energy 0.3 makes half your loads three times darker than the original for
    no reason. Default is the single sky that matches worldspawn.skyname.
    """
    primary = SKY_MAP.get((skyname or '').lower(), 'cloudy_sunny')
    rot = source_yaw_to_sky_rotation(sun_yaw, sun_offset) if sun_yaw is not None else 0.0
    # the sky turns with the map (spawn_turn), so the sun keeps its bearing
    rot = wrap_deg(rot + turn_deg)
    sky = {'skybox_name': primary, 'sky_rotation': round(rot, 2),
           'energy': round(energy, 3)}

    names = [primary] + [v for v in (variations or []) if v != primary]
    lv = {}
    for name in dict.fromkeys(names):
        lv[name] = {'skybox': {'skybox_name': name,
                               'sky_rotation': round(rot, 2),
                               'energy': round(energy, 3)}}

    return {
        'spawn_point': vec9(spawn_pos, (0.0, spawn_yaw_rad, 0.0)),
        'skybox': sky,
        'lighting_variations': lv,
        'assets': assets or [],
    }


def write(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=1)
