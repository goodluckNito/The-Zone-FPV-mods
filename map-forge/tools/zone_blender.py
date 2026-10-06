"""Zone Map Forge - Blender round trip.

Loads a converted map into Blender the way the game sees it, and exports it
back without breaking anything the game depends on.

Install as an add-on (Edit > Preferences > Add-ons > Install...) and use the
"Zone Map" tab in the 3D view sidebar (press N). Or just open it in the
Scripting tab and press Run, which does the same thing without installing.

WHAT IT HANDLES, and why each one matters
-----------------------------------------
* **Textures.** The .glb carries its images packed inside the binary chunk, so
  a plain File > Import shows them in the material but leaves nothing on disk
  to edit, and the viewport shows flat grey until you leave Solid shading.
  Import here writes every image out to `<map>_textures/` and switches the
  viewport to Material Preview, so you can see them and edit them as files.

* **The spawn.** The converter already recentres the map so the drone starts
  at the engine's fixed spawn - glTF (0, 10, 0), which is Blender (0, 0, 10),
  ten metres straight up from the world origin. Nothing needs moving on
  import or export. What was missing was any way to SEE it, so an empty named
  DRONE_SPAWN is dropped there along with a marker on the ground below it.
  Leave the map where it is and the spawn survives the round trip; if you do
  move things, move them relative to that empty.

* **Material names.** Two of the game's behaviours key off them. Names
  starting `z_` are substituted wholesale for the game's own PBR set, so
  `z_brick-wall.001` - which is what Blender silently makes of a second user -
  matches nothing and loses the substitution. And converted materials are
  cached by name, so two sharing one name collapse into a single material in
  game and the second one's textures are dropped. Export repairs both: it
  strips Blender's `.001` suffixes, lets `z_` names collide (they are meant
  to), and makes every other name unique with a `_2` style suffix instead.

* **Helpers stay out.** DRONE_SPAWN and friends live in a ZONE_HELPERS
  collection that is never exported.

* **UVs on geometry you add.** Every UV in a converted map is an AFFINE
  FUNCTION OF WORLD POSITION - Source's own `u = (p . tex_vecs[0] + off) / w`,
  or the fill's 2 m-per-tile box projection. Nothing is unwrapped, which is why
  the texture runs unbroken across face boundaries. Extrude breaks that: it
  copies the source verts' UVs onto the new ones, so the new face has zero
  extent in UV space and one row of texels smears across it. Follow Active
  Quads cannot fix it either, because it walks through SHARED VERTICES and this
  mesh has none - the converter emits every triangle with its own three.
  "Match UV to Active" recovers that affine map from a face that is already
  right (least squares over its corners, in the plane of the face) and applies
  the same map to everything else selected. Coplanar faces come out exact:
  same scale, same rotation, same phase, no seam.

* **The manifest.** `manifest.json` carries the spawn, skybox and lighting.
  Export copies the original through so the folder stays loadable. Note the
  uploader keeps only the .glb, so the manifest only applies to local play.
"""

bl_info = {
    "name": "Zone Map Forge round trip",
    "author": "zone-map-forge",
    "version": (1, 0, 0),
    "blender": (3, 0, 0),
    "location": "View3D > Sidebar (N) > Zone Map",
    "description": "Import/export The Zone FPV custom maps with textures and spawn intact",
    "category": "Import-Export",
}

import os
import re
import json
import shutil

import bpy
from mathutils import Vector

# The engine always spawns the drone here, in glTF metres (Y up). The uploader
# discards manifest.json, so this is fixed and the converter moves the MAP to
# suit it rather than the other way round.
ENGINE_SPAWN_GLTF = (0.0, 10.0, 0.0)
HELPERS = "ZONE_HELPERS"
_SUFFIX = re.compile(r"\.\d{3}$")


def gltf_to_blender(v):
    """glTF is Y-up, Blender is Z-up: (x, y, z) -> (x, -z, y)."""
    return Vector((v[0], -v[2], v[1]))


def _call(op, **kw):
    """Call an operator with only the arguments this Blender version knows.

    The glTF exporter's options have been renamed and added to across 3.x,
    4.x and 5.x; filtering keeps one script working on all of them.
    """
    known = set(op.get_rna_type().properties.keys())
    return op(**{k: v for k, v in kw.items() if k in known})


# ---------------------------------------------------------------- import ----
def _helpers_collection(scene):
    col = bpy.data.collections.get(HELPERS)
    if col is None:
        col = bpy.data.collections.new(HELPERS)
    if col.name not in scene.collection.children:
        scene.collection.children.link(col)
    return col


