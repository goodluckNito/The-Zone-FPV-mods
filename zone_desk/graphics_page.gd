extends VBoxContainer

const UI = preload("ui.gd")
const KEYS = ["RENDER_RESOLUTION", "TEXTURE_QUALITY", "FPS_LIMIT", "SHADOWS", "ENABLE_NEW_LIGHTING", "AUDIO_VOLUME", "ASPECT_RATIO", "SIGNAL_SIMULATION", "FPS_DEBUG"]
var desk: Node
var draft = {}
var _snapshot = {}
var _resolution_label: Label

func build(owner_desk: Node) -> void:
	desk = owner_desk
	for key in KEYS:
		draft[key] = desk.settings.get(key)
	_snapshot = draft.duplicate(true)
	var display = UI.card(self, "Rendering", "3D render scale changes the world resolution while keeping menus sharp. Texture quality mainly changes memory use.")
	_resolution_label = UI.note("")
	display.add_child(_resolution_label)
	_update_resolution_label()
	UI.choice(display, "3D render scale", ["100% · native detail", "75% · balanced", "50% · performance", "25% · minimum"], ["100", "75", "50", "25"], draft.RENDER_RESOLUTION, func(v): draft.RENDER_RESOLUTION = v; _update_resolution_label())
	UI.choice(display, "Texture detail", ["High · ~6 GB", "Medium · ~3 GB", "Low · ~2 GB", "Minimum · ~1 GB"], ["100", "50", "25", "12.5"], draft.TEXTURE_QUALITY, func(v): draft.TEXTURE_QUALITY = v)
	UI.choice(display, "Frame limit", ["60 FPS", "120 FPS", "240 FPS", "Match display", "Unlimited", "VSync"], ["60", "120", "240", "1x", "unlimited", "vsync"], draft.FPS_LIMIT, func(v): draft.FPS_LIMIT = v)
	_toggle(display, "Shadows", "SHADOWS")
	_toggle(display, "Modern lighting", "ENABLE_NEW_LIGHTING")
	display.add_child(UI.note("Render scale and frame limit apply now. Texture detail, shadows and lighting apply when the map reloads."))
	var diagnostics = UI.card(self, "Performance", "Compare the same map and camera position. A lower render scale tests GPU load; a higher FPS cap alone cannot make rendering faster.")
	_toggle(diagnostics, "Show the game's FPS / physics overlay", "FPS_DEBUG")
	diagnostics.add_child(UI.note("Flight physics frequency and the drone model are preserved."))
	var picture = UI.card(self, "Picture & sound")
	UI.choice(picture, "FPV aspect ratio", ["Match display", "4:3", "16:9"], ["native", "4_3", "16_9"], draft.ASPECT_RATIO, func(v): draft.ASPECT_RATIO = v)
	UI.choice(picture, "Video signal simulation", ["Disabled", "Digital Vista", "Digital O4 Race", "Analog"], ["disabled", "digital_vista_700", "digital_o4_race_700", "analog_2500"], draft.SIGNAL_SIMULATION, func(v): draft.SIGNAL_SIMULATION = v)
	var volume = HSlider.new()
	volume.min_value = 0
	volume.max_value = 100
	volume.step = 1
	volume.value = float(draft.AUDIO_VOLUME) * 100
	volume.custom_minimum_size = Vector2(200, 35)
	volume.value_changed.connect(func(v): draft.AUDIO_VOLUME = v / 100.0)
	picture.add_child(UI.label("Master volume"))
	picture.add_child(volume)
	if desk.ingame() != null:
		picture.add_child(UI.button("Reload current map…", desk.confirm_reload))

func _toggle(parent: Node, title: String, key: String) -> void:
	var control = CheckButton.new()
	control.text = title
	control.button_pressed = bool(draft[key])
	control.toggled.connect(func(on): draft[key] = on)
	parent.add_child(control)

func _update_resolution_label() -> void:
	var size = DisplayServer.window_get_size()
	var scale = float(draft.RENDER_RESOLUTION) / 100.0
	_resolution_label.text = "Window %d × %d · 3D scale %s%% · %d%% of the native pixel count" % [size.x, size.y, draft.RENDER_RESOLUTION, roundi(scale * scale * 100)]

func is_changed() -> bool:
	return draft != _snapshot

func apply() -> void:
	for key in KEYS:
		desk.settings.set(key, draft[key])
	var scene = desk.ingame()
	if scene != null:
		scene.call("set_max_fps")
		scene.call("_set_viewport_size")
		var viewport = scene.get_node_or_null("CanvasLayer/MainViewport/SubViewportContainer/SubViewport") as SubViewport
		if viewport != null:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			viewport.scaling_3d_scale = float(draft.RENDER_RESOLUTION) / 100.0
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if draft.RENDER_RESOLUTION == "100" else Viewport.SCREEN_SPACE_AA_DISABLED
			viewport.use_debanding = draft.RENDER_RESOLUTION == "100"

func mark_saved() -> void:
	_snapshot = draft.duplicate(true)
