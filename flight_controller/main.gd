extends Node
## flight_controller 1.1
##
## A flight controller for The Zone FPV's quads: four motors, each with its
## own speed and thrust at its own corner, set by a Betaflight-style rate
## PID and mixer, so the quad turns because some motors push harder than
## others - as a real one does - instead of by the game's idealised torque.
## Off until turned on in settings.cfg (enabled=true).
##
## How: the game's quad is player_rigid_body.gd. This mounts a small resource
## pack that points the game at fc.gd instead: the game's own script (read
## from a copy made at every launch) with its rotation and motor steps handed
## to controller.gd. If the game's script is not what this expects, nothing
## is mounted and the game runs as without this mod. motor_response stands
## aside while this is on: the motors here respond the same way.
##
## Uninstall: delete the flight_controller folder.

const VERSION := "1.1"
const DIR := "res://flight_controller/"
const GAME := "res://player_rigid_body.gdc"
const COPY := "base/player_rigid_body.gdc"

const DEFAULTS := {
	"airmode": true,
	"airmode_start_throttle_percent": 25.0,
	"idle_percent": 5.5,
	"tpa_rate": 65.0,
	"tpa_breakpoint": 1350.0,
	"dterm_lowpass_hz": 100.0,
	"feedforward_smoothing_hz": 30.0,
	"feedforward_max_rate_limit": 90.0,
	"iterm_relax": "RP",
	"iterm_relax_cutoff": 15.0,
	"rotor_inertia": 1.0,
	"gyro_noise": 1.0,
	"iterm_limit": 400.0,
	"iterm_windup": 85.0,
	"braking": true,
	"ground_friction": 0.5,
}
# Each of the game's drones' props, frame and motors: drones/settings.cfg,
# shared with the other mods. Here, what only this mod uses: yaw_torque (a
# prop's drag torque over its thrust, in metres) and the PID profile.
const SPECS_PATH := "res://drones/specs.gd"
const DRONES := {
	"5in_freestyle": {"yaw_torque": 0.011, "pids": "5inch"},
	"5in_racer": {"yaw_torque": 0.011, "pids": "5inch"},
	"beginner_5_in_quad": {"yaw_torque": 0.011, "pids": "5inch"},
	"3.5in_freestyle": {"yaw_torque": 0.009, "pids": "5inch"},
	"2.5in_freestyle": {"yaw_torque": 0.008, "pids": "5inch"},
	"85mm_freestyle": {"yaw_torque": 0.006, "pids": "whoop"},
	"65mm_freestyle": {"yaw_torque": 0.006, "pids": "whoop"},
	"other": {"yaw_torque": 0.006, "pids": "whoop"},
}
# P, I, D, F per axis: Betaflight 4.5's defaults, and a whoop's (BETAFPV's
# Air65 II freestyle tune)
const PIDS := {
	"5inch": {"roll": [45.0, 80.0, 40.0, 120.0], "pitch": [47.0, 84.0, 46.0, 125.0], "yaw": [45.0, 80.0, 0.0, 120.0]},
	"whoop": {"roll": [49.0, 79.0, 38.0, 35.0], "pitch": [59.0, 95.0, 52.0, 43.0], "yaw": [49.0, 79.0, 0.0, 35.0]},
}
# Moment of inertia as mass x (k x wheelbase)^2: open frames (a 5" at 680 g
# about 2e-3 kg m^2 in roll, 3.5e-3 in yaw) and whoops, whose ducts carry
# mass further out (a 28 g 65mm about 1.2e-5 and 2.2e-5, like a Crazyflie)
const GYRATION := {"open": Vector2(0.241, 0.319), "ducted": Vector2(0.318, 0.43)}

var cfg := {}
var drones := {}
var pids := {}
var on := false
var settings_gen := 0            # counts settings.cfg reads, for the controllers
var _specs = null                # the drones mod's specs.gd, or null without it
var _core: Node = null
var _copied := false
var _said := {}
var _log := PackedStringArray()
var _controller_script: Script = null


