prop_damage 1.0
=================

Props that chip, wear and break when they hit things. A clipped prop tip
kicks the quad and takes a chip off the prop; a worn prop loses thrust and,
out of balance, shakes the quad, the gyro and the motor sound; a very hard
hit can break one off. A respawn puts new props on. Off until you turn it on.


TURN IT ON
  Set enabled=true at the top of prop_damage/settings.cfg, or use its switch in
  Pause > Mods with mod_settings. It takes effect at the next start; after
  that its settings change at once.


HITS
  A prop is hit when the quad knocks something next to it, or - in the game
  the tips of the props stick out past the quad's collision shape, by about
  a third of their length on the 5", so a pole or a branch clipped with them
  goes straight through - when a tip goes into something (tip_strikes).
  How much a hit wears the prop goes with how fast the props spin (a clip at
  full throttle chips far more than one at idle), how fast the quad was
  going into it, and how far in the prop went. Landing on the arms does
  nothing; landing upside down on spinning props does. Props in ducts (the
  whoops) take a sixth of it.

  A very hard hit with the props spinning can break a prop off, and so can
  any hit on a prop already worn right through (breaking=false: they never
  break off). Its corner then gives no thrust, and the quad usually goes
  down - as a real one does.

ON SCREEN
  The quad you fly seen from above, front at the top, its props where they
  are on it (spread wide on a 5", in their ducts on a whoop), showing which
  props are damaged, how badly, and which was just hit - so after a crash
  that caught more than one you can see which.

  With fpv_osd (display="auto", the default) it is drawn into the OSD, in
  the OSD's own look: white outlined in black, through the video effect like
  the rest of the OSD. Each prop is a ring that fills in white as it wears,
  clockwise from the top like a clock - a quarter filled is 25% worn, filled
  right in is worn through - a prop broken off is an X where it was, and a
  prop just hit blinks while its warning shows. A whoop's ducts are thicker
  rings.

  Without fpv_osd, or with display="colour", it is drawn in colour over the
  game (not into the video picture): each prop's blades go from white
  through yellow to red as it wears, a broken one is a red X, and a prop
  just hit flashes. Hidden while paused.

  display_x and display_y place it (fractions of the picture across and
  down), display_size sizes it and display_opacity sets how solid it is -
  in either look; with mod_settings they change as you move the sliders. It
  comes up once a prop is damaged and stays until new props go on
  (display_only_damaged=false: always while flying). display="off" turns it
  off.

  With fpv_osd, a hit also comes up in its warnings for a couple of seconds -
  which prop and how worn it is ("PROP FR 23%"), "PROP FR LOST" blinking when
  one breaks off - and its show_props can keep each prop's wear on screen as
  numbers (see fpv_osd's README). Without fpv_osd, show_damage puts the same
  line in the game's grey message box ("FRONT LEFT PROP 23%").
  prop_damage/status.txt lists every hit that wore a prop.

  A real quad has no such display - its flight controller cannot tell a prop
  is damaged; you feel it in the handling and hear it, as here.


WHAT A DAMAGED PROP DOES
  less thrust   its blade tips make most of its thrust; a prop worn right
                through has lost 35% (thrust_loss), a broken one all of it
  vibration     chips are never even, so the prop is out of balance: a shake
                at the prop's speed, more the faster it spins (vibration).
                The camera shakes with the frame; with flight_controller the
                gyro feels it and its D term turns it into twitchy, busy
                motors; with pilot_audio the motor sound turns rough
  a kick        a clipped tip is pushed back against its spin by the thing
                it hit: a shove and a yaw twitch (kick)

  With flight_controller on, the motors and PIDs fly the damaged quad as a
  real one flies: the weak corner's motor spins up to make up for it, runs out
  first in a punch, and the quad yaws and drops a corner. Without it, the
  game's own rotation control holds the quad level against a weak corner, so
  a damaged prop mostly costs thrust.


NEW PROPS
  Every respawn puts new props on (fresh_props_on_respawn=false: only
  picking a drone does), as Uncrashed's reset does. Nothing is sent to other
  players: it is all on your own quad.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods,
     prop_damage and drones folders sit next to thezone.exe. Replace files when
     asked - your settings are kept.

  prop_damage is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt. It reads each drone's prop size from the drones mod,
  which comes with it.


UNINSTALL
  Set enabled=false at the top of prop_damage/settings.cfg, or delete the prop_damage
  folder. If no other mods use zonemods, delete override.cfg and the zonemods
  folder too.
