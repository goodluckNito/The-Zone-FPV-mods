extends Node
## battery_sag: a flight pack that drains, sags under load and changes how the
## quad flies.
##
## The pack, per cell (an equivalent-circuit model):
##   resting voltage   follows the state of charge on a LiHV or LiPo curve,
##                     dropping away fast once the rated capacity is used up
##   under load        minus current x internal resistance straight away, plus
##                     two polarisation drops that build and recover over about
##                     1.5 s and 40 s - so a punch dips at once and deepens,
##                     and a long flight sags more than a short one; the
##                     resistance rises as the pack empties
## The current comes from how hard the motors work: the thrust the game's
## flight model is making, as a share of the quad's full thrust, gives the
## motor current (full_throttle_amps at full thrust, rising as thrust^1.3,
## since props need more power per gram the harder they push), plus idle_amps
## for the flight controller, receiver, camera and VTX.
##
## Handling: the game's quad has a battery voltage that sets how fast its
## motors can spin (BAT_CURRENT_VOLTAGE, normally fixed at full). Each physics
## tick, before the quad's own, this sets it from the pack's voltage under load
## against a fresh pack's at the same current. A fresh pack flies exactly as
## the game is tuned; as it drains and sags the quad needs more throttle to
## hover and punches weaker, until a flat pack can barely hold it up. The
## game's own value comes back when the mod is not driving it.
##
## Packs: each of the game's quads gets a pack of its own (PACKS, and a
## section of settings.cfg per quad), picked from the quad you have selected
## and swapped in fresh when you change quad.

const DEFAULTS := {
	"sag_effect": 1.0,
	"sag_compensation": 0.0,
	"new_pack_on_respawn": "disarmed",
}

# A common pack for each of the game's quad presets (by the game's vehicle id),
# and for anything else. full_throttle_amps is the whole quad at full thrust on
# a fresh pack; idle_amps the flight controller, receiver, camera and VTX;
# resistance_mohm a cell and its share of the lead and connector.
const PACKS := {
	"65mm_freestyle": {"name": "65mm Whoop", "capacity_mah": 300, "cells": 1, "lihv": true,
		"full_throttle_amps": 15.0, "idle_amps": 0.9, "resistance_mohm": 37.0},
	"85mm_freestyle": {"name": "85mm Whoop", "capacity_mah": 450, "cells": 2, "lihv": true,
		"full_throttle_amps": 30.0, "idle_amps": 0.45, "resistance_mohm": 14.0},
	"2.5in_freestyle": {"name": "2.5\" Freestyle", "capacity_mah": 550, "cells": 2, "lihv": true,
		"full_throttle_amps": 36.0, "idle_amps": 0.45, "resistance_mohm": 12.0},
	"3.5in_freestyle": {"name": "3.5\" Freestyle", "capacity_mah": 850, "cells": 4, "lihv": false,
		"full_throttle_amps": 55.0, "idle_amps": 0.35, "resistance_mohm": 6.5},
	"5in_freestyle": {"name": "5\" Freestyle", "capacity_mah": 1300, "cells": 6, "lihv": false,
		"full_throttle_amps": 147.0, "idle_amps": 0.3, "resistance_mohm": 4.3},
	"beginner_5_in_quad": {"name": "Beginner 5\"", "capacity_mah": 1500, "cells": 4, "lihv": false,
		"full_throttle_amps": 90.0, "idle_amps": 0.35, "resistance_mohm": 3.2},
	"5in_racer": {"name": "5\" Racer", "capacity_mah": 1100, "cells": 6, "lihv": false,
		"full_throttle_amps": 170.0, "idle_amps": 0.3, "resistance_mohm": 4.1},
	"other": {"name": "any other quad", "capacity_mah": 550, "cells": 1, "lihv": true,
		"full_throttle_amps": 26.0, "idle_amps": 0.9, "resistance_mohm": 20.0},
}