def _writable(folder):
    """Can we actually create files here? Program Files says yes, then no."""
    try:
        os.makedirs(folder, exist_ok=True)
        probe = os.path.join(folder, ".zone_write_test")
        with open(probe, "wb") as f:
            f.write(b"x")
        os.remove(probe)
        return True
    except Exception:
        return False


def texture_folder(glb_path):
    """Where the textures can go: beside the .blend, else beside the .glb.

    Beside the .blend comes FIRST on purpose. Maps are normally imported
    straight out of `custom_maps/`, which for a Steam install lives under
    Program Files - not writable without elevation. Writing there fails, or
    worse silently lands in Windows' VirtualStore, and either way the images
    end up pointing at a file that is not there.
    """
    base = os.path.splitext(os.path.basename(glb_path))[0] + "_textures"
    here = bpy.data.filepath
    for parent in ([os.path.dirname(bpy.path.abspath(here))] if here else []) + \
                  [os.path.dirname(bpy.path.abspath(glb_path))]:
        if not parent:
            continue
        cand = os.path.join(parent, base)
        if _writable(cand):
            return cand
    return None


def missing_images():
    """Images with no usable pixels: nothing packed and no readable file."""
    bad = []
    for img in bpy.data.images:
        if img.source in ("VIEWER", "GENERATED"):
            continue
        if img.packed_file and img.packed_file.data:
            continue
        path = bpy.path.abspath(img.filepath) if img.filepath else ""
        if path and os.path.isfile(path):
            continue
        bad.append(img)
    return bad


def write_out_textures(folder):
    """Write every packed image to `folder` and point the datablock at it.

    The bytes are taken straight from `image.packed_file.data`, which is the
    original JPEG or PNG exactly as the converter embedded it - no decode and
    re-encode, so nothing is lost on the way out or back in. Note that a
    freshly imported image reports `has_data == False` until something touches
    it, so that is NOT a usable test for "is there an image here"; the packed
    block is.

    The pack is only DROPPED once the file has been written and read back at
    the right size. Unpacking first and hoping is how a whole map loses its
    textures: `unpack` is not reversible, so a write that failed - or that
    Windows quietly redirected somewhere else - leaves every image pointing at
    nothing, and from then on every exporter, this one and Blender's own,
    writes a materials-only .glb. Nothing in the export can detect that the
    damage happened at import time, which is why it has to not happen.
    """
    if not folder:
        print("[zone] no writable folder for textures; leaving them packed")
        return 0
    os.makedirs(folder, exist_ok=True)
    written = 0
    for img in bpy.data.images:
        if img.source == "VIEWER":
            continue
        pf = img.packed_file
        if not pf or not pf.data:
            continue
        data = bytes(pf.data)
        ext = ".jpg" if (img.file_format or "").upper() in ("JPEG", "JPG") else ".png"
        name = re.sub(r"[^A-Za-z0-9._-]+", "_", _SUFFIX.sub("", img.name)) or "image"
        if not name.lower().endswith((".png", ".jpg", ".jpeg")):
            name += ext
        path = os.path.join(folder, name)
        try:
            with open(path, "wb") as f:
                f.write(data)
            if os.path.getsize(path) != len(data):
                raise IOError("short write")
            with open(path, "rb") as f:
                if f.read(16) != data[:16]:
                    raise IOError("read back wrong")
        except Exception as ex:
            print(f"[zone] could not write {img.name}: {ex} - left packed")
            continue
        img.filepath_raw = path
        img.filepath = path
        try:
            img.unpack(method="USE_ORIGINAL")
        except Exception as ex:
            print(f"[zone] {img.name} stays packed ({ex})")
        written += 1
    return written


def set_viewport_material_preview():
    """Solid shading is why an imported map looks untextured."""
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type != "VIEW_3D":
                continue
            for space in area.spaces:
                if space.type != "VIEW_3D":
                    continue
                space.shading.type = "MATERIAL"
                space.clip_start = 0.05      # drone-scale near plane
                space.clip_end = 4000.0      # maps run to a few hundred metres


def add_spawn_marker(scene, spawn_gltf=ENGINE_SPAWN_GLTF):
    col = _helpers_collection(scene)
    loc = gltf_to_blender(spawn_gltf)

    old = bpy.data.objects.get("DRONE_SPAWN")
    if old:
        bpy.data.objects.remove(old, do_unlink=True)
    e = bpy.data.objects.new("DRONE_SPAWN", None)
    e.empty_display_type = "ARROWS"
    e.empty_display_size = 1.0
    e.location = loc
    col.objects.link(e)

    old = bpy.data.objects.get("DRONE_SPAWN_GROUND")
    if old:
        bpy.data.objects.remove(old, do_unlink=True)
    g = bpy.data.objects.new("DRONE_SPAWN_GROUND", None)
    g.empty_display_type = "PLAIN_AXES"
    g.empty_display_size = 2.0
    g.location = Vector((loc.x, loc.y, 0.0))
    col.objects.link(g)
    return e


