extends SceneTree
## Run headlessly with --script /absolute/path/to/this/file.

var _checks = 0
var _failures: Array[String] = []


func _initialize() -> void:
	var root: String = get_script().resource_path.get_base_dir().get_base_dir()
	var model_script = load(root.path_join("zone_desk/controller_model.gd"))
	if model_script == null or not model_script.can_instantiate():
		push_error("Controller model failed to load")
		quit(1)
		return
	_test_schema_and_transaction(model_script)
	_test_validation(model_script)
	_test_detection(model_script)
	_test_labels(model_script)
	if _failures.is_empty():
		print("PASS: controller model, %d behavioral checks" % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _test_schema_and_transaction(script) -> void:
	var model = script.new()
	var source = {"roll": {"channel": 3, "inverted": true, "min": -0.8, "max": 0.9, "center": 0.1}}
	model.begin(source)
	_expect(model.get_configs().size() == 10, "All ten actions must always exist")
	for action in model.ACTIONS:
		_expect(model.get_config(action).size() == 7, "Every mapping needs the seven apply_config fields: " + action)
	_expect(not model.changed(), "Opening a session must be clean")
	source.roll.channel = 4
	_expect(model.get_config("roll").channel == 3, "Opening data must be deeply detached")
	var returned = model.get_configs()
	returned.roll.channel = 5
	var returned_single = model.get_config("roll")
	returned_single.inverted = false
	_expect(model.get_config("roll").channel == 3 and model.get_config("roll").inverted, "Read copies must not mutate working data")
	model.set_channel("roll", 8)
	model.set_half_range("roll", true)
	model.set_toggle("arm", true)
	_expect(model.changed("roll") and model.changed("arm") and not model.changed("yaw"), "Dirty state must track only changed actions")
	model.rollback()
	_expect(model.get_config("roll").channel == 3 and not model.changed(), "Cancel must restore the original profile")
	model.reset_binding("roll")
	_expect(model.get_config("roll") == model.default_config(), "Clear must produce complete safe defaults")
	model.rollback()
	model.reset_all()
	for action in model.ACTIONS:
		_expect(model.get_config(action) == model.default_config(), "Profile reset must clear every action: " + action)
	_expect(model.changed(), "Reset must remain cancellable until Save")
	model.mark_saved()
	model.set_channel("yaw", 2)
	model.rollback()
	_expect(model.get_config("yaw").channel == -1 and not model.changed(), "Saved state must become the new cancellation baseline")


func _test_validation(script) -> void:
	var model = script.new()
	model.begin(null)
	_expect(model.get_config("roll") == model.default_config(), "Missing profile must fall back to defaults")
	model.begin({"roll": {"channel": 999, "min": 1, "max": 1, "center": 1, "inverted": "false"}, "yaw": false, "pitch": {"channel": 2.5}})
	_expect(model.get_config("roll") == model.default_config(), "Invalid channel, flags, and degenerate calibration must be safe")
	_expect(model.get_config("pitch").channel == -1 and model.get_config("yaw").channel == -1, "Fractional channels and invalid mappings must be rejected")
	_expect(not model.set_channel("roll", model.CHANNEL_COUNT) and not model.set_channel("roll", -2), "Channels must fit the actual native input buffer")
	_expect(not model.set_channel("unknown", 0) and not model.reset_binding("unknown") and not model.set_inverted("unknown", true), "Unknown actions must never create extra mappings")
	_expect(not model.set_range("roll", 0, 0) and not model.set_range("roll", -1, 1, 1) and not model.set_range("roll", -2, 1), "Invalid calibration must be rejected")
	_expect(not model.set_range("roll", NAN, 1) and not model.set_range("roll", -1, INF), "Non-finite calibration must be rejected")
	_expect(model.set_range("roll", -0.8, 0.9, 0.2), "Valid calibration must remain editable")
	model.set_inverted("roll", true)
	model.set_half_range("roll", true)
	model.set_toggle("roll", true)
	_expect(model.get_config("roll").inverted and model.get_config("roll").half_range and model.get_config("roll").is_toggle, "All mode setters must update the working mapping")
	model.set_channel("roll", 2)
	_expect(not model.binding_available("roll", [0.0]) and model.binding_available("roll", [0.0, 0.0, 0.2]), "Preview must guard missing input channels")


func _test_detection(script) -> void:
	var model = script.new()
	model.begin({"roll": {"channel": 4}, "yaw": {"channel": 7}})
	var raw: Array = []
	raw.resize(model.CHANNEL_COUNT)
	raw.fill(0.0)
	_expect(model.start_detection("roll", raw, 2), "Valid detector must start")
	raw[1] = 0.49
	_expect(model.update_detection(raw, 0.1, 2).status == "waiting", "Subthreshold movement must not bind")
	raw[1] = 0.5
	var detected = model.update_detection(raw, 0.1, 2)
	_expect(detected.status == "assigned" and detected.channel == 1 and model.get_config("roll").channel == 1, "Exact threshold and gradual movement must bind the selected action")
	_expect(model.get_config("yaw").channel == 7 and model.get_detecting_action() == "", "Successful detection must stop and leave other actions unchanged")
	model.start_detection("roll", raw, 2)
	model.cancel_detection()
	_expect(model.get_config("roll").channel == 1, "Cancelling detection must preserve the prior binding")
	model.start_detection("roll", raw, 2, 0.5)
	_expect(model.update_detection(raw, 0.5, 2).status == "timed_out" and model.get_config("roll").channel == 1, "Timeout must preserve the prior binding")
	model.start_detection("roll", raw, 2)
	_expect(model.update_detection(raw, 0.01, 3).status == "device_changed" and model.get_config("roll").channel == 1, "Device changes must cancel safely")
	model.start_detection("roll", raw, 2)
	_expect(model.update_detection([1.0], 0.01, 2).status == "input_changed" and model.get_config("roll").channel == 1, "Input-buffer length changes must cancel safely")
	model.start_detection("roll", raw, 2)
	model.start_detection("yaw", raw, 2)
	raw[10] = 1.0
	_expect(model.update_detection(raw, 0.01, 2).channel == 10 and model.get_config("yaw").channel == 10 and model.get_config("roll").channel == 1, "Only the most recent detector may assign, including button channels")
	_expect(not model.start_detection("roll", [], 2) and not model.start_detection("unknown", raw, 2), "Missing samples and unknown actions must be rejected")
	_expect(not model.start_detection("roll", [NAN], 2) and not model.start_detection("roll", raw, 2, 0), "Invalid samples and timeout must be rejected")
	model.start_detection("roll", raw, 2)
	raw[0] = INF
	_expect(model.update_detection(raw, 0.01, 2).status == "input_changed" and model.get_config("roll").channel == 1, "Invalid samples must never create a binding")
	_expect(model.update_detection([], 0.01, 2).status == "idle", "An inactive detector must ignore any input buffer")


func _test_labels(script) -> void:
	var model = script.new()
	_expect(model.source_label("roll") == "Unassigned", "Unassigned source must be explicit")
	_expect(model.channel_label(0) == "Axis 1 (channel 0)" and model.channel_label(9) == "Axis 10 (channel 9)", "Physical axis names must distinguish zero-based internal channels")
	_expect(model.channel_label(10) == "Button 1 (channel 10)", "Button channels must never be labelled axes")
	_expect(model.channel_label(model.CHANNEL_COUNT) == "Unassigned", "Out-of-range source labels must be safe")
