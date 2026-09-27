throttle_fix 1.0
=================

Fixes the throttle reading half when The Zone FPV starts. Until you move the
throttle stick, the game reads it as sitting in the middle, so it refuses to
arm ("LOWER THROTTLE TO ARM") until you push the stick up and back down.
With throttle_fix the throttle reads as all the way down from the start, so you
can arm straight away, and the moment the stick moves the game follows it.


WHY IT HAPPENS
  The game runs on Godot 4.5, which reads controllers through a library
  called SDL. SDL holds back each stick's first reading until that stick
  moves a little (about 1% of its travel) - it does this to skip jittery
  controllers - and until then Godot has every stick in the middle. For
  roll, pitch and yaw that is where they are anyway; for the throttle it is
  wrong. Nothing in the game or a mod can ask SDL where the stick really
  is, but a stick that has not been heard from is always exactly in the
  middle, which a real reading never is.

  So from the moment the radio connects until its first reading of the
  throttle, throttle_fix has the throttle read all the way down - where the stick
  is when you arm - worked out from your controller setup (which axis, its
  end points, centre, invert and half range). When you first move the stick
  the real reading replaces it, and from then on throttle_fix leaves the throttle
  alone: the stick passing through the middle later is never touched. If the
  radio is unplugged and plugged back in, it starts over. With a gamepad set
  up so the throttle's rest position is already throttle down, it has
  nothing to do.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     throttle_fix folders sit next to thezone.exe. Replace files when asked.

  throttle_fix is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn throttle_fix off without uninstalling it, set enabled=false at the top
  of throttle_fix/settings.cfg.

  Delete the throttle_fix folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


TROUBLESHOOTING
  throttle_fix/status.txt is rewritten at every launch. It names the controller
  and axis it set and when the radio first reported the throttle.
  zonemods/status.txt lists which mods loaded.
