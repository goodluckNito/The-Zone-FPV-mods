extends Node
## drones 1.0
##
## Every drone in one place, for The Zone FPV:
##   - each drone's props, frame and motors (settings.cfg, a section per game
##     drone), which the physics mods share: rotor_drag, dirty_air,
##     motor_response and flight_controller read them through specs.gd, so
##     each figure is set once. Changed in the game (mod_settings), they are
##     read again and those mods take them on their next physics tick.
##   - more drones, each set up in one block of my_drones.cfg (made from
##     my_drones.template.cfg at the first launch, never replaced by an
##     update). A drone added is built on one of the game's drones - its 3D
##     body, collision shape and sound - with its own name, weight, thrust,
##     drag, rotation, camera, props, motors, battery and OSD craft name. They
##     appear after the game's drones in the drone list. A BETAFPV Meteor75
##     Pro II comes in it, commented out: none is added as shipped.
##
## How drones are added: the game builds its drone list in
## common/default_vehicles.gd. At startup this mounts a small resource pack
## that points the game at vehicles.gd instead, which returns the game's own
## list (read from a copy of its script) with the added drones. Two more
## pointers keep every added drone's name on this computer, so multiplayer
## stays as it was: multiplayer.gd, in place of multiplayer/z_multiplayer.gd,
## sends an added drone to other players as the game drone it is built on, so
## a player without this mod sees that drone's body rather than an error;
## api.gd, in place of multiplayer/z_api.gd, does not send race runs flown on
## one to the online leaderboard, and saves a race track made while flying
## one for the drone it is built on.
##
## The copies of the game's scripts are made from the game's own files at
## every launch, with their class_name changed by one letter's case so they
## can sit beside the originals; nothing of the game's is shipped or changed on
## disk. With no drone to add, none of this happens: the game's scripts are
## left alone. If the game's scripts are not what this expects, or the game
## already had them loaded, nothing is added and the game runs as without
## those drones (the figures still work).
##
## Other mods ask for an added drone with zm_vehicle(id): battery_sag takes
## its battery, fpv_osd its craft name (and battery, without battery_sag); the
## physics mods its props and motors, through specs.gd.
##
## With mod_settings, the added drones show on this mod's page beside the
## game's (zm_settings_more), each with the settings its block has, and a
## change is written into my_drones.cfg. Read again at once: the props and
## motors take effect on the next physics tick, the battery and craft name at
## once (zm_vehicle_changed(id) tells the mods using them), and the rest -
## weight, thrust, drag, camera, sound, even the drone it is built on - when
## the game next goes on from the pause menu, where it reads the drone's
## settings again. hide= takes effect at the next start.
##
## Uninstall: delete the drones folder (rotor_drag, dirty_air,
## motor_response and flight_controller need it).

const VERSION := "1.0"
const DIR := "res://drones/"
const SPECS := preload("res://drones/specs.gd")

# A block's settings, and where each goes in the game's drone entry
const KEYS := {
	"weight": ["adjustable_settings", "weight"],
	"thrust": ["adjustable_settings", "thrust"],
	"top_speed": ["adjustable_settings", "top_speed"],
	"drag_left_right": ["adjustable_settings", "surface_area_x_multi"],
	"drag_top_bottom": ["adjustable_settings", "surface_area_y_multi"],
	"drag_front_back": ["adjustable_settings", "surface_area_z_multi"],
	"camera_angle": ["adjustable_settings", "camera_angle"],
	"camera_fov": ["adjustable_settings", "camera_fov_new"],
	"camera_fisheye": ["adjustable_settings", "camera_fisheye_strength"],
	"rotation": ["internal_settings", "torque_scale"],
	"turtle": ["internal_settings", "turtle_torque_scale"],
	"corner_drag": ["internal_settings", "corner_drag_factor"],
	"idle_rpm": ["internal_settings", "dynamic_idle_rpm"],
	"sound_pitch": ["", "audio_pitch_offset"],
}
# ... and the battery, in battery_sag's names
const BATTERY_KEYS := {
	"battery_mah": "capacity_mah",
	"battery_cells": "cells",
	"battery_lihv": "lihv",
	"battery_full_throttle_amps": "full_throttle_amps",
	"battery_idle_amps": "idle_amps",
	"battery_resistance_mohm": "resistance_mohm",
}
# ... the props, in rotor_drag's and dirty_air's names
const ROTOR_KEYS := {
	"prop_mm": "prop_mm",
	"ducted": "ducted",
	"wheelbase_mm": "wheelbase_mm",
}
# ... and the motors, in motor_response's
const MOTOR_KEYS := {
	"motor_ms": "motor_ms",
}
const OTHER_KEYS := ["name", "description", "base", "craft_name", "hide"]