# Resting voltage of a cell against state of charge (the usual LiPo chart; LiHV
# the same shape, 0.15 V higher when full). Below 0 - the rated capacity used
# up - it falls away quickly.
const LIPO := [[-0.10, 2.70], [0.00, 3.27], [0.05, 3.61], [0.10, 3.69], [0.15, 3.71],
	[0.20, 3.73], [0.25, 3.75], [0.30, 3.77], [0.35, 3.79], [0.40, 3.80], [0.45, 3.82],
	[0.50, 3.84], [0.55, 3.85], [0.60, 3.87], [0.65, 3.91], [0.70, 3.95], [0.75, 3.98],
	[0.80, 4.02], [0.85, 4.08], [0.90, 4.11], [0.95, 4.15], [1.00, 4.20]]
const LIHV := [[-0.10, 2.70], [0.00, 3.270], [0.05, 3.612], [0.10, 3.695], [0.15, 3.719],
	[0.20, 3.743], [0.25, 3.769], [0.30, 3.795], [0.35, 3.821], [0.40, 3.838], [0.45, 3.865],
	[0.50, 3.893], [0.55, 3.911], [0.60, 3.940], [0.65, 3.989], [0.70, 4.038], [0.75, 4.077],
	[0.80, 4.127], [0.85, 4.198], [0.90, 4.238], [0.95, 4.289], [1.00, 4.350]]

# Polarisation: resistance (times the ohmic one) and time constant, fast and slow
const POL_FAST := 0.4
const TAU_FAST := 1.5
const POL_SLOW := 1.5
const TAU_SLOW := 40.0
# Motor current against thrust share
const THRUST_EXP := 1.3

var cfg := {}
var packs := {}              # PACKS with settings.cfg's sections applied
var pack := {}               # the one in use
var pack_id := ""

# the pack - read by zm_battery() and the tests
var mah_used := 0.0
var current := 0.0
var cell_voltage := 4.33
var thrust_share := 0.0
var voltage_scale := 1.0     # what BAT_CURRENT_VOLTAGE was set to, against full

var _r0 := 0.02             # ohms per cell, full pack
var _vf := 0.0
var _vs := 0.0
var _vk := 1.0              # smoothed voltage ratio used for the motors
var _scene: Node = null
var _player: Node = null
var _vmax := 22.2
var _driving := false
var _t_retry := 0.0
var _last_pos := Vector3.ZERO
var _have_pos := false
var _at_spawn := false
var _spawn_last := Vector3.ZERO
var _have_spawn := false
var _r_key := false
var _sw_last = null


## Reads settings.cfg: [battery] and a section per quad. Returns a line for
## status.txt.
func setup(dir: String) -> String:
	cfg = DEFAULTS.duplicate()
	packs = {}
	for id in PACKS:
		packs[id] = (PACKS[id] as Dictionary).duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK:
		if c.has_section("battery"):
			for k in c.get_section_keys("battery"):
				if cfg.has(k):
					cfg[k] = c.get_value("battery", k)
		for id in packs:
			if c.has_section(id):
				for k in c.get_section_keys(id):
					if packs[id].has(k):
						packs[id][k] = c.get_value(id, k)
	use_pack("")
	var parts := PackedStringArray()
	for id in packs:
		parts.append("%s %s" % [packs[id]["name"], describe(packs[id])])
	return "battery: a pack for each quad - " + ", ".join(parts) + "; sag_effect %s" % str(cfg["sag_effect"])


## "4S 850 mAh LiPo"
static func describe(p: Dictionary) -> String:
	return "%dS %d mAh %s" % [clampi(int(p["cells"]), 1, 8), int(p["capacity_mah"]), "LiHV" if bool(p["lihv"]) else "LiPo"]


## Puts in a fresh pack of the kind for this vehicle id (or "other").
func use_pack(vehicle_id: String) -> void:
	pack_id = vehicle_id
	pack = packs.get(vehicle_id, packs["other"])
	var mohm := float(pack["resistance_mohm"])
	if mohm <= 0.0:
		# about 20 mOhm for a 550 mAh whoop cell and its lead; bigger packs of
		# better cells much less
		var cap := maxf(float(pack["capacity_mah"]), 50.0)
		mohm = 11000.0 / cap if int(pack["cells"]) <= 2 else 5000.0 / cap + 0.5
	_r0 = mohm / 1000.0
	new_pack()


