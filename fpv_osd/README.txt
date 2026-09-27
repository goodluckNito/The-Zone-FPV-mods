fpv_osd 1.1
=================

A Betaflight-style OSD for The Zone FPV - link quality, flight timer, battery,
mAh, current, warnings and craft name - in a real Betaflight font, with the
horizon, sidebars, crosshair and stick overlay each drawn as Betaflight,
BrainFPV or INAV draws it, mixed as you like, INAV's HUD, vario and more, and
QUICKSILVER's fuel gauge. It is drawn into the picture before the game's video
effect, so with an analog mode on (analog400mw's, or the game's own) it blurs
and breaks up with the video like an OSD added on the quad. It works on its
own or alongside analog400mw and battery_sag.


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

  INAV's parts use INAV's own characters, from INAV's default font (included;
  inav_font= takes any of INAV Configurator's analogue fonts).


BETAFLIGHT, BRAINFPV, INAV
  style= sets whose OSD it is: "betaflight" (a Betaflight OSD chip, about 15
  redraws a second) or "brainfpv" (a BrainFPV RADIX running Betaflight: the
  same text, but redrawn 30 times a second, every other video field). Each
  part then has its own setting, and "auto" means style's own version:

    horizon_style     betaflight, brainfpv (its pitch ladder), inav
    sidebars_style    betaflight, inav (can scroll with altitude, speed or
                      distance home)
    crosshair         betaflight, brainfpv, inav and INAV's other seven,
                      or one of six drawn shapes
    sticks_style      betaflight, brainfpv

  QUICKSILVER, a whoop firmware, adds one part: its fuel gauge (see
  BATTERY). Betaflight's flip arrow and up/down marker are there too (see
  FLIP ARROW AND UP/DOWN).

  So BrainFPV's sticks with Betaflight's horizon is sticks_style="brainfpv"
  and horizon_style="betaflight". BrainFPV's altitude and speed scales can
  be turned on with any style; any of BrainFPV's drawn parts makes the OSD
  redraw 30 times a second. BrainFPV's pixel-drawing code is followed pixel
  for pixel, and Betaflight's and INAV's parts use the same characters in
  the same places as theirs.


INAV
  INAV's analog OSD draws its horizon with the same line characters as
  Betaflight's, so level they look alike. Its line is 11 characters wide to
  Betaflight's 9, it turns to upright characters past 45 degrees of bank
  where Betaflight's breaks up, it can show one pitch rung at a time
  (horizon_pitch_interval), and with horizon_uptilt it takes the camera's
  tilt off its pitch as INAV does - so hovering with a lot of uptilt it sits
  low, or off the bottom, until you tip forward. Its sidebars can scroll like
  tapes, with arrows for which way.

  Its HUD marks home with an H where it is in the picture and its distance
  under it (hud_homepoint), puts arrows round the crosshair pointing home
  (hud_homing), and shows other players' quads as INAV shows other aircraft
  from its radar: A to D for the nearest (hud_radar), each with which way it
  is heading and its height and distance. Off the edge of the picture, a
  marker goes to the side it is round, with arrows.

  Also: its vario (climb and sink arrows) and vertical speed, its g-force
  readout and its throttle gauge.


COMPASS AND HOME
  show_compass=true puts a compass along the top, the way the quad faces in
  the middle; north is the game world's -z. show_home=true adds Betaflight's
  home arrow and distance. Home is the spawn point, and moves the moment you
  move the spawn with S or X; the HUD's H follows it too.


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

  show_fuel_gauge=true adds QUICKSILVER's fuel gauge after the throttle: the
  voltage with the sag from the throttle added back, so it holds steady
  through a punch and falls only as the pack drains - how much is left,
  where Betaflight's voltage is how hard you are working the pack. As on
  QUICKSILVER it learns how much the pack sags while you fly, above 10%
  throttle; for about the first half minute it reads close to the voltage
  shown. It learns up to 1.2 V of sag at full throttle, as QUICKSILVER does -
  plenty for a whoop or a toothpick, short of what a big pack sags.

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
  font, so a custom font's own shows), BrainFPV's, one of INAV's, or one of
  six drawn in the OSD's white-with-black-edge style - plus, gap, cross, dot,
  circle, chevron - at a size you choose, and it can be moved up or down.
  show_horizon=true adds an artificial horizon, which tilts and moves with
  the quad's roll and pitch, and show_horizon_sidebars=true sidebars.

  As on the real firmware, the horizon shows the quad's attitude and knows
  nothing of the camera's uptilt, so hovering level it sits above the real
  horizon. horizon_uptilt=true allows for it: the camera's tilt and field of
  view are read from the quad you fly, so every preset lines up. Betaflight's
  and BrainFPV's then go on the real horizon; INAV's takes the uptilt off its
  pitch, as INAV does. BrainFPV's with horizon_steps=0 is a single thin line
  on the horizon.


FLIP ARROW AND UP/DOWN
  Betaflight's, both off by default. show_flip_arrow=true puts an arrow
  above the warnings, pointing the way to flip the quad back over, while the
  game's turtle mode is on or while you are disarmed and more than 25
  degrees off level. show_up_down=true shows a U or a D where straight up or
  down is, while the nose points within about 25 degrees of it - climbing or
  diving vertically: on the crosshair when it is dead ahead, off it the way it
  lies. Betaflight goes by the quad, so with a tilted camera it is off by the
  tilt; with horizon_uptilt=true it goes by the camera.


BATTERY WARNINGS
  They work as Betaflight's do, from its own code: the voltage shown and
  warned on is smoothed over about half a second, LOW BATTERY blinks below
  3.50 V a cell and LAND NOW below 3.30 V (Betaflight's defaults), and the
  voltage readout blinks with them. In settings.cfg you can change both
  levels, make the voltage stay low for a while before they come up, add a
  LOW BATTERY by percentage of the pack left, an OVER CAP warning at a set
  mAh, and a timer that blinks after a set number of minutes.

  warnings_use_fuel_gauge=true has them read the fuel gauge instead, as
  QUICKSILVER's low-battery warning does (at 3.60 V a cell there): punches
  then do not set them off, and a pack that is really low still does. Until
  the gauge has learnt the pack's sag they behave as on the voltage shown.


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
