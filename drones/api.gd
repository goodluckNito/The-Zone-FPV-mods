extends "res://drones/base/z_api.gdc"
## drones: the game's online API (multiplayer/z_api.gd), with two
## changes, so no preset's name reaches the game's server. A race run flown on
## a preset is not sent to the online leaderboard, which is for the game's own
## drones (the race itself, its timer and your session best work as ever). A
## race track made in the map editor while flying a preset is saved for the
## game drone the preset is built on.

const ZM_DRONES := 1

var zm_skipped := 0              # race runs not sent, for the tests
var zm_last_track = null         # what was last sent with a track, for the tests


func _mod():
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("ZoneMods/drones") if tree != null else null


func _as_base(data):
	var mod = _mod()
	if mod != null and data is Dictionary and data.has("vehicle_id"):
		var base: String = mod.base_of(str(data["vehicle_id"]))
		if base != "":
			data = data.duplicate()
			data["vehicle_id"] = base
	return data


func post_race_run(track_id: int, data, callback: Callable):
	var mod = _mod()
	if mod != null and data is Dictionary and mod.base_of(str(data.get("vehicle_id", ""))) != "":
		zm_skipped += 1
		mod.race_not_sent(str(data.get("vehicle_id", "")))
		if callback.is_valid():
			callback.call("not sent: flown on a drone added by the drones mod", null)
		return OK
	return super(track_id, data, callback)


func create_race_track(data, callback: Callable):
	data = _as_base(data)
	zm_last_track = data
	return super(data, callback)


func update_race_track(track_id: int, data, callback: Callable):
	data = _as_base(data)
	zm_last_track = data
	return super(track_id, data, callback)
