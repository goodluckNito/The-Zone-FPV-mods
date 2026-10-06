"""Probe: does the custom-map loader look for lightmaps, and WHERE?

The Zone names lightmapped nodes '<10-char-id>_zlms-<size>' and loads
'<id>_zlms-<size>_comb.dds' from a baked_<skybox>_<quality>/ folder. This map
names its nodes that way and ships NO dds files, so the loader should complain
- and the complaint names the path it wanted.

Watch the log at:
  %APPDATA%/Godot/app_userdata/The Zone/logs/godot.log
for 'No shadowmap:' / 'cannot open' lines, and a non-zero "shadow_maps" time.
"""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from zonemap.glb import Glb
from zonemap import manifest as MF


def box(cx, cy, cz, sx, sy, sz):
    s = np.array([sx, sy, sz], np.float64) / 2.0
    c = np.array([cx, cy, cz], np.float64)
    v = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)],
                 np.float64) * s + c
    F = [((0, 1, 3, 2), (-1, 0, 0)), ((4, 6, 7, 5), (1, 0, 0)),
         ((0, 4, 5, 1), (0, -1, 0)), ((2, 3, 7, 6), (0, 1, 0)),
         ((0, 2, 6, 4), (0, 0, -1)), ((1, 5, 7, 3), (0, 0, 1))]
    P, N, U, U2, I = [], [], [], [], []
    for fi, (idx, n) in enumerate(F):
        q = v[list(idx)]
        base = len(P)
        P += list(q); N += [n] * 4
        U += [(0, 0), (1, 0), (1, 1), (0, 1)]
        # each face gets its own cell of a 3x2 lightmap atlas, 0-1 with padding
        gx, gy = fi % 3, fi // 3
        x0, y0 = gx / 3 + 0.01, gy / 2 + 0.01
        x1, y1 = (gx + 1) / 3 - 0.01, (gy + 1) / 2 - 0.01
        U2 += [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        I += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
    return (np.array(P, np.float32), np.array(N, np.float32),
            np.array(U, np.float32), np.array(U2, np.float32),
            np.array(I, np.uint32))


def main(out_dir):
    g = Glb(generator='zone-map-forge lightmap probe')
    m_floor = g.material('z_clean-concrete', roughness=0.9)
    m_box = g.material('z_brick-wall', roughness=0.9)
    kids = []

    def add(name, geom, mat):
        p, n, u, u2, i = geom
        kids.append(g.node(name, mesh=g.mesh(name, [(p, n, u, i, mat, u2)])))

    # names follow the engine's convention: <10 letters>_zlms-<size>
    add('AAAAAAAAAA_zlms-256', box(0, -0.25, 0, 60, 0.5, 24), m_floor)
    add('BBBBBBBBBB_zlms-256', box(-12, 2, 0, 4, 4, 4), m_box)
    add('CCCCCCCCCC_zlms-512', box(0, 2, 0, 4, 4, 4), m_box)
    add('DDDDDDDDDD_zlms-1024', box(12, 2, 0, 4, 4, 4), m_box)

    g.root(g.node('lightmap_probe', children=kids))
    os.makedirs(out_dir, exist_ok=True)
    size = g.save(os.path.join(out_dir, 'lightmap_probe.glb'))
    MF.write(os.path.join(out_dir, 'manifest.json'),
             MF.build(spawn_pos=(0.0, 1.6, 14.0), skyname='sky_day01_01',
                      sun_yaw=45.0, energy=1.0))
    print(f'{out_dir}/lightmap_probe.glb  {size/1024:.0f} KB')
    print('nodes:', [n['name'] for n in g.j['nodes'] if n['name'] != 'lightmap_probe'])


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else './out/lightmap_probe')
