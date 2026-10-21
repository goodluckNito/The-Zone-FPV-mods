throttle_curve 1.0
==================

A throttle curve for The Zone FPV, as Betaflight's Rates tab has it: a hover
point and a throttle expo. The game reads the throttle stick in a straight
line - half stick is half throttle - which makes it hard to hold a hover and
twitchy around it. With throttle_curve the stick runs along a curve instead:
flatter around the hover, so small stick movements make small changes in
throttle, and with the hover put where on the stick you want it.

With the default settings the curve is a straight line, the game's own, and
nothing is changed. Set your hover and expo (below) to switch it on.


SETTINGS
  Edit throttle_curve/settings.cfg (made at the first launch), or use
  mod_settings: Pause > Mods, or F9 while flying - the curve changes at once,
  so you can hover and tune it by feel.

    hover_percent        The throttle your quad needs to hover (5 to 95).
                         Hover level and steady, and read the throttle off
                         the OSD or the stick overlay. It is different for
                         every drone: a punchy 5" hovers near 30, a floaty
                         whoop nearer 50.
    hover_stick_percent  Where on the stick you want that hover to sit
                         (5 to 95). 50 = the middle of the stick.
    expo_percent         Throttle expo (0 to 100). Flattens the stick around
                         the hover and steepens it towards the ends.

  Both ends are fixed: the stick all the way down is always zero throttle
  (so arming works as it does now) and all the way up is always full.

  Examples
    Hover at the middle of the stick, whatever the drone's thrust:
        hover_percent=32   hover_stick_percent=50   expo_percent=0
      (a 5" that hovers at 32% now hovers with the stick at the middle; the
      lower half of the stick covers 0-32%, the upper half 32-100%)
    The same, with fine control around the hover:
        hover_percent=32   hover_stick_percent=50   expo_percent=50
    The hover left where the game has it, only the feel around it shaped
    (both numbers equal):
        hover_percent=40   hover_stick_percent=40   expo_percent=50

  status.txt lists the curve as it comes out: the stick every 10% and the
  throttle it gives.

  The curve is Betaflight's own throttle curve, with the same three settings:
  hover_stick_percent is its thr_mid, hover_percent its thr_hover and
  expo_percent its thr_expo. Two curved segments, from the bottom of the
  stick to the hover and from the hover to the top, flat through the hover
  at 100% expo and straight lines at 0% (Betaflight's rc.c, initRcProcessing:
  quadratic Bezier segments). Betaflight samples the curve at 12 points and
  interpolates between them; this uses the smooth curve itself. The tests
  check it against a port of Betaflight's code.


HOW IT WORKS
  Nothing of the game is replaced, so it sits alongside every other mod,
  including flight_controller and mode_3d, which each replace the game's quad.
  The game reads the throttle as a joypad axis through its controller setup
  (the radio's end points, centre, invert and half range). When the radio
  reports a new reading of that axis, throttle_curve works out the throttle
  the game would make of it, bends it along the curve, and puts in the
  reading of the axis that makes the game give the bent throttle - through
  the same joypad event the radio sends, before the game's next physics tick.
  So the game's own calibration still applies, and everything that looks at
  the throttle - the stick overlay, the OSD, flight_controller's motors,
  other players - sees the bent throttle, as on a real quad.
  It works with throttle_fix (which only sets the throttle low until the
  radio first reports it).


THINGS TO KNOW
  - Calibrating: the ends of the stick are not bent, so calibrating the
    throttle's end points in the game's controller setup works as usual.
    The stick shown while you do it is the bent one; set hover_percent and
    hover_stick_percent equal and expo to 0 if you want it plain there.
  - mode_3d in centre mode (the middle of the stick is zero throttle): the
    curve stands aside while it is on, as a hover would bend it wrongly.
    mode_3d in switch mode is fine. status.txt and the settings page say
    when it stands aside.
  - Only a radio or gamepad's throttle axis is bent. A throttle on keys or
    a switch (the game's toggle) is left alone.
  - Multiplayer and races: only your own throttle is changed, on your
    computer; others are sent the bent throttle like any other.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so the throttle_curve folder sits
     next to thezone.exe, with override.cfg and the zonemods folder already
     there. Replace files when asked.
  3. Start the game; set your hover and expo as above.

  throttle_curve is loaded by zonemods, which loads other mods alongside it -
  see zonemods/README.txt.


UNINSTALL
  To turn throttle_curve off without uninstalling it, set enabled=false at
  the top of throttle_curve/settings.cfg.

  Delete the throttle_curve folder. If no other mods use zonemods, delete
  override.cfg and the zonemods folder too.


TROUBLESHOOTING
  throttle_curve/status.txt is rewritten at every launch and after every
  change: the curve in effect, the controller and axis it first bent, and
  whether it is standing aside. zonemods/status.txt lists which mods loaded.
  If it says the game's controller code (gdutil/z_input.gd) is not as this
  expects, a game update has changed it and this mod needs an update.