## A fresh pack for this quad, and a line in status.txt saying which.
func _switch_to(vehicle_id: String) -> void:
	use_pack(vehicle_id)
	if get_parent() != null and get_parent().has_method("pack_changed"):
		get_parent().call("pack_changed", "%s: %s" % [pack["name"], describe(pack)])


func _vehicle_id() -> String:
	var gs := get_node_or_null("/root/ZGamestate")
	var v = gs.get("selected_vehicle_id") if gs != null else null
	return str(v) if v != null else ""


func _ready() -> void:
	# run before the quad's own physics, so it flies on this tick's voltage
	process_physics_priority = -100


func cells() -> int:
	return clampi(int(pack["cells"]), 1, 8)


func capacity_mah() -> float:
	return maxf(float(pack["capacity_mah"]), 50.0)


func new_pack() -> void:
	mah_used = 0.0
	current = 0.0
	_vf = 0.0
	_vs = 0.0
	_vk = 1.0
	cell_voltage = ocv(1.0)


func soc() -> float:
	return 1.0 - mah_used / capacity_mah()


func ocv(s: float) -> float:
	var curve: Array = LIHV if bool(pack["lihv"]) else LIPO
	if s <= curve[0][0]:
		return curve[0][1]
	for i in range(1, curve.size()):
		if s <= curve[i][0]:
			var a = curve[i - 1]
			var b = curve[i]
			return lerpf(a[1], b[1], (s - a[0]) / (b[0] - a[0]))
	return curve[-1][1]


## Internal resistance of a cell (ohms) at state of charge s: flat for most of
## the pack, rising towards empty and more once past it.
func resistance(s: float) -> float:
	var used := 1.0 - clampf(s, 0.0, 1.0)
	return _r0 * (1.0 + 0.8 * pow(used, 4.0)) * (1.0 + 3.0 * maxf(-s, 0.0))


## One step of the pack: current in amps for dt seconds.
func step(amps: float, dt: float) -> void:
	current = amps
	mah_used += amps * dt / 3.6
	var s := soc()
	var r := resistance(s)
	_vf += (amps * r * POL_FAST - _vf) * (1.0 - exp(-dt / TAU_FAST))
	_vs += (amps * r * POL_SLOW - _vs) * (1.0 - exp(-dt / TAU_SLOW))
	cell_voltage = maxf(ocv(s) - amps * r - _vf - _vs, 0.0)


## Current for a thrust share (0 = motors stopped, 1 = the quad's full thrust).
func amps_for(share: float, armed: bool) -> float:
	var a := float(pack["idle_amps"])
	if armed:
		a += float(pack["full_throttle_amps"]) * pow(clampf(share, 0.0, 1.5), THRUST_EXP)
	return a


## Motor voltage against full: the loaded voltage over a fresh pack's at the
## same current, then sag_effect and Betaflight-style sag compensation.
func motor_scale(throttle: float) -> float:
	var fresh := ocv(1.0) - current * _r0
	var k := clampf(cell_voltage / maxf(fresh, 0.5), 0.2, 1.0)
	var e := clampf(float(cfg["sag_effect"]), 0.0, 1.0)
	k = 1.0 - e * (1.0 - k)
	# vbat_sag_compensation: the flight controller turns the motor output up
	# to make up for sag - but never past 100%
	var comp := clampf(float(cfg["sag_compensation"]) / 100.0, 0.0, 1.0)
	return lerpf(k, minf(1.0, k / maxf(throttle, 0.01)), comp)


func report() -> Dictionary:
	return {"cell_voltage": cell_voltage, "mah_used": mah_used, "cells": cells(), "current": current,
		"lihv": bool(pack["lihv"]), "capacity_mah": capacity_mah(), "pack": describe(pack)}


