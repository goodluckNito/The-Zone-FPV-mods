extends Node
## rotor_drag 1.0
##
## Rotor drag for The Zone FPV: the braking force spinning props (and more so
## a whoop's ducts) put on a quad moving across them, which the game leaves
## out. Loaded by zonemods (override.cfg in the game folder). Settings are in
## rotor_drag/settings.cfg; rotor.gd does the work.
##
## Uninstall: delete the rotor_drag folder.

const VERSION := "1.0"
const DIR := "res://rotor_drag/"

var _rotor: Node = null
var _log := PackedStringArray()


func zm_init(core: Node, _dir: String) -> void:
	_say("rotor_drag %s" % VERSION)
	var script = load(DIR + "rotor.gd")
	if script is Script and script.can_instantiate():
		_rotor = script.new()
		_rotor.name = "Rotor"
		_say(_rotor.setup(DIR, core))
		add_child(_rotor)
	else:
		_say("could not load rotor.gd")
	_write_status()


## Called by rotor.gd when the drone flown changes.
func drone_changed(note: String) -> void:
	_say(note)
	_write_status()


## Called by mod_settings when settings.cfg has been changed in the game:
## read again, and the drone flown worked out again on the next tick
func zm_apply_settings() -> void:
	if _rotor != null and is_instance_valid(_rotor):
		_say(_rotor.setup(DIR, _rotor.get("_core")))
		_rotor.set("drone_id", "-")
		_write_status()


func _say(s: String) -> void:
	_log.append(s)
	print("[rotor_drag] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("rotor_drag/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
