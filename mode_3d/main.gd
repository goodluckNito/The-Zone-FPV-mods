extends Node
## mode_3d 1.0
##
## 3D mode for The Zone FPV: motors that run both ways, as on a quad flown
## with Betaflight's 3D feature and bidirectional ESCs. Push the throttle
## past the middle and the props push as usual; pull it below the middle and
## the motors brake to a stop, start again the other way and push the other
## way - so the quad can hang upside down, fly inverted and flip back over
## without turtle mode. Or, in switch mode, the throttle works as usual and
## a switch reverses the motors. Off until turned on.
##
## Props spinning backwards push less: a normal prop about three quarters
## of its forward thrust at the same speed (reverse_thrust; a bench test of
## a 7x5 tri-blade: 0.59 against 0.81 kgf at full throttle) for the same
## power, so the motors work as hard for less. Through zero the motors stop
## for a moment (reverse_ms) before they can turn the other way, and the
## quad drops or floats for that long.
##
## How: the game's quad is player_rigid_body.gd. With flight_controller on,
## its quad (fc.gd and controller.gd) runs each motor both ways itself,
## asking this for the throttle, how a motor reverses and what a reversed
## prop pushes - and Betaflight's mixer turns its corrections round with the
## motors. Without it, this mounts a small resource pack that points the game
## at quad.gd: the game's own script (read from a copy made at every launch)
## with its throttle, motor and thrust steps made two-way, the game's own
## rotation control flying the quad either way up. With motor_response the
## motors here follow its time constants (it stands aside, as it does for
## flight_controller).
##
## The quad's 3D state is kept on it as metadata ("zm3", see state()), and
## dirty_air, prop_damage and fpv_osd read it: the props' push the other way
## up, and the throttle shown as Betaflight's OSD shows it in 3D mode.
##
## Uninstall: delete the mode_3d folder.

const VERSION := "1.0"
const DIR := "res://mode_3d/"
const GAME := "res://player_rigid_body.gdc"
const COPY := "base/player_rigid_body.gdc"
const DEFAULTS := {"throttle": "centre", "deadband_percent": 10.0, "reverse_thrust": 0.73, "reverse_ms": 40.0}
# Betaflight keeps the I term at zero this long after the motors reverse
# (mixer.c: "keep iterm zero for 250ms after motor reversal")
const ITERM_HOLD_S := 0.25
# below this share of its idle speed a sensorless ESC can no longer follow
# the motor: braking to reverse, the motor is taken as stopped there
const STOP_OF_IDLE := 0.33

var cfg := {}
var on := false                 # in effect: through quad.gd or flight_controller
var mounted := false            # quad.gd is the game's quad
var via_fc := false             # flight_controller's quad runs the motors both ways
var _core: Node = null
var _copied := false
var _why_off := ""
var _mr = null                  # motor_response, for its time constants
var _log := PackedStringArray()


func zm_init(core: Node, _dir: String) -> void:
	_core = core
	_say("mode_3d %s" % VERSION)
	_read_settings()
	var why := _copy()
	if why != "":
		_why_off = "the game's player_rigid_body.gd is not as expected (see mode_3d/status.txt)"
		_say("not in effect: player_rigid_body.gd - %s. The game runs as without this mod; an update of it is needed" % why)
	else:
		_copied = true
	_write_status()


func _read_settings() -> void:
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(DIR + "settings.cfg") == OK and c.has_section("mode_3d"):
		for k in c.get_section_keys("mode_3d"):
			if cfg.has(k):
				cfg[k] = c.get_value("mode_3d", k)
	var t := str(cfg["throttle"]).strip_edges().to_lower()
	cfg["throttle"] = "switch" if t == "switch" else "centre"
	cfg["deadband_percent"] = clampf(float(cfg["deadband_percent"]), 0.0, 40.0)
	cfg["reverse_thrust"] = clampf(float(cfg["reverse_thrust"]), 0.1, 1.2)
	cfg["reverse_ms"] = clampf(float(cfg["reverse_ms"]), 0.0, 500.0)
	_say("throttle: %s; props backwards give %s of their thrust; a motor reversing stops for %d ms" % [
		("the middle is zero, above it forward and below it reversed (deadband %s percent each side); arm with the throttle at the middle" % str(cfg["deadband_percent"]))
		if cfg["throttle"] == "centre" else "as usual, the game's turtle-mode switch reverses the motors",
		str(cfg["reverse_thrust"]), int(round(float(cfg["reverse_ms"])))])


## Called by mod_settings when settings.cfg has been changed in the game
func zm_apply_settings() -> void:
	_read_settings()
	_write_status()


## For mod_settings' page: a note when these settings do nothing
func zm_settings_status() -> String:
	return ("Not in effect: %s. Its settings do nothing meanwhile." % _why_off) if _why_off != "" else ""


