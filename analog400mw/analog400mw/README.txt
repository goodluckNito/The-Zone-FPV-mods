analog400mw 1.0
==================

Analog 5.8 GHz FPV video for The Zone FPV, modelled on a 400 mW analog whoop
(Meteor75 Pro II class). Close in, the picture is soft with slightly muted
colour. With range and walls between you and the drone, colour bands, white
snow and sideways warble appear more and more often. At the edge of range the
feed breaks up into random-colour noise and sometimes drops to black and white.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract this zip into that folder, so override.cfg and the analog400mw folder
     sit next to thezone.exe.
  3. In game: Pause > Game Settings > Signal Simulation > Analog 0.4W > Save.

  Already have an override.cfg from another mod? Add our [autoload] line to
  yours instead of replacing it.


UNINSTALL
  Delete override.cfg and the analog400mw folder. Nothing else is changed.


TUNING
  Edit analog400mw/settings.cfg, save, restart the game. Every setting has a
  one-line description; delete a line to go back to its default.


TROUBLESHOOTING
  analog400mw/status.txt is rewritten at every launch and lists what was applied.

  No status.txt, and the menu still says "Analog 2.5W"
      The mod didn't load. Start the game from Steam or by double-clicking
      thezone.exe. Godot looks for the mod folder relative to where the game
      was started from.

  "SKIP ... the game's file has changed"
      A game update changed that file, so that part of the mod turns itself
      off rather than load an outdated copy. The rest still works.


WHAT IT CHANGES
  The game already works out signal quality from distance and walls; this mod
  changes how that quality looks and feels:

  ingame_main.gdshader   The analog picture. Digital modes are untouched.
  ingame_main.gd         One change to the signal-strength formula:
                             (distance * 0.3) * (walls * 1.5)
                         becomes
                             (distance * 0.3) * (walls + 1.5)
                         so signal fades with distance in the open, not only
                         behind walls. Walls still multiply the loss.
  game_settings menu     The "Analog 2.5W" preset is renamed "Analog 0.4W".
                         This mod replaces that preset while installed.

  thezone.pck is only read. Every change is loaded from the analog400mw folder at
  startup.
