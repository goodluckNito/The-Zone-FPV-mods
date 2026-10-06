"""Probe: what do metallic and roughness actually do in The Zone?

v4. Every earlier version measured something real and then lost it to an
identification problem, so this one makes each plate label itself.

v1 - one grid of cubes, shot from above. Only ever showed SUNLIT faces.
v2 - added a roofed grid to get a shaded case. Wasted: THE GAME CASTS NO
     DIRECTIONAL SHADOWS for custom maps, so a roof blocks nothing. Its index
     markers used `z_clean-concrete`, which renders flat black on 0.5-1 m
     geometry and was unreadable.
v3 - dropped occlusion entirely. With no shadow casting, a surface's normal
     against the sun is the only thing that varies its direct light, so a
     plate facing straight DOWN gets none. Ground grid = sun reference,
     canopy grid = ambient only. That worked, and gave:

  SUNLIT plate tops (median luminance 0-255, axes identified from v1's markers):

              metallic 0.00  0.15  0.35  0.60  0.85
    roughness 0.95      93   106   131   155   160
    roughness 0.75     146   145   160   173   177
    roughness 0.55     172   177   181   188   189
    roughness 0.35     206   193   187   194   201
    roughness 0.15     219   214   205   201   204

  CANOPY undersides, ambient only - three clean rows out of the five:

    flat row    38  36  35  38   ...
    steep row   59  44  36  30  31
    steep row   71  47  36  29  25

     So an unlit surface is 3-8x darker than a lit one, AND material choice
     still swings it ~2.9x. Both matter. But v3's edge-of-grid marker walls
     were not readable in the canopy shot, so WHICH axis produces that 2.9x
     is unresolved - and it decides whether the fix is metallic or roughness.

v4 - each plate carries its own coordinates, so no screenshot can be
     misread:

         METALLIC  index = number of CUBES   along the plate's west edge (1-5)
         ROUGHNESS index = number of POSTS   along the plate's south edge (1-5)

     Cubes are squat, posts are tall and thin; they are never confusable, and
     both are attached to the plate's VISIBLE side (above the ground grid,
     below the canopy) so they read in the same shot as the plate.

     Count cubes -> metallic = [0.00, 0.15, 0.35, 0.60, 0.85][cubes - 1]
     Count posts -> roughness = [0.15, 0.35, 0.55, 0.75, 0.95][posts - 1]

Labels use our own material, never a `z_` builtin, for the reason v2 found.
"""
import sys, os, json, io, numpy as np
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from zonemap.glb import Glb

METALLIC = [0.00, 0.15, 0.35, 0.60, 0.85]
ROUGHNESS = [0.15, 0.35, 0.55, 0.75, 0.95]
PITCH = 8.0
PLATE = 5.0
THICK = 0.4
CANOPY_Y = 5.0
GAP = 64.0


def box(centre, size):
    """Axis-aligned box, counter-clockwise from outside (front faces out)."""
    s = np.asarray(size, np.float64) / 2.0
    c = np.asarray(centre, np.float64)
    v = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)],
                 np.float64) * s + c
    F = [((0, 1, 3, 2), (-1, 0, 0)), ((4, 6, 7, 5), (1, 0, 0)),
         ((0, 4, 5, 1), (0, -1, 0)), ((2, 3, 7, 6), (0, 1, 0)),
         ((0, 2, 6, 4), (0, 0, -1)), ((1, 5, 7, 3), (0, 0, 1))]
    P, N, U, I = [], [], [], []
    for idx, n in F:
        q = v[list(idx)]
        b = len(P)
        P += list(q); N += [n] * 4
        U += [(0, 0), (1, 0), (1, 1), (0, 1)]
        I += [(b, b + 1, b + 2), (b, b + 2, b + 3)]
    return (np.array(P, np.float32), np.array(N, np.float32),
            np.array(U, np.float32), np.array(I, np.uint32))


