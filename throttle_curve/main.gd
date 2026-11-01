extends Node
## throttle_curve 1.0
##
## A throttle curve for The Zone FPV, as Betaflight's Rates tab has it: a
## hover point and a throttle expo. The game maps the throttle stick straight
## to throttle; with this the stick runs along a curve instead, flatter around
## the hover so small stick movements make small changes, and with the hover
## put where on the stick you want it.
##
## The curve (stick and throttle both 0..1, ends fixed: all the way down is
## 0 and all the way up is 1), Betaflight's own throttle curve:
##     hover_stick_percent = Betaflight's thr_mid    where on the stick the hover sits
##     hover_percent       = Betaflight's thr_hover  the throttle it gives there
##     expo_percent        = Betaflight's thr_expo
##   Two quadratic Bezier segments, (0,0) to the hover point and the hover
##   point to (1,1), their control points moving from the straight line
##   (expo 0) to level with the hover (expo 100) - rc.c's initRcProcessing.
##   Betaflight samples it at 12 points and interpolates between them; this
##   uses the smooth curve itself.
##
## How: nothing of the game is replaced. The game reads the throttle as a
## joypad axis (Input.get_joy_axis, through z_input.apply_config: the radio's
## end points, centre, invert and half range). When the radio reports a new
## reading of that axis, this works out the throttle the game would make of
## it with the game's own mapping, bends it along the curve, finds the
## reading of the axis that makes the game's mapping give the bent throttle,
## and puts that in as the axis's reading, through the same joypad event the
## radio sends (as throttle_fix does). Events are handled before the game's
## next physics tick reads the stick. Because it works on the axis, it
## sits beside flight_controller, mode_3d and the rest without touching their
## scripts, and the stick overlay, the OSD and other players all see the bent
## throttle, as on a real quad.
## With the default settings the curve is a straight line and nothing is put
## in at all.
##
## Uninstall: delete the throttle_curve folder.

const VERSION := "1.0"
const META := "zm_throttle_curve"      # on the events this puts in
const FIX_META := "zm_throttle_fix"    # throttle_fix's: all the way down, left alone
const ITERATIONS := 22                 # of the search for the axis reading (about 2e-7)
const EPS := 0.00002

const DEFAULTS := {"hover_percent": 50.0, "hover_stick_percent": 50.0, "expo_percent": 0.0}

var cfg := {}
var hover_out := 0.5            # throttle at the hover (0..1)
var hover_in := 0.5             # where on the stick it sits (0..1)
var expo := 0.0                 # 0..1
var bent := 0                   # readings bent so far, for status and tests

var _core: Node = null
var _dir := "res://throttle_curve/"
var _zi: Object = null          # the game's z_input
var _zs: Node = null            # the game's ZSettings
var _arr := []                  # a reading of every axis, for apply_config
var _raw := {}                  # "device:axis" -> the radio's last reading
var _log := PackedStringArray()
var _why := ""                  # why it does nothing, if it does not
var _noted := {}


func zm_init(core: Node, dir: String) -> void:
	_core = core
	_dir = dir
	process_mode = Node.PROCESS_MODE_ALWAYS
	_arr.resize(64)
	_arr.fill(0.0)
	_say("throttle_curve %s" % VERSION)
	_read_settings()
	var s = load("res://gdutil/z_input.gd")
	if s is Script and s.can_instantiate():
		_zi = s.new()
	if _zi == null or not _zi.has_method("apply_config") or not _zi.has_method("get_device_id"):
		_zi = null
		_why = "the game's controller code (gdutil/z_input.gd) is not as this expects; an update of this mod is needed"
		_say("not in effect: " + _why)
	else:
		Input.joy_connection_changed.connect(_on_joy)
	_write_status()


