extends Node
## prop_damage 1.0
##
## Props that chip, bend and break when they hit things, for The Zone FPV:
## less thrust, a prop out of balance shaking the quad, a clipped tip kicking
## it, new props at a respawn. Loaded by zonemods (override.cfg in the game
## folder). Settings are in prop_damage/settings.cfg; props.gd does the work.
## flight_controller and pilot_audio read the props' state from its Props
## node (thrust_factor, factor_at(), vibration_level).
##
## Uninstall: delete the prop_damage folder.

const VERSION := "1.0"
const DIR := "res://prop_damage/"
const KEEP_LINES := 60

var _props: Node = null
var _head := PackedStringArray()
var _log := PackedStringArray()


func zm_init(core: Node, _dir: String) -> void:
	_head.append("prop_damage %s" % VERSION)
	print("[prop_damage] prop_damage " + VERSION)
	var script = load(DIR + "props.gd")
	if script is Script and script.can_instantiate():
		_props = script.new()
		_props.name = "Props"
		_head.append(_props.setup(DIR, core))
		add_child(_props)
	else:
		_head.append("could not load props.gd")
	_write_status()


## Called by props.gd when the drone flown changes
func drone_changed(note: String) -> void:
	_say(note)


## Called by props.gd for each hit that did damage, and new props
func prop_hit(line: String) -> void:
	_say(line)


## Called by mod_settings when settings.cfg has been changed in the game: the
## props keep what damage they have
func zm_apply_settings() -> void:
	if _props != null and is_instance_valid(_props):
		_head[_head.size() - 1] = _props.setup(DIR, _props.get("_core"))
		_write_status()


func _say(s: String) -> void:
	_log.append(s)
	while _log.size() > KEEP_LINES:
		_log.remove_at(0)
	print("[prop_damage] " + s)
	_write_status()


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("prop_damage/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_head) + "\n" + ("\n".join(_log) + "\n" if not _log.is_empty() else ""))
