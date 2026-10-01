dirty_air 1.0
==================

Flying into your own dirty air, and near floors and ceilings. The Zone FPV
gives a quad the same thrust falling as hovering, and none of the prop wash
you get dropping or punching out through the air the props have just thrown
down, or flying back through where you punched or hovered; nor any cushion
over the floor or pull towards a ceiling. dirty_air adds them, from
measurements on small props where they exist.


FALLING INTO YOUR OWN WAKE
  What matters is how fast the quad falls along its thrust axis against the
  speed of the air its props push down (the "wake speed", worked out from
  the thrust at that moment - about 6 m/s for the game's 65mm Whoop at
  hover, less at low throttle):

    falling at        thrust         what happens
    half wake speed   +4%            the props bite into rising air
    0.75-1.8x         down to -30%   the props sit in their own wake (the
                                     vortex ring state): thrust drops, each
                                     prop's comes and goes by up to 17%, and
                                     the ring round the whole quad lifts one
                                     side more than the other - prop wash
    2x and more       up to +50%     falling clear through it

  The thrust figures are measured on small props at constant rpm (Veismann
  et al. 2023, the Leishman descent curve). Moving across the wake at its
  own speed or more clears it, as flying forward out of a dive does.

  Because the wake speed follows the throttle, a punch out of a fall sweeps
  right through the worst of it - the classic prop-wash moment. Falling
  slowly at hover throttle, a 65mm Whoop meets it at about 4.6-11 m/s; at
  low throttle, much sooner.

  On a real quad the prop-wash shake is the flight controller and motors
  fighting that uneven thrust. With the flight_controller mod on, that is
  what happens here too: each prop's thrust comes and goes on its own, and
  the flight controller's corrections, through motors that take time to
  respond, shake the quad. The game's own attitude control is idealised and
  shrugs it off, so without flight_controller you feel the lift come and
  go, but little shake.

  How much it shakes: held in the ring state, a 5" on its stock tune
  jitters about 20 degrees a second back and forth (a third of a degree)
  and rocks by a degree or two - small, as on a well-tuned quad; you notice
  the sinking more. It is at its worst dropping straight down at around
  hover throttle, at 0.75-1.8x the wake speed (status.txt gives it for each
  drone). Punching hard sweeps through it in a few hundredths of a second.
  The fluctuation measured on small props is the gentle end of what has
  been measured: wash= in settings.cfg scales it - at 2, about 40 degrees a
  second and a few degrees of rocking; at 3, more. An added, hand-sized
  jitter is also there as shake=, off by default.


THE AIR YOU LEAVE BEHIND
  Hovering, climbing or flying, the props leave a column of air going the
  other way at twice the speed through them - less the faster you fly, so
  a fast pass leaves little, and a punch or a hover leaves a lot. It stays
  where you left it for a second or two, spreading and slowing as a
  turbulent jet does (a 5"'s hover column is about 6 m down and 3.5 m/s
  after a second), gusting at a quarter of its speed, and drifting with the
  wind.

  Fly back into it - diving down the column of a punch, dropping or
  turning back through where you hovered - and each prop meets that air:
    - flowing down through the props, it takes lift away (as climbing
      does), and a quad falling through it falls more slowly against the
      air around it - which can put it right in the vortex ring state above
    - its gusts make each prop's thrust come and go, by up to about 10-15%
      in a punch's column - more the faster you fall through it
    - at the edge of a column, the props in it lose more lift than the ones
      outside, and the quad tips towards it
  What a change in the flow through a prop does to its thrust is from
  blade-element momentum theory: 0.3 x the change over the props' wake
  speed at that thrust. How the column spreads and slows is from
  measurements of turbulent jets.

  Your own column only counts once you have left it: the wake a steady
  descent drags along is the vortex ring state above.


FLOORS AND CEILINGS
  Under each prop and over it, dirty_air looks for a surface:
    - Floor: more thrust within about five prop radii - +15% one radius
      up, +8% at two, at most +20% (a multirotor ground-effect model that
      fits a Crazyflie's measured lift). Ducts take about half of it and
      none right on the floor. A tilted quad or one half over a ledge gets
      it on one side only, and is rocked by it: low over the floor it
      tends to level out.
    - Ceiling: the props are pulled up, within two radii - +2% one radius
      under it, +18% at half a radius, at most +60%. It gets stronger the
      closer you go, so it draws you in, as it does real whoops.
  Both fade with speed, as the wake is swept away: skimming the floor at
  50 km/h leaves little of it.


SETTINGS
  Edit dirty_air/settings.cfg (made at the first launch), save, restart the game.
  descent, wake, wash, shake, ground_effect and ceiling_effect each scale
  their part: 1 as above, 0 off (the game as it is), 2 twice. descent is
  the ring state and the rest of falling into your own wake, lift lost and
  fluctuation both; wake the air left behind; wash how much each prop's
  thrust comes and goes in either, leaving the lift lost as it is.

  Each drone's prop size, ducts and motor-to-motor distance are in
  drones/settings.cfg, which comes with this mod and is shared with
  rotor_drag, motor_response and flight_controller, so each is set once. A
  drone added by the drones mod sets its own with prop_mm=, ducted= and
  wheelbase_mm= in its block (the Meteor75 Pro II: 46 mm, ducted, 80 mm).


MULTIPLAYER AND RACES
  Only the quad you fly is changed, on your computer.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods,
     drones and dirty_air folders sit next to thezone.exe. Replace files
     when asked.

  dirty_air is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn dirty_air off without uninstalling it, set enabled=false at the top
  of dirty_air/settings.cfg.

  Delete the dirty_air folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


TROUBLESHOOTING
  dirty_air/status.txt is rewritten at every launch: the settings, and a line
  each time you fly a different drone with its props and the speeds its
  prop wash comes at. zonemods/status.txt lists which mods loaded.
