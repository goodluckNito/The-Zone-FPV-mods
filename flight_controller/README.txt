flight_controller 1.1
=======================

A flight controller for the quad: Betaflight's rate PIDs, mixer and airmode,
driving four motors that each take time to change speed, each prop pushing
at its own corner. The Zone FPV turns the quad with an idealised torque that
goes wherever the sticks point; with flight_controller it turns only as its motors can
make it, so it runs out of motor in a punch, yaws on its motors' torque and
its props' drag, stops a move where you stop the sticks, and shakes in dirty
air as a real quad does. Off until you turn it on.


TURNING IT ON
  Set enabled=true at the top of flight_controller/settings.cfg (made at the first
  launch), save, restart the game. flight_controller/status.txt says whether it is in
  effect.


WHAT CHANGES
  Each physics tick (the game's: 500 a second, 250 on a slower computer):
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
      While a stick moves quickly, I gathers little (Betaflight's I-term
      relax, roll and pitch), so it doesn't wind up during a move and throw
      the quad back past where it stopped; and near full stick feedforward
      eases off, so it can't push the quad past its top rate (Betaflight's
      ff_max_rate_limit). As the corrections near more than the motors
      have, I gathers less, and none once they need it all (iterm_windup)
    - the gyro reads the quad's rotation with a little noise - the motors'
      vibration that gets through Betaflight's filters, about a degree a
      second - and four times that in rough air (with dirty_air: falling
      through your own wash, flying back into your wake). The D term turns
      it into a fine jitter of the motors, as on a real quad
    - Betaflight's mixer (mixer.c) spreads the corrections over the four
      motors by corner and spin. With airmode, the throttle moves as far as
      it has to for them; if they need more than the motors have, they are
      scaled down to fit
    - each motor follows its output with a first-order response: 40 ms to
      close 63% of a change on a 5", 25 ms on a 65mm whoop (the same time
      constants as motor_response)
    - each prop's thrust is the game's own thrust for the drone at that
      motor's speed, pushing at its corner
    - yaw: each prop's drag torque, and each motor's own torque as it speeds
      its prop up or slows it - the rotor's spin taken from the frame or
      given back to it. That kick is quick and strong (each of a whoop's
      rotors, at full speed, carries as much spin as the whole quad yawing
      at 500 degrees a second), and it is what lets a real quad start and
      stop a yaw crisply; the drag carries it on. The rotors' moment of
      inertia and top speed come from the prop's size
    - the quad's moment of inertia is worked out from its weight and frame

  What you notice:
    - rolls and flips start and stop as a real quad's do: the 5" reaches 90%
      of half rate in about 30 ms, with some overshoot; a whoop too, with
      less. Flicked to full stick, both are at 90% of the full rate in about
      40 ms, over it by a few percent at most
    - yaw: the motors' kick starts it at once - a whoop about as quickly as
      it starts a roll, a 5" about half as quickly - and the props' drag
      takes it on from there. From a flick of the stick a 65mm whoop is at
      90% of its full yaw rate in about 50 ms, a 5" in about a sixth of a
      second
    - a move stops where you stop the sticks: let go of a turn and the yaw
      comes back by 4-6% of its rate at most, a roll 5% (a 5", whose motors
      are slower, about 12%). 1.0 threw a turn back by a third, wobbling on
      for a quarter of a second or more
    - on the ground the quad slides on its ducts or frame as plastic does
      (ground_friction, 0.5), so the props' drag turns it there even at zero
      throttle with airmode off; at the game's own grip, 1.0, like rubber,
      it would hardly turn until nearly off the ground
    - full throttle with a full roll: some motors are already at 100%, so
      the throttle gives way to keep the roll (a 5" loses about a tenth of
      its thrust while it rolls)
    - at zero throttle, airmode spins the motors up to turn you
    - prop wash: with dirty_air, each prop's thrust comes and goes on its
      own in dirty air, and the flight controller fights it through motors
      that lag, and a gyro that reads noisier there. Held in its own wake a
      whoop shakes at about 25 degrees a second back and forth, a 5" about
      40, and both rock a degree or two - small, as on a well-tuned quad. It is worst dropping straight down at around hover
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
  wind; flight_controller adds each motor's share of the thrust at its corner, and the
  props' and motors' yaw torque. Nothing of the game's is shipped or changed on disk. If
  a game update changes the script so that this no longer fits, flight_controller stays
  out and the game runs as without it; status.txt says so.


SETTINGS
  Edit flight_controller/settings.cfg, save, restart the game.
    - airmode, airmode_start_throttle_percent, idle_percent, tpa_rate and
      tpa_breakpoint, dterm_lowpass_hz, feedforward_smoothing_hz,
      feedforward_max_rate_limit, iterm_relax, iterm_relax_cutoff,
      iterm_windup and iterm_limit, as in Betaflight
    - gyro_noise: the gyro's noise in clean air, degrees a second (1); 0 =
      a perfect gyro
    - rotor_inertia: the motors' kick on yaw, 1 = as worked out from the
      prop's size, 0 = none (yaw from the props' drag alone, as in 1.0)
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
