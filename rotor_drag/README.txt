rotor_drag 1.1
===============

Adds the drag spinning props put on a quad moving across them, which The
Zone FPV leaves out, and takes off a drag it should not have: the physics
engine's own damping. Let go at course speed, a whoop now stops in about
two thirds of the distance it slid before; top speeds hardly change, and
falls and long coasts carry the weight they should.


WHAT IT CHANGES
  The game slows a quad with air resistance on its body, which grows with
  the square of the speed, and with the physics engine's damping. At the
  few metres a second of a whoop course the air resistance is tiny: the
  game's 65mm Whoop, flown level at 14 km/h and let go, coasts about 6 m
  before it is down to half speed, and 13 m before it is nearly stopped -
  and a third of what stops it is the damping.

  That damping is no air at all. Godot, the engine the game is made in,
  slows every moving body by a tenth of its speed each second (its
  default_linear_damp, 0.1) unless a game sets it otherwise, and The Zone
  FPV leaves it: falling, climbing or coasting at any speed, the quad loses
  10% of its speed a second on top of the air's drag, as if it were lighter
  than it is. rotor_drag takes it off the quad you fly (engine_damping=0); a 5"
  falling flat then reaches 72 km/h rather than 65, and coasts further.

  A real quad also has rotor drag. Its props draw air in and throw it out
  along their axis, so air arriving across them - the quad moving sideways
  or forwards, or wind - has that motion taken out of it, and the quad is
  pushed back. That force grows with the speed itself, not its square, so it
  does most of the slowing at low speeds, and it grows with how much air the
  props move. Ducts turn more of that air along the axis, so a whoop's is
  about twice an open-prop quad's of the same size.

  With rotor_drag - rotor drag on, the engine's damping off - from 14 km/h,
  flown level and let go (measured in Godot with the game's flight model
  and physics settings):

    quad             half speed after     nearly stopped (2 km/h) after
                     game   rotor_drag    game   rotor_drag
    65mm Whoop       6.1 m  3.9 m         13 m   7.5 m
    85mm Whoop       8.5 m  5.4 m         18 m   10 m
    2.5" Freestyle   9.8 m  7.4 m         20 m   14 m
    5" Freestyle     11 m   10 m          22 m   20 m

  Tilted forward and holding height, a quad settles at a lower speed for
  the same tilt - the 65mm Whoop at 45 degrees cruises at 28 km/h instead
  of 31 - so you tilt a little further for the same speed. Flat out, at the
  best tilt, top speeds change by a few percent. Flying forward it also
  needs a touch less throttle to hold height: tilted, the props' drag lies
  in their plane, so it points back and slightly up. Straight up and down is
  not changed. Wind pushes a whoop around more, since its props drag on the
  wind as well.


HOW IT WORKS OUT THE FORCE
  From momentum theory: props of total disc area A making thrust T move
  sqrt(1.225 x A x T / 2) kg of air a second (open), or sqrt(1.225 x A x T)
  in ducts. Part of the sideways momentum of that air is felt as drag:
    open props  0.17 of it - what a Crazyflie 2.0's measured rotor drag is
                (Forster 2015, system identification of the Crazyflie 2.0)
    ducts       0.25 of it - a quarter of the full ducted-fan figure, since
                a whoop's ducts are short and open at the bottom. This one
                is set by flying: against a real Meteor75 Pro II, the game's
                version slid further without rotor drag and stopped shorter
                at twice this
  The thrust is the game's own at that moment, so the drag follows the
  throttle (and battery_sag's sag); disarmed, the props are stopped and so
  is the drag.


SETTINGS
  Edit rotor_drag/settings.cfg (made at the first launch), save, restart the game.

  strength scales the rotor drag: 0 = none, 1 = the default, 2 = the 1.0
  release's (the 65mm Whoop above: half speed after 2.5 m), 4 = the whole
  ducted-fan momentum drag. If a whoop still slides further than a real
  one, try 1.3 or 1.5; if it feels heavy and stops short, 0.7.

  engine_damping is the engine's damping on the quad you fly: 0 = none (the
  default), 0.1 = as the game has it. strength=0 with engine_damping=0.1 is
  the game exactly as it is.

  Each drone's prop size (prop_mm) and whether it has ducts are in
  drones/settings.cfg, which comes with this mod and is shared with
  dirty_air, motor_response and flight_controller, so each is set once. A
  drone added by the drones mod sets its own with prop_mm= and ducted= in its
  block (the Meteor75 Pro II: 46 mm, ducted).


MULTIPLAYER AND RACES
  Only the quad you fly is changed, on your computer; other players see
  where you fly as ever. Like any change to the flight model it changes how
  fast you get round a race track: the rotor drag makes a quad slower;
  without the engine's damping, climbs, falls and long coasts carry a
  little further.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods,
     drones and rotor_drag folders sit next to thezone.exe. Replace files
     when asked.

  rotor_drag is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn rotor_drag off without uninstalling it, set enabled=false at the top
  of rotor_drag/settings.cfg (or strength=0).

  Delete the rotor_drag folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


TROUBLESHOOTING
  rotor_drag/status.txt is rewritten at every launch: the strength, and a line
  each time you fly a different drone with its props and rotor drag.
  zonemods/status.txt lists which mods loaded.