def import_map(glb_path, textures=True, mark_spawn=True, clear_scene=False):
    glb_path = bpy.path.abspath(glb_path)
    if not os.path.isfile(glb_path):
        raise FileNotFoundError(glb_path)
    scene = bpy.context.scene

    if clear_scene:
        for obj in list(bpy.data.objects):
            bpy.data.objects.remove(obj, do_unlink=True)
        # objects alone is not enough - Blender's startup materials survive and
        # then show up in the pre-export check as untextured
        for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
            for db in list(coll):
                if db.users == 0:
                    coll.remove(db)

    _call(bpy.ops.import_scene.gltf, filepath=glb_path)

    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0

    n_tex = 0
    if textures:
        base = os.path.splitext(os.path.basename(glb_path))[0]
        n_tex = write_out_textures(texture_folder(glb_path))

    spawn = ENGINE_SPAWN_GLTF
    man = os.path.join(os.path.dirname(glb_path), "manifest.json")
    if os.path.isfile(man):
        try:
            with open(man, "r", encoding="utf-8") as f:
                sp = json.load(f).get("spawn_point")
            if isinstance(sp, list) and len(sp) >= 3:
                spawn = tuple(float(x) for x in sp[:3])
        except Exception as ex:
            print(f"[zone] manifest unreadable ({ex}); using the engine default")
    if mark_spawn:
        add_spawn_marker(scene, spawn)

    set_viewport_material_preview()
    print(f"[zone] imported {os.path.basename(glb_path)}; "
          f"{n_tex} textures written; spawn at glTF {spawn}")
    return n_tex


# ---------------------------------------------------------------- export ----
def fix_material_names():
    """Undo Blender's `.001` renaming and keep non-builtin names unique.

    `z_` names are the game's substitution keys and are SUPPOSED to repeat, so
    they are only stripped. Everything else is converted by the game and cached
    by name, where a repeat means the second material silently loses its
    textures - so those get a readable `_2` suffix instead.
    """
    renamed, deduped = 0, 0
    seen = {}
    for mat in bpy.data.materials:
        stripped = _SUFFIX.sub("", mat.name)
        if stripped != mat.name:
            renamed += 1
        name = stripped
        if not name.startswith("z_"):
            if name in seen:
                seen[name] += 1
                name = f"{name}_{seen[name] + 1}"
                deduped += 1
            else:
                seen[name] = 0
        mat.name = name
    return renamed, deduped


def export_map(glb_path, copy_manifest_from=None):
    glb_path = bpy.path.abspath(glb_path)
    os.makedirs(os.path.dirname(glb_path) or ".", exist_ok=True)
    bad = missing_images()
    if bad:
        # refuse rather than write a materials-only map - a 5 MB .glb that
        # loads and is simply untextured is far harder to notice than an error
        raise RuntimeError(
            f"{len(bad)} image(s) have no pixels - nothing packed and no file "
            f"on disk: {', '.join(i.name for i in bad[:4])}"
            + (" ..." if len(bad) > 4 else "")
            + ". Export would be untextured. File > External Data > Find "
              "Missing Files (point it at the *_textures folder), or re-import "
              "the map, then File > External Data > Pack Resources.")
    renamed, deduped = fix_material_names()

    helper_names = set()
    col = bpy.data.collections.get(HELPERS)
    if col:
        helper_names = {o.name for o in col.objects}

    # select everything except the helpers, and export the selection
    for obj in bpy.data.objects:
        try:
            obj.select_set(obj.name not in helper_names and obj.type == "MESH")
        except RuntimeError:
            pass          # not in the view layer; nothing to select

    _call(bpy.ops.export_scene.gltf,
          filepath=glb_path,
          export_format="GLB",
          use_selection=True,
          export_yup=True,              # Z-up -> Y-up, matching the importer
          export_apply=True,            # bake modifiers
          export_materials="EXPORT",
          export_image_format="AUTO",   # keep JPEG as JPEG
          export_texcoords=True,
          export_normals=True,
          export_cameras=False,
          export_lights=False,
          export_extras=False)

    if copy_manifest_from:
        src = os.path.join(os.path.dirname(bpy.path.abspath(copy_manifest_from)),
                           "manifest.json")
        dst = os.path.join(os.path.dirname(glb_path), "manifest.json")
        if os.path.isfile(src) and os.path.abspath(src) != os.path.abspath(dst):
            shutil.copy2(src, dst)

    size = os.path.getsize(glb_path)
    print(f"[zone] exported {os.path.basename(glb_path)}  {size:,} bytes  "
          f"({renamed} names unsuffixed, {deduped} deduped)")
    return size


