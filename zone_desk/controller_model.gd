extends RefCounted
## Detached edit session. Returned dictionaries are copies; only get_configs() is saved.

const ACTIONS = [
	"throttle", "roll", "pitch", "yaw", "arm", "turtle_mode",
	"respawn", "flip_over", "trails", "head_tracker",
]
const AXIS_COUNT = 10
const CHANNEL_COUNT = AXIS_COUNT + JoyButton.JOY_BUTTON_SDL_MAX
const DETECT_THRESHOLD = 0.5

var _configs: Dictionary = {}
var _snapshot: Dictionary = {}
var _detect_action = ""
var _detect_baseline: Array = []
var _detect_device = -1
var _detect_remaining = 0.0


func _init() -> void:
	begin({})


## Normalize incomplete or unsafe data and capture the opening state for Cancel.
func begin(configs: Variant) -> void:
	cancel_detection()
	_configs = {}
	var source: Dictionary = configs if configs is Dictionary else {}
	for action in ACTIONS:
		_configs[action] = _normalize(source.get(action, {}))
	_snapshot = _configs.duplicate(true)


static func default_config() -> Dictionary:
	return {
		"channel": -1, "min": -1.0, "max": 1.0, "center": 0.0,
		"inverted": false, "half_range": false, "is_toggle": false,
	}


func get_config(action: String) -> Dictionary:
	return _configs.get(action, {}).duplicate(true)


func get_configs() -> Dictionary:
	return _configs.duplicate(true)


func changed(action: String = "") -> bool:
	if action.is_empty():
		return _configs != _snapshot
	return _configs.get(action) != _snapshot.get(action)


func rollback() -> void:
	cancel_detection()
	_configs = _snapshot.duplicate(true)


## Call only after persistence succeeds, making subsequent Cancel return here.
func mark_saved() -> void:
	cancel_detection()
	_snapshot = _configs.duplicate(true)


## Clearing removes calibration and mode flags too, leaving a complete safe schema.
func reset_binding(action: String) -> bool:
	if not _configs.has(action):
		return false
	if _detect_action == action:
		cancel_detection()
	_configs[action] = default_config()
	return true


## Deliberate profile reset; the UI must provide the separate user confirmation.
func reset_all() -> void:
	cancel_detection()
	for action in ACTIONS:
		_configs[action] = default_config()


func set_channel(action: String, channel: int) -> bool:
	if not _configs.has(action) or channel < -1 or channel >= CHANNEL_COUNT:
		return false
	_configs[action]["channel"] = channel
	return true


func set_inverted(action: String, enabled: bool) -> bool:
	return _set_flag(action, "inverted", enabled)


func set_half_range(action: String, enabled: bool) -> bool:
	return _set_flag(action, "half_range", enabled)


func set_toggle(action: String, enabled: bool) -> bool:
	return _set_flag(action, "is_toggle", enabled)


func set_range(action: String, low: float, high: float, center: float = 0.0) -> bool:
	if not _configs.has(action) or not _valid_range(low, high, center):
		return false
	_configs[action]["min"] = low
	_configs[action]["max"] = high
	_configs[action]["center"] = center
	return true


func _set_flag(action: String, key: String, enabled: bool) -> bool:
	if not _configs.has(action):
		return false
	_configs[action][key] = enabled
	return true


## Starts one detector, replacing any pending one without changing either binding.
## Pass the same actual device ID on every update to guard disconnect/reconnect.
func start_detection(action: String, raw: Array, device_id: int = -1, timeout_seconds: float = 10.0) -> bool:
	if not _configs.has(action) or not _valid_raw(raw):
		return false
	if not is_finite(timeout_seconds) or timeout_seconds <= 0.0:
		return false
	cancel_detection()
	_detect_action = action
	_detect_baseline = raw.duplicate()
	_detect_device = device_id
	_detect_remaining = timeout_seconds
	return true


func cancel_detection() -> void:
	_detect_action = ""
	_detect_baseline = []
	_detect_device = -1
	_detect_remaining = 0.0


func get_detecting_action() -> String:
	return _detect_action


## status: idle, waiting, assigned, timed_out, device_changed, input_changed.
## Only assigned mutates a binding. The baseline is fixed, so slow movement works.
func update_detection(raw: Array, delta: float = 0.0, device_id: int = -1) -> Dictionary:
	if _detect_action.is_empty():
		return {"status": "idle", "action": "", "channel": -1}
	var action = _detect_action
	if device_id != _detect_device:
		return _finish_detection("device_changed", action)
	if raw.size() != _detect_baseline.size() or not _valid_raw(raw):
		return _finish_detection("input_changed", action)
	if is_finite(delta) and delta > 0.0:
		_detect_remaining -= delta
	if _detect_remaining <= 0.0:
		return _finish_detection("timed_out", action)
	var largest = DETECT_THRESHOLD
	var selected = -1
	for channel in range(raw.size()):
		var movement: float = abs(float(raw[channel]) - float(_detect_baseline[channel]))
		if movement >= largest and (selected < 0 or movement > largest):
			largest = movement
			selected = channel
	if selected >= 0:
		set_channel(action, selected)
		cancel_detection()
		return {"status": "assigned", "action": action, "channel": selected}
	return {"status": "waiting", "action": action, "channel": -1}


func _finish_detection(status: String, action: String) -> Dictionary:
	cancel_detection()
	return {"status": status, "action": action, "channel": -1}


func source_label(action: String) -> String:
	return channel_label(int(_configs.get(action, {}).get("channel", -1)))


static func channel_label(channel: int) -> String:
	if channel < 0 or channel >= CHANNEL_COUNT:
		return "Unassigned"
	if channel < AXIS_COUNT:
		return "Axis %d (channel %d)" % [channel + 1, channel]
	return "Button %d (channel %d)" % [channel - AXIS_COUNT + 1, channel]


## Safe preview guard before calling the game's apply_config with a raw array.
func binding_available(action: String, raw: Array) -> bool:
	var channel = int(_configs.get(action, {}).get("channel", -1))
	return channel >= 0 and channel < raw.size() and _finite_number(raw[channel])


static func _normalize(value: Variant) -> Dictionary:
	var result = default_config()
	if not value is Dictionary:
		return result
	var channel: Variant = value.get("channel", -1)
	if _finite_number(channel) and float(channel) == floor(float(channel)):
		if channel >= -1 and channel < CHANNEL_COUNT:
			result["channel"] = int(channel)
	for key in ["inverted", "half_range", "is_toggle"]:
		if value.get(key) is bool:
			result[key] = value[key]
	var low: Variant = value.get("min", -1.0)
	var high: Variant = value.get("max", 1.0)
	var center: Variant = value.get("center", 0.0)
	if _finite_number(low) and _finite_number(high) and _finite_number(center):
		if _valid_range(float(low), float(high), float(center)):
			result["min"] = float(low)
			result["max"] = float(high)
			result["center"] = float(center)
	return result


static func _valid_range(low: float, high: float, center: float) -> bool:
	return (
		is_finite(low) and is_finite(high) and is_finite(center)
		and low >= -1.0 and high <= 1.0 and high - low >= 0.000001
		and center > -1.0 and center < 1.0
	)


static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_raw(raw: Array) -> bool:
	if raw.is_empty() or raw.size() > CHANNEL_COUNT:
		return false
	for value in raw:
		if not _finite_number(value) or float(value) < -1.0 or float(value) > 1.0:
			return false
	return true