func zm_init(core: Node, _dir: String) -> void:
	_core = core
	_say("flight_controller %s" % VERSION)
	_read_settings()
	var why := _copy()
	if why != "":
		_say("not in effect: player_rigid_body.gd - %s. The game runs as without this mod; an update of it is needed" % why)
	else:
		_copied = true
	_write_status()


func _read_settings() -> void:
	cfg = DEFAULTS.duplicate()
	drones = {}
	for id in DRONES:
		drones[id] = (DRONES[id] as Dictionary).duplicate()
	pids = {}
	for name in PIDS:
		pids[name] = {}
		for ax in PIDS[name]:
			pids[name][ax] = (PIDS[name][ax] as Array).duplicate()
	var c := ConfigFile.new()
	_specs = load(SPECS_PATH) if ResourceLoader.exists(SPECS_PATH) else null
	if c.load(DIR + "settings.cfg") == OK:
		if c.has_section("flight_controller"):
			for k in c.get_section_keys("flight_controller"):
				if cfg.has(k):
					cfg[k] = c.get_value("flight_controller", k)
		for id in drones:
			if c.has_section(id):
				for k in c.get_section_keys(id):
					if drones[id].has(k):
						drones[id][k] = c.get_value(id, k)
		for name in pids:
			var sec: String = "pids_" + str(name)
			if c.has_section(sec):
				for ax in ["roll", "pitch", "yaw"]:
					var i := 0
					for term in ["p", "i", "d", "f"]:
						if c.has_section_key(sec, ax + "_" + term):
							pids[name][ax][i] = float(c.get_value(sec, ax + "_" + term))
						i += 1
	_say("airmode %s, idle %s percent, TPA %s from %s, I-term relax %s at %s Hz, feedforward limit %s percent, rotor inertia %s, gyro noise %s deg/s, ground friction %s; PIDs (P/I/D/F roll, pitch, yaw) - 5inch %s, whoop %s" % [
		"on" if bool(cfg["airmode"]) else "off", str(cfg["idle_percent"]), str(cfg["tpa_rate"]), str(cfg["tpa_breakpoint"]),
		str(cfg["iterm_relax"]), str(cfg["iterm_relax_cutoff"]), str(cfg["feedforward_max_rate_limit"]), str(cfg["rotor_inertia"]), str(cfg["gyro_noise"]),
		str(cfg["ground_friction"]), _pid_text("5inch"), _pid_text("whoop")])
	settings_gen += 1


## Called by mod_settings when settings.cfg has been changed in the game:
## read again; each quad's controller takes the new figures on its next tick
func zm_apply_settings() -> void:
	_read_settings()
	_said.clear()
	_write_status()


func _pid_text(name: String) -> String:
	var parts := PackedStringArray()
	for ax in ["roll", "pitch", "yaw"]:
		var a: Array = pids[name][ax]
		parts.append("%d/%d/%d/%d" % [int(a[0]), int(a[1]), int(a[2]), int(a[3])])
	return ", ".join(parts)


# After every mod's zm_init and before the game loads its first scene
func _ready() -> void:
	if not _copied:
		return
	var why := "" if _specs != null else "the drones folder is missing (it comes with this mod: extract the zip again)"
	if why == "":
		why = _check()
	if why == "":
		why = _mount()
	if why != "":
		_say("not in effect: " + why)
	else:
		on = true
		_say("in effect: the quads are flown by this flight controller")
	_write_status()


## A controller for one quad (fc.gd asks for it on its first tick)
func new_controller():
	if not on or _controller_script == null:
		return null
	var c = _controller_script.new()
	c.mod = self
	return c


