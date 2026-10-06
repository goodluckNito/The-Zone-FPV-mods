"""Runs INSIDE Blender: bakes irradiance into one atlas page per image.

    blender -b -P tools/bake_cycles_blender.py -- scene.glb lights.json outdir
            [--samples 128] [--device GPU] [--pages 0,1,2]

The scene .glb is written by tools/bake_glb.py and is already laid out:

  * objects named `bakepage_<n>` hold the world geometry whose atlas UVs live
    on page n, in TEXCOORD_1 (`UVMap.001` after import). TEXCOORD_0 is the
    material's own UV and stays wired to the albedo.
  * everything else - props, instanced meshes - is in the scene as an occluder
    and is never a bake target.

Each page is baked on its own: point every material's target image node at
that page, select only that page's object, bake, and write the pixels out as
a float .npy (Blender ships numpy, and .npy sidesteps every question about
EXR readers on the other side).

The bake is DIFFUSE with direct + indirect and **colour off**, which is
irradiance - the light arriving at the surface, not the surface times the
light. bake_glb.py multiplies it by the albedo itself, exactly as it does with
Valve's luxels, so the two paths stay interchangeable.
"""
import json, math, os, sys, time
import numpy as np
import bpy


def argv():
    a = sys.argv
    return a[a.index('--') + 1:] if '--' in a else []


def opt(args, name, default=None, cast=str):
    if name in args:
        return cast(args[args.index(name) + 1])
    return default


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def enable_gpu():
    prefs = bpy.context.preferences.addons.get('cycles')
    if not prefs:
        return False
    cp = prefs.preferences
    for kind in ('OPTIX', 'CUDA', 'HIP', 'METAL', 'ONEAPI'):
        try:
            cp.compute_device_type = kind
        except TypeError:
            continue
        cp.get_devices()
        got = [d for d in cp.devices if d.type == kind]
        if got:
            for d in cp.devices:
                d.use = (d.type == kind)
            print(f'[cycles] using {kind}: {[d.name for d in got]}')
            return True
    return False


def add_lights(lights, env, sun_angle=2.0):
    global bg
    for i, L in enumerate(lights):
        data = bpy.data.lights.new(f'src_{i}', 'SPOT' if L['type'] == 'spot'
                                   else 'POINT')
        data.color = L['color']
        data.energy = L['energy']
        try:
            data.shadow_soft_size = L.get('radius', 0.05)
        except AttributeError:
            pass
        if L['type'] == 'spot':
            data.spot_size = math.radians(L['cone'] * 2.0)
            data.spot_blend = L['blend']
        ob = bpy.data.objects.new(f'src_{i}', data)
        # glTF is Y-up, Blender Z-up: (x, y, z) -> (x, -z, y)
        p = L['pos']
        ob.location = (p[0], -p[2], p[1])
        if L['type'] == 'spot':
            d = L['dir']
            v = np.array([d[0], -d[2], d[1]], float)
            n = np.linalg.norm(v)
            if n > 1e-9:
                v /= n
            # a Blender spot points down -Z
            ob.rotation_euler = (math.acos(max(-1.0, min(1.0, -v[2]))),
                                 0.0, math.atan2(-v[0], v[1]))
        bpy.context.scene.collection.objects.link(ob)

    world = bpy.data.worlds.new('W')
    world.use_nodes = True
    globals()['bg'] = bg = world.node_tree.nodes['Background']
    if env:
        c = env.get('ambient_color', (1, 1, 1))
        amb = env.get('ambient', 0.0)
        bg.inputs[0].default_value = (c[0], c[1], c[2], 1.0)
        # / PI, and the factor is exact rather than tuned. srclights returns
        # the sun and the sky through the same _light_value(), so on
        # de_cpl_strike they arrive as 829.4 and 128.6 - a ratio of 0.155, and
        # Source means both as irradiance-like quantities. But a Background
        # node's Strength is RADIANCE: a surface open to a uniform environment
        # of radiance L receives PI*L, while a Sun lamp's Strength already IS
        # the irradiance. Feeding amb in raw therefore delivered 404 against
        # 829 - a ratio of 0.487, the sky exactly PI times too strong.
        #
        # That is what flattened every bake. The sky drowned the sun (shade at
        # 129 against sunlight at 368, only 2.9:1) and it drowned the 65 point
        # and spot lights, whose pools were sitting on an inflated ambient
        # floor - which is why lamps never appeared to project anything.
        bg.inputs[1].default_value = max(amb, 0.0) / math.pi
        data = bpy.data.lights.new('sun', 'SUN')
        data.color = env['color']
        data.energy = env['energy']
        data.angle = math.radians(env.get('angle', sun_angle))
        ob = bpy.data.objects.new('sun', data)
        d = env['dir']
        v = np.array([d[0], -d[2], d[1]], float)
        n = np.linalg.norm(v)
        if n > 1e-9:
            v /= n
        ob.rotation_euler = (math.acos(max(-1.0, min(1.0, -v[2]))),
                             0.0, math.atan2(-v[0], v[1]))
        bpy.context.scene.collection.objects.link(ob)
    else:
        bg.inputs[0].default_value = (0.5, 0.55, 0.6, 1.0)
        bg.inputs[1].default_value = 1.0
    bpy.context.scene.world = world