# The game's scripts this stands in for: a copy of each (class_name renamed)
# is what the stand-in builds on
const SCRIPTS := [
	{"game": "common/default_vehicles", "copy": "base/default_vehicles.gdc", "class": "default_vehicles",
		"ours": "vehicles.gd", "needs": {"get_vehicles": 0, "get_vehicle_by_id": 1}},
	{"game": "multiplayer/z_multiplayer", "copy": "base/z_multiplayer.gdc", "class": "z_multiplayer",
		"ours": "multiplayer.gd", "needs": {"broadcast_status": 1}},
	{"game": "multiplayer/z_api", "copy": "base/z_api.gdc", "class": "z_api",
		"ours": "api.gd", "needs": {"post_race_run": 3, "create_race_track": 2, "update_race_track": 3}},
]

var _blocks := {}              # id -> the block's settings (my_drones.cfg)
var _block_order: Array = []
var _presets := {}             # the blocks that passed the checks
var _order: Array = []
var _game_ids: Array = []
var _game_names := {}
var _on := false               # mounted and in effect: the presets are in the game
var _first_frame := true
var _raced := {}
var _log := PackedStringArray()
var _core: Node = null

# On mod_settings' page: a block's settings in this order, named and noted
# (props and motors take the notes the game's drones have there)
const PAGE_KEYS := ["name", "description", "base", "weight", "thrust", "top_speed", "drag_left_right",
	"drag_top_bottom", "drag_front_back", "camera_angle", "camera_fov", "camera_fisheye", "rotation", "turtle",
	"corner_drag", "idle_rpm", "sound_pitch", "battery_mah", "battery_cells", "battery_lihv",
	"battery_full_throttle_amps", "battery_idle_amps", "battery_resistance_mohm", "prop_mm", "ducted",
	"wheelbase_mm", "motor_ms", "craft_name", "hide"]
# ... under these small titles, each before the first of its settings
const PAGE_GROUPS := {"weight": "Flight", "battery_mah": "Battery", "prop_mm": "Props and motors", "craft_name": "OSD"}
const PAGE_LABELS := {"base": "Built on", "weight": "Weight (g)", "thrust": "Thrust (g)", "top_speed": "Top speed (km/h)",
	"drag_left_right": "Drag left/right (%)", "drag_top_bottom": "Drag top/bottom (%)",
	"drag_front_back": "Drag front/back (%)", "camera_angle": "Camera angle (degrees)", "camera_fov": "Camera FOV",
	"rotation": "Rotation torque", "turtle": "Turtle torque", "idle_rpm": "Idle rpm", "battery_lihv": "Battery LiHV",
	"craft_name": "OSD craft name", "hide": "Hide"}
const PAGE_NOTES := {
	"name": "Its name in the drone list.",
	"description": "Shown under its name in the drone list.",
	"base": "The game drone it is built on: its body, collision shape and sound, and every setting the block leaves out.",
	"weight": "All-up, battery included. A few grams change how a whoop flies.",
	"thrust": "All the motors together at full throttle: the maker's thrust-to-weight ratio times the weight.",
	"top_speed": "How fast the air through the props can go before they have lost half their push.",
	"drag_left_right": "Drag moving sideways, in percent of the base drone's; smaller = slipperier.",
	"drag_top_bottom": "Drag moving up and down, in percent of the base drone's.",
	"drag_front_back": "Drag moving forwards, in percent of the base drone's.",
	"camera_angle": "Camera uptilt.",
	"camera_fov": "The game's camera FOV setting.",
	"camera_fisheye": "The game's fisheye strength, 0-100.",
	"rotation": "Torque the motors have to turn the drone; higher = the rates are reached sooner.",
	"turtle": "Torque in turtle mode.",
	"corner_drag": "Extra drag from the spinning props, at full rpm.",
	"idle_rpm": "Motor rpm at zero throttle while armed.",
	"sound_pitch": "Motor sound pitch, added to the game's.",
	"battery_mah": "Pack size, for battery_sag (and fpv_osd's readout without it).",
	"battery_cells": "Cells in series.",
	"battery_lihv": "On = LiHV (4.35 V a cell full), off = LiPo (4.20 V).",
	"battery_full_throttle_amps": "The whole drone's draw at full thrust on a fresh pack.",
	"battery_idle_amps": "Flight controller, receiver, camera and VTX.",
	"battery_resistance_mohm": "A cell and its lead; higher = more sag.",
	"craft_name": "Shown on the OSD while you fly it (fpv_osd).",
	"hide": "On = left out of the drone list, without deleting its block. Takes effect at the next start.",
}


