"""Tiny diagnostic map: does a '-collider' mesh REPLACE The Zone's automatic
per-mesh trimesh collider, or only add to it?

Three stations on a runway, 15 m apart, all visually identical 4 m cubes:

  A  (left,  rust)   'boxA'                      - control, plain mesh
  B  (mid,   brick)  'boxB' + 'boxB-collider'    - visible 4 m shell, 1 m core
  C  (right, gold)   'boxC-collider' only        - no visible sibling

Fly into each at chest height:
  B stops at the big shell  -> auto-collision still applies, '-collider' ADDS.
  B lets you inside, stops  -> '-collider' REPLACES. Foliage can get real
    at a small core             colliders and we can cut the phantom panes.
  C invisible but solid     -> '-collider' meshes are hidden and collidable.
  C invisible and passable  -> they are visual-only.
"""
import sys, os, json, numpy as np
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from zonemap.glb import Glb
from zonemap import manifest as MF


def box(cx, cy, cz, sx, sy, sz):
    s = np.array([sx, sy, sz], np.float64) / 2.0
    c = np.array([cx, cy, cz], np.float64)
    # 8 corners
    v = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)],
                 np.float64) * s + c
    # faces as (indices, normal), CCW seen from outside
    F = [((0, 1, 3, 2), (-1, 0, 0)), ((4, 6, 7, 5), (1, 0, 0)),
         ((0, 4, 5, 1), (0, -1, 0)), ((2, 3, 7, 6), (0, 1, 0)),
         ((0, 2, 6, 4), (0, 0, -1)), ((1, 5, 7, 3), (0, 0, 1))]
    P, N, U, I = [], [], [], []
    for idx, n in F:
        q = v[list(idx)]
        base = len(P)
        P += list(q)
        N += [n] * 4
        U += [(0, 0), (1, 0), (1, 1), (0, 1)]
        I += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
    return (np.array(P, np.float32), np.array(N, np.float32),
            np.array(U, np.float32), np.array(I, np.uint32))


def main(out_dir):
    g = Glb(generator='zone-map-forge collider probe')
    m_floor = g.material('z_clean-concrete', roughness=0.9)
    m_a = g.material('z_rusted-steel', roughness=0.6)
    m_b = g.material('z_brick-wall', roughness=0.9)
    m_c = g.material('z_gold-nugget1', roughness=0.35)

    kids = []

    def add(name, geom, mat):
        p, n, u, i = geom
        kids.append(g.node(name, mesh=g.mesh(name, [(p, n, u, i, mat)])))

    add('runway', box(0, -0.25, 0, 70, 0.5, 24), m_floor)
    add('boxA', box(-15, 2, 0, 4, 4, 4), m_a)              # control
    add('boxB', box(0, 2, 0, 4, 4, 4), m_b)                # visible shell
    add('boxB-collider', box(0, 2, 0, 1, 1, 1), m_b)       # 1 m core
    add('boxC-collider', box(15, 2, 0, 4, 4, 4), m_c)      # no visible sibling

    g.root(g.node('collider_probe', children=kids))
    os.makedirs(out_dir, exist_ok=True)
    size = g.save(os.path.join(out_dir, 'collider_probe.glb'))

    man = MF.build(spawn_pos=(-15.0, 1.6, 14.0), spawn_yaw_rad=0.0,
                   skyname='sky_day01_01', sun_yaw=45.0, energy=1.0)
    MF.write(os.path.join(out_dir, 'manifest.json'), man)
    print(f'{out_dir}/collider_probe.glb  {size/1024:.0f} KB')
    print('stations at x = -15 (A control), 0 (B shell+core), +15 (C collider-only)')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else './out/collider_probe')