def prep_materials():
    """Pin every existing texture to UVMap, and give each material a target."""
    targets = {}
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        nt = mat.node_tree
        uvnode = nt.nodes.new('ShaderNodeUVMap')
        uvnode.uv_map = 'UVMap'
        uvnode.location = (-900, 0)
        for n in list(nt.nodes):
            if n.type == 'TEX_IMAGE' and not n.inputs['Vector'].is_linked:
                nt.links.new(uvnode.outputs['UV'], n.inputs['Vector'])
        tgt = nt.nodes.new('ShaderNodeTexImage')
        tgt.name = 'ZONE_BAKE_TARGET'
        tgt.location = (-400, 400)
        targets[mat.name] = tgt
    return targets


def main():
    args = argv()
    scene_glb, lights_json, outdir = args[0], args[1], args[2]
    samples = opt(args, '--samples', 128, int)
    device = opt(args, '--device', 'GPU')
    margin = opt(args, '--margin', 4, int)

    clear_scene()
    bpy.ops.import_scene.gltf(filepath=scene_glb)
    spec = json.load(open(lights_json))
    add_lights(spec['lights'], spec.get('env'))

    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    # with the sky corrected, interiors are lit by lamps and bounce rather than
    # by an inflated ambient, so a stray bright path is now visible as a white
    # speckle on black. Clamp the indirect contribution rather than paying for
    # the samples it would take to converge them away.
    sc.cycles.sample_clamp_indirect = float(spec.get('clamp_indirect', 2.5))
    sc.cycles.max_bounces = spec.get('bounces', 4)
    sc.cycles.diffuse_bounces = spec.get('bounces', 4)
    sc.render.bake.use_pass_direct = True
    sc.render.bake.use_pass_indirect = True
    sc.render.bake.use_pass_color = False        # irradiance, not albedo*light
    sc.render.bake.margin = margin
    sc.render.bake.use_clear = True
    sc.cycles.bake_type = 'DIFFUSE'
    if device.upper() == 'GPU' and enable_gpu():
        sc.cycles.device = 'GPU'
    else:
        sc.cycles.device = 'CPU'

    targets = prep_materials()
    pages = {}
    for ob in bpy.data.objects:
        if ob.type == 'MESH' and ob.name.startswith('bakepage_'):
            try:
                n = int(ob.name.split('_')[1].split('.')[0])
            except (IndexError, ValueError):
                continue
            pages.setdefault(n, []).append(ob)
    want = opt(args, '--pages', '')
    only = {int(x) for x in want.split(',') if x.strip()} if want else None
    px = spec.get('page_px', 2048)
    os.makedirs(outdir, exist_ok=True)
    print(f'[cycles] {len(pages)} pages, {samples} samples, '
          f'{sc.cycles.diffuse_bounces} bounces, device {sc.cycles.device}, '
          f'{len(spec["lights"])} lamps, world {bg.inputs[1].default_value:.0f}',
          flush=True)

    for n in sorted(pages):
        if only is not None and n not in only:
            continue
        img = bpy.data.images.new(f'page{n}', px, px, float_buffer=True,
                                  is_data=True)
        for t in targets.values():
            t.image = img
        for mat in bpy.data.materials:
            if mat.use_nodes and 'ZONE_BAKE_TARGET' in mat.node_tree.nodes:
                nt = mat.node_tree
                nt.nodes.active = nt.nodes['ZONE_BAKE_TARGET']
        bpy.ops.object.select_all(action='DESELECT')
        for ob in pages[n]:
            ob.select_set(True)
            bpy.context.view_layer.objects.active = ob
            for uv in ob.data.uv_layers:
                uv.active = uv.name != 'UVMap'
            if len(ob.data.uv_layers) > 1:
                ob.data.uv_layers[1].active = True
        print(f'[cycles] baking page {n} ({len(pages[n])} objects)', flush=True)
        t0 = time.time()
        bpy.ops.object.bake(type='DIFFUSE')
        secs = time.time() - t0
        buf = np.empty(px * px * 4, np.float32)
        img.pixels.foreach_get(buf)
        # Blender images are bottom-up; glTF UVs run top-down
        arr = np.flipud(buf.reshape(px, px, 4))[:, :, :3].copy()
        np.save(os.path.join(outdir, f'page{n}.npy'), arr)
        bpy.data.images.remove(img)
        print(f'[cycles] page {n} done in {secs:.0f}s -> mean '
              f'{float(arr.mean()):.4f} max {float(arr.max()):.3f}', flush=True)
    print('[cycles] done')


if __name__ == '__main__':
    main()
