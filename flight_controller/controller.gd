extends RefCounted
## flight_controller: one quad's flight controller, motors and props.
##
## Each physics tick, from the gyro (the quad's rotation rate, in its own
## frame) and the sticks:
##   1. the rate the pilot asks for, from the game's own rates (z_rates); the
##      gyro's reading, with a little noise (more in rough air)
##   2. a Betaflight-style rate PID per axis, in Betaflight's units and
##      scaling (pid.c): P on the rate error, I on its sum, D on the gyro's
##      change (low-passed, and cut at high throttle as TPA does),
##      feedforward on the change of the stick's rate (smoothed, and eased
##      off near full stick: ff_max_rate_limit, roll and pitch)
##      While the stick's rate changes quickly, I gathers little (I-term
##      relax: Betaflight's setpoint type, 40 deg/s over a 15 Hz low-pass)
##      As the corrections near more than the motors have, I gathers less,
##      and none once they need it all (iterm_windup)
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
##      corner; and for yaw, against its spin, the drag torque of its prop
##      and the motor's own torque speeding the rotor up or slowing it (its
##      moment of inertia times its change of speed: the spin it takes from
##      the frame or gives back)
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
var noise_dps := 0.0             # the gyro's noise this tick (rms, deg/s)

var _i := Vector3.ZERO
var _prev_gyro := Vector3.ZERO
var _dterm := Vector3.ZERO
var _prev_sp := Vector3.ZERO
var _ff := Vector3.ZERO
var _relax := Vector3.ZERO       # the setpoint, low-passed, for I-term relax
var _gn := Vector3.ZERO          # the gyro's noise, band-limited, unit variance
var _rng := RandomNumberGenerator.new()
var _air = null                  # dirty_air's Air node, for how rough the air is
var _air_look := 0
var _mix_range := 0.0            # the last mixer's spread of corrections (Betaflight's motorMixRange)
var _fresh := true


func _reset() -> void:
	resets += 1
	_i = Vector3.ZERO
	_dterm = Vector3.ZERO
	_ff = Vector3.ZERO
	_relax = Vector3.ZERO
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
	# what the gyro reads: the rate plus noise - the motors' vibration that
	# gets through the flight controller's filters, about a degree a second,
	# and four times that in rough air (dirty_air's wash_level), as in
	# Propwash FPV; band-limited at 100 Hz. The D term turns it into a fine
	# jitter of the motors
	var gn: float = prm["gyro_noise"]
	noise_dps = 0.0
	if gn > 0.0:
		var wl := 0.0
		var air = _dirty_air(p)
		if air != null:
			wl = clampf(float(air.get("wash_level")), 0.0, 2.0)
		noise_dps = gn * (1.0 + 3.0 * wl)
		var a := _pt1(dt, 100.0)
		var sc := sqrt((2.0 - a) / a)
		_gn += (Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()) * sc - _gn) * a
		gyro += _gn * noise_dps
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
		_relax = want
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
	# feedforward limited near the top of the rates (Betaflight's
	# ff_max_rate_limit), roll and pitch: it may not push the rate past the
	# limit, and stops once the stick asks for more than it
	var fl: float = prm["ff_limit"]
	if fl < 1.0:
		var top := _deg(Vector3(z_rates.calc_rates(r.type, r.pitch, 1.0), 0.0, z_rates.calc_rates(r.type, r.roll, 1.0))).abs() * fl
		for a in [0, 2]:
			if f_term[a] * want[a] > 0.0:
				if absf(want[a]) <= top[a]:
					f_term[a] = clampf(f_term[a], (-top[a] - want[a]) * kp[a], (top[a] - want[a]) * kp[a])
				else:
					f_term[a] = 0.0
	# I: kept at zero at low throttle until the throttle has first been up
	if thr >= float(prm["airmode_start"]):
		airmode_started = true
	var di := ki * err * dt
	# I-term relax (Betaflight's iterm_relax, setpoint type): while the stick
	# moves quickly, I gathers little or nothing - else it winds up during
	# the move and throws the quad back past where it stopped (bounce-back)
	_relax += (want - _relax) * _pt1(dt, prm["relax_hz"])
	var rx: Vector3 = prm["relax"]
	for a in 3:
		if rx[a] > 0.0:
			di[a] *= maxf(0.0, 1.0 - absf(want[a] - _relax[a]) / 40.0)
	# and as the corrections near more than the motors have, I gathers less,
	# none once they need it all (Betaflight's iterm_windup, from the last
	# mixer's spread)
	var wp: float = prm["iterm_windup"]
	if wp < 1.0:
		di *= clampf((1.0 - _mix_range) / (1.0 - wp), 0.0, 1.0)
	var lim: float = prm["iterm_limit"]
	if thr < 0.05 and not airmode_started:
		_i = Vector3.ZERO
	else:
		for a in 3:
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
	_mix_range = span
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
	var kick := 0.0
	var spin: Array = prm["spin"]
	var per_rpm: float = prm["rotor_j"] * prm["omega_max"] / maxf(float(p.MAX_MOTOR_RPM), 1.0) / dt
	for i in 4:
		var raw: float = t + mix[i]
		if raw > 1.0 or raw < 0.0:
			saturated = true
		var o := clampf(raw, 0.0, 1.0)
		out[i] = idle + (1.0 - idle) * o
		var target := maxf(kv * volts * out[i], idle_rpm)
		var was: float = rpm[i]
		rpm[i] = _lag(rpm[i], target, dt, tau_up, tau_down)
		s2 += rpm[i]
		# the motor's own torque on the frame as it speeds its rotor up or
		# slows it down: the rotor's angular momentum, taken from the frame
		kick += -float(spin[i]) * per_rpm * (rpm[i] - was)
	mean_rpm = s2 / 4.0

	# ---- the motors' thrust at their corners, and their drag torque ----
	var centre := float(p.get_thrust_at_rpm(mean_rpm)) * 0.25
	var up := basis.y.normalized()
	var pos: Array = prm["pos"]
	var kq: float = prm["yaw_torque"]
	var yaw := kick
	for i in 4:
		thrust[i] = float(p.get_thrust_at_rpm(rpm[i])) * 0.25
		var local: Vector3 = pos[i]
		p.apply_force(up * (thrust[i] - centre), basis * local)
		yaw += -float(spin[i]) * kq * thrust[i]
	p.apply_torque(up * yaw)


# dirty_air's Air node, if it is loaded (looked for again now and then)
func _dirty_air(p):
	if _air != null and is_instance_valid(_air):
		return _air
	_air = null
	_air_look -= 1
	if _air_look <= 0:
		_air_look = 250
		_air = p.get_node_or_null("/root/ZoneMods/dirty_air/Air")
	return _air


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