def check_scene():
    """Problems worth knowing about before exporting. Returns a list of lines."""
    out = []
    dupes = {}
    for mat in bpy.data.materials:
        base = _SUFFIX.sub("", mat.name)
        dupes.setdefault(base, []).append(mat.name)
    clashing = {k: v for k, v in dupes.items()
                if len(v) > 1 and not k.startswith("z_")}
    if clashing:
        out.append(f"{len(clashing)} material name(s) repeat and will be "
                   f"suffixed on export: {', '.join(list(clashing)[:4])}")
    notex = [m.name for m in bpy.data.materials
             if m.use_nodes and not any(n.type == "TEX_IMAGE" for n in m.node_tree.nodes)
             and not m.name.startswith("z_")]
    if notex:
        out.append(f"{len(notex)} material(s) have no image texture and will "
                   f"render as flat colour: {', '.join(notex[:4])}")
    tris = sum(len(o.data.loop_triangles) for o in bpy.data.objects
               if o.type == "MESH" and o.data.loop_triangles)
    if tris:
        out.append(f"{tris:,} triangles in the scene")
    bad = missing_images()
    if bad:
        out.append(f"{len(bad)} image(s) have NO PIXELS and would export "
                   f"untextured: {', '.join(i.name for i in bad[:4])}"
                   + (" ..." if len(bad) > 4 else ""))
    if not bpy.data.objects.get("DRONE_SPAWN"):
        out.append("no DRONE_SPAWN marker - import through this add-on to get one")
    return out or ["nothing to flag"]


def match_uv_to_active():
    """Copy the active face's world->UV mapping onto every other selected face.

    A Source UV is `uv = A . world_position + b`, so one correctly-mapped face
    is enough to recover A and b: fit them by least squares over that face's
    corners, in a 2D basis lying in its plane, then evaluate the same map at
    every selected vertex. Exact for coplanar faces; for a face on another
    plane it projects along the active face's normal, which is what extending
    a roof wants.
    """
    import bmesh
    obj = bpy.context.edit_object
    if obj is None:
        raise RuntimeError("not in Edit Mode")
    bm = bmesh.from_edit_mesh(obj.data)
    uvs = bm.loops.layers.uv.active
    if uvs is None:
        raise RuntimeError("this mesh has no UV layer")
    act = bm.faces.active
    if act is None or not act.select:
        raise RuntimeError("no active face - shift-click a correctly mapped "
                           "face LAST so it is the active one")
    n = act.normal.copy()
    if n.length < 1e-9:
        raise RuntimeError("the active face is degenerate")
    n.normalize()
    p0 = act.verts[0].co.copy()
    e1 = None
    for v in act.verts[1:]:
        cand = v.co - p0
        cand -= n * cand.dot(n)
        if cand.length > 1e-6:
            e1 = cand.normalized()
            break
    if e1 is None:
        raise RuntimeError("the active face is degenerate")
    e2 = n.cross(e1)

    rows, us, vs = [], [], []
    for loop in act.loops:
        d = loop.vert.co - p0
        rows.append((d.dot(e1), d.dot(e2), 1.0))
        uv = loop[uvs].uv
        us.append(uv.x)
        vs.append(uv.y)
    if len(rows) < 3:
        raise RuntimeError("the active face needs at least 3 corners")

    # plain 3x3 normal equations - no numpy dependency inside Blender
    def solve(target):
        ata = [[0.0] * 3 for _ in range(3)]
        atb = [0.0, 0.0, 0.0]
        for r, t in zip(rows, target):
            for i in range(3):
                atb[i] += r[i] * t
                for j in range(3):
                    ata[i][j] += r[i] * r[j]
        m = [ata[i] + [atb[i]] for i in range(3)]
        for col in range(3):
            piv = max(range(col, 3), key=lambda r_: abs(m[r_][col]))
            if abs(m[piv][col]) < 1e-12:
                raise RuntimeError("the active face's UVs are degenerate - "
                                   "pick a face that is not already smeared")
            m[col], m[piv] = m[piv], m[col]
            f = m[col][col]
            m[col] = [x / f for x in m[col]]
            for r_ in range(3):
                if r_ == col:
                    continue
                f = m[r_][col]
                if f:
                    m[r_] = [a - f * b for a, b in zip(m[r_], m[col])]
        return [m[i][3] for i in range(3)]

    cu, cv = solve(us), solve(vs)
    done = 0
    for f in bm.faces:
        if not f.select or f is act:
            continue
        for loop in f.loops:
            d = loop.vert.co - p0
            s_, t_ = d.dot(e1), d.dot(e2)
            loop[uvs].uv = (cu[0] * s_ + cu[1] * t_ + cu[2],
                            cv[0] * s_ + cv[1] * t_ + cv[2])
        done += 1
    bmesh.update_edit_mesh(obj.data)
    return done


