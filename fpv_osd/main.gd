extends Node
## fpv_osd 1.0
##
## A Betaflight-style OSD for The Zone FPV, loaded by zonemods (override.cfg in
## the game folder). Settings are in fpv_osd/settings.cfg; osd.gd does the work.
## With the battery_sag mod installed it shows that mod's pack.
##
## Uninstall: delete the fpv_osd folder.

const VERSION := "1.0"
const DIR := "res://fpv_osd/"

var _log := PackedStringArray()


func zm_init(core: Node, _dir: String) -> void:
	_say("fpv_osd %s" % VERSION)
	var script = load(DIR + "osd.gd")
	if script is Script and script.can_instantiate():
		var osd: Node = script.new()
		osd.name = "OSD"
		_say(osd.setup(DIR, core))
		add_child(osd)
	else:
		_say("could not load osd.gd")
	# mods load in name order, so one loaded later is not listed here; the OSD
	# itself looks again every frame
	var from := ""
	for m in core.get_mods():
		if m.has_method("zm_battery"):
			from = str(m.name)
	_say("battery: from %s" % from if from != "" else "battery: display only (no battery mod loaded before this one)")
	_write_status()


func _say(s: String) -> void:
	_log.append(s)
	print("[fpv_osd] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("fpv_osd/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
