zonemods - Mod Loader
===========

Loads any number of mods for The Zone FPV. override.cfg next to thezone.exe
starts it; each mod is a folder next to thezone.exe with a zonemod.cfg in it.

zonemods/status.txt is rewritten at every launch and lists which mods loaded.


CHOOSING MODS
  By default every mod folder is loaded, in name order.

  To turn one mod off, set enabled=false at the top of its settings.cfg
  (true turns it back on). zonemods/status.txt then lists it as OFF.

  Or, to load only some of them, or in a set order, list their folder names
  in override.cfg:

      [zonemods]
      mods="analog400mw,another_mod"

  Leave it empty (mods="") to go back to loading everything.


INSTALLING MORE MODS
  Extract each mod next to thezone.exe. Mods for zonemods all ship the same
  override.cfg, so replacing it is fine - unless you have listed mods in it,
  in which case keep yours.


UPDATING
  Extract the new zip over the old install and replace files when asked.
  Your settings are safe: mods ship their settings as settings.default.cfg,
  and at the next launch zonemods brings your settings.cfg up to date -
  new settings added with their notes, every value you changed kept.
  zonemods/status.txt says what it did. Delete a settings.cfg to go back to
  that mod's defaults. (settings.base.cfg, next to each settings.cfg, is its
  record of the defaults; leave it be.)


UNINSTALL
  Delete override.cfg, the zonemods folder and the mod folders.


WRITING A MOD
  A folder with a zonemod.cfg:

      [mod]
      name="my mod"
      version="1.0"
      entry="main.gd"   ; a script that extends Node
      requires=1        ; the oldest zonemods version it works with

  zonemods instances the entry script once. If it has
      func zm_init(core: Node, dir: String) -> void
  that is called straight away, before the game loads its first scene, so
  ProjectSettings.load_resource_pack() there replaces the game's files. dir is
  "res://<folder>/". The node is then added as /root/ZoneMods/<folder> and
  runs like any other node.

  Other mods: core.get_mod("<folder>") or core.get_mods().

  Settings: ship them as settings.default.cfg (sections, key=value lines and
  ; notes). zonemods makes settings.cfg from it, keeps it up to date across
  updates with the player's changes in, and does it before zm_init runs, so
  read settings.cfg there. Start settings.default.cfg with the on/off switch
  every mod has,
      [mod]
      ; false = turn <name> off: the game runs as if it were not installed.
      enabled=true
  and zonemods leaves the mod unloaded while it is false.

  Files next to thezone.exe are reachable as res://<folder>/..., as long as
  the game is started from its own folder (Steam and double-clicking both do).