# After every mod's zm_init and before the game loads its first scene. With
# flight_controller on, its quad runs the motors both ways; otherwise point
# the game at quad.gd
func _ready() -> void:
	if not _copied:
		return
	var fc = _core.call("get_mod", "flight_controller") if _core != null and _core.has_method("get_mod") else null
	if fc != null and (not fc.is_node_ready() or bool(fc.get("on"))):
		on = true
		via_fc = true
		_say("in effect through flight_controller: its four motors run both ways")
		_write_status()
		return
	var why := _check()
	if why == "":
		why = _mount()
	if why != "":
		_why_off = why
		_say("not in effect: " + why)
	else:
		on = true
		mounted = true
		_say("in effect: the quad's motors run both ways, the game's own rotation control flying it either way up")
	_write_status()


# ---- for quad.gd and flight_controller ----

## The quad's 3D state, kept on it as metadata "zm3" (a Dictionary):
##   raw    the throttle stick, -1 (low) .. 1 (high)
##   mag    what the motors are asked for, 0..1: the game's throttle_input
##   dir    the way the throttle asks the motors to turn: 1 forward, -1 reversed
##   osd    the throttle as Betaflight's OSD shows it in 3D mode, -1..1
##   ready  centre mode: the throttle has been at the middle since arming
##   w      the motors' speed, rpm, negative reversed (the game's
##          current_motor_rpm is its size)
##   wait   seconds before a motor stopped to reverse starts again
##   sign   the way the props push: 1 as usual, -1 reversed
##   k      what they push against a prop turning forward at that speed
##   rev_t  seconds since dir last changed (Betaflight holds the I term at
##          zero for 0.25 s after)
func state(p) -> Dictionary:
	if not p.has_meta("zm3"):
		p.set_meta("zm3", {"raw": -1.0, "mag": 0.0, "dir": 1, "osd": 0.0, "ready": false, "w": 0.0, "wait": 0.0,
			"sign": 1, "k": 1.0, "rev_t": 99.0})
	return p.get_meta("zm3")


func _set_dir(s: Dictionary, d: int) -> void:
	if int(s["dir"]) != d:
		s["dir"] = d
		s["rev_t"] = 0.0


## The sticks as 3D mode reads them, each physics tick. The throttle the game
## goes on with (sp.throttle) becomes the size of what the motors are asked
## for - so its throttle_input is that - and the way they are to turn goes
## into the state.
##   centre  the middle of the stick is zero: above the deadband forward,
##           below it reversed, scaled to the ends; in the deadband the
##           motors idle the way they last turned. Disarmed they are set to
##           turn forward, and after arming nothing happens until the
##           throttle has been at the middle (it arms only there, with an
##           arm switch)
##   switch  the throttle as usual (low is idle), and the game's turtle-mode
##           switch turns the motors round - so the game's own turtle mode
##           never starts
func map_setpoint(p, sp: Dictionary) -> Dictionary:
	var s := state(p)
	var t := clampf(float(sp.get("throttle", -1.0)), -1.0, 1.0)
	s["raw"] = t
	s["rev_t"] = float(s["rev_t"]) + 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	var armed := bool(p.call("is_armed"))
	var out := sp.duplicate()
	var mag := 0.0
	if cfg["throttle"] == "switch":
		mag = (t + 1.0) * 0.5
		var rev := float(sp.get("turtle_mode", 0.0)) > 0.8
		_set_dir(s, -1 if rev else 1)
		out["turtle_mode"] = 0.0
		s["ready"] = true
		s["osd"] = mag * float(s["dir"])
	else:
		var db := float(cfg["deadband_percent"]) / 100.0
		var side := 0.0
		if t > db:
			side = (t - db) / maxf(1.0 - db, 0.01)
		elif t < -db:
			side = -(-t - db) / maxf(1.0 - db, 0.01)
		s["osd"] = side
		if not armed:
			s["ready"] = false
			_set_dir(s, 1)
		elif absf(t) <= db:
			s["ready"] = true
		if armed and bool(s["ready"]) and side != 0.0:
			mag = absf(side)
			_set_dir(s, 1 if side > 0.0 else -1)
	s["mag"] = mag
	out["throttle"] = mag * 2.0 - 1.0
	return out


## Centre mode arms only with the throttle in the deadband at the middle, as
## Betaflight's 3D mode does
func arm_blocked(p) -> bool:
	if cfg["throttle"] == "switch":
		return false
	var s := state(p)
	return not bool(p.call("is_armed")) and absf(float(s["raw"])) > float(cfg["deadband_percent"]) / 100.0


## What other players are sent for the sticks: the throttle as the motors
## have it (their mods hear and feel the quad from it), not the stick
func udp_stick(p, stick: Vector4) -> Vector4:
	return Vector4(stick.x, stick.y, float(state(p)["mag"]) * 2.0 - 1.0, stick.w)


## The time constants a motor follows (s; speeding up, slowing down), from
## motor_response when it is there, else 0 (the game's own ramp)
func motor_taus() -> Vector2:
	if _mr == null or not is_instance_valid(_mr):
		_mr = _core.call("get_mod", "motor_response") if _core != null and _core.has_method("get_mod") else null
	if _mr == null or not _mr.has_method("time_constant"):
		return Vector2.ZERO
	return Vector2(float(_mr.call("time_constant", true)), float(_mr.call("time_constant", false)))


