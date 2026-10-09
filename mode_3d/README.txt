mode_3d 1.0
=================

3D mode: motors that turn both ways, as on a quad flown with Betaflight's
3D feature and bidirectional ESCs. Pull the throttle below the middle and
the motors stop, start again backwards and push the other way - so the quad
can hang upside down, fly inverted and flip back over without turtle mode.
Off until you turn it on.


TURN IT ON
  Set enabled=true at the top of mode_3d/settings.cfg, or use its switch in
  Pause > Mods with mod_settings, and restart the game. mode_3d/status.txt
  says whether it is in effect.


THE THROTTLE (throttle)
  "centre" (as shipped) - Betaflight's 3D mode. The middle of the stick is
  zero: above it the props push as usual, below it they turn backwards and
  push the other way, more the further you go. A little either side of the
  middle (deadband_percent, 10) is still zero; there the motors idle the
  way they last turned. Arm with the throttle at the middle, as Betaflight
  does - with the stick low it won't arm. Without an arm switch set up in
  the game, the motors wait at idle until the throttle has been to the
  middle. A throttle stick that springs back to the middle makes this
  easiest; on a normal one, find the middle by feel.

  "switch" - Betaflight's 3D on a switch. The throttle works as usual (low
  is idle) and the switch you set for the game's turtle mode turns the
  motors round. The game's own turtle mode is off meanwhile: flipping the
  switch and adding throttle flips the quad back over anyway.

  Either way the props never stop while armed: they idle one way or the
  other, as in Betaflight 3D. With fpv_osd, the throttle on the OSD goes
  below zero when reversed, as Betaflight's OSD shows it.


WHAT IT FEELS LIKE
  - Backwards, normal props push less: about three quarters of their forward
    thrust at the same speed (reverse_thrust, 0.73 - a bench test of a 7x5
    tri-blade gave 0.59 against 0.81 kgf at full throttle), for the same
    power. Hanging upside down takes more throttle than hovering, and the
    battery (with battery_sag) drains faster for it. Set 1.0 for
    symmetrical 3D props.
  - Through zero the motors stop for a moment: the ESC brakes each one until
    it can no longer follow it, waits (reverse_ms, 40 ms) and starts it the
    other way. For that moment the props push nothing and the quad drops or
    floats - the pause every 3D pilot feels crossing the middle.
  - The air comes through reversed props from the other side, so diving
    "down" along their push costs thrust as climbing does normally.

  With flight_controller on, each motor turns round on its own, as a real
  quad's do, and Betaflight's mixer turns its corrections round with them
  (motorOutputMixSign); the I term is held at zero for a quarter of a second
  after the motors reverse, as Betaflight holds it. Crossing zero the quad
  wobbles while the motors are stopped. Without flight_controller, the
  game's own rotation control flies the quad either way up, and the motors
  reverse together.

  With motor_response, the motors here follow its time constants (it says
  so in its status.txt). dirty_air puts your wake on the side the props push
  it to, prop_damage counts reversed props as spinning, and other players see
  and hear your motors as they turn.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     mode_3d folders sit next to thezone.exe. Replace files when asked - your
     settings are kept.

  mode_3d is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt. If you list mods in override.cfg, put mode_3d after
  flight_controller and before motor_response.


UNINSTALL
  Set enabled=false at the top of mode_3d/settings.cfg, or delete the mode_3d
  folder. If no other mods use zonemods, delete override.cfg and the zonemods
  folder too.
