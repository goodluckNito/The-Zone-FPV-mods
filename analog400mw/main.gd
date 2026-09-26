extends Node
## analog400mw 2.0.1
##
## Loaded by zonemods (override.cfg in the game folder). At startup it loads
## small resource packs over three of the game's files, applies settings.cfg to
## the shader, and starts the camera (softening and glare). thezone.pck
## itself is only ever read. The OSD is its own mod now, fpv_osd.
##
## Uninstall: delete override.cfg and the zonemods and analog400mw folders.

const VERSION := "2.0.1"
const DIR := "res://analog400mw/"
const SHADER_PATH := "res://ingame/ingame_main.gdshader"

# One pack per replaced file. A pack is applied only when the game's file is
# the version this release was built against, so a game update that changes
# one of them disables that part instead of loading an outdated copy.
const TARGETS := [
	{"name": "shader", "pck": "shader.pck", "entry": "ingame/ingame_main.gdshader", "stock_md5": "7fb773464b378d17733ac92e5eaddaeb", "mod_md5": "1ea6d7138c4fcf9343bc9487554ebeb9"},
	{"name": "signal calc", "pck": "signal_calc.pck", "entry": "ingame/ingame_main.gdc", "stock_md5": "d9bd33fdaf46a65c41dd0a3c8f4891a8", "mod_md5": "3e314201092b50d6d376ecea78f3e7df"},
	{"name": "menu label", "pck": "menu_label.pck", "entry": ".godot/exported/133200997/export-393508ea6b566b4a8186d1dfb73de934-game_settings.scn", "stock_md5": "f46d7d76005ecdafb8bd708be397dfcc", "mod_md5": "39cecfcce4212fdf5f66770e89cd2078"},
]

# Holds the tuned shader. The resource cache keeps only weak references, so
# without this the tuned copy could be freed and reloaded with the defaults.
var _keep: Array = []
var _log := PackedStringArray()
var _applied := {}


func zm_init(_core: Node, _dir: String) -> void:
	_say("analog400mw %s" % VERSION)
	for t in TARGETS:
		_apply(t)
	_tune_shader()
	_link()
	var cam_script = load(DIR + "camera.gd")
	if cam_script is Script and cam_script.can_instantiate():
		var cam: Node = cam_script.new()
		cam.name = "Camera"
		_say(cam.setup(DIR))
		add_child(cam)
	else:
		_say("camera: could not load camera.gd")
	_write_status()


func _apply(t: Dictionary) -> void:
	var path: String = "res://" + str(t["entry"])
	var cur := FileAccess.get_md5(path)
	if cur != t["stock_md5"] and cur != t["mod_md5"]:
		_say("SKIP %s - the game's file has changed (md5 %s); an update of this mod is needed" % [t["name"], cur])
		return
	if not ProjectSettings.load_resource_pack(DIR + str(t["pck"]), true):
		_say("FAIL %s - could not open %s%s" % [t["name"], DIR, t["pck"]])
		return
	if FileAccess.get_md5(path) == t["mod_md5"]:
		_applied[t["name"]] = true
		_say("OK   %s" % t["name"])
	else:
		_say("FAIL %s - pack loaded but the file did not change" % t["name"])


func _tune_shader() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(DIR + "settings.cfg") != OK or not cfg.has_section("tuning"):
		_say("tuning: no settings.cfg, using defaults")
		return
	var sh := load(SHADER_PATH) as Shader
	if sh == null:
		_say("tuning: could not load the shader")
		return
	var ident := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$")
	var code := sh.code
	var n := 0
	for key in cfg.get_section_keys("tuning"):
		var v = cfg.get_value("tuning", key)
		if ident.search(key) == null or (typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT):
			_say("tuning: ignored %s = %s (needs a number)" % [key, str(v)])
			continue
		var re := RegEx.create_from_string("uniform float %s = [^;]+;" % key)
		if re.search(code) == null:
			_say("tuning: unknown setting %s" % key)
			continue
		code = re.sub(code, "uniform float %s = %s;" % [key, "%.6f" % float(v)])
		n += 1
	if code != sh.code:
		sh.code = code
	_keep.append(sh)
	_say("tuning: %d values from settings.cfg" % n)


# [link] open_range: how far the video reaches in the open. The patched signal
# script (see WHAT IT CHANGES in README.txt) takes its open-air loss per metre
# from this project setting, in the analog mode only; the picture is gone at
# degrade_span quality points below 100.
func _link() -> void:
	var cfg := ConfigFile.new()
	cfg.load(DIR + "settings.cfg")
	var r := float(cfg.get_value("link", "open_range", 400.0))
	var span := float(cfg.get_value("tuning", "degrade_span", 55.0))
	var k := span / (0.3 * r) if r > 0.0 else 0.0
	ProjectSettings.set_setting("analog400mw/open_loss", k)
	if not _applied.has("signal calc"):
		_say("range: not applied - the signal calc part was skipped")
	elif r > 0.0:
		_say("range: the picture is gone at about %d m in the open; walls cut it shorter" % roundi(r))
	else:
		_say("range: no loss in the open, only behind walls")


func _exit_tree() -> void:
	_keep.clear()


func _say(s: String) -> void:
	_log.append(s)
	print("[analog400mw] " + s)


func _write_status() -> void:
	# analog400mw/status.txt next to the game's exe: what the last launch applied
	var p := OS.get_executable_path().get_base_dir().path_join("analog400mw/status.txt")
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
