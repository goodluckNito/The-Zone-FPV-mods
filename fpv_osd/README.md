fpv_osd 1.0.1
=================

A Betaflight-style OSD for The Zone FPV - link quality, flight timer, battery,
mAh, current, warnings and craft name - in a real Betaflight font, or as a
BrainFPV RADIX draws it, with its graphical extras. It is drawn
into the picture before the game's video effect, so with an analog mode on
(analog400mw's, or the game's own) it blurs and breaks up with the video like
an OSD added on the quad. It works on its own or alongside analog400mw and
battery_sag.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     fpv_osd folders sit next to thezone.exe. Replace files when asked - your
     settings are kept (see UPDATING in zonemods/README.txt).

  fpv_osd is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn fpv_osd off without uninstalling it, set enabled=false at the top
  of fpv_osd/settings.cfg.

  Delete the fpv_osd folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


SETTINGS
  Edit fpv_osd/settings.cfg (made at the first launch), save, restart the game:
  Betaflight's look or BrainFPV's, which elements show, the craft name, the
  font, the stick overlay, the crosshair and horizon, the battery warnings and
  the stats screen. Every setting has a description.

  While the OSD is showing, the game's grey message box ("DISARMED", "Press R
  to reset...") is hidden and the OSD's own warnings stand in for it;
  hide_game_messages=false brings the box back. The OSD shows whatever the
  game's Signal Simulation is set to, so turning the analog video off leaves
  it on; show_in_digital=false shows it only with analog video.


FONTS
  Fonts are Betaflight .mcm files. Betaflight's default, large and bold fonts
  are included (GPL-3.0, see fonts/FONTS.txt). To use another - one from
  Betaflight Configurator's font manager, the font on your own quad, or any
  other .mcm - put it in fpv_osd/fonts and set font= to its file name.


BRAINFPV
  style="brainfpv" makes it a BrainFPV RADIX's OSD, from BrainFPV's own
  open-source Betaflight: the same text, but the whole OSD redrawn 30 times a
  second (every other video field) instead of about 15, with BrainFPV's
  drawn crosshair (crosshair="betaflight" or "brainfpv"), its pitch ladder in
  place of Betaflight's horizon line (show_horizon=true), and, if you turn
  them on, its altitude and speed scales down the sides. BrainFPV's own
  pixel-drawing code is followed pixel for pixel, black and white as it
  draws them. For its look without the extras - its crosshair and
  30-times-a-second drawing only - leave show_horizon and the scales off.


BATTERY
  The voltage is shown per cell, as most pilots have it (Betaflight's
  "average cell voltage"): 4.20 V full, 4.35 V on LiHV, about 3.5 V to land,
  whatever the pack. battery_voltage="total" shows the whole pack's instead.

  With the battery_sag mod installed, the OSD shows that mod's pack: its
  voltage under load, mAh used and current, as it drains and sags and changes
  how the quad flies.

  Without it, the readout is for show: a pack that drains and sags with
  throttle - its mAh, cell count and LiHV or LiPo are set in settings.cfg - and
  the quad flies the same whatever it shows. Respawning while disarmed puts in
  a fresh pack (new_pack_on_respawn changes that).

  The flight timer restarts on every respawn.


STICK OVERLAY
  Off by default. show_sticks=true draws your sticks into the OSD, for any of
  the four radio modes, and hides the game's own stick overlay (which sits
  over the craft name). By default it is BrainFPV's: a small cross for each
  stick with a square where the stick is, in the bottom corners, redrawn 30
  times a second so it moves smoothly, and no bigger than the game's own
  (sticks_size, sticks_x and sticks_y change that). sticks_style="betaflight"
  gives Betaflight's instead: boxes of font characters with a dot that steps
  about, as it does on a real Betaflight OSD.


CROSSHAIR AND HORIZON
  Both off by default. crosshair= picks Betaflight's crosshair (from the
  font, so a custom font's own shows), BrainFPV's, or one of six drawn in the
  OSD's white-with-black-edge style - plus, gap, cross, dot, circle, chevron -
  at a size you choose, and it can be moved up or down. show_horizon=true
  adds Betaflight's artificial horizon, which tilts and moves with the quad's
  roll and pitch (BrainFPV's pitch ladder with style="brainfpv"), and
  show_horizon_sidebars=true its sidebars.

  Like Betaflight's, the horizon shows the quad's attitude and knows nothing
  of the camera's uptilt, so hovering level it sits above the real horizon.
  horizon_uptilt=true puts it on the real horizon instead, as INAV can: the
  camera's tilt and field of view are read from the quad you fly, so every
  preset lines up. With style="brainfpv" and horizon_steps=0 that is a
  single thin line on the horizon.


BATTERY WARNINGS
  They work as Betaflight's do, from its own code: the voltage shown and
  warned on is smoothed over about half a second, LOW BATTERY blinks below
  3.50 V a cell and LAND NOW below 3.30 V (Betaflight's defaults), and the
  voltage readout blinks with them. In settings.cfg you can change both
  levels, make the voltage stay low for a while before they come up, add a
  LOW BATTERY by percentage of the pack left, an OVER CAP warning at a set
  mAh, and a timer that blinks after a set number of minutes.


POST-FLIGHT STATS
  Disarm after a flight and the OSD clears and shows Betaflight's stats
  screen: by default time armed, max speed, min battery, min link quality,
  max current and mAh used. It goes after 60 s, when you arm again, or when
  you push the throttle or pitch stick more than halfway up. There are 23
  lines to pick from in settings.cfg, among them max altitude and distance,
  g-force, throttle stats and running totals of flights, hours and km.

  Disarming needs an arm switch set up in the game's controller settings;
  without one the quad is always armed. stats_on_respawn=true shows the
  stats when you respawn instead.


LINK QUALITY
  The game has one radio link, the video. A real quad also has a control
  link for the sticks - ExpressLRS, Crossfire - that reaches far beyond
  analog video, and that is what an OSD's link quality (LQ), RSSI and
  RXLOSS warning show. So the OSD works one out: ExpressLRS 2.4 GHz at 100 mW
  (rc_power), from the distance to where you stand and the walls in between.
  LQ stays at 100 while the picture breaks up; it drops, and RXLOSS comes
  up, only far out or deep behind buildings. rc_link="video" makes it follow
  the game's video signal instead: 100 while the picture is clean, falling
  as it breaks up, and 0 when it is gone.

  As in Betaflight, RXLOSS shows while the arm switch is on (armed or trying
  to arm) and comes before every other warning, CRASH FLIP included; and a
  flight that ends with the link lost gets no stats screen.


FOR MOD AUTHORS
  If a zonemods mod has a zm_battery() method, the OSD shows its numbers. It
  returns a Dictionary: cell_voltage (volts per cell under load), mah_used,
  and optionally cells, current (amps), lihv (bool) and capacity_mah.


LICENSE
  GPL-3.0-or-later - see LICENSE.txt. Parts of the OSD are translated from
  Betaflight's and BrainFPV's open-source firmware, which are GPL, so the mod
  is too: you may share and change it, and anything made from it has to stay
  GPL with its source available.


TROUBLESHOOTING
  fpv_osd/status.txt is rewritten at every launch and says what the OSD found;
  zonemods/status.txt lists which mods loaded.