func zm_init(core: Node, _dir: String) -> void:
	_core = core
	_say("drones %s" % VERSION)
	SPECS.read_settings()
	_list_figures()
	_read_blocks()
	var want := 0
	for id in _block_order:
		if not _truth(_blocks[id].get("hide", false)):
			want += 1
	if want == 0:
		_say("no drones to add from my_drones.cfg (it comes with a Meteor75 Pro II commented out: take the \"; \" off its lines and restart to add it); the game's drone list and multiplayer are left as they are")
	elif _prepare():
		_check_presets()
		if _order.is_empty():
			_say("none of the drones could be added: nothing to add")
		elif _mount():
			_on = true
			var names := []
			for id in _order:
				names.append("%s [%s] on the game's %s" % [_presets[id].get("name", id), id, _game_names.get(_presets[id]["base"], _presets[id]["base"])])
			_say("added after the game's own drones: " + ", ".join(names))
			_say("in multiplayer each is sent as the game drone it is built on; race runs on them are not sent to the online leaderboard")
	_write_status()


## Called by mod_settings when settings.cfg or my_drones.cfg has been
## changed in the game: the figures and the added drones' blocks read again
## (the physics mods take them on their next tick; the game the rest when it
## next goes on from the pause menu)
func zm_apply_settings() -> void:
	var changed := _reread_blocks()
	SPECS.read_settings()
	_say("figures read again: the mods using them take them on their next physics tick")
	_list_figures()
	if not changed.is_empty():
		_say("my_drones.cfg read again: %s changed - the game takes them when it next goes on from the pause menu" % ", ".join(changed))
		for id in changed:
			_tell_changed(id)
	_write_status()


## mod_settings: the added drones (and hidden ones), each with the settings
## its block has, written into my_drones.cfg
func zm_settings_more() -> Array:
	var items := []
	var c := ConfigFile.new()
	if c.load(_game_dir().path_join("my_drones.cfg")) != OK:
		return items
	var ident := RegEx.create_from_string("^[a-z0-9_]+$")
	for id in c.get_sections():
		var hidden := _truth(c.get_value(id, "hide", false))
		var was_hidden: bool = id in _block_order and _truth(_blocks[id].get("hide", false))
		var added: bool = id in _order
		if not (added or ((hidden or was_hidden) and ident.search(id) != null and not id in _game_ids)):
			continue
		var base := str(c.get_value(id, "base", ""))
		var text := str(c.get_value(id, "description", ""))
		if not added:
			text = "Hidden (hide=true): not in the drone list this time. Changes take effect at the next start."
		elif not _on:
			text = "Not added this time (see status.txt): changes take effect at the next start."
		else:
			text = (text.trim_suffix(".") + ". " if text != "" else "") + "Built on the game's %s; set up in my_drones.cfg." % _game_names.get(base, base)
			if hidden:
				text += " Hidden from the next start (hide=true)."
		items.append({"kind": "section", "section": id, "file": "my_drones.cfg", "text": text,
			"title": str(c.get_value(id, "name", id)) + (" (hidden)" if hidden or not added else "")})
		var keys := Array(c.get_section_keys(id))
		var group := ""
		for k in PAGE_KEYS:
			if PAGE_GROUPS.has(k):
				group = PAGE_GROUPS[k]
			if not k in keys:
				continue
			if group != "":
				items.append({"kind": "group", "section": id, "file": "my_drones.cfg", "text": group})
				group = ""
			var it := {"kind": "value", "section": id, "file": "my_drones.cfg", "key": k,
				"default": var_to_str(c.get_value(id, k)), "desc": PAGE_NOTES.get(k, ""), "label": PAGE_LABELS.get(k, "")}
			if k == "base":
				it["options"] = _game_ids.duplicate()
				it["option_names"] = _game_names.duplicate()
			items.append(it)
	return items


## mod_settings: what of my_drones.cfg waits for a restart - hide=, and all of
## a drone not added this time
func zm_restart_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for id in _block_order:
		if _on and id in _order:
			out.append("my_drones.cfg|%s/hide" % id)
		else:
			out.append("my_drones.cfg|%s/*" % id)
	return out