func _physics_process(dt: float) -> void:
	var cs := get_tree().current_scene
	_t_retry += dt
	if cs != _scene or (_player == null and _t_retry > 1.0):
		_release()
		_scene = cs
		_t_retry = 0.0
		_player = cs.find_child("Player", true, false) if cs != null else null
		_have_pos = false
		if _player != null:
			var consts = _player.get_script().get_script_constant_map() if _player.get_script() != null else {}
			_vmax = float(consts.get("BAT_MAX_VOLTAGE", 22.2))
			_switch_to(_vehicle_id())
	if _player == null or not is_instance_valid(_player):
		_player = null
		return
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return
	# the quad chosen in the game's menu; a different one gets its own pack
	var vid := _vehicle_id()
	if vid != pack_id:
		_switch_to(vid)
	var p := _player
	var armed := bool(p.call("is_armed")) if p.has_method("is_armed") else false
	var t = p.get("throttle_input")
	var throttle := clampf(float(t), 0.0, 1.0) if t != null else 0.0
	_check_respawn(p, armed)
	# how hard the motors are working, from the game's own thrust
	var share := throttle
	var st = p.get("_SETTINGS")
	var quad := p.get("physics_handler") == null and p.has_method("get_thrust_at_rpm") and p.get("current_motor_rpm") != null
	if quad and st is Dictionary and st.has("adjustable_settings"):
		var full := float(st["adjustable_settings"].get("thrust", 0.0)) / 1000.0 * 9.8
		if full > 0.0:
			share = float(p.call("get_thrust_at_rpm", float(p.get("current_motor_rpm")))) / full
	thrust_share = share if armed else 0.0
	step(amps_for(thrust_share, armed), dt)
	if not quad or float(cfg["sag_effect"]) <= 0.0:
		_release()
		return
	# a short smoothing so the voltage and the motors do not chase each other
	# from one tick to the next
	_vk += (motor_scale(throttle) - _vk) * (1.0 - exp(-dt / 0.03))
	voltage_scale = _vk
	p.set("BAT_CURRENT_VOLTAGE", _vmax * _vk)
	_driving = true


# A respawn: the game's R key; the radio's respawn switch (seen as the game
# does it, ingame_main.gd's _respawn_switch_cycled flipping off); or the quad
# arriving exactly on the game's respawn point, or moving more than 4 m in one
# tick. The spawn point itself moving onto the quad - S saving where you are,
# X going back to the map's, a race track's - is not one.
func _check_respawn(p: Node, armed: bool) -> void:
	if not (p is Node3D):
		return
	var pos := (p as Node3D).global_position
	var at_spawn := false
	var moved := false
	var gs := get_node_or_null("/root/ZGamestate")
	var rt = gs.get("respawn_transform") if gs != null else null
	if rt is Transform3D:
		at_spawn = pos.distance_to(rt.origin) < 0.05
		moved = _have_spawn and rt.origin.distance_to(_spawn_last) > 0.001
		_spawn_last = rt.origin
		_have_spawn = true
	var cs := get_tree().current_scene
	var sw = cs.get("_respawn_switch_cycled") if cs != null else null
	var radio: bool = sw is bool and _sw_last is bool and _sw_last and not sw
	_sw_last = sw
	var jumped := _have_pos and pos.distance_to(_last_pos) > 4.0
	var arrived := _have_pos and at_spawn and not _at_spawn and not moved
	var respawned := _r_key or radio or jumped or arrived
	_r_key = false
	if respawned:
		match str(cfg["new_pack_on_respawn"]):
			"always":
				new_pack()
			"never":
				pass
			_:
				if not armed:
					new_pack()
	_at_spawn = at_spawn
	_last_pos = pos
	_have_pos = true


# The game's respawn key, taken as ingame_main.gd takes it: R, unless the
# game is paused or you are typing in the chat.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_R and not _typing():
		_r_key = true


func _typing() -> bool:
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return true
	var cs := get_tree().current_scene
	var chat := cs.get_node_or_null("%ChatInput") if cs != null else null
	return chat != null and chat.has_method("is_editing") and bool(chat.call("is_editing"))


func _release() -> void:
	if _driving and _player != null and is_instance_valid(_player):
		_player.set("BAT_CURRENT_VOLTAGE", _vmax)
	_driving = false
	voltage_scale = 1.0


func _exit_tree() -> void:
	_release()
