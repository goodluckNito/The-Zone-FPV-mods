extends RefCounted
## drones: each drone's props, frame and motors - the figures the physics
## mods share - read from drones/settings.cfg (a section per game drone), so
## each is set in one place. rotor_drag, dirty_air, motor_response and
## flight_controller load this script by its path:
##     var specs = load("res://drones/specs.gd")
##     var d: Dictionary = specs.figures(vehicle_id, core)
## d has name, base (the game drone it is, or is built on, or "other"),
## prop_mm, ducted, wheelbase_mm and motor_ms. A drone this mod adds gets what
## its block sets (through zm_vehicle), the rest from the drone it is built
## on; any other id gets [other]'s. It works whether or not the mod adds any
## drones. generation() goes up each time the settings are read again - after
## a change in the game, through mod_settings - so a mod knows to look again.

const DIR := "res://drones/"
const KEYS := ["prop_mm", "ducted", "wheelbase_mm", "motor_ms"]
const NAMES := {
	"65mm_freestyle": "65mm Whoop", "85mm_freestyle": "85mm Whoop", "2.5in_freestyle": "2.5\" Freestyle",
	"3.5in_freestyle": "3.5\" Freestyle", "5in_freestyle": "5\" Freestyle", "beginner_5_in_quad": "Beginner 5\"",
	"5in_racer": "5\" Racer", "other": "any other quad",
}
# only if a figure is missing from both settings files
const LAST_RESORT := {"prop_mm": 40.0, "ducted": true, "wheelbase_mm": 75.0, "motor_ms": 30.0}

static var _table := {}
static var _gen := 0


## Reads the settings again: settings.default.cfg, then settings.cfg over it
## (a line deleted there is the default again)
static func read_settings() -> void:
	var t := {}
	for f in ["settings.default.cfg", "settings.cfg"]:
		var c := ConfigFile.new()
		if c.load(DIR + f) != OK:
			continue
		for sec in c.get_sections():
			if sec == "mod":
				continue
			if not t.has(sec):
				t[sec] = {"name": str(NAMES.get(sec, sec))}
			for k in KEYS:
				if c.has_section_key(sec, k):
					t[sec][k] = value(k, c.get_value(sec, k))
	if not t.has("other"):
		t["other"] = {"name": NAMES["other"]}
	for k in KEYS:
		if not t["other"].has(k):
			t["other"][k] = LAST_RESORT[k]
	_table = t
	_gen += 1


## Goes up each time the settings are read again
static func generation() -> int:
	if _table.is_empty():
		read_settings()
	return _gen


## The game's drones, in the settings' order
static func ids() -> Array:
	if _table.is_empty():
		read_settings()
	return _table.keys()


## A figure as the mods use it: ducted true or false, the rest numbers
static func value(key: String, v):
	if key == "ducted":
		return v if v is bool else str(v).strip_edges().to_lower() in ["true", "yes", "on", "1"]
	return float(v)


## The figures for the drone with this vehicle id
static func figures(vehicle_id: String, core: Node = null) -> Dictionary:
	if _table.is_empty():
		read_settings()
	if _table.has(vehicle_id):
		var g := _full(_table[vehicle_id])
		g["base"] = vehicle_id
		return g
	var v := _preset(vehicle_id, core)
	if not v.is_empty():
		var base := str(v.get("base", ""))
		if not _table.has(base):
			base = "other"
		var d := _full(_table[base])
		d["base"] = base
		for part in ["rotor", "motor"]:
			var r = v.get(part, {})
			if r is Dictionary:
				for k in r:
					if k in KEYS:
						d[k] = value(k, r[k])
		d["name"] = str(v.get("name", vehicle_id))
		return d
	var o := _full(_table["other"])
	o["base"] = "other"
	return o


## "31 mm props in ducts, 65 mm apart, 25 ms motors"
static func describe(d: Dictionary) -> String:
	return "%d mm props%s, %d mm apart, %d ms motors" % [int(round(float(d["prop_mm"]))), " in ducts" if bool(d["ducted"]) else "",
		int(round(float(d["wheelbase_mm"]))), int(round(float(d["motor_ms"])))]


static func _full(d: Dictionary) -> Dictionary:
	var o := d.duplicate()
	for k in KEYS:
		if not o.has(k):
			o[k] = _table["other"].get(k, LAST_RESORT[k])
	if not o.has("name"):
		o["name"] = NAMES["other"]
	return o


# A drone added by the drones mod (or another): its zm_vehicle(id), or {}
static func _preset(vehicle_id: String, core: Node) -> Dictionary:
	if vehicle_id == "" or core == null or not is_instance_valid(core) or not core.has_method("get_mods"):
		return {}
	for m in core.call("get_mods"):
		if is_instance_valid(m) and m.has_method("zm_vehicle"):
			var v = m.call("zm_vehicle", vehicle_id)
			if v is Dictionary and not v.is_empty():
				return v
	return {}