## mod_settings: how the page's changes take effect
func zm_settings_status() -> String:
	if _on and not _order.is_empty():
		return "Changes take effect at once, except those marked restart; an added drone's weight, thrust, drag, camera and sound when the game next goes on from the pause menu."
	return ""


# The added drones' blocks, read again: those that still pass the checks
# take their new settings (a drone is not added or taken out until the next
# start). The ids changed.
func _reread_blocks() -> Array:
	var changed := []
	if not _on:
		return changed
	var c := ConfigFile.new()
	if c.load(_game_dir().path_join("my_drones.cfg")) != OK:
		return changed
	for id in _order:
		if not c.has_section(id):
			continue
		var b := {}
		for k in c.get_section_keys(id):
			b[k] = c.get_value(id, k)
		var ok := _checked(id, b)
		if ok.is_empty():
			_say("[%s]: kept as it was" % id)
			continue
		if ok.has("hide"):
			ok.erase("hide")
		var was: Dictionary = _presets[id].duplicate()
		was.erase("hide")
		if ok != was:
			_presets[id] = ok
			changed.append(id)
	return changed


# The mods using an added drone (battery_sag, fpv_osd) told it changed
func _tell_changed(id: String) -> void:
	if _core == null or not _core.has_method("get_mods"):
		return
	for m in _core.call("get_mods"):
		if m != self and is_instance_valid(m) and m.has_method("zm_vehicle_changed"):
			m.call("zm_vehicle_changed", id)


func _list_figures() -> void:
	for id in SPECS.ids():
		var d: Dictionary = SPECS.figures(id)
		_say("%s: %s" % [d["name"], SPECS.describe(d)])


func _game_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("drones")


# ---- the added drones ----

func _read_blocks() -> void:
	var mine := _game_dir().path_join("my_drones.cfg")
	var tmpl := _game_dir().path_join("my_drones.template.cfg")
	if not FileAccess.file_exists(mine) and FileAccess.file_exists(tmpl):
		var f := FileAccess.open(mine, FileAccess.WRITE)
		if f != null:
			f.store_string(FileAccess.get_file_as_string(tmpl))
			f.close()
			_say("made my_drones.cfg, for your own drones")
	if not FileAccess.file_exists(mine):
		return
	var c := ConfigFile.new()
	var err := c.load(mine)
	if err != OK:
		_say("my_drones.cfg: could not read it (%s) - check the line the error names, and that text values are in quotes" % error_string(err))
		return
	for id in c.get_sections():
		if not _blocks.has(id):
			_blocks[id] = {}
			_block_order.append(id)
		for k in c.get_section_keys(id):
			_blocks[id][k] = c.get_value(id, k)


func _check_presets() -> void:
	for id in _block_order:
		if _truth(_blocks[id].get("hide", false)):
			continue
		var b := _checked(id, _blocks[id].duplicate())
		if not b.is_empty():
			_presets[id] = b
			_order.append(id)


# A block as it is added: {} if it is left out (and why said), otherwise
# without the settings it has wrong (and those said)
func _checked(id: String, b: Dictionary) -> Dictionary:
	var ident := RegEx.create_from_string("^[a-z0-9_]+$")
	if ident.search(id) == null:
		_say("[%s]: left out - a drone's [name] is lowercase letters, digits and _ only" % id)
		return {}
	if id in _game_ids:
		_say("[%s]: left out - that is one of the game's own drones; give yours another [name]" % id)
		return {}
	if not b.has("base") or not (str(b["base"]) in _game_ids):
		_say("[%s]: left out - base= must be one of the game's drones: %s" % [id, ", ".join(_game_ids)])
		return {}
	var bad := []
	for k in b.keys():
		if k == "battery_lihv" or k == "hide" or k == "ducted":
			if typeof(b[k]) != TYPE_BOOL:
				bad.append("%s (true or false, without quotes)" % k)
				b.erase(k)
			continue
		if KEYS.has(k) or BATTERY_KEYS.has(k) or ROTOR_KEYS.has(k) or MOTOR_KEYS.has(k):
			if typeof(b[k]) != TYPE_INT and typeof(b[k]) != TYPE_FLOAT:
				bad.append("%s (a number, without quotes)" % k)
				b.erase(k)
		elif not (k in OTHER_KEYS):
			bad.append("%s (not a setting)" % k)
			b.erase(k)
	if not bad.is_empty():
		_say("[%s]: ignored: %s" % [id, ", ".join(bad)])
	b["base"] = str(b["base"])
	return b


# ---- what the rest of the game and the other mods ask ----

