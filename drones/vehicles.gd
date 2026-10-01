extends RefCounted
## drones: the game's list of drones (common/default_vehicles.gd), with
## the drones from my_drones.cfg added at the end. The game
## loads this in place of its own list, through a small resource pack that
## the drones mod mounts. The game's own list comes from a copy of its script
## that the drones mod makes at each launch, so drones added by a game update
## are kept.

const ZM_DRONES := 1
const BASE := "res://drones/base/default_vehicles.gdc"

static var _game = null


static func get_vehicles():
	if _game == null:
		_game = load(BASE)
	var list = _game.get_vehicles()
	var tree := Engine.get_main_loop() as SceneTree
	var mod = tree.root.get_node_or_null("ZoneMods/drones") if tree != null else null
	if mod != null and mod.has_method("vehicles_for"):
		list.append_array(mod.vehicles_for(list))
	return list


static func get_vehicle_by_id(id: String):
	for v in get_vehicles():
		if v.id == id:
			return v
	return null