func _read_settings() -> void:
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(_dir + "settings.cfg") == OK and c.has_section("throttle_curve"):
		for k in c.get_section_keys("throttle_curve"):
			if cfg.has(k):
				cfg[k] = c.get_value("throttle_curve", k)
	hover_out = clampf(float(cfg["hover_percent"]), 5.0, 95.0) / 100.0
	hover_in = clampf(float(cfg["hover_stick_percent"]), 5.0, 95.0) / 100.0
	expo = clampf(float(cfg["expo_percent"]), 0.0, 100.0) / 100.0
	if is_straight():
		_say("the throttle is the game's own: a straight line (hover %s percent at %s percent of the stick, expo %s)" % [
			str(snappedf(hover_out * 100.0, 0.01)), str(snappedf(hover_in * 100.0, 0.01)), str(snappedf(expo * 100.0, 0.01))])
	else:
		_say("curve: hover %s percent throttle at %s percent of the stick, expo %s percent" % [
			str(snappedf(hover_out * 100.0, 0.01)), str(snappedf(hover_in * 100.0, 0.01)), str(snappedf(expo * 100.0, 0.01))])


## Called by mod_settings when settings.cfg has been changed in the game: the
## radio's last reading is bent again by the new curve at once
func zm_apply_settings() -> void:
	_read_settings()
	var m := _throttle_map()
	if _zi != null and not m.is_empty():
		var ch := int(m["channel"])
		for key in _raw.keys():
			var parts := str(key).split(":")
			if parts.size() == 2 and int(parts[1]) == ch:
				_apply(int(parts[0]), ch, m, float(_raw[key]), true)
	_write_status()


## For mod_settings' page: a note when these settings do nothing
func zm_settings_status() -> String:
	if _why != "":
		return "Not in effect: %s. Its settings do nothing meanwhile." % _why
	var why := _aside()
	if why != "":
		return "Standing aside: %s. Its settings do nothing meanwhile." % why
	return ""


# Godot puts a joypad's axes back to 0.0 when it connects: nothing is known of
# the radio until it reports again
func _on_joy(device: int, _connected: bool) -> void:
	for k in _raw.keys():
		if str(k).begins_with("%d:" % device):
			_raw.erase(k)


func _input(event: InputEvent) -> void:
	var jm := event as InputEventJoypadMotion
	if _zi == null or jm == null:
		return
	if jm.has_meta(META) or jm.has_meta(FIX_META):
		return
	var m := _throttle_map()
	if m.is_empty():
		return
	var ch := int(m["channel"])
	if int(jm.axis) != ch or int(jm.device) != int(_zi.get_device_id()):
		return
	_apply(int(jm.device), ch, m, float(jm.axis_value), false)


# The radio's reading raw of the throttle axis on device dev: put in the bent
# one, if the curve changes it (again: the curve has changed, so put it in
# even to take a bent reading back)
func _apply(dev: int, ch: int, m: Dictionary, raw: float, again: bool) -> void:
	_raw["%d:%d" % [dev, ch]] = raw
	var want := raw
	if not is_straight() and _aside() == "":
		want = bend_reading(m, ch, raw)
	var have := Input.get_joy_axis(dev, ch)
	if absf(want - (have if again else raw)) <= EPS:
		return
	var ev := InputEventJoypadMotion.new()
	ev.device = dev
	ev.axis = ch
	ev.axis_value = want
	ev.set_meta(META, true)
	Input.parse_input_event(ev)
	bent += 1
	if not _noted.has("first"):
		_noted["first"] = true
		var jname := Input.get_joy_name(dev) if dev in Input.get_connected_joypads() else "controller %d" % dev
		_say("%s, axis %d: the first throttle reading bent by the curve (%.2f became %.2f)" % [jname, ch, raw, want])
		_write_status()


## The reading of the throttle axis that makes the game's own mapping give the
## throttle the curve gives for the radio's reading raw. Ends stay as they are.
func bend_reading(m: Dictionary, ch: int, raw: float) -> float:
	var t := _mapped(m, ch, raw)
	var u := clampf((t + 1.0) * 0.5, 0.0, 1.0)
	if u <= 0.0001 or u >= 0.9999:
		return raw
	var target := curve(u, hover_in, hover_out, expo) * 2.0 - 1.0
	# the mapping runs one way along the axis (either, with invert); search for the target
	var fa := _mapped(m, ch, -1.0)
	var fb := _mapped(m, ch, 1.0)
	if absf(fb - fa) < 0.01:
		return raw
	var rising := fb > fa
	var lo := -1.0
	var hi := 1.0
	for i in ITERATIONS:
		var mid := (lo + hi) * 0.5
		if (_mapped(m, ch, mid) < target) == rising:
			lo = mid
		else:
			hi = mid
	return clampf((lo + hi) * 0.5, -1.0, 1.0)


