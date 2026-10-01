extends Node
## dirty_air 1.0
##
## Dirty air for The Zone FPV: flying into the air the props have already
## pushed down (the thrust it takes away, and the shake of prop wash), and
## the floor and ceiling close to the props. Loaded by zonemods (override.cfg
## in the game folder). Settings are in dirty_air/settings.cfg; air.gd does the
## work.
##
## Uninstall: delete the dirty_air folder.

const VERSION := "1.0"
const DIR := "res://dirty_air/"

var _air: Node = null
var _log := PackedStringArray()


func zm_init(core: Node, _dir: String) -> void:
	_say("dirty_air %s" % VERSION)
	var script = load(DIR + "air.gd")
	if script is Script and script.can_instantiate():
		_air = script.new()
		_air.name = "Air"
		_say(_air.setup(DIR, core))
		add_child(_air)
	else:
		_say("could not load air.gd")
	_write_status()


## Called by air.gd when the drone flown changes.
func drone_changed(note: String) -> void:
	_say(note)
	_write_status()


## Called by mod_settings when settings.cfg has been changed in the game:
## read again, and the drone flown worked out again on the next tick
func zm_apply_settings() -> void:
	if _air != null and is_instance_valid(_air):
		_say(_air.setup(DIR, _air.get("_core")))
		_air.set("drone_id", "-")
		_write_status()


func _say(s: String) -> void:
	_log.append(s)
	print("[dirty_air] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("dirty_air/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
