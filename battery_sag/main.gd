extends Node
## battery_sag 1.0
##
## A flight pack for The Zone FPV that drains, sags under load and changes how
## the quad flies. Loaded by zonemods (override.cfg in the game folder).
## Settings are in battery_sag/settings.cfg; battery.gd does the work. Other mods -
## fpv_osd - read the pack with zm_battery().
##
## Uninstall: delete the battery_sag folder.

const VERSION := "1.0"
const DIR := "res://battery_sag/"

var _battery: Node = null
var _log := PackedStringArray()


func zm_init(_core: Node, _dir: String) -> void:
	_say("battery_sag %s" % VERSION)
	var script = load(DIR + "battery.gd")
	if script is Script and script.can_instantiate():
		_battery = script.new()
		_battery.name = "Battery"
		_say(_battery.setup(DIR))
		add_child(_battery)
	else:
		_say("could not load battery.gd")
	_write_status()


## The pack, for an OSD: cell_voltage (volts a cell under load), mah_used,
## cells, current (amps), lihv, capacity_mah, pack (e.g. "6S 1300 mAh LiPo").
func zm_battery() -> Dictionary:
	return _battery.report() if _battery != null and is_instance_valid(_battery) else {}


## Called by battery.gd when a flight starts or the quad - and so the pack -
## changes.
func pack_changed(note: String) -> void:
	_say("pack in use: " + note)
	_write_status()


func _say(s: String) -> void:
	_log.append(s)
	print("[battery_sag] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("battery_sag/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