## The throttle (0..1) for stick position s (0..1), a hover at stick position
## p giving throttle h, and expo e (0..1): Betaflight's throttle curve
## (rc.c, initRcProcessing). Each segment is a quadratic Bezier whose x
## control point is halfway along it, so x is linear in t and y follows in
## closed form.
static func curve(s: float, p: float, h: float, e: float) -> float:
	s = clampf(s, 0.0, 1.0)
	if s <= p:
		var t := s / p
		var cy := h * 0.5 * (1.0 + e)
		return clampf(2.0 * (1.0 - t) * t * cy + t * t * h, 0.0, 1.0)
	var t2 := (s - p) / (1.0 - p)
	var cy2 := 1.0 + (h - 1.0) * 0.5 * (1.0 + e)
	return clampf((1.0 - t2) * (1.0 - t2) * h + 2.0 * (1.0 - t2) * t2 * cy2 + t2 * t2, 0.0, 1.0)


## True when the curve is a straight line: nothing is put in
func is_straight() -> bool:
	return absf(hover_in - hover_out) < 0.00001 and expo < 0.00001


# The throttle, -1 to 1, that a reading of the axis gives, by the game's code
func _mapped(m: Dictionary, ch: int, raw: float) -> float:
	_arr[ch] = raw
	var v := float(_zi.call("apply_config", m, _arr))
	_arr[ch] = 0.0
	return v


# The game's throttle setting, if it is on a stick axis
func _throttle_map() -> Dictionary:
	if _zs == null or not is_instance_valid(_zs):
		_zs = get_node_or_null("/root/ZSettings")
	var inputs = _zs.get("INPUTS_V2") if _zs != null else null
	if not (inputs is Dictionary) or not inputs.has("throttle"):
		return {}
	var m = inputs["throttle"]
	if not (m is Dictionary):
		return {}
	for k in ["channel", "min", "max", "center", "inverted", "half_range", "is_toggle"]:
		if not m.has(k):
			_once("the game's throttle setting has no %s: nothing done" % k)
			return {}
	var ch := int(m["channel"])
	if ch < 0 or ch >= 10 or bool(m["is_toggle"]):
		return {}                # not on a stick axis
	return m


# Why the curve stands aside, "" if it does not: mode_3d's centre mode reads
# the stick as zero in the middle, which a hover and expo would bend wrongly
func _aside() -> String:
	var m = _core.call("get_mod", "mode_3d") if _core != null and _core.has_method("get_mod") else null
	if m == null or not bool(m.get("on")):
		return ""
	var c = m.get("cfg")
	if c is Dictionary and str(c.get("throttle", "centre")) == "centre":
		return "mode_3d is on in centre mode, where the middle of the stick is zero throttle"
	return ""


func _once(s: String) -> void:
	if not _noted.has(s):
		_noted[s] = true
		_say(s)
		_write_status()


func _say(s: String) -> void:
	_log.append(s)
	print("[throttle_curve] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("throttle_curve/status.txt"), FileAccess.WRITE)
	if f == null:
		return
	var lines := _log.duplicate()
	var aside := _aside()
	if aside != "":
		lines.append("standing aside: " + aside)
	# the curve as the stick makes it, for the settings in effect
	var row := PackedStringArray()
	var col := PackedStringArray()
	for i in range(0, 11):
		row.append("%3d" % (i * 10))
		col.append("%3d" % roundi(curve(i * 0.1, hover_in, hover_out, expo) * 100.0))
	lines.append("")
	lines.append("stick percent    : " + " ".join(row))
	lines.append("throttle percent : " + " ".join(col))
	f.store_string("\n".join(lines) + "\n")