## The presets, as entries of the game's drone list (called by vehicles.gd
## every time the game asks for its list: fresh copies each time, as the game
## changes them)
func vehicles_for(game_list: Array) -> Array:
	var out := []
	if not _on:
		return out
	var by_id := {}
	for v in game_list:
		by_id[str(v.id)] = v
	for id in _order:
		if by_id.has(id) or not by_id.has(_presets[id]["base"]):
			continue
		out.append(_entry(id, _presets[id], by_id[_presets[id]["base"]]))
	return out


func _entry(id: String, b: Dictionary, base: Dictionary) -> Dictionary:
	var v: Dictionary = base.duplicate(true)
	v["id"] = id
	v["name"] = str(b.get("name", id))
	v["description"] = str(b.get("description", "%s - built on the game's %s" % [v["name"], base.get("name", b["base"])]))
	for k in KEYS:
		if not b.has(k):
			continue
		var where: Array = KEYS[k]
		var val = b[k]
		if typeof(val) == TYPE_INT or typeof(val) == TYPE_FLOAT:
			# as decimals, as the Physics menu saves them: the drone list works
			# out "Power / weight ratio" as thrust / weight, which for two
			# whole numbers GDScript rounds down (266 / 42 = 6, not 6.3)
			val = float(val)
			if where[0] == "":
				v[where[1]] = val
			elif v.get(where[0]) is Dictionary:
				v[where[0]][where[1]] = val
	if v.get("adjustable_settings") is Dictionary and float(v["adjustable_settings"].get("weight", 1.0)) < 1.0:
		v["adjustable_settings"]["weight"] = 1.0
	return v


# true/false as written in a .cfg (a number or text too, rather than fail)
static func _truth(v) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			return str(v).strip_edges().to_lower() in ["true", "yes", "1"]
	return false


## The game drone a preset is built on, or "" for any other id
func base_of(id: String) -> String:
	return str(_presets[id]["base"]) if _on and _presets.has(id) else ""


## A preset, for other mods: id, name, base, battery (battery_sag's names,
## only those the block sets), rotor (rotor_drag's and dirty_air's, the
## same), motor (motor_response's) and craft_name; {} for any other id
func zm_vehicle(id: String) -> Dictionary:
	if not _on or not _presets.has(id):
		return {}
	var b: Dictionary = _presets[id]
	var bat := {}
	for k in BATTERY_KEYS:
		if b.has(k):
			var val = b[k]
			if k == "battery_lihv":
				val = _truth(val)
			elif k == "battery_cells":
				val = clampi(int(val), 1, 8)
			else:
				val = float(val)
			bat[BATTERY_KEYS[k]] = val
	var rotor := {}
	for k in ROTOR_KEYS:
		if b.has(k):
			rotor[ROTOR_KEYS[k]] = _truth(b[k]) if k == "ducted" else float(b[k])
	var motor := {}
	for k in MOTOR_KEYS:
		if b.has(k):
			motor[MOTOR_KEYS[k]] = float(b[k])
	return {"id": id, "name": str(b.get("name", id)), "base": str(b["base"]), "battery": bat,
		"rotor": rotor, "motor": motor, "craft_name": str(b.get("craft_name", ""))}


## api.gd: a race run on a preset was not sent to the leaderboard
func race_not_sent(id: String) -> void:
	if not _raced.has(id):
		_raced[id] = true
		_say("race runs on %s are not sent to the online leaderboard" % id)
		_write_status()


func _process(_delta: float) -> void:
	if not _first_frame:
		return
	_first_frame = false
	set_process(false)
	# The game's Physics menu saves its values for the drone in view, presets
	# too. The block is the preset: values kept from an earlier session would
	# hide changes made to it since, so they go at each launch.
	var zs := get_node_or_null("/root/ZSettings")
	var vs = zs.get("VEHICLE_SETTINGS") if zs != null else null
	if _on and vs is Dictionary:
		var gone := []
		for id in _order:
			if vs.has(id):
				vs.erase(id)
				gone.append(id)
		if not gone.is_empty():
			_say("the Physics menu's saved values for %s set aside: its block in my_drones.cfg sets it" % ", ".join(gone))
			_write_status()


# ---- putting it in the game ----

