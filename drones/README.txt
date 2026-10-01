drones 1.0
=============

Every drone in one place. Each drone's props, frame and motors - set once
here, and shared by rotor_drag, dirty_air, motor_response and
flight_controller - and more drones for The Zone FPV, each set up in one
block of a text file: weight, thrust, drag, rotation, camera, battery and
OSD craft name, built on the body of one of the game's drones, in
my_drones.cfg. A BETAFPV Meteor75 Pro II is in it, commented out, ready
to add. Multiplayer stays safe: other players see the game drone yours is
built on.


THE GAME'S DRONES
  drones/settings.cfg (made at the first launch) has a section for each of
  the game's drones and one for any other quad:
    prop_mm       prop diameter, mm
    ducted        true = props in ducts (a whoop or cinewhoop)
    wheelbase_mm  motor to motor, diagonally across the frame, mm
    motor_ms      the motors' time constant: ms to close 63% of a throttle
                  change
  rotor_drag and dirty_air use the props, dirty_air and flight_controller
  the frame, motor_response and flight_controller the motors. With
  mod_settings, pick the drone in Pause > Mods > drones and change one: each
  of those mods takes it at once. Or edit the file, save, restart the game.


MORE DRONES
  Added drones appear after the game's own: Pause > the drone list's
  Next/Previous. The game starts on its 5" as always.

  my_drones.cfg is yours: made from my_drones.template.cfg the first time
  the game starts with this mod, and never replaced by an update. It
  explains every setting. Each block in it is one drone, added at the next
  start:

      [my_whoop]
      name="My Whoop"
      base="65mm_freestyle"
      weight=31
      thrust=150
      camera_angle=30
      battery_mah=300
      battery_cells=1
      battery_lihv=true
      craft_name="MY WHOOP"

  base= is the game drone it is built on - its 3D body, collision shape and
  sound, and every setting the block leaves out. Save the file and restart
  the game; drones/status.txt lists what was added and says why anything was
  left out. hide=true leaves a drone out without deleting its block. With
  no drone to add, the game's drone list and multiplayer scripts are left
  alone.

  The BETAFPV Meteor75 Pro II block is at the end of the file, commented
  out: take the "; " off the start of its lines and restart the game to
  add it.

  With mod_settings, the drones added are in the Drone list in Pause > Mods
  > drones too, each with the settings its block has; a change is written
  into my_drones.cfg. Its props, motors, battery and craft name take effect
  at once; its weight, thrust, drag, camera and sound when the game next
  goes on from the pause menu (the game reads a drone's settings then);
  hide= at the next start. To give a drone a setting its block does not
  have yet, add the line to the block.

  The game's Physics menu works on an added drone as on any drone, until
  you quit. At each launch the menu's saved values for an added drone are
  set aside, so a change to its block always shows. To keep a change, put
  it in the block.

THRUST AND WEIGHT
  thrust= is all the motors together at full throttle, in grams, on the
  scale the game's own drones use: the maker's thrust-to-weight ratio times
  the all-up weight. The game's 65mm Whoop - 28 g and 160 g of thrust, 5.7:1
  - matches the ratios makers give for its class of motor; the Meteor75 Pro
  II, rated 6.33:1 at 42 g, gets 266 g. The Physics menu shows the ratio.
  weight= is all-up, battery included, and a few grams change how a whoop
  flies, so weigh yours with the pack you fly.

  With battery_sag, a fresh pack gives the block's thrust. As the pack's
  voltage falls - fast at first on a LiHV, from 4.35 V - so does the motors'
  top speed, the same on every drone: after a minute of hard flying a punch
  has about 80% of the fresh pack's thrust, after two about 75%.
  sag_effect=0 in battery_sag/settings.cfg keeps the full thrust all flight
  (the pack still drains and sags on the OSD).


WITH THE OTHER MODS
  battery_sag   flies each added drone on its own pack: the block's battery_
                settings, and the base drone's pack in battery_sag/settings.cfg
                for any it leaves out.
  rotor_drag    works out each added drone's rotor drag from the block's
                prop_mm and ducted, and the base drone's props (above) for
                any it leaves out.
  dirty_air     the same, with wheelbase_mm, for the wake and ground and
                ceiling effect.
  motor_response,
  flight_controller  the block's motor_ms (and for flight_controller its
                frame), or the base drone's.
  fpv_osd       shows the block's craft_name while you fly it (fpv_osd's own
                craft_name for the other drones). Without battery_sag, its
                battery readout uses the block's battery_mah, battery_cells
                and battery_lihv.


MULTIPLAYER AND THE LEADERBOARD
  Every second the game tells the other players in your lobby which drone
  you fly. A player without drones would not know an added drone's name, so
  drones sends the game drone it is built on instead: they see that drone's
  body - the body you fly - and their game carries on as normal. Race runs
  flown on an added drone are not sent to the online leaderboard, which is
  for the game's own drones; the race, its timer and your session best work
  as ever. A race track made in the map editor while flying an added drone
  is saved for its base drone. No added drone's name ever leaves your
  computer.


HOW IT WORKS
  The game builds its drone list in one script. At startup drones mounts a
  small resource pack (drones/remap.pck) that points the game at drones's
  own version of that script, which returns the game's list with the
  added drones; two more pointers do the same for the game's multiplayer
  and online code, for the changes above. The game's own list and code are
  read from copies of its scripts made from the game's files at every
  launch (drones/base), so drones and fixes from a game update are kept.
  Nothing of the game's is shipped or changed on disk.

  If a game update changes those scripts so that this no longer fits, or
  the game already had them loaded, drones adds nothing and the game runs
  as without those drones (the figures above still work); status.txt says
  so.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     drones folders sit next to thezone.exe. Replace files when asked -
     your my_drones.cfg is not in the zip, so it is kept. It also comes in
     the zips of rotor_drag, dirty_air, motor_response and
     flight_controller.

  drones is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To leave the added drones out, put hide=true in their blocks in
  my_drones.cfg (or comment them out). drones has no on/off
  switch of its own: the figures are needed by rotor_drag, dirty_air,
  motor_response and flight_controller, which come with it.

  Delete the drones folder once none of those is installed (keep a copy of
  my_drones.cfg if you want your drones back later). If no other mods use
  zonemods, delete override.cfg and the zonemods folder too.


TROUBLESHOOTING
  drones/status.txt is rewritten at every launch and after a change in the
  game: each game drone's figures, the drones added (or off), anything left
  out of a block and why, and whether the game's scripts fitted.
  zonemods/status.txt lists which mods loaded.
