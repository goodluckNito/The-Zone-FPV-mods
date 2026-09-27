extends Node
## throttle_fix 1.0
##
## The Zone FPV reads the throttle as half until the stick is first moved, so
## arming is refused ("LOWER THROTTLE TO ARM") until you move it up and down.
##
## Why: Godot 4.5 gets controllers through SDL 3, and SDL holds back each
## axis's first reading until that axis moves by more than 1/80 of its range
## (SDL_SendJoystickAxis: "don't send motion until there's real activity on
## this axis"). Godot keeps an axis at 0.0 - the middle - until SDL sends it
## something, and a real reading is never exactly 0.0 (SDL's -32768..32767
## scaled to -1..1 cannot land on it). So a throttle axis at exactly 0.0 has
## not been heard from yet, and nothing a script can call reads where the
## stick really is.
##
## What this does: only between the radio connecting (the game starting, or
## plugging it in again) and its first reading of the throttle axis, while
## that axis is still at the untouched 0.0, it puts in the reading for all the
## way down, through the same joypad event SDL would send, worked out with the
## game's own mapping (gdutil/z_input.gd: its device choice, endpoints,
## centre, invert and half range). That is where the stick is when you arm.
## Once the radio has sent any reading of the axis, this leaves it alone until
## the radio connects again - a stick passing through the middle later is
## never touched.
## A mapping where 0.0 already reads as throttle down (a gamepad's half-range
## stick or trigger) is left alone.
##
## Uninstall: delete the throttle_fix folder.

const VERSION := "1.0"
const META := "zm_throttle_fix"
const EVERY := 0.1

var assume_connected := false   # for tests, which have no controller

var _zi: Object = null          # the game's z_input
var _t := 0.0
var _put := {}                  # "device:axis" -> the reading put in
var _heard := {}                # "device:axis" the radio has sent a reading of since it connected
var _put_at := {}               # when
var _now := 0.0
var _log := PackedStringArray()
var _note := ""


func zm_init(_core: Node, _dir: String) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_say("throttle_fix %s" % VERSION)
	var s = load("res://gdutil/z_input.gd")
	if s is Script and s.can_instantiate():
		_zi = s.new()
	if _zi == null or not _zi.has_method("apply_config") or not _zi.has_method("get_device_id"):
		_zi = null
		_say("could not find the game's controller code (gdutil/z_input.gd): nothing done")
	else:
		_say("until the radio reports the throttle, it reads as all the way down")
		Input.joy_connection_changed.connect(_on_joy)
	_write_status()


# Godot puts a joypad's axes back to 0.0 when it connects: watch it afresh
func _on_joy(device: int, _connected: bool) -> void:
	for d in [_heard, _put, _put_at]:
		for k in d.keys():
			if str(k).begins_with("%d:" % device):
				d.erase(k)


func _process(delta: float) -> void:
	_now += delta
	_t += delta
	if _zi == null or _t < EVERY:
		return
	_t = 0.0
	_check()


func _check() -> void:
	var zs := get_node_or_null("/root/ZSettings")
	var inputs = zs.get("INPUTS_V2") if zs != null else null
	if not (inputs is Dictionary) or not inputs.has("throttle"):
		return
	var m = inputs["throttle"]
	if not (m is Dictionary):
		return
	for k in ["channel", "min", "max", "center", "inverted", "half_range", "is_toggle"]:
		if not m.has(k):
			_once("the game's throttle setting has no %s: nothing done" % k)
			return
	var ch := int(m["channel"])
	if ch < 0 or ch >= 10 or bool(m["is_toggle"]):
		return                   # not on a stick axis
	var dev := int(_zi.get_device_id())
	if not (assume_connected or dev in Input.get_connected_joypads()):
		return
	var key := "%d:%d" % [dev, ch]
	if _heard.has(key):
		return                   # the radio has reported this axis: never touched again
	var now := Input.get_joy_axis(dev, ch)
	if _put.has(key):
		if now != _put[key]:
			_heard[key] = true
			_say("the radio reported the throttle %.1f s after it was set: %.2f; the game follows the stick from here" % [_now - float(_put_at[key]), now])
			_write_status()
		return
	if now != 0.0:
		_heard[key] = true       # a real reading
		return
	# where 0.0 puts the throttle, and which end of the axis is all the way down
	var at_zero := _mapped(m, ch, 0.0)
	if at_zero <= -0.99:
		return
	var low := 0.0
	var best := at_zero
	for raw in [float(m["min"]), float(m["max"]), -1.0, 1.0]:
		var v := _mapped(m, ch, raw)
		if v < best - 0.0001:
			best = v
			low = raw
	if best > -0.99:
		_once("no reading of axis %d puts the throttle all the way down: nothing done" % ch)
		return
	var ev := InputEventJoypadMotion.new()
	ev.device = dev
	ev.axis = ch
	ev.axis_value = low
	ev.set_meta(META, true)
	Input.parse_input_event(ev)
	_put[key] = low
	_put_at[key] = _now
	var jname := Input.get_joy_name(dev) if dev in Input.get_connected_joypads() else "controller %d" % dev
	_say("%s, axis %d: the throttle read %d percent (not reported yet); set to 0 percent (axis %.2f)" % [jname, ch, roundi((at_zero + 1.0) * 50.0), low])
	_write_status()


# The throttle, -1 to 1, that a reading of the axis gives, by the game's code
func _mapped(m: Dictionary, ch: int, raw: float) -> float:
	var arr := []
	arr.resize(64)
	arr.fill(0.0)
	arr[ch] = raw
	return float(_zi.call("apply_config", m, arr))


func _once(s: String) -> void:
	if _note != s:
		_note = s
		_say(s)
		_write_status()


func _say(s: String) -> void:
	_log.append(s)
	print("[throttle_fix] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("throttle_fix/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