def checker(px=256, cells=6, light=(206, 198, 184), dark=(142, 135, 122)):
    """A flat mid-grey checker. Deliberately not game art: a neutral mid tone
    makes a brightness change between plates obvious, and the checker gives the
    eye an edge to judge a specular highlight against."""
    yy, xx = np.mgrid[0:px, 0:px]
    m = (((xx * cells) // px + (yy * cells) // px) % 2).astype(bool)
    img = np.zeros((px, px, 3), np.uint8)
    img[m] = light
    img[~m] = dark
    return img


def main(out_dir):
    from PIL import Image
    g = Glb(generator='zone-map-forge metallic/roughness probe v4')

    buf = io.BytesIO()
    Image.fromarray(checker()).save(buf, 'PNG', optimize=True)
    tex = g.image(buf.getvalue(), 'probe_checker')

    pad = g.material('z_clean-concrete', roughness=0.9)
    # Labels and pillars use OUR material: a z_ builtin on small geometry
    # renders flat black (v2), which made its markers useless.
    plain = g.material('src_probe_label', albedo_tex=tex,
                       roughness=0.6, metallic=0.0)
    kids = []

    def add(name, geom, mat):
        p, n, u, i = geom
        kids.append(g.node(name, mesh=g.mesh(name, [(p, n, u, i, mat)])))

    mats = {}
    for met in METALLIC:
        for rough in ROUGHNESS:
            mats[(met, rough)] = g.material(
                f'src_probe_m{int(met * 100):02d}_r{int(rough * 100):02d}',
                albedo_tex=tex, roughness=rough, metallic=met)

    span = PITCH * 4

    def grid(tag, ox, y, side):
        """side = +1 labels above the plate, -1 labels below it."""
        x0, z0 = ox - span / 2.0, -span / 2.0
        for ci, met in enumerate(METALLIC):
            x = x0 + ci * PITCH
            for ri, rough in enumerate(ROUGHNESS):
                z = z0 + ri * PITCH
                add(f'{tag}_plate_m{ci}_r{ri}',
                    box((x, y, z), (PLATE, THICK, PLATE)), mats[(met, rough)])
                # METALLIC: (ci+1) squat cubes along the west edge, spread in z
                for k in range(ci + 1):
                    cz = z - PLATE / 2 + 0.9 + k * 0.85
                    add(f'{tag}_m{ci}_r{ri}_cube{k}',
                        box((x - PLATE / 2 + 0.55,
                             y + side * (THICK / 2 + 0.3), cz),
                            (0.6, 0.6, 0.6)), plain)
                # ROUGHNESS: (ri+1) tall thin posts along the south edge, in x
                for k in range(ri + 1):
                    px_ = x - PLATE / 2 + 1.5 + k * 0.85
                    add(f'{tag}_m{ci}_r{ri}_post{k}',
                        box((px_, y + side * (THICK / 2 + 0.85),
                             z - PLATE / 2 + 0.45),
                            (0.22, 1.7, 0.22)), plain)

    grid('up', 0.0, THICK / 2 + 0.05, +1)           # faces the sky
    grid('down', GAP, CANOPY_Y + THICK / 2, -1)     # faces the ground

    add('pad', box((GAP / 2.0, -0.5, 0),
                   (span + GAP + 30, 1.0, span + 26)), pad)

    # pillars well outside the canopy grid (nothing shades anything here anyway)
    r = span / 2 + 6
    for sx in (-1, 1):
        for sz in (-1, 1):
            add(f'down_pillar_{sx}_{sz}',
                box((GAP + sx * r, CANOPY_Y / 2, sz * r),
                    (1.2, CANOPY_Y, 1.2)), plain)

    g.root(g.node('probe', children=kids))
    os.makedirs(out_dir, exist_ok=True)
    glb = os.path.join(out_dir, 'material_probe.glb')
    n = g.save(glb)

    man = {'spawn_point': [0.0, 10.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
           'skybox': {'skybox_name': 'cloudy_sunny',
                      'sky_rotation': 45.0, 'energy': 1.0},
           'lighting_variations': {
               'cloudy_sunny': {'skybox': {'skybox_name': 'cloudy_sunny',
                                           'sky_rotation': 45.0,
                                           'energy': 1.0}}},
           'assets': []}
    with open(os.path.join(out_dir, 'manifest.json'), 'w') as f:
        json.dump(man, f, indent=1)

    print(f'{glb}  {n:,} bytes   {len(mats)} materials, 2 x 25 self-labelled plates')
    print(f'  GRID UP    x ~ 0     plates face the sky    (sun + ambient)')
    print(f'  GRID DOWN  x ~ {GAP:.0f}    canopy at y={CANOPY_Y:.0f}, faces the '
          f'ground (ambient only)')
    print(f'  per plate: CUBES along one edge = metallic index  {METALLIC}')
    print(f'             POSTS along the other = roughness index {ROUGHNESS}')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else './out/material_probe')
