# Audited runtime enable/disable

In override.cfg change only the ZoneMods autoload path to `res://zonemods/live.gd`. Preserve other autoloads and existing mod choices. Install the changed worker files and mod_settings files together. Restart once to mount the compatible player wrapper.

Live switches: fpv_osd, dirty_air, rotor_drag, battery_sag, prop_damage, pilot_audio; optional video_profiles and zone_fixes. flight_controller stays resident with a per-frame gate: off delegates to the original game controller, clears cached PID state and restores inertia/material. Drones hot-toggle only without custom definitions/resource remapping. Unknown mods keep restart behavior; the settings service cannot disable itself. Runtime transitions happen only after verified settings writes.

Unloading frees nodes and their child workers, restoring damping/thrust curves, wind/shake, contacts/display, audio routing/pitch/volume and battery voltage. It does not rewind previously applied motion. Original worker implementations remain in *_original.gd. No proprietary player base is shipped; the existing flight_controller still makes its compatibility-checked private copy at runtime.

Native proof on the legacy macOS Godot 4.7.2 build: 344 checks, three toggle cycles per audited mod on an existing disarmed map, then combined dependency cleanup. Checked active registry, settings readback, cached controllers, render/OSD restoration, audio buses and physical property restoration. No transmitter, armed transitions, multiplayer or custom-resource hot swaps were tested. The resident player wrapper can conflict with external player-script replacements.