## Everything the controller needs for a drone of this mass
func params_for(vid: String, mass: float) -> Dictionary:
	var d := _drone(vid)
	var wb := clampf(float(d["wheelbase_mm"]), 20.0, 1000.0) / 1000.0
	var s := wb / (2.0 * sqrt(2.0))
	var k: Vector2 = GYRATION["ducted" if bool(d["ducted"]) else "open"]
	var roll := mass * pow(k.x * wb, 2.0)
	var yaw := mass * pow(k.y * wb, 2.0)
	var prof: Dictionary = pids.get(str(d["pids"]), pids["5inch"])
	var ax := {}
	for pair in [["x", "pitch"], ["y", "yaw"], ["z", "roll"]]:
		var a: Array = prof[pair[1]]
		ax[pair[0]] = Vector4(a[0], a[1], a[2], a[3])
	var tau := clampf(float(d["motor_ms"]), 1.0, 500.0) / 1000.0
	# the rotors (prop and motor bell): their moment of inertia and top speed,
	# from the prop's size - a 31 mm whoop prop on an 0802 motor about 3.5e-8
	# kg m2 at 52,000 rpm, a 5" prop on a 2306 about 5e-6 at 32,000
	var prop := clampf(float(d["prop_mm"]), 10.0, 400.0) / 31.0
	var rotor_j := 3.5e-8 * pow(prop, 3.56) * maxf(float(cfg["rotor_inertia"]), 0.0)
	var omega_max := 52000.0 * pow(prop, -0.33) * TAU / 60.0
	var rx := str(cfg["iterm_relax"]).to_upper()
	# quad X, forward is -z: front-left, front-right, rear-left, rear-right;
	# front-left and rear-right spin anticlockwise seen from above
	var pos := [Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(-s, 0, s), Vector3(s, 0, s)]
	var spin := [1, -1, -1, 1]
	var mix := []
	for i in 4:
		var q: Vector3 = pos[i]
		# pitch (x) from the front motors, roll (z) from the right ones, yaw
		# (y) from those spinning clockwise
		mix.append(Vector3(signf(-q.z), -float(spin[i]), signf(q.x)))
	var bp := clampf((float(cfg["tpa_breakpoint"]) - 1000.0) / 1000.0, 0.0, 0.99)
	var p := {
		"name": d["name"], "pos": pos, "spin": spin, "mix": mix,
		"inertia": Vector3(roll, yaw, roll),
		"tau_up": tau, "tau_down": tau * (1.0 if bool(cfg["braking"]) else 4.0),
		"yaw_torque": float(d["yaw_torque"]), "pids": ax,
		"idle": clampf(float(cfg["idle_percent"]) / 100.0, 0.0, 0.3),
		"airmode": bool(cfg["airmode"]),
		"airmode_start": clampf(float(cfg["airmode_start_throttle_percent"]) / 100.0, 0.0, 1.0),
		"tpa_rate": clampf(float(cfg["tpa_rate"]) / 100.0, 0.0, 1.0), "tpa_breakpoint": bp,
		"dterm_hz": float(cfg["dterm_lowpass_hz"]), "ff_hz": float(cfg["feedforward_smoothing_hz"]),
		"ff_limit": clampf(float(cfg["feedforward_max_rate_limit"]) / 100.0, 0.0, 1.0),
		"relax": Vector3(1.0 if rx.begins_with("RP") else 0.0, 1.0 if rx == "RPY" else 0.0, 1.0 if rx.begins_with("RP") else 0.0),
		"relax_hz": clampf(float(cfg["iterm_relax_cutoff"]), 1.0, 100.0),
		"rotor_j": rotor_j, "omega_max": omega_max,
		"gyro_noise": clampf(float(cfg["gyro_noise"]), 0.0, 20.0),
		"iterm_limit": float(cfg["iterm_limit"]),
		"iterm_windup": clampf(float(cfg["iterm_windup"]) / 100.0, 0.0, 1.0),
		"ground_friction": clampf(float(cfg["ground_friction"]), 0.0, 2.0),
	}
	var key := "%s %.4f" % [vid, mass]
	if not _said.has(key):
		_said[key] = true
		_say("flying %s (%d g): motors %d mm apart, %d ms; inertia %d g cm2 roll and pitch, %d yaw; rotors %s g cm2 each, up to %d rpm; %s PIDs" % [
			d["name"], int(round(mass * 1000.0)), int(round(wb * 1000.0)), int(round(tau * 1000.0)),
			int(round(roll * 1e7)), int(round(yaw * 1e7)), str(snappedf(rotor_j * 1e7, 0.01)),
			int(round(omega_max * 60.0 / TAU / 100.0)) * 100, str(d["pids"])])
		_write_status()
	return p


