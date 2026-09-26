battery_sag 1.0
=====================

A flight pack for The Zone FPV that drains, sags under load and changes how
the quad flies. A fresh pack flies exactly as the game is tuned. As it drains,
the voltage under load drops - at once on a punch, and more the longer you
push - so the quad needs more throttle to hover and punches weaker, and a flat
pack can barely hold it up. Land, respawn while disarmed - at the map's
spawn or one you saved with S - and a fresh pack goes in.

With fpv_osd installed, the OSD's battery, mAh and current show this pack.


INSTALL
  1. Steam: right-click The Zone FPV > Manage > Browse local files.
  2. Extract the zip into that folder, so override.cfg and the zonemods and
     battery_sag folders sit next to thezone.exe. Replace files when asked - your
     settings are kept (see UPDATING in zonemods/README.txt).

  battery_sag is loaded by zonemods, which loads other mods alongside it - see
  zonemods/README.txt.


UNINSTALL
  To turn battery_sag off without uninstalling it, set enabled=false at the top
  of battery_sag/settings.cfg.

  Delete the battery_sag folder. If no other mods use zonemods, delete override.cfg
  and the zonemods folder too.


SETTINGS
  Edit battery_sag/settings.cfg (made at the first launch), save, restart the game.
  Every setting has a one-line description.

  Each of the game's quads has its own pack, a common one for its class. The
  pack for the quad you have selected is used, and a fresh one goes in when
  you change quad:

    quad            pack                like
    65mm Whoop      1S 300 mAh LiHV     Air65, Meteor65, Mobula6
    85mm Whoop      2S 450 mAh LiHV     Mobula8, Meteor85
    2.5" Freestyle  2S 550 mAh LiHV     ultralight 2.5" toothpicks
    3.5" Freestyle  4S 850 mAh LiPo     Smart35 and other 3.5" cinewhoops
    5" Freestyle    6S 1300 mAh LiPo
    Beginner 5"     4S 1500 mAh LiPo
    5" Racer        6S 1100 mAh LiPo
    any other       1S 550 mAh LiHV     Meteor75 Pro

  Roughly: 2-3.5 minutes flown hard, 4-6 minutes cruising, landing at
  3.2 V a cell on 1S and 3.5 V on the rest. settings.cfg lists each quad's
  times.

  Each quad's section of settings.cfg sets its pack: capacity_mah, cells and
  lihv describe it, resistance_mohm how much it sags; full_throttle_amps and
  idle_amps describe the quad's draw. The quad's weight is not part of it -
  the game's own weight and thrust settings still change how it flies.

  In [battery]: sag_effect=0 keeps the handling as the game has it while the
  pack still drains and sags on the OSD. sag_compensation works like
  Betaflight's vbat_sag_compensation.


HOW IT WORKS
  The pack is a standard battery model: a resting voltage that follows the
  charge left (LiHV or LiPo curve), an internal resistance that rises as the
  pack empties, and two polarisation terms that build and recover over about
  1.5 s and 40 s. The current comes from the thrust the game's flight model is
  making, as a share of the quad's full thrust, plus the electronics.

  The game's quad has a battery voltage that sets how fast its motors can
  spin. The mod sets it every physics tick from the pack's voltage under
  load, against a fresh pack's at the same current. Nothing else in the game
  is changed.

  The packs come from published figures: the usual pack for each class, flight
  times (Meteor75 Pro 3-5 minutes flown hard; Air65 about 4 minutes; 5" on
  6S 1100-1300 about 4-7 minutes), a 5" drawing about 150 A flat out, whoop
  packs landing at 3.1-3.2 V a cell under load and bigger packs at 3.5 V,
  and the LiPo charge curve (LiHV the same shape, 4.35 V full).


FOR MOD AUTHORS
  core.get_mod("battery_sag").zm_battery() returns a Dictionary: cell_voltage
  (volts a cell under load), mah_used, cells, current (amps), lihv,
  capacity_mah and pack (e.g. "6S 1300 mAh LiPo").


TROUBLESHOOTING
  battery_sag/status.txt is rewritten at every launch and shows the pack in use;
  zonemods/status.txt lists which mods loaded.
