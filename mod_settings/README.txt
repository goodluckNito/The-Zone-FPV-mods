mod_settings 1.0
====================

Every mod's settings in the game, with the changes showing as you make them:
a Mods page in the pause menu, and the same over the picture while you fly
(F9), so you can dial in the analog video's look or a physics mod's feel
without leaving the game or editing a file.


USING IT
  Pause (Esc) > Mods: the mods on the left, the chosen one's settings on
  the right, each with its note from the settings file. Or press F9 while
  flying: the same settings in a panel on the right of the picture, notes
  as tooltips, while you keep flying. F9 again or x closes it.

  true/false settings are switches, numbers a slider and a box (type any
  value into the box - the slider only covers a sensible range), choices a
  list, text a text box. Typing works in both: press Enter or click away to
  set what you typed. While you type, the keys go to the box, not the game -
  R does not reset the drone and Enter does not open the chat. Esc stops
  typing.

  A change is saved into that mod's settings.cfg a moment after you make it,
  just as an edit by hand would be, and updates keep it. The line by the
  Save button says when it was saved (or, in red, what went wrong); Save,
  Go back, x and leaving the pause menu all save at once too. Most changes
  take effect at once. Those marked "restart" take effect when the game is
  next started - turning a mod on or off always does - and a note at the
  top says which mods are waiting for one. "Reset to defaults" puts a mod's
  settings back (leaving it on or off as it is).

  Mods that are turned off are listed too (dimmed), so you can turn them on.

  Settings kept for each drone - drones' props and motors, battery_sag's
  packs, flight_controller's PIDs - show one drone at a time: pick it from
  the Drone list at the top. The list starts on the drone you are flying
  (for a drone the drones mod adds, on the one it is built on, where the mod
  has no section of its own for it).


WHAT TAKES EFFECT AT ONCE
  analog400mw      all of it: the picture, the range, the camera and glare
  fpv_osd          all of it; the flight's stats and totals carry on
  battery_sag      all of it; the pack in use keeps its charge
  pilot_audio      all of it
  rotor_drag,
  dirty_air,
  motor_response   all of it (none of it while flight_controller is on: it
                   runs the motors itself, and the page says so)
  flight_controller  all of it but turning it on or off; the PIDs and the
                   drone's figures take over on the next physics tick, the
                   flight carrying on (as when PIDs are changed in flight)
  drones           each drone's figures: each mod that uses them takes them
                   on its next physics tick. An added drone's battery and
                   craft name at once; its weight, thrust, drag, camera and
                   sound when the game next goes on from the pause menu;
                   hide= at the next start
  throttle_fix     only on or off, at the next start
  mod_settings     its own hotkey and overlay width


SETTINGS
  mod_settings/settings.cfg: hotkey (F9 by default) and overlay_width.


FOR MOD MAKERS
  Any zonemods mod with a settings.default.cfg shows up here, its notes as
  the descriptions. To take changes while the game runs, give the mod's main
  script
      func zm_apply_settings() -> void
  which is called a moment after a change: read settings.cfg again and use
  it. Settings that still need a restart can be listed in
      func zm_restart_keys() -> PackedStringArray    # "section/key" or "section/*"
  When its settings do nothing for now (another mod has taken over), it can
  say why, shown at the top of its settings:
      func zm_settings_status() -> String           # "" when they do
  A string setting whose note lists quoted choices, its default among them,
  is shown as a list of those choices. Three or more sections in a row are
  shown one at a time, picked from a list (named after the game's drones
  when they are drones, otherwise from the start of each section's note).

  Settings kept in another .cfg file in the mod's folder can be shown on its
  page and written into that file, with
      func zm_settings_more() -> Array
  returning items as cfgdoc.gd makes them ({kind: "section", section,
  text}, {kind: "value", section, key, default, desc}, and {kind: "group",
  section, text} for a small title), each with "file" set to the file's
  name; a section can have a "title", a value a "label", a list of
  "options" and their "option_names". Its restart keys are written
  "file|section/key". The drones mod shows my_drones.cfg this way.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     mod_settings folders sit next to thezone.exe. Replace files when asked.

  mod_settings is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn mod_settings off without uninstalling it, set enabled=false at the top
  of mod_settings/settings.cfg.

  Delete the mod_settings folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


TROUBLESHOOTING
  mod_settings/status.txt is rewritten at every launch and after every change:
  the mods found, which take changes at once, and each change saved (or
  why it could not be). The run before's is kept as status.last.txt.
  zonemods/status.txt lists which mods loaded.