# the drones mod's figures for the drone (an added drone's from its
# block, the rest from the drone it is built on), with its yaw torque and
# PID profile from here (those of the drone it is, or is built on)
func _drone(vid: String) -> Dictionary:
	var d: Dictionary = _specs.figures(vid, _core)
	var own: Dictionary = drones.get(str(d.get("base", "other")), drones["other"])
	for k in own:
		d[k] = own[k]
	return d


## Changes when the settings here or the drones mod's change: the controllers
## take the new figures on when it does
func generation() -> int:
	return settings_gen * 100000 + (int(_specs.generation()) if _specs != null else 0)

func _game_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("flight_controller")


func _copy() -> String:
	if not FileAccess.file_exists(GAME):
		return "the game has no " + GAME
	var d := FileAccess.get_file_as_bytes(GAME)
	if d.size() < 12 or d.slice(0, 4).get_string_from_ascii() != "GDSC" or d.decode_u32(4) != 101:
		return "not a script this knows (Godot 4.5 compiled GDScript)"
	DirAccess.make_dir_recursive_absolute(_game_dir().path_join("base"))
	var f := FileAccess.open(_game_dir().path_join(COPY), FileAccess.WRITE)
	if f == null:
		return "could not write " + _game_dir().path_join(COPY)
	f.store_buffer(d)
	f.close()
	return ""


func _check() -> String:
	# loaded by its .gd name (base/player_rigid_body.gd.remap points it at the
	# .gdc), as a script without a class_name is only found under that name
	var copy = load(DIR + "base/player_rigid_body.gd")
	if not (copy is Script) or not copy.can_instantiate():
		return "the copy of player_rigid_body.gd does not load; an update of this mod is needed"
	var have := {}
	for m in copy.get_script_method_list():
		have[m["name"]] = (m["args"] as Array).size()
	if have.get("calc_motor_rpm", -1) != 3 or have.get("_handle_rotation", -1) != 2 or have.get("get_thrust_at_rpm", -1) != 1:
		return "player_rigid_body.gd's motor, rotation or thrust step has changed; an update of this mod is needed"
	var ctl = load(DIR + "controller.gd")
	if not (ctl is Script) or not ctl.can_instantiate():
		return "controller.gd does not work with this version of the game; an update of this mod is needed"
	_controller_script = ctl
	var ours = load(DIR + "fc.gd")
	if not (ours is Script) or not ours.can_instantiate():
		return "fc.gd does not work with this version of the game; an update of this mod is needed"
	return ""


func _mount() -> String:
	var pck := _game_dir().path_join("remap.pck")
	var pk := PCKPacker.new()
	if pk.pck_start(pck) != OK:
		return "could not write " + pck
	pk.add_file("res://player_rigid_body.gd.remap", _game_dir().path_join("remap/player_rigid_body.gd.remap"))
	if pk.flush() != OK or not ProjectSettings.load_resource_pack(pck, true):
		return "could not mount " + pck
	var got = load("res://player_rigid_body.gd")
	if not (got is Script) or not got.get_script_constant_map().has("ZM_FLIGHT_CONTROLLER"):
		return "the game already had player_rigid_body.gd loaded before this mod started"
	return ""


func _say(s: String) -> void:
	_log.append(s)
	print("[flight_controller] " + s)


func _write_status() -> void:
	var f := FileAccess.open(_game_dir().path_join("status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
