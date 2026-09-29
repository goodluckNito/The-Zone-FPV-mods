glb_animations 0.1 - an example mod for zonemods
================================================

Plays the animations in a map's .glb. The Zone FPV loads custom maps
(custom_maps/<name>/<name>.glb) with Godot's glTF loader, which turns the
file's animations into an AnimationPlayer - but never starts it, so the map
stands still. This starts every animation in the map as it loads, looping.


MAKING AN ANIMATED MAP
  In Blender, animate objects - a spinning fan, a sliding door, a gate that
  swings - and export the map to .glb as usual, with Animation ticked (it
  is by default). Each object's action plays at the same time.

  Move whole objects (location, rotation, scale): the game gives every mesh
  a collider, which moves with it. Armature and shape-key animations play
  too, but their collision stays where the mesh was at rest.


INSTALL
  Extract the zip next to thezone.exe, so override.cfg, the zonemods folder
  and the glb_animations folder sit beside it. zonemods/status.txt says
  whether it loaded.


SETTINGS
  glb_animations/settings.cfg (made at the first launch):
    loop           true: every animation repeats; false: each plays once
    speed          1 = the speed it was made at
    sync_to_clock  true: loops are set by the clock, so everyone in a
                   multiplayer race sees the same part of each loop (each
                   player's game plays its own copy of the map)


COPYING IT FOR A MOD OF YOUR OWN
  A mod is a folder next to thezone.exe with:
    zonemod.cfg           its name and version, its entry script, and the
                          oldest zonemods it works with
    main.gd               the entry script - it must extend Node
    settings.default.cfg  optional: zonemods makes settings.cfg from it, and
                          keeps the player's changes across updates

  1. Copy the glb_animations folder and rename it: the folder name is the
     mod's id.
  2. Change name= in zonemod.cfg, and the section in settings.default.cfg.
  3. In main.gd, zm_init(core, dir) runs first - once, before the game
     loads its first scene. Read settings.cfg there, and load any resource
     pack of replacement game files there too
     (ProjectSettings.load_resource_pack), so the game picks them up.
     After that the node sits at /root/ZoneMods/<folder> and _ready,
     _process and the rest run as any node's do.
  4. Files in your folder are res://<folder>/... Other mods are
     core.get_mod("<folder>").

  More in zonemods/README.txt, under WRITING A MOD.


LIMITS
  - Light baked into a map doesn't move with its objects.
  - Moving colliders are moved, not driven: fine for scenery and obstacles
    to fly through or around, but a quad sitting on a moving platform
    isn't carried along.
