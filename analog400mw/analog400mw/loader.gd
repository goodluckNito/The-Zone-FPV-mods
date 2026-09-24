extends Node
## analog400mw 1.1
##
## Registered as an autoload by override.cfg in the game folder. At startup it
## loads small resource packs over three of the game's files, then applies
## settings.cfg to the shader. thezone.pck itself is only ever read.
##
## Uninstall: delete override.cfg and the analog400mw folder.

const VERSION := "1.1"
const DIR := "res://analog400mw/"
const SHADER_PATH := "res://ingame/ingame_main.gdshader"

# One pack per replaced file. A pack is applied only when the game's file is
# the version this release was built against, so a game update that changes
# one of them disables that part instead of loading an outdated copy.
const TARGETS := [
	{"name": "shader", "pck": "shader.pck", "entry": "ingame/ingame_main.gdshader", "stock_md5": "7fb773464b378d17733ac92e5eaddaeb", "mod_md5": "fcd4511b1b0541ae8245b6b72078e1c0"},
	{"name": "signal calc", "pck": "signal_calc.pck", "entry": "ingame/ingame_main.gdc", "stock_md5": "d9bd33fdaf46a65c41dd0a3c8f4891a8", "mod_md5": "2f61d497f5e8bb0393b0a670c68d6005"},
	{"name": "menu label", "pck": "menu_label.pck", "entry": ".godot/exported/133200997/export-393508ea6b566b4a8186d1dfb73de934-game_settings.scn", "stock_md5": "f46d7d76005ecdafb8bd708be397dfcc", "mod_md5": "39cecfcce4212fdf5f66770e89cd2078"},
]

# Holds the tuned shader. The resource cache keeps only weak references, so
# without this the tuned copy could be freed and reloaded with the defaults.
var _keep: Array = []
var _log := PackedStringArray()


func _init() -> void:
	_say("analog400mw %s" % VERSION)
	for t in TARGETS:
		_apply(t)
	_tune_shader()
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
