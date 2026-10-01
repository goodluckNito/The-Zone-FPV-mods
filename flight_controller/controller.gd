extends RefCounted
## flight_controller: one quad's flight controller, motors and props.
##
## Each physics tick, from the gyro (the quad's rotation rate, in its own
## frame) and the sticks:
##   1. the rate the pilot asks for, from the game's own rates (z_rates)
##   2. a Betaflight-style rate PID per axis, in Betaflight's units and
##      scaling (pid.c): P on the rate error, I on its sum, D on the gyro's
##      change (low-passed, and cut at high throttle as TPA does),
##      feedforward on the change of the stick's rate (smoothed)
##      Until the throttle has first passed airmode_start_throttle_percent
##      since arming, I is held at zero while the throttle is low (under 5%),
##      as Betaflight does, so it cannot wind up on the ground
##   3. Betaflight's LEGACY mixer (mixer.c) for a quad X: the PID sums over
##      1000 spread over the four motors by corner and spin; with airmode (or
##      above half throttle) the throttle is moved just enough that no motor
##      goes past 0 or 1 - and if the corrections need more than the whole
##      range, they are scaled down to fit, and with airmode the throttle
##      goes to half
##   4. the motor output, from idle up, as a motor speed (the game's: kv x
##      battery voltage x output), which each motor follows with its own
##      first-order response
##   5. each motor's thrust from its speed, on the game's own thrust curve
##      for the drone (a quarter of the game's thrust at that speed), at its
##      corner; and the drag torque of its prop, against its spin, for yaw
## The game still pushes the quad with one thrust at its centre, worked out
## from the motors' mean speed (fc.gd hands it that), along with its drag
## and wind; this adds, at each corner, that motor's difference from a
## quarter of it, and the yaw torque. Rotation comes from nothing else.

const KP := 0.032029
const KI := 0.244381
const KD := 0.000529
const KF := 0.013754

var mod = null                   # the flight_controller mod
var prm := {}                    # the drone's parameters
var vid := "-"
var mass := -1.0
var gen := -1
var rpm := [0.0, 0.0, 0.0, 0.0]
var out := [0.0, 0.0, 0.0, 0.0]  # motor outputs, 0-1
var thrust := [0.0, 0.0, 0.0, 0.0]
var mean_rpm := 0.0
var saturated := false
var pid_sum := Vector3.ZERO      # last PID sums (Betaflight units), x pitch, y yaw, z roll
var setpoint_dps := Vector3.ZERO
var gyro_dps := Vector3.ZERO
var iterm := Vector3.ZERO        # the I terms (Betaflight units)
var airmode_started := false     # the throttle has passed airmode_start since arming
var resets := 0                 # times the I term and filters started afresh

var _i := Vector3.ZERO
var _prev_gyro := Vector3.ZERO
var _dterm := Vector3.ZERO
var _prev_sp := Vector3.ZERO
var _ff := Vector3.ZERO
var _fresh := true


func _reset() -> void:
	resets += 1
	_i = Vector3.ZERO
	_dterm = Vector3.ZERO
	_ff = Vector3.ZERO
	_fresh = true


static func _deg(v: Vector3) -> Vector3:
	return Vector3(rad_to_deg(v.x), rad_to_deg(v.y), rad_to_deg(v.z))


