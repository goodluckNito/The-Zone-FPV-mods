extends "res://mode_3d/base/player_rigid_body.gd"
## mode_3d: the game's quad (player_rigid_body.gd) with motors that run both
## ways, when flight_controller is off. The game's own rotation control flies
## it either way up; here its throttle, motors and thrust are made two-way:
##   - the throttle as 3D mode reads it (main.gd's map_setpoint): the game
##     goes on with its size, the way the motors turn kept in the state
##   - the motors turn one way or the other, braking to a stop and starting
##     again to reverse (main.gd's motor_step); the game's current_motor_rpm
##     is their speed's size, so its sound, drag and the other mods see a
##     motor turning
##   - the game pushes the quad with its thrust, always up as the quad sees
##     it; reversed, that push is turned round and cut to what props turning
##     backwards give (reverse_thrust), the air through them coming from the
##     other side
## Everything else is the game's own, from a copy of its script made at each
## launch.

const ZM_MODE_3D := 1

var zm3_mod = null               # the mode_3d mod


func _zm3():
	if zm3_mod == null or not is_instance_valid(zm3_mod):
		var tree := get_tree()
		zm3_mod = tree.root.get_node_or_null("ZoneMods/mode_3d") if tree != null else null
	# not for the wing, which the game flies with a physics handler of its own
	if zm3_mod == null or not bool(zm3_mod.get("mounted")) or physics_handler != null:
		return null
	return zm3_mod


# The sticks, with the throttle as 3D mode reads it
func apply_setpoint_latency(current_setpoint: Dictionary):
	var sp = super(current_setpoint)
	var m = _zm3()
	if m == null or not (sp is Dictionary):
		return sp
	return m.map_setpoint(self, sp)


# The throttle stick shown (the game's stick overlay, fpv_osd's sticks) as it
# is, not as the motors take it; and in centre mode arming only with the
# throttle at the middle
func _check_arm_switch(setpoint: Dictionary):
	var m = _zm3()
	if m == null:
		super(setpoint)
		return
	stick_pos.z = float(m.state(self)["raw"])
	var keep = throttle_input
	if m.arm_blocked(self):
		throttle_input = 1.0
	super(setpoint)
	throttle_input = keep


# The motors' speed: turning the way the throttle asks, reversing through a
# stop. The game gets its size
func calc_motor_rpm(current: float, wanted: float, delta: float) -> float:
	var m = _zm3()
	if m == null:
		return super(current, wanted, delta)
	var s: Dictionary = m.state(self)
	var w := float(s["w"])
	# the game sets the motors' speed itself in turtle mode
	if absf(absf(w) - current) > 1.0:
		w = current * (-1.0 if w < 0.0 else 1.0)
	var idle := float(_SETTINGS.internal_settings.dynamic_idle_rpm) if _SETTINGS else float(DYN_IDLE_RPM)
	var taus: Vector2 = m.motor_taus()
	w = m.motor_step(w, wanted * float(s["dir"]), delta, taus.x, taus.y, float(MOTOR_RPM_INC_PER_SECOND),
		m.stop_rpm(idle, float(MAX_MOTOR_RPM)), s)
	s["w"] = w
	if w != 0.0:
		s["sign"] = 1 if w > 0.0 else -1
	s["k"] = m.reverse_thrust() if int(s["sign"]) < 0 else 1.0
	return absf(w)


# Turning backwards, the air comes through the props from the other side
# (what they push is reverse_thrust of this: render_speed)
func get_thrust_at_rpm(rpm: float):
	var m = _zm3()
	if m != null and int(m.state(self)["sign"]) < 0 and not turtle_mode_active:
		return m.thrust_reversed(self, rpm)
	return super(rpm)


# Called right after the game has pushed the quad with its thrust - up, as
# the quad sees it, whatever the sign: with the props turning backwards,
# turn that push round and cut it to what they give that way
func render_speed():
	super()
	var m = _zm3()
	if m == null or turtle_mode_active or not is_armed() or not get_viewport().get_window().has_focus():
		return
	var s: Dictionary = m.state(self)
	if int(s["sign"]) >= 0:
		return
	var t := float(get_thrust_at_rpm(current_motor_rpm))
	apply_central_force(global_transform.basis.y.normalized() * -(1.0 + float(s["k"])) * t)


# Other players are sent the throttle as the motors have it
func get_udp_position():
	var a = super()
	var m = _zm3()
	if m != null and a is Array and a.size() > 3 and a[3] is Vector4:
		a[3] = m.udp_stick(self, a[3])
	return a