# ------------------------------------------------------------------- UI -----
class ZONE_OT_import(bpy.types.Operator):
    bl_idname = "zone.import_map"
    bl_label = "Import Map"
    bl_description = "Import a .glb with textures written out and the spawn marked"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        p = context.scene.zone_map_path
        try:
            n = import_map(p, clear_scene=context.scene.zone_clear_scene)
        except Exception as ex:
            self.report({"ERROR"}, str(ex))
            return {"CANCELLED"}
        self.report({"INFO"}, f"Imported; {n} textures written out")
        return {"FINISHED"}


class ZONE_OT_export(bpy.types.Operator):
    bl_idname = "zone.export_map"
    bl_label = "Export Map"
    bl_description = "Export back to .glb, repairing material names and skipping helpers"
    bl_options = {"REGISTER"}

    def execute(self, context):
        src = context.scene.zone_map_path
        dst = context.scene.zone_out_path or src
        try:
            size = export_map(dst, copy_manifest_from=src)
        except Exception as ex:
            self.report({"ERROR"}, str(ex))
            return {"CANCELLED"}
        self.report({"INFO"}, f"Exported {size:,} bytes")
        return {"FINISHED"}


class ZONE_OT_check(bpy.types.Operator):
    bl_idname = "zone.check_scene"
    bl_label = "Check Scene"
    bl_description = "Report anything that would not survive the trip back"
    bl_options = {"REGISTER"}

    def execute(self, context):
        for line in check_scene():
            self.report({"INFO"}, line)
            print("[zone] " + line)
        return {"FINISHED"}


class ZONE_OT_match_uv(bpy.types.Operator):
    bl_idname = "zone.match_uv"
    bl_label = "Match UV to Active"
    bl_description = ("Give every selected face the active face's world-to-UV "
                      "mapping, so extruded geometry tiles like its neighbours")
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context):
        return context.mode == "EDIT_MESH"

    def execute(self, context):
        try:
            n = match_uv_to_active()
        except Exception as ex:
            self.report({"ERROR"}, str(ex))
            return {"CANCELLED"}
        self.report({"INFO"}, f"Re-mapped {n} face(s)")
        return {"FINISHED"}


class ZONE_PT_panel(bpy.types.Panel):
    bl_label = "Zone Map Forge"
    bl_idname = "ZONE_PT_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Zone Map"

    def draw(self, context):
        c = self.layout.column(align=True)
        c.prop(context.scene, "zone_map_path", text="Map")
        c.prop(context.scene, "zone_clear_scene", text="Clear scene first")
        c.operator("zone.import_map", icon="IMPORT")
        c.separator()
        c.prop(context.scene, "zone_out_path", text="Save as")
        c.operator("zone.check_scene", icon="CHECKMARK")
        c.operator("zone.export_map", icon="EXPORT")
        c.separator()
        c.label(text="Editing")
        c.operator("zone.match_uv", icon="UV")


_CLASSES = (ZONE_OT_import, ZONE_OT_export, ZONE_OT_check,
            ZONE_OT_match_uv, ZONE_PT_panel)


def register():
    for c in _CLASSES:
        bpy.utils.register_class(c)
    bpy.types.Scene.zone_map_path = bpy.props.StringProperty(
        name="Map", subtype="FILE_PATH",
        description="The map .glb, e.g. custom_maps/ctf_2fort/ctf_2fort.glb")
    bpy.types.Scene.zone_out_path = bpy.props.StringProperty(
        name="Save as", subtype="FILE_PATH",
        description="Where to write the edited .glb (blank = over the original)")
    bpy.types.Scene.zone_clear_scene = bpy.props.BoolProperty(
        name="Clear scene first", default=True)


def unregister():
    for c in reversed(_CLASSES):
        bpy.utils.unregister_class(c)
    for p in ("zone_map_path", "zone_out_path", "zone_clear_scene"):
        if hasattr(bpy.types.Scene, p):
            delattr(bpy.types.Scene, p)


if __name__ == "__main__":
    try:
        unregister()
    except Exception:
        pass
    register()