func step(p, dt: float, sp: Dictionary) -> void:
	if dt <= 0.0:
		return
	var gs = p.get_node_or_null("/root/ZGamestate")
	var v := str(gs.get("selected_vehicle_id")) if gs != null else ""
	if v != vid or absf(p.mass - mass) > 1e-6 or gen != int(mod.generation()):
		# a settings change while flying (mod_settings) takes the new figures
		# on as they are, the I term and filters carrying on as Betaflight's
		# do when PIDs are changed in flight; another drone starts afresh
		var other := v != vid or absf(p.mass - mass) > 1e-6
		vid = v
		mass = p.mass
		gen = int(mod.generation())
		prm = mod.params_for(vid, mass)
		p.inertia = prm["inertia"]
		_set_friction(p, prm["ground_friction"])
		if other:
			_reset()
	var basis: Basis = p.global_transform.basis
	var av: Vector3 = p.angular_velocity
	var gyro := _deg(av * basis)
	gyro_dps = gyro
	var r = ZSettings.RATES
	var want := _deg(Vector3(
		z_rates.calc_rates(r.type, r.pitch, sp.pitch),
		z_rates.calc_rates(r.type, r.yaw, sp.yaw),
		z_rates.calc_rates(r.type, r.roll, sp.roll),
	) * -1.0)
	setpoint_dps = want
	var thr := clampf(float(p.get("throttle_input")), 0.0, 1.0)
	var volts := float(p.BAT_CURRENT_VOLTAGE)
	var kv := float(p.MOTOR_KV)
	var idle_rpm := float(p._SETTINGS.internal_settings.dynamic_idle_rpm) if p._SETTINGS else 0.0
	var tau_up: float = prm["tau_up"]
	var tau_down: float = prm["tau_down"]

	if not p.is_armed():
		# disarmed: no corrections; the motors do what the game has them do
		_reset()
		airmode_started = false
		iterm = Vector3.ZERO
		var target := maxf(kv * volts * thr, idle_rpm)
		var s := 0.0
		for i in 4:
			rpm[i] = _lag(rpm[i], target, dt, tau_up, tau_down)
			out[i] = 0.0
			thrust[i] = 0.0
			s += rpm[i]
		mean_rpm = s / 4.0
		pid_sum = Vector3.ZERO
		return

	# ---- PID (Betaflight units: deg/s in, "PID sum" out) ----
	if _fresh:
		_prev_gyro = gyro
		_prev_sp = want
		_fresh = false
	var err := want - gyro
	var g: Dictionary = prm["pids"]   # per axis: Vector4(P, I, D, F)
	var px: Vector4 = g["x"]
	var py: Vector4 = g["y"]
	var pz: Vector4 = g["z"]
	var kp := Vector3(px.x, py.x, pz.x) * KP
	var ki := Vector3(px.y, py.y, pz.y) * KI
	var kd := Vector3(px.z, py.z, pz.z) * KD
	var kf := Vector3(px.w, py.w, pz.w) * (KF / 100.0)
	var p_term := kp * err
	# D on the gyro, low-passed (PT1), cut above the TPA breakpoint
	var raw_d := -(gyro - _prev_gyro) / dt
	_prev_gyro = gyro
	_dterm += (raw_d - _dterm) * _pt1(dt, prm["dterm_hz"])
	var tpa := 1.0
	var bp: float = prm["tpa_breakpoint"]
	if thr > bp:
		tpa = 1.0 - float(prm["tpa_rate"]) * (thr - bp) / maxf(1.0 - bp, 0.01)
	var d_term := kd * _dterm * tpa
	# feedforward on the setpoint's change, smoothed
	var raw_f := (want - _prev_sp) / dt
	_prev_sp = want
	_ff += (raw_f - _ff) * _pt1(dt, prm["ff_hz"])
	var f_term := kf * _ff
	# I, held while the mixer is saturated (and pushing the same way); and
	# kept at zero at low throttle until the throttle has first been up
	if thr >= float(prm["airmode_start"]):
		airmode_started = true
	var di := ki * err * dt
	var lim: float = prm["iterm_limit"]
	if thr < 0.05 and not airmode_started:
		_i = Vector3.ZERO
	else:
		for a in 3:
			if saturated and signf(di[a]) == signf(_i[a]):
				continue
			_i[a] = clampf(_i[a] + di[a], -lim, lim)
	iterm = _i
	var sum := p_term + _i + d_term + f_term
	sum = Vector3(clampf(sum.x, -500.0, 500.0), clampf(sum.y, -400.0, 400.0), clampf(sum.z, -500.0, 500.0))
	pid_sum = sum
	var u := sum / 1000.0

	# ---- mixer (LEGACY), airmode ----
	var mix := [0.0, 0.0, 0.0, 0.0]
	var lo := INF
	var hi := -INF
	var axes: Array = prm["mix"]
	for i in 4:
		var m: Vector3 = axes[i]
		mix[i] = u.x * m.x + u.y * m.y + u.z * m.z
		lo = minf(lo, mix[i])
		hi = maxf(hi, mix[i])
	var span := hi - lo
	saturated = false
	var t := thr
	var air := bool(prm["airmode"])
	if span > 1.0:
		# more than the motors have: scale the corrections down to fit, and
		# with airmode put the throttle at half, for all of them
		for i in 4:
			mix[i] /= span
		saturated = true
		if air:
			t = 0.5
	elif air or t > 0.5:
		# move the throttle just enough that no motor passes 0 or 1
		var t2 := clampf(t, -lo, 1.0 - hi)
		if absf(t2 - t) > 1e-6:
			saturated = true
		t = t2
	var idle: float = prm["idle"]
	var s2 := 0.0
	for i in 4:
		var raw: float = t + mix[i]
		if raw > 1.0 or raw < 0.0:
			saturated = true
		var o := clampf(raw, 0.0, 1.0)
		out[i] = idle + (1.0 - idle) * o
		var target := maxf(kv * volts * out[i], idle_rpm)
		rpm[i] = _lag(rpm[i], target, dt, tau_up, tau_down)
		s2 += rpm[i]
	mean_rpm = s2 / 4.0

	# ---- the motors' thrust at their corners, and their drag torque ----
	var centre := float(p.get_thrust_at_rpm(mean_rpm)) * 0.25
	var up := basis.y.normalized()
	var pos: Array = prm["pos"]
	var spin: Array = prm["spin"]
	var kq: float = prm["yaw_torque"]
	var yaw := 0.0
	for i in 4:
		thrust[i] = float(p.get_thrust_at_rpm(rpm[i])) * 0.25
		var local: Vector3 = pos[i]
		p.apply_force(up * (thrust[i] - centre), basis * local)
		yaw += -float(spin[i]) * kq * thrust[i]
	p.apply_torque(up * yaw)


# The quad's grip on the ground. The game gives it the physics engine's
# default, 1.0 - rubber on concrete - which, against a quad's yaw torque
# (drag torque from its props, not the game's idealised one), holds it
# still on the ground; its plastic ducts, frame and feet slide more like 0.3
# to 0.5. Its bounce and the rest of its material stay the game's.
static func _set_friction(p, f: float) -> void:
	var m = p.physics_material_override
	if m is PhysicsMaterial and is_equal_approx(m.friction, f):
		return
	var nm: PhysicsMaterial = m.duplicate() if m is PhysicsMaterial else PhysicsMaterial.new()
	nm.friction = f
	p.physics_material_override = nm


static func _pt1(dt: float, hz: float) -> float:
	if hz <= 0.0:
		return 1.0
	var rc := 1.0 / (TAU * hz)
	return dt / (dt + rc)


static func _lag(x: float, target: float, dt: float, up: float, down: float) -> float:
	var tau := up if target > x else down
	if tau <= 0.0:
		return target
	return target + (x - target) * exp(-dt / tau)