## Below this a motor (rpm) is stopped, for an ESC reversing it
func stop_rpm(idle_rpm: float, max_rpm: float) -> float:
	return maxf(STOP_OF_IDLE * idle_rpm, 0.004 * max_rpm)


## A motor's speed after dt (rpm, negative reversed), heading for target, as
## a bidirectional ESC runs it: towards the target as in normal flight while
## both turn the same way (tau_up / tau_down: time constants, s; 0 = the
## game's own ramp, rate rpm a second), but to turn it round it brakes the
## motor to a stop - below stop rpm the ESC can no longer follow it - waits
## reverse_ms with it stopped, and starts it the other way. st[key] holds
## the wait.
func motor_step(w: float, target: float, dt: float, tau_up: float, tau_down: float, rate: float, stop: float, st: Dictionary, key := "wait") -> float:
	var wait := float(st.get(key, 0.0))
	if wait > 0.0:
		wait -= dt
		st[key] = maxf(wait, 0.0)
		if wait > 0.0:
			return 0.0
		w = signf(target) * stop          # started again, the new way
	if w == 0.0 or target == 0.0 or signf(w) == signf(target):
		return _follow(w, target, dt, tau_up, tau_down, rate)
	var w2 := _follow(w, 0.0, dt, tau_up, tau_down, rate)
	if absf(w2) <= stop:
		st[key] = float(cfg["reverse_ms"]) / 1000.0
		if st[key] <= 0.0:
			return signf(target) * stop
		return 0.0
	return w2


static func _follow(w: float, target: float, dt: float, tau_up: float, tau_down: float, rate: float) -> float:
	var tau := tau_up if absf(target) > absf(w) else tau_down
	if tau <= 0.0:
		return move_toward(w, target, rate * dt)
	return target + (w - target) * exp(-dt / tau)


## The whole quad's thrust (N) at rpm (its size) with the props turning
## backwards, before reverse_thrust: the game's own thrust curve for the
## drone (get_thrust_at_rpm's), with the air coming through the props from
## below - so flying along the way they push (down, as the quad sees it)
## costs thrust, as climbing does turning forward. What a prop takes to turn
## (its drag torque, the power) goes with this; what it pushes is
## reverse_thrust of it.
func thrust_reversed(p, rpm: float) -> float:
	var stt = p.get("_SETTINGS")
	if not (stt is Dictionary) or not stt.has("adjustable_settings"):
		return 0.0
	var mx := maxf(float(p.get("MAX_MOTOR_RPM")), 1.0)
	var curve = p.get("RPM_THRUST_CURVE")
	var scurve = p.get("SPEED_THRUST_CURVE")
	if not (curve is Array and scurve is Array) or curve.is_empty() or scurve.is_empty():
		return 0.0
	var rb := clampi(int(floor(rpm / mx * 100.0)), 0, curve.size() - 1)
	var axial := maxf(-((p as Node3D).global_transform.basis.y.normalized().dot((p as RigidBody3D).linear_velocity)), 0.0)
	var top := maxf(float(stt["adjustable_settings"].get("top_speed", 100.0)) / 3.6, 0.1)
	var sb := clampi(int(floor(axial / top * 100.0)), 0, scurve.size() - 1)
	return rpm * float(p.call("get_thrust_per_rpm")) * float(curve[rb]) * float(scurve[sb])


func reverse_thrust() -> float:
	return float(cfg["reverse_thrust"])


func _game_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("mode_3d")


# A copy of the game's compiled script beside this mod: quad.gd builds on it
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
	var copy = load(DIR + "base/player_rigid_body.gd")
	if not (copy is Script) or not copy.can_instantiate():
		return "the copy of player_rigid_body.gd does not load; an update of this mod is needed"
	var have := {}
	for m in copy.get_script_method_list():
		have[m["name"]] = (m["args"] as Array).size()
	for need in [["calc_motor_rpm", 3], ["get_thrust_at_rpm", 1], ["apply_setpoint_latency", 1], ["_check_arm_switch", 1],
			["render_speed", 0], ["get_udp_position", 0], ["get_thrust_per_rpm", 0]]:
		if have.get(need[0], -1) != need[1]:
			return "player_rigid_body.gd's %s has changed; an update of this mod is needed" % need[0]
	var ours = load(DIR + "quad.gd")
	if not (ours is Script) or not ours.can_instantiate():
		return "quad.gd does not work with this version of the game; an update of this mod is needed"
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
	if not (got is Script) or not got.get_script_constant_map().has("ZM_MODE_3D"):
		return "the game already had player_rigid_body.gd loaded before this mod started (another mod that changes the quad, listed before this one in override.cfg?)"
	return ""


func _say(s: String) -> void:
	_log.append(s)
	print("[mode_3d] " + s)


func _write_status() -> void:
	var f := FileAccess.open(_game_dir().path_join("status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
