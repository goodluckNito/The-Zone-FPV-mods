"""Probe: where do the floating light blobs come from?

A custom map is lit by env_dynamic - three DirectionalLight3Ds and an
unoccluded sky - and the game's shader adds SPECULAR_LIGHT on top of
ALBEDO * (DIFFUSE_LIGHT + AMBIENT_LIGHT). Specular is ADDITIVE and does not
care what the albedo holds, so a baked map whose albedo is nearly black in a
dark room still shows every specular lobe. With --flat-normals the whole map
shares ONE normal, so each light's lobe stops being a per-face highlight and
becomes a single map-wide gradient: a soft glow that slides across walls,
floors and ceilings alike and reads as a light source shining through the
geometry.

Every panel here has a PURE BLACK albedo. Whatever you can see is specular,
full stop. Panels are numbered by the posts at their base, left to right.

  1  roughness 1.0  metallic 0  flat normal, flat normal map   <- what ships now
  2  roughness 1.0  metallic 0  flat normal, NOISE normal map  <- breaks the lobe up
  3  roughness 1.0  metallic 1  flat normal                    <- f0 = albedo = black
  4  roughness 2.0  metallic 0  flat normal                    <- does >1 survive import?
  5  roughness 1.0  metallic 0  REAL face normal               <- per-face, for contrast
  6  roughness 1.0  metallic 0  normal straight DOWN           <- N.L <= 0 for all 3 suns
  7  roughness 0.2  metallic 0  flat normal                    <- positive control, must glow
  8  WHITE albedo   roughness 1.0                              <- exposure reference

Read it as: any panel that stays black is a cure. Panel 7 proves the probe
works; panel 8 says how bright "fully lit" is on your screen right now.
"""
import io, json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from zonemap.glb import Glb
from zonemap.lightmap import ZONE_FLAT_NORMAL

W, H, GAP = 6.0, 5.0, 2.5
FLAT = np.array(ZONE_FLAT_NORMAL, np.float32)


def quad(cx, y0, z, w, h, normal):
    """Vertical quad facing +Z, with an explicit shading normal."""
    P = np.array([[cx - w / 2, y0, z], [cx + w / 2, y0, z],
                  [cx + w / 2, y0 + h, z], [cx - w / 2, y0 + h, z]], np.float32)
    N = np.tile(np.asarray(normal, np.float32), (4, 1))
    U = np.array([[0, 1], [1, 1], [1, 0], [0, 0]], np.float32)
    I = np.array([[0, 1, 2], [0, 2, 3]], np.uint32)
    return P, N, U, I


def box(centre, size, normal=None):
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
        P += list(q)
        N += [normal if normal is not None else n] * 4
        U += [(0, 0), (1, 0), (1, 1), (0, 1)]
        I += [(b, b + 1, b + 2), (b, b + 2, b + 3)]
    return (np.array(P, np.float32), np.array(N, np.float32),
            np.array(U, np.float32), np.array(I, np.uint32))


def noise_normal(px=512, strength=0.55, seed=7):
    """High-frequency tangent-space noise. Perturbing the normal per texel is
    the one legitimate way to widen a specular lobe past roughness 1."""
    r = np.random.default_rng(seed)
    n = r.normal(0.0, strength, (px, px, 2))
    z = np.ones((px, px, 1))
    v = np.concatenate([n, z], 2)
    v /= np.linalg.norm(v, axis=2, keepdims=True)
    return ((v * 0.5 + 0.5) * 255).astype(np.uint8)


def flat_normal(px=4):
    a = np.zeros((px, px, 3), np.uint8)
    a[:, :, 0] = 128; a[:, :, 1] = 128; a[:, :, 2] = 255
    return a


def main(out_dir):
    from PIL import Image
    g = Glb(generator='zone-map-forge specular probe')

    def png(a):
        b = io.BytesIO(); Image.fromarray(a).save(b, 'PNG', optimize=True)
        return b.getvalue()

    nflat = g.image(png(flat_normal()), 'probe_nflat')
    nnoise = g.image(png(noise_normal()), 'probe_nnoise')

    BLACK = (0.0, 0.0, 0.0, 1.0)
    cfg = [
        ('r100_m0_flat',   1.0, 0.0, FLAT,                   nflat,  BLACK),
        ('r100_m0_noise',  1.0, 0.0, FLAT,                   nnoise, BLACK),
        ('r100_m1_flat',   1.0, 1.0, FLAT,                   nflat,  BLACK),
        ('r200_m0_flat',   2.0, 0.0, FLAT,                   nflat,  BLACK),
        ('r100_m0_real',   1.0, 0.0, (0.0, 0.0, 1.0),        nflat,  BLACK),
        ('r100_m0_down',   1.0, 0.0, (0.0, -1.0, 0.0),       nflat,  BLACK),
        ('r020_m0_flat',   0.2, 0.0, FLAT,                   nflat,  BLACK),
        ('white_ref',      1.0, 0.0, FLAT,                   nflat,  (1, 1, 1, 1)),
    ]
    kids = []

    def add(name, geom, mat):
        p, n, u, i = geom
        kids.append(g.node(name, mesh=g.mesh(name, [(p, n, u, i, mat)])))

    post = g.material('src_probe_post', roughness=0.35, metallic=0.0,
                      base_color=(0.85, 0.82, 0.70, 1))
    ground = g.material('src_probe_ground', roughness=1.0, metallic=0.0,
                        base_color=(0.06, 0.06, 0.06, 1))

    span = (len(cfg) - 1) * (W + GAP)
    for i, (tag, rough, metal, nrm, ntex, col) in enumerate(cfg):
        cx = -span / 2 + i * (W + GAP)
        m = g.material(f'src_probe_{i + 1}_{tag}', normal_tex=ntex,
                       roughness=rough, metallic=metal, base_color=col)
        add(f'panel{i + 1}', quad(cx, 0.4, 0.0, W, H, nrm), m)
        for k in range(i + 1):
            px = cx - W / 2 + 0.45 + k * 0.62
            add(f'post{i + 1}_{k}', box((px, 0.9, 1.6), (0.22, 1.8, 0.22)), post)

    add('ground', box((0, -0.5, 14.0), (span + 30, 1.0, 60.0)), ground)

    g.root(g.node('specprobe', children=kids))
    os.makedirs(out_dir, exist_ok=True)
    name = os.path.basename(out_dir.rstrip('/\\'))
    glb = os.path.join(out_dir, f'{name}.glb')
    n = g.save(glb)
    man = {'spawn_point': [0.0, 3.0, 26.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
           'skybox': {'skybox_name': 'cloudy_sunny', 'sky_rotation': 0.0,
                      'energy': 1.0},
           'lighting_variations': {'cloudy_sunny': {
               'skybox': {'skybox_name': 'cloudy_sunny', 'sky_rotation': 0.0,
                          'energy': 1.0}}},
           'assets': []}
    with open(os.path.join(out_dir, 'manifest.json'), 'w') as f:
        json.dump(man, f, indent=1)
    print(f'{glb}  {n:,} bytes')
    for i, (tag, rough, metal, nrm, ntex, col) in enumerate(cfg):
        print(f'  panel {i + 1} ({i + 1} post{"s" if i else " "}): {tag}')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else './out/specprobe')
