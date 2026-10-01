flight_controller 1.0
=======================

A flight controller for the quad: Betaflight's rate PIDs, mixer and airmode,
driving four motors that each take time to change speed, each prop pushing
at its own corner. The Zone FPV turns the quad with an idealised torque that
goes wherever the sticks point; with flight_controller it turns only as its motors can
make it, so it runs out of motor in a punch, yaws more slowly than it rolls,
and shakes in dirty air as a real quad does. Off until you turn it on.


TURNING IT ON
  Set enabled=true at the top of flight_controller/settings.cfg (made at the first
  launch), save, restart the game. flight_controller/status.txt says whether it is in
  effect.


WHAT CHANGES
  Each physics tick (240 a second):
    - the sticks ask for a rotation rate, from your own Rates settings in
      the game, as they would on a Betaflight radio
    - a PID controller per axis compares it with the gyro, in Betaflight's
      own units and scaling (pid.c): P on the rate error, I on its sum, D on
      the gyro (low-passed, and cut at high throttle by TPA), feedforward on
      how fast the stick moves. The 5" quads fly Betaflight 4.5's default
      tune; the whoops BETAFPV's Air65 II freestyle tune
      Until the throttle first goes past 25% after arming, I is held at
      zero while the throttle is low, as in Betaflight, so the quad can't
      wind itself up sitting on the ground
    - Betaflight's mixer (mixer.c) spreads the corrections over the four
      motors by corner and spin. With airmode, the throttle moves as far as
      it has to for them; if they need more than the motors have, they are
      scaled down to fit
    - each motor follows its output with a first-order response: 40 ms to
      close 63% of a change on a 5", 25 ms on a 65mm whoop (the same time
      constants as motor_response)
    - each prop's thrust is the game's own thrust for the drone at that
      motor's speed, pushing at its corner; yaw comes only from the props'
      drag torque
    - the quad's moment of inertia is worked out from its weight and frame

  What you notice:
    - rolls and flips start and stop as a real quad's do: the 5" reaches 90%
      of a rate in about 30 ms, with some overshoot; a whoop in about 25 ms
    - yaw starts more slowly than roll: a 5" picks up yaw about a seventh
      as quickly as roll, a 65mm whoop about a quarter, as real ones do. In
      the air it still gets to full rate, only later: from a flick of the
      stick, a 5" is at full yaw rate in about a quarter of a second (full
      roll rate in a twentieth), a 65mm in about a tenth. On the ground the
      quad slides on its ducts or frame as plastic does (ground_friction,
      0.5), so the props' drag turns it there even at zero throttle with
      airmode off; at the game's own grip, 1.0, like rubber, it would hardly
      turn until nearly off the ground
    - full throttle with a full roll: some motors are already at 100%, so
      the throttle gives way to keep the roll (a 5" loses about a tenth of
      its thrust while it rolls)
    - at zero throttle, airmode spins the motors up to turn you
    - prop wash: with dirty_air, each prop's thrust comes and goes on its
      own in dirty air, and the flight controller fights it through motors
      that lag. Held in its own wake the quad shakes at about 20 degrees a
      second back and forth and rocks a degree or two - small, as on a
      well-tuned quad. It is worst dropping straight down at around hover
      throttle. wash= in dirty_air's settings makes the air rougher; lower
      D (or P) here and the quad fights it less well, as a real one would


WITH THE OTHER MODS
  motor_response stands aside while flight_controller is on - the flight controller
  runs the motors itself, with the same time constants - and its status.txt
  and its Mods page say so. dirty_air, rotor_drag and battery_sag work as
  before, with the quad now turned by its motors. Each drone's props, frame
  and motors come from drones/settings.cfg, shared with those mods; a
  drone added by the drones mod uses its block's prop_mm, ducted,
  wheelbase_mm and motor_ms, and the rest from the quad it is built on.


HOW IT WORKS
  The game's quad is the script player_rigid_body.gd. At startup flight_controller
  copies it out of the game (into flight_controller/base), and mounts a small resource
  pack (flight_controller/remap.pck) that points the game at flight_controller's fc.gd instead:
  the game's own script with its rotation and motor steps handed to
  controller.gd. The game still pushes the quad with its thrust, drag and
  wind; flight_controller adds each motor's share of the thrust at its corner and the
  props' yaw torque. Nothing of the game's is shipped or changed on disk. If
  a game update changes the script so that this no longer fits, flight_controller stays
  out and the game runs as without it; status.txt says so.


SETTINGS
  Edit flight_controller/settings.cfg, save, restart the game.
    - airmode, airmode_start_throttle_percent, idle_percent, tpa_rate and
      tpa_breakpoint, dterm_lowpass_hz, feedforward_smoothing_hz and
      iterm_limit, as in Betaflight
    - braking=false lets the motors coast down, 4 times more slowly
    - [pids_5inch] and [pids_whoop]: P, I, D and F for roll, pitch and yaw,
      in Betaflight's units - paste a tune in
    - a section for each of the game's quads: yaw_torque (a prop's drag
      torque over its thrust, in metres) and which PID profile it flies.
      Its prop size, ducts, motor to motor distance and motor time constant
      are in drones/settings.cfg, shared with the other physics mods

  The game's Physics menu still sets each quad's weight, thrust and drag.


MULTIPLAYER AND RACES
  Only the quad you fly is changed, on your computer.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods,
     drones and flight_controller folders sit next to thezone.exe. Replace files
     when asked.
  3. Turn it on: enabled=true in flight_controller/settings.cfg (see above).

  flight_controller is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn flight_controller off without uninstalling it, set enabled=false at the top
  of flight_controller/settings.cfg.

  Delete the flight_controller folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


TROUBLESHOOTING
  flight_controller/status.txt is rewritten at every launch: the settings and PIDs,
  whether it is in effect, and a line each time you fly a different drone
  with its motors, moment of inertia and PID profile. zonemods/status.txt
  lists which mods loaded.
