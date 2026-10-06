"""Source light entities, converted to something Blender can light a scene with.

Valve's radiosity is baked into the .bsp, but the *lights* that produced it are
still in the entity lump, and they are what a Cycles bake needs. Three classes
carry a map's lighting:

    light              a point light          `_light` "R G B brightness"
    light_spot         a cone                 + `_cone`, `_inner_cone`, `pitch`
    light_environment  the sun plus sky       + `_ambient`

`_light` is four numbers: an 0-255 colour and a brightness. HDR maps often
carry a second set in `_lightHDR` with a multiplier in `_lightscaleHDR`, and
where that is present it is the one VRAD actually used.

Units. Source gives a point light irradiance `B / d^2` with d in Hammer units,
and a light_environment irradiance `B` flat. Blender gives a point light
`P / (4*pi*d^2)` with d in metres and a sun its strength directly. Matching
the two at the same physical distance:

    P_watts   = 4*pi * (0.0254^2) * B  =  0.0081 * B
    sun_W_m2  = B

so the two families stay in the same relative balance, which is what matters -
a global factor cancels when the baked light is normalised.

What is NOT here: texture lights. Source's `lights.rad` turns named materials
into emitters, and that file is not in the .bsp. Materials that carry
`$selfillum` do come through as glTF `emissiveFactor`, and the Blender side
turns those into emission shaders, which covers most lamps and light panels.
"""
import math
import numpy as np

UNIT = 0.0254
# VRAD normalises a point light at 100 units, so its irradiance is
# B * 100^2 / d^2 with d in units, not B / d^2. Missing that factor of 10,000
# made every lamp 75,000 times weaker than the sun instead of 8 times, and a
# Cycles bake of de_cpl_strike came back binary: sunlit faces clipped, every
# interior at zero, and the 65 lights it had carefully rebuilt invisible.
VRAD_UNIT_REF = 100.0
POINT_W_PER_B = 4.0 * math.pi * UNIT * UNIT * VRAD_UNIT_REF ** 2   # 81.07


def _nums(v, n=4, default=(255.0, 255.0, 255.0, 200.0)):
    try:
        p = [float(x) for x in str(v).replace('"', ' ').split()]
    except ValueError:
        return list(default[:n])
    while len(p) < n:
        p.append(default[len(p)] if len(p) > len(default) - 1 else default[len(p)])
    return p[:n]


def _light_value(ent):
    """-> (rgb 0-1, brightness), preferring the HDR pair when the map has one."""
    raw = ent.get('_light', '255 255 255 200')
    hdr = ent.get('_lightHDR')
    scale = 1.0
    if hdr and not str(hdr).startswith('-1'):
        raw = hdr
        try:
            scale = float(ent.get('_lightscaleHDR', 1.0) or 1.0)
        except ValueError:
            scale = 1.0
    r, g, b, br = _nums(raw)
    mx = max(r, g, b, 1e-6)
    return (r / mx, g / mx, b / mx), br * (mx / 255.0) * scale


def _direction(ent):
    """Source pitch/yaw -> a unit vector in Hammer space."""
    try:
        ang = [float(x) for x in str(ent.get('angles', '0 0 0')).split()[:3]]
    except ValueError:
        ang = [0.0, 0.0, 0.0]
    while len(ang) < 3:
        ang.append(0.0)
    pitch = ang[0]
    if ent.get('pitch') not in (None, ''):
        try:
            pitch = float(ent['pitch'])
        except ValueError:
            pass
    # Source: positive pitch points UP, and the entity's own `pitch` key wins
    p = math.radians(pitch)
    y = math.radians(ang[1])
    return np.array([math.cos(p) * math.cos(y),
                     math.cos(p) * math.sin(y),
                     math.sin(p)], np.float64)


def collect(bsp, scale=UNIT, shift=(0.0, 0.0, 0.0), point_scale=1.0,
            sun_scale=1.0):
    """-> (lights, environment). Positions are in glTF space (metres, Y-up)."""
    shift = np.asarray(shift, np.float64)

    def to_glb(p):
        return np.array([p[0], p[2], -p[1]], np.float64) * scale + shift

    def dir_glb(d):
        return np.array([d[0], d[2], -d[1]], np.float64)

    out, env = [], None
    for e in bsp.entities:
        cn = str(e.get('classname', '')).lower()
        if cn not in ('light', 'light_spot', 'light_environment'):
            continue
        rgb, br = _light_value(e)
        if br <= 0:
            continue
        if cn == 'light_environment':
            amb_rgb, amb = (1.0, 1.0, 1.0), 0.0
            # the HDR pair uses "-1 -1 -1 1" to mean "not set", and that
            # sentinel has to be honoured here too - read as a colour it comes
            # out as -1000000 and the sky's fill silently becomes zero
            a_raw = e.get('_ambientHDR')
            if not a_raw or str(a_raw).strip().startswith('-1'):
                a_raw = e.get('_ambient')
            if a_raw and not str(a_raw).strip().startswith('-1'):
                a = dict(e)
                a['_light'] = a_raw
                a['_lightHDR'] = None
                amb_rgb, amb = _light_value(a)
                if e.get('_ambientHDR') and a_raw is e.get('_ambientHDR'):
                    try:
                        amb *= float(e.get('_AmbientScaleHDR', 1.0) or 1.0)
                    except ValueError:
                        pass
            amb = max(amb, 0.0)
            env = {'type': 'sun',
                   'dir': dir_glb(_direction(e)).tolist(),
                   'color': list(rgb),
                   'energy': br * sun_scale,
                   'ambient_color': list(amb_rgb),
                   'ambient': amb * sun_scale,
                   'angle': 2.0}
            continue
        try:
            o = [float(x) for x in str(e.get('origin', '0 0 0')).split()[:3]]
        except ValueError:
            continue
        rec = {'type': 'point', 'pos': to_glb(o).tolist(), 'color': list(rgb),
               'energy': br * POINT_W_PER_B * point_scale,
               'radius': 0.05}
        if cn == 'light_spot':
            try:
                cone = float(e.get('_cone', 45) or 45)
                inner = float(e.get('_inner_cone', cone * 0.6) or cone * 0.6)
            except ValueError:
                cone, inner = 45.0, 27.0
            cone = max(1.0, min(89.0, cone))
            inner = max(0.0, min(cone, inner))
            rec['type'] = 'spot'
            rec['dir'] = dir_glb(_direction(e)).tolist()
            rec['cone'] = cone
            rec['blend'] = 1.0 - (inner / cone if cone else 0.0)
            # a spot pushes its whole output through a cone, so it reads much
            # brighter than a point of the same brightness in Source too
            rec['energy'] *= 1.0
        out.append(rec)
    return out, env