# Makes the copies of the game's scripts and checks them and the stand-ins;
# reads the game's own drones from the copy of its list.
func _prepare() -> bool:
	var dir := _game_dir()
	DirAccess.make_dir_recursive_absolute(dir.path_join("base"))
	for s in SCRIPTS:
		var why := _derive("res://%s.gdc" % s["game"], dir.path_join(s["copy"]), s["class"])
		if why != "":
			_say("nothing added: %s.gd - %s. The game runs as without this mod; an update of it is needed" % [s["game"], why])
			return false
		var copy = load(DIR + s["copy"])
		if not (copy is Script) or not copy.can_instantiate():
			_say("nothing added: the copy of %s.gd does not load; an update of this mod is needed" % s["game"])
			return false
		var have := {}
		for m in copy.get_script_method_list():
			have[m["name"]] = (m["args"] as Array).size()
		for m in s["needs"]:
			if not have.has(m) or have[m] != s["needs"][m]:
				_say("nothing added: %s.gd has no %s() with %d arguments any more; an update of this mod is needed" % [s["game"], m, s["needs"][m]])
				return false
		var ours = load(DIR + s["ours"])
		if not (ours is Script) or not ours.can_instantiate():
			_say("nothing added: %s does not work with this version of the game; an update of this mod is needed" % s["ours"])
			return false
	var list = load(DIR + "base/default_vehicles.gdc").get_vehicles()
	if not (list is Array) or list.is_empty():
		_say("nothing added: the game's drone list is not what this expects; an update of this mod is needed")
		return false
	for v in list:
		if not (v is Dictionary) or not v.has("id") or not (v.get("adjustable_settings") is Dictionary) or not (v.get("internal_settings") is Dictionary):
			_say("nothing added: the game's drone list is not what this expects; an update of this mod is needed")
			return false
		_game_ids.append(str(v["id"]))
		_game_names[str(v["id"])] = str(v.get("name", v["id"]))
	return true


# Mounts the pack that points the game's three scripts at the stand-ins, and
# checks the game now gets them. Before any of the game's own scenes load, so
# the game has not loaded the originals yet; if it had, it would keep them,
# and then the presets stay out, as they would not be safe in multiplayer.
func _mount() -> bool:
	var dir := _game_dir()
	var pck := dir.path_join("remap.pck")
	var pk := PCKPacker.new()
	if pk.pck_start(pck) != OK:
		_say("nothing added: could not write %s" % pck)
		return false
	for s in SCRIPTS:
		pk.add_file("res://%s.gd.remap" % s["game"], dir.path_join("remap/%s.gd.remap" % str(s["game"]).get_file()))
	if pk.flush() != OK or not ProjectSettings.load_resource_pack(pck, true):
		_say("nothing added: could not mount %s" % pck)
		return false
	for s in SCRIPTS:
		var got = load("res://%s.gd" % s["game"])
		if not (got is Script) or not got.get_script_constant_map().has("ZM_DRONES"):
			_say("nothing added: the game already had %s.gd loaded before this mod started" % s["game"])
			return false
	return true


# Copies one of the game's compiled scripts, with its class_name changed by
# one letter's case: a copy under another path may not claim the game's class
# name, and in its place the copy could not be extended by the stand-in.
func _derive(src: String, dst: String, cls: String) -> String:
	if not FileAccess.file_exists(src):
		return "the game has no " + src
	var d := FileAccess.get_file_as_bytes(src)
	if d.size() < 12 or d.slice(0, 4).get_string_from_ascii() != "GDSC" or d.decode_u32(4) != 101:
		return "not a script this knows (Godot 4.5 compiled GDScript)"
	var dsize := d.decode_u32(8)
	var body := d.slice(12)
	if dsize != 0:
		body = body.decompress(dsize, FileAccess.COMPRESSION_ZSTD)
		if body.size() != dsize:
			return "could not unpack it"
	var nid := body.decode_u32(0)
	var p := 16
	var renamed := false
	for i in nid:
		var n := body.decode_u32(p)
		p += 4
		if n == cls.length():
			var s := ""
			for k in n:
				s += char(body.decode_u32(p + 4 * k) ^ 0xb6b6b6b6)
			if s == cls:
				body.encode_u32(p, (cls.unicode_at(0) - 32) ^ 0xb6b6b6b6)
				renamed = true
		p += 4 * n
	if not renamed:
		return "its class_name is not %s" % cls
	var out := d.slice(0, 12)
	out.append_array(body.compress(FileAccess.COMPRESSION_ZSTD) if dsize != 0 else body)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return "could not write %s" % dst
	f.store_buffer(out)
	f.close()
	return ""


func _say(s: String) -> void:
	_log.append(s)
	print("[drones] " + s)


func _write_status() -> void:
	var f := FileAccess.open(_game_dir().path_join("status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
