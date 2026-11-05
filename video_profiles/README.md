# Legacy video profiles

Six live visual styles in the existing `mod_settings` forms: Clean, Stock analog, Nito DVR, Soft, Crisp and Monochrome. Noise, sharpness, colour and signal quality stay adjustable. These are appearance presets, not calibrated VTX simulations. `fpv_osd` independently owns fonts, statistics and sticks.

First generate its local shader asset using a Godot 4 editor binary and the repository's existing public shader pack:

```sh
godot --headless --script /absolute/path/The-Zone-FPV-mods/video_profiles/prepare_assets.gd
```

Keep `analog400mw/shader.pck` in its repository location for that one-time command. The exported game executable does not support this script command. No REA tools are required.

Then copy `video_profiles` beside the game executable and use the existing ZoneMods loader. Enable it through its settings. Do not run it together with `analog400mw` or `signal_sim`, because they own the same video pipeline. Disabling restores the pre-enable native video mode, material, lens settings, render scale and camera overrides.

Compatibility is limited to the legacy analog game pipeline tested on Godot 4.7.2 (stock shader MD5 `7fb773464b378d17733ac92e5eaddaeb`). It does not target the newer multi-pass `signal_sim` pipeline. Native hot unloading also requires the optional live-mod lifecycle change; otherwise enabling/disabling the mod itself requires restart, while profile controls apply live.

Asset provenance: `assets/nito.gdshader` is generated locally (not committed) from the shader from this repository's public `analog400mw/shader.pck`; `camera.gd` and its helper config are unchanged files from `analog400mw`. No game scripts, user profile or binary game assets are included.

Validated in the actual native map: all six material selections, settings readback, OSD preservation and restoration on disable. No claim of hardware-accurate RF simulation or identical output to a screenshot.
