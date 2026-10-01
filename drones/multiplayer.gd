extends "res://drones/base/z_multiplayer.gdc"
## drones: the game's multiplayer code (multiplayer/z_multiplayer.gd),
## with one change. The status it sends other players every second names the
## drone you fly; a player without the drones mod would not know a preset's
## name, so a preset is sent as the game drone it is built on. Their game shows
## that drone's body - the body you fly - and nothing else changes.

const ZM_DRONES := 1

var zm_last_status = null        # what was last sent, for the tests


func broadcast_status(data):
	var tree := Engine.get_main_loop() as SceneTree
	var mod = tree.root.get_node_or_null("ZoneMods/drones") if tree != null else null
	if mod != null and data is Dictionary and data.has("vehicle_id"):
		var base: String = mod.base_of(str(data["vehicle_id"]))
		if base != "":
			data = data.duplicate()
			data["vehicle_id"] = base
	zm_last_status = data
	super(data)
