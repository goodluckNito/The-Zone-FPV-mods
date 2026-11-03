# Flight Desk (F10)

Compact controller rows show assigned channels, live input, invert, Assign and Clear. Two stick previews use the game's Mode 1/2 pairing. Apply saves; closing a changed draft asks before discarding it. Display/sound and native tuning pages are reachable during flight.

Copy `zone_desk` next to the game executable. Add this entry to the existing `[autoload]` section in `override.cfg`, preserving ZoneMods and other entries:

```ini
ZoneDesk="*res://zone_desk/main.gd"
```

F10 opens the desk before or during flight. Optional `mod_settings` opens its own settings UI. No physics replacement is installed. Remove the autoload entry and folder to uninstall. This is an additive editor, not a replacement for every native menu.

Tested on a macOS Godot 4.7.2 game build: native UI, apply/discard and live disconnected preview; 56 detached-model checks and Mode 1/2 pairing checks. No physical transmitter was connected. Game settings/save schema compatibility must be checked on other builds. Texture/shadow/lighting changes require map reload; no FPS improvement is claimed.
