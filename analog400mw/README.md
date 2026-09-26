analog400mw 2.0.1
==================

Analog 5.8 GHz FPV video for The Zone FPV, modelled on a 400 mW analog whoop
(Meteor75 Pro II class). Close in, the picture is soft with slightly muted
colour, and every so often a hit knocks the colour off for a frame: below one
line, coloured things swing through the wrong hues and back, lighter and
darker parts each their own way, while night sky and grey surfaces stay as
they are. Hits come in bursts, several a second. With range and walls between
you and the drone, colour bands, white snow and torn lines appear more and
more often: noise knocks the receiver's line timing, so lines in a band jump
sideways and the ones below ease back, and on a weak link the top of the
picture bends. At the edge of range the feed breaks up into random-colour
noise and sometimes drops to black and white.

Three more mods work with it, each on its own or all together in the
zone-fpv-mods zip: fpv_osd, a Betaflight or BrainFPV-style OSD; battery_sag,
a flight pack that drains and sags; and pilot_audio, which makes the quad
sound as it would from where you stand - quieter and duller with distance,
left or right, with doppler.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     analog400mw folders sit next to thezone.exe. Replace files when asked - your
     settings are kept (see UPDATING in zonemods/README.txt).
  3. In game: Pause > Game Settings > Signal Simulation > Analog 0.4W > Save.

  analog400mw is loaded by zonemods, which can load other mods alongside it -
  see zonemods/README.txt.


UNINSTALL
  To turn analog400mw off without uninstalling it, set enabled=false at the top
  of analog400mw/settings.cfg.

  Delete the analog400mw folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too. Nothing else is changed.


TUNING
  Edit analog400mw/settings.cfg (made at the first launch), save, restart the
  game. Every setting has a one-line description; delete a line to go back
  to its default.


CAMERA
  While the analog feed is on, the game's 3D view is rendered at about 480
  lines - roughly what a whoop camera and analog video carry - so fine and
  distant detail goes soft while the OSD stays sharp. It also runs faster.
  [camera] lines= in settings.cfg sets it; 0 renders at full resolution.

  Glare: bright sky, windows, lamps and the sun bloom out past their edges
  with a soft halo, as with a cheap whoop camera, and shadows next to them
  wash out. It uses the map's own glow, so it follows what is really bright
  and never touches the OSD. [camera] glare= sets how strong; 0 turns it off.

  The game's own render and glow settings come back in the other video modes.


UPGRADING FROM 1.x
  Extract this zip over the old install and replace files when asked -
  override.cfg has to be replaced, as the mod now starts through zonemods.
  Your settings.cfg is kept and brought up to date at the next launch.


TROUBLESHOOTING
  analog400mw/status.txt is rewritten at every launch and lists what was applied;
  zonemods/status.txt lists which mods loaded.

  No status.txt, and the menu still says "Analog 2.5W"
      The mod didn't load. Start the game from Steam or by double-clicking
      thezone.exe. Godot looks for the mod folders relative to where the
      game was started from.

  status.txt says override.cfg is from an older version
      Replace override.cfg in the game folder with the one from this zip.

  "SKIP analog400mw ..." in zonemods/status.txt
      The line says why. If override.cfg lists mods, analog400mw must be one of
      them.

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

  The camera softening and glare are set at run time on the game's 3D view
  and come back off in the other video modes; no game file is changed for
  them.

  thezone.pck is only read. Every change is loaded from the analog400mw folder at
  startup.
