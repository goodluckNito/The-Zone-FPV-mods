extends Node
## dirty_air: the air a quad has already pushed down, and the floor and
## ceiling close to its props.
##
## Descending along the thrust axis, the props meet the air they threw down
## (the game gives the same thrust falling as hovering):
##   - falling slowly, a little more thrust - momentum theory, with
##     Leishman's fit for the air through the props in descent: +4% at half
##     the props' hover wake speed vh, +8% at vh, +14% at 1.5 vh
##   - from about half vh to 1.7 vh the props sit in their own wake (the
##     vortex ring state), deepest at 1.1 vh: thrust drops to about 0.7 of
##     hover and each prop's fluctuates by 17% (ducted) or 30% (open props) -
##     measured on small props at constant rpm, 0.7 of hover at 1.2-1.3 vh
##     and 14-20% (Veismann et al. 2023), but met earlier and over a wider
##     band by a quad flying, its props' speed changing, than on a test
##     stand (as in Propwash FPV's model); flying across the wake at vh or
##     more clears it
##   - the fluctuation is each prop's own, so besides a bob it rocks the
##     quad; and a quad in its wake shakes (prop wash) as its flight
##     controller and motors fight that - the shake is added as a small
##     attitude jitter around 25 Hz, the band Betaflight's tuning notes give
##     for prop wash, sized by feel (the game's own rotation control is
##     idealised and would not shake by itself)
## vh is worked out from the thrust at that moment, so a punch out of a fall
## sweeps through the wake - where prop wash is worst.
##
## The air the quad leaves behind stays: hovering, climbing or flying, its
## props leave a column of air going the other way at twice the speed
## through them (momentum theory: slower the faster it flies, so a fast pass
## leaves little). It is kept as puffs along the path, each spreading and
## slowing as a turbulent round jet does (half-width +0.094 per metre it
## travels, speed falling with its width), turbulent at a quarter of its
## speed, and drifting with the wind. Flying back into it - diving down the
## column of a punch, turning back through a hover - each prop meets that
## air: its flow through the prop, and its gusts (a quarter of the jet's
## speed on its axis, less towards its edge), change that prop's thrust as
## a change in its climb or descent would - at fixed rpm, by the slope of
## thrust against axial speed: 0.3 x the change over vh near hover
## (blade-element momentum theory), more falling fast, where the props act
## as a disc the air is forced through (the descent curve above, and 0.9 x
## the dynamic pressure's change on the disc beyond it). Each prop has its
## own gusts, but alike where the eddies are bigger than the frame. The quad's own column counts only once it has
## left it; the wake of a steady descent is the vortex ring state above.
##
## Near a floor each prop gains thrust, from the multirotor ground-effect
## model of Sanchez-Cuevas et al. (2017), which fits a Crazyflie's measured
## lift (Carter et al. 2021): +15% one prop radius up, +8% at two, fading by
## five, and at most +20%. Ducts take about half of that, and none right on
## the floor. Near a ceiling the props are pulled up: Hsiao and
## Chirarattananon's model, up to +60%, within two radii. Both come from a
## ray under and over each prop, so a tilted quad or one half over a ledge
## gets them on one side only - and is rocked by it. They fade with speed,
## as the wake is swept away.
##
## Each physics tick it adds these as forces at the props of the quad the
## game flies (its RigidBody3D) - not while disarmed, paused or in turtle
## mode, and never to other players' quads.

const RHO := 1.225
const DEFAULTS := {"descent": 1.0, "wake": 1.0, "wash": 1.0, "shake": 0.0, "ground_effect": 1.0, "ceiling_effect": 1.0}

# each drone's props and frame: drones/settings.cfg, shared with the
# other mods
const SPECS_PATH := "res://drones/specs.gd"

# Mean thrust at fixed rpm against the speed of descent along the thrust
# axis, in units of vh (x = Vz / vh, Vz < 0 descending)
const DESCENT := [[0.0, 1.0], [-0.5, 1.04], [-1.0, 1.08], [-1.5, 1.14], [-2.0, 1.39], [-2.5, 1.78]]
const DESCENT_MAX := 1.5
const VRS_CENTRE := -1.1
const VRS_WIDTH := 0.45
const VRS_LOSS := 0.3           # thrust at the heart of the wake: 0.7 of the mean
const VRS_SIGMA := 0.17         # each prop's thrust fluctuation there, in ducts
const OPEN_ROUGH := 1.75        # props in the open fluctuate this much more (0.30)
const VRS_TILT := 0.5           # the part of it that tilts across the quad
const SHAKE_DEG := 1.5          # rms attitude shake there, at shake=1
const SHAKE_HZ := 25.0
const SHAKE_ZETA := 0.3
const GROUND_MAX := 1.2
const GROUND_REACH := 5.0       # prop radii
const CEILING_MAX := 1.6
const CEILING_REACH := 2.0
# the wake left behind
const K_INFLOW := 0.3           # thrust change per change in flow through the prop, over vh
const WAKE_SPREAD := 0.094      # a turbulent round jet's half-width, per metre travelled
const WAKE_TURB := 0.25         # its turbulence (rms) over its speed
const WAKE_SLOTS := 256
const WAKE_LIFE := 2.5          # seconds
const WAKE_SLOWEST := 0.5       # m/s: slower than this, it is gone
const WAKE_EVERY := 1.0 / 30.0  # a puff at least this often while flying ...
const WAKE_MOST := 1.0 / 120.0  # ... at most this often, every half frame-width moved

var cfg := {}
var _specs = null            # the drones mod's specs.gd, or null without it
var _spec_gen := -1
var drone := {}
var drone_id := "-"
# what the last tick did, for the tests and status
var wake := 0.0                 # how deep in its own wake (0-1)
var descent_ratio := 1.0        # mean thrust ratio from the descent
var ground := [1.0, 1.0, 1.0, 1.0]
var ceiling := [1.0, 1.0, 1.0, 1.0]
var force := Vector3.ZERO
var torque := Vector3.ZERO
var shake_offset := Vector2.ZERO   # the jitter in place (radians, roll and pitch)
var wake_flow := Vector3.ZERO   # the old wake's air velocity at the quad (m/s)
var gusts := 0.0                # the thrust fluctuation it gives the props (rms, fraction)
var wash_level := 0.0           # how rough the air is: 1 = the heart of its wake (flight_controller's gyro)
var vrs_sigma := 0.0            # each prop's thrust fluctuation in its own wake (rms, fraction)
var puffs := 0                  # puffs of wake alive

var _core: Node = null
var _scene: Node = null
var _player: Node = null
var _t_retry := 0.0
var _x := 0.0                   # descent speed over vh, lagged as the wake builds
var _flying := false
var _noise := [0.0, 0.0, 0.0, 0.0]
var _tilt := Vector2.ZERO
var _sh := [Vector2.ZERO, Vector2.ZERO]  # the shake resonator: position, velocity
var _rng := RandomNumberGenerator.new()
var _ray: PhysicsRayQueryParameters3D = null
var _local: Array = []          # prop positions in the quad's frame
var _r := 0.02
var _area := 0.005
var _frame := 0.05              # frame radius, motor to prop tip (m)
var _clock := 0.0
var _tick := 0
# the wake: a ring of puffs, each where it was left, which way it blows, its
# starting half-width and speed, when it was left (-1: none), and whether the
# quad has left it yet
var _wp := PackedVector3Array()
var _wd := PackedVector3Array()
var _wr := PackedFloat32Array()
var _wu := PackedFloat32Array()
var _wt := PackedFloat64Array()
var _wfree := PackedByteArray()
var _wnext := 0
var _wlast_t := -1.0
var _wlast_p := Vector3.ZERO
var _near := PackedInt32Array()  # puffs close enough to matter, looked for every few ticks
var _gust := [0.0, 0.0, 0.0, 0.0]
var _gust_all := 0.0
var _last_pos := Vector3.ZERO


## Reads settings.cfg [dirty_air]; the drones' props and frames are
## the drones mod's. Returns a line for status.txt.
func setup(dir: String, core: Node) -> String:
	_core = core
	_rng.randomize()
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK and c.has_section("dirty_air"):
		for k in c.get_section_keys("dirty_air"):
			if cfg.has(k):
				cfg[k] = clampf(float(c.get_value("dirty_air", k)), 0.0, 5.0)
	_specs = load(SPECS_PATH) if ResourceLoader.exists(SPECS_PATH) else null
	if _specs == null:
		return "not in effect: the drones folder is missing (it comes with this mod: extract the zip again)"
	return "descent %s, wake %s, wash %s, shake %s, ground effect %s, ceiling effect %s; each drone's props and frame from drones/settings.cfg" % [
		str(cfg["descent"]), str(cfg["wake"]), str(cfg["wash"]), str(cfg["shake"]), str(cfg["ground_effect"]), str(cfg["ceiling_effect"])]


## "31 mm props in ducts, 65 mm apart"
static func describe(d: Dictionary) -> String:
	return "%d mm props%s, %d mm apart" % [int(round(float(d["prop_mm"]))), " in ducts" if bool(d["ducted"]) else "",
		int(round(float(d["wheelbase_mm"])))]


## The drone flown: the drones mod's figures for it (an added drone's from
## its block, the rest from the drone it is built on)
func use_drone(vehicle_id: String) -> void:
	drone_id = vehicle_id
	_spec_gen = _specs.generation()
	drone = _specs.figures(vehicle_id, _core)
	_r = clampf(float(drone["prop_mm"]), 10.0, 400.0) / 2000.0
	_area = 4.0 * PI * _r * _r
	var s := clampf(float(drone["wheelbase_mm"]), 20.0, 1000.0) / 1000.0 / (2.0 * sqrt(2.0))
	# quad X, forward is -z
	_local = [Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(-s, 0, s), Vector3(s, 0, s)]
	_frame = s * sqrt(2.0) + _r
	clear_wake()


## The props' hover wake speed (m/s) for a quad of this weight
func hover_wake(mass_kg: float) -> float:
	return sqrt(mass_kg * 9.8 / (2.0 * RHO * _area))


## Mean thrust ratio from descending at x = Vz / vh (Vz < 0)
static func descent_curve(x: float) -> float:
	if x >= 0.0:
		return 1.0
	for i in range(1, DESCENT.size()):
		if x >= DESCENT[i][0]:
			var a = DESCENT[i - 1]
			var b = DESCENT[i]
			return minf(lerpf(a[1], b[1], (x - a[0]) / (b[0] - a[0])), DESCENT_MAX)
	return DESCENT_MAX


## Ground effect on one prop z metres above a surface (Sanchez-Cuevas et al.
## 2017, with K_b = 2)
func ground_ratio(z: float) -> float:
	var R := _r
	if z >= GROUND_REACH * R:
		return 1.0
	z = maxf(z, 0.25 * R)
	var b: float = 4.0 * R
	if not _local.is_empty():
		var p0: Vector3 = _local[0]
		b = 2.0 * sqrt(2.0) * absf(p0.x)
	var d: float = b / sqrt(2.0)
	var den := 1.0 - pow(R / (4.0 * z), 2.0) - R * R * z / pow(d * d + 4.0 * z * z, 1.5) \
		- 0.5 * R * R * z / pow(2.0 * d * d + 4.0 * z * z, 1.5) - 4.0 * R * R * z / pow(b * b + 4.0 * z * z, 1.5)
	var g := GROUND_MAX if den <= 1.0 / GROUND_MAX else minf(1.0 / den, GROUND_MAX)
	if bool(drone.get("ducted", false)):
		# a duct takes about half of it, and none right on the floor
		g = 1.0 + (g - 1.0) * 0.5 * clampf((z / R - 0.25) / 0.5, 0.0, 1.0)
	return g


## Ceiling effect on one prop z metres below a surface (Hsiao and
## Chirarattananon), fading to nothing at CEILING_REACH radii
func ceiling_ratio(z: float) -> float:
	var zr := maxf(z / _r, 0.05)
	if zr >= CEILING_REACH:
		return 1.0
	var at_edge := 0.5 + 0.5 * sqrt(1.0 + 1.0 / (8.0 * CEILING_REACH * CEILING_REACH))
	return minf(1.0 + (0.5 + 0.5 * sqrt(1.0 + 1.0 / (8.0 * zr * zr))) - at_edge, CEILING_MAX)


func _vehicle_id() -> String:
	var gs := get_node_or_null("/root/ZGamestate")
	var v = gs.get("selected_vehicle_id") if gs != null else null
	return str(v) if v != null else ""


## Forgets the wake left behind
func clear_wake() -> void:
	_wp.resize(WAKE_SLOTS)
	_wd.resize(WAKE_SLOTS)
	_wr.resize(WAKE_SLOTS)
	_wu.resize(WAKE_SLOTS)
	_wt.resize(WAKE_SLOTS)
	_wt.fill(-1.0)
	_wfree.resize(WAKE_SLOTS)
	_near = PackedInt32Array()
	_wlast_t = -1.0
	puffs = 0


## Leaves a puff of wake at the quad, blowing along -up at twice the air's
## speed through the props: momentum theory, for a climb c and a speed
## across the props vx
func _leave_puff(at: Vector3, up: Vector3, vh: float, c: float, vx: float) -> void:
	var cc := maxf(c, 0.0)
	var vi := vh
	for n in 8:
		vi = 0.5 * (vi + vh * vh / maxf(sqrt(vx * vx + (cc + vi) * (cc + vi)), 1e-3))
	var u0 := 2.0 * vi
	if u0 < 2.0 * WAKE_SLOWEST:
		return
	var n := _wnext
	_wnext = (_wnext + 1) % WAKE_SLOTS
	_wp[n] = at
	_wd[n] = -up
	_wr[n] = _frame
	_wu[n] = u0
	_wt[n] = _clock
	_wfree[n] = 0


## Goes through the puffs: drops the spent ones, frees the ones the quad has
## left, and keeps those near enough to reach it in the next few ticks. A
## puff is a slice of a turbulent round jet: its half-width r grows with the
## distance it has travelled and its speed falls as 1/r, so that
## r^2 = r0^2 + 2 k u0 r0 t.
func _scan(pos: Vector3, speed: float, wind: Vector3, dt: float) -> void:
	_near.clear()
	puffs = 0
	for n in WAKE_SLOTS:
		var t0 := _wt[n]
		if t0 < 0.0:
			continue
		var age := _clock - t0
		var r0 := _wr[n]
		var u0 := _wu[n]
		var r := sqrt(r0 * r0 + 2.0 * WAKE_SPREAD * u0 * r0 * age)
		var u := u0 * r0 / r
		if age > WAKE_LIFE or u < WAKE_SLOWEST:
			_wt[n] = -1.0
			continue
		puffs += 1
		var c := _wp[n] + _wd[n] * ((r - r0) / WAKE_SPREAD) + wind * age
		var dist := c.distance_to(pos)
		if _wfree[n] == 0:
			if dist > r + 2.0 * _frame:
				_wfree[n] = 1
			else:
				continue
		if dist < 2.1 * r + _frame + (speed + u) * 5.0 * dt:
			_near.append(n)


## The old wake at each point: the strongest puff there, its speed (into
## speeds), which way it blows (into dirs) and the speed its gusts go with
## (into turb: a round jet's turbulence falls off towards its edge more
## slowly than its speed). Returns the half-width of the one at the first
## point, for the size of its eddies.
func _old_wake(pts: Array[Vector3], wind: Vector3, speeds: Array, dirs: Array[Vector3], turb: Array) -> float:
	var size := _frame
	for n in _near:
		var t0 := _wt[n]
		if t0 < 0.0:
			continue
		var age := _clock - t0
		var r0 := _wr[n]
		var u0 := _wu[n]
		var r := sqrt(r0 * r0 + 2.0 * WAKE_SPREAD * u0 * r0 * age)
		var u := u0 * r0 / r
		var c := _wp[n] + _wd[n] * ((r - r0) / WAKE_SPREAD) + wind * age
		var inv := -0.693 / (r * r)
		for k in 5:
			var g := exp(inv * (pts[k] - c).length_squared())
			var w := u * g
			if w > speeds[k] and g > 0.05:
				speeds[k] = w
				dirs[k] = _wd[n]
				turb[k] = u * sqrt(g)
				if k == 0:
					size = r
	return size


## How much a prop's thrust changes with the air's speed along its axis, per
## vh, as a fraction of its thrust, at x = Vz / vh: 0.3 near hover and
## climbing, rising along the descent curve's slope falling fast (0.5 at
## 1.5-2 vh, 0.78 at 2-2.5 vh) towards a disc's 0.45 x (Vz / vh)
static func gust_slope(x: float) -> float:
	if x >= 0.0:
		return K_INFLOW
	return clampf(0.45 * -x - 0.35, K_INFLOW, 3.0)


func _gauss() -> float:
	return _rng.randfn(0.0, 1.0)


func _physics_process(dt: float) -> void:
	force = Vector3.ZERO
	torque = Vector3.ZERO
	var tree := get_tree()
	var cs := tree.current_scene if tree != null else null
	_t_retry += dt
	if cs != _scene or (_player == null and _t_retry > 1.0):
		_scene = cs
		_t_retry = 0.0
		_player = cs.find_child("Player", true, false) if cs != null else null
	if _player == null or not is_instance_valid(_player):
		_player = null
		return
	var p := _player
	if not (p is RigidBody3D) or p.get("physics_handler") != null or not p.has_method("get_thrust_at_rpm"):
		return
	# the game loads the drone's settings on its first tick of a flight, and
	# drops them while paused: its thrust cannot be asked for until then
	if not (p.get("_SETTINGS") is Dictionary):
		return
	var body := p as RigidBody3D
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return
	if _specs == null:
		return
	var vid := _vehicle_id()
	if vid != drone_id or _specs.generation() != _spec_gen:
		use_drone(vid)
		if get_parent() != null and get_parent().has_method("drone_changed"):
			var vh := hover_wake(float(body.mass))
			get_parent().call("drone_changed", "flying %s: %s; its wake at hover %.1f m/s, so prop wash falling at about %.1f-%.1f m/s at hover throttle, worst at %.1f; its own wash %s and wake %s" % [
				drone["name"], describe(drone), vh, 0.5 * vh, 1.7 * vh, -VRS_CENTRE * vh, str(drone.get("wash", 1.0)), str(drone.get("wake", 1.0))])
	if dt <= 0.0:
		return
	_clock += dt
	_tick += 1
	var origin := body.global_position
	if origin.distance_to(_last_pos) > 3.0 + 2.0 * body.linear_velocity.length() * dt:
		clear_wake()   # a respawn: the air here is not the quad's
	_last_pos = origin
	var armed: bool = p.has_method("is_armed") and bool(p.call("is_armed")) and p.get("turtle_mode_active") != true
	if not armed:
		wake = 0.0
		wake_flow = Vector3.ZERO
		gusts = 0.0
		wash_level = 0.0
		vrs_sigma = 0.0
		_flying = false
		_unshake(body)
		return
	var thrust := maxf(float(p.call("get_thrust_at_rpm", float(p.get("current_motor_rpm")))), 0.0)
	var basis := body.global_transform.basis
	var up := basis.y.normalized()
	var wind = gs.get("current_wind_effect") if gs != null else null
	var windv: Vector3 = wind if wind is Vector3 else Vector3.ZERO
	var air: Vector3 = body.linear_velocity - windv
	var vh := sqrt(maxf(thrust, 1e-4) / (2.0 * RHO * _area))

	# the wake left behind, at the quad's centre and each prop
	var ws := float(cfg["wake"]) * float(drone.get("wake", 1.0))
	var pts: Array[Vector3] = [origin, origin + basis * _local[0], origin + basis * _local[1],
		origin + basis * _local[2], origin + basis * _local[3]]
	var old := [0.0, 0.0, 0.0, 0.0, 0.0]
	var edge := [0.0, 0.0, 0.0, 0.0, 0.0]
	var odir: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var eddy := _frame
	if ws > 0.0:
		if _tick % 4 == 0:
			_scan(origin, body.linear_velocity.length(), windv, dt)
		eddy = _old_wake(pts, windv, old, odir, edge)
	wake_flow = odir[0] * old[0] * ws
	var rel := air - wake_flow
	var vz := rel.dot(up)
	var vx := (rel - up * vz).length()

	# the wake: descent along the thrust axis, lagged as the wake builds
	# (starting from where it is when the props start)
	var tau_in := clampf(4.4 * _r / vh, 0.005, 0.06)
	if not _flying:
		_flying = true
		_x = vz / vh
	_x += (vz / vh - _x) * (1.0 - exp(-dt / tau_in))
	var strength := float(cfg["descent"])
	var mean := 1.0
	wake = 0.0
	if _x < 0.0:
		var across := 1.0 / (1.0 + pow(vx / vh, 2.0))
		mean = 1.0 + (descent_curve(_x) - 1.0) * across
		wake = exp(-pow((_x - VRS_CENTRE) / VRS_WIDTH, 2.0)) * maxf(0.0, 1.0 - vx / vh)
		mean *= 1.0 - VRS_LOSS * wake
	mean = 1.0 + (mean - 1.0) * strength
	# old wake blowing through the props as a climb would (the game's own
	# thrust already counts the quad's climb)
	var climb := maxf(vz, 0.0) - maxf(air.dot(up), 0.0)
	if climb != 0.0:
		mean *= clampf(1.0 - K_INFLOW * climb / vh, 0.4, 1.2)
	descent_ratio = mean
	# each prop's own fluctuation: noise with a corner at the wake's
	# frequency, about half vh over the prop's circumference
	var fc := clampf(0.5 * vh / (TAU * _r), 4.0, 40.0)
	var tn := 1.0 / (TAU * fc)
	var k := minf(dt / tn, 1.0)
	for i in 4:
		_noise[i] += -_noise[i] * k + sqrt(2.0 * k) * _gauss()
	# and the ring round the whole quad, lifting one side more than the
	# other: a tilt across the props, at the frame's own (slower) frequency
	var ft := clampf(0.5 * vh / (TAU * _frame), 1.0, 40.0)
	var kt := minf(dt * TAU * ft, 1.0)
	_tilt += -_tilt * kt + Vector2(_gauss(), _gauss()) * sqrt(2.0 * kt)
	var wash := float(cfg["wash"]) * float(drone.get("wash", 1.0))
	var rough := 1.0 if bool(drone.get("ducted", true)) else OPEN_ROUGH
	var sigma := VRS_SIGMA * rough * wake * strength * wash
	vrs_sigma = sigma
	# the old wake's gusts: eddies about 0.4 of its half-width, swept through
	# the props at the speed the air passes them; neighbouring props share
	# the gusts of eddies bigger than the gap between them
	var scale := 0.4 * eddy
	var fg := clampf((rel.length() + vh) / (TAU * scale), 2.0, 60.0)
	var kg := minf(dt * TAU * fg, 1.0)
	_gust_all += -_gust_all * kg + sqrt(2.0 * kg) * _gauss()
	var shared := exp(-2.0 * absf((_local[0] as Vector3).x) / scale)
	var slope := gust_slope(_x)
	gusts = 0.0

	# floor and ceiling under and over each prop
	var ge := float(cfg["ground_effect"])
	var ce := float(cfg["ceiling_effect"])
	var fade := 1.0 / (1.0 + pow(air.length() / vh, 2.0))
	var space := body.get_world_3d().direct_space_state if body.get_world_3d() != null else null
	if _ray == null:
		_ray = PhysicsRayQueryParameters3D.new()
	_ray.exclude = [body.get_rid()]
	for i in 4:
		var at: Vector3 = pts[i + 1]
		var g := 1.0
		var c := 1.0
		if space != null and ge > 0.0:
			_ray.from = at
			_ray.to = at - up * (GROUND_REACH * _r)
			var hit := space.intersect_ray(_ray)
			if not hit.is_empty():
				g = ground_ratio(at.distance_to(hit["position"]))
		if space != null and ce > 0.0:
			_ray.from = at
			_ray.to = at + up * (CEILING_REACH * _r)
			var hit2 := space.intersect_ray(_ray)
			if not hit2.is_empty():
				c = ceiling_ratio(at.distance_to(hit2["position"]))
		ground[i] = 1.0 + (g - 1.0) * fade * ge
		ceiling[i] = 1.0 + (c - 1.0) * fade * ce
		# the old wake here: its flow through this prop against the centre's
		# (rocking the quad at the edge of a column), and its gusts
		var here: Vector3 = odir[i + 1] * old[i + 1] * ws
		var inflow := clampf(1.0 - slope * (here - wake_flow).dot(-up) / vh, 0.3, 2.0)
		var sg := minf(slope * WAKE_TURB * edge[i + 1] * ws * wash * rough / vh, 1.0)
		_gust[i] += -_gust[i] * kg + sqrt(2.0 * kg) * _gauss()
		gusts += sg * 0.25
		var gust: float = sg * (sqrt(shared) * _gust_all + sqrt(1.0 - shared) * _gust[i])
		var lp: Vector3 = _local[i]
		var side := Vector2(signf(lp.x), signf(lp.z)) / sqrt(2.0)
		var vrs: float = sqrt(1.0 - VRS_TILT) * _noise[i] + sqrt(VRS_TILT) * _tilt.dot(side)
		var ratio: float = mean * (1.0 + sigma * vrs) * inflow * clampf(1.0 + gust, 0.0, 2.0) * ground[i] * ceiling[i]
		var extra: float = thrust * 0.25 * (ratio - 1.0)
		if extra != 0.0:
			var f := up * extra
			body.apply_force(f, at - origin)
			force += f
			torque += (at - origin).cross(f)

	wash_level = clampf((sigma + gusts) / (VRS_SIGMA * rough), 0.0, 2.0)

	# leave some wake: not while falling along the thrust axis (that wake
	# stays round the props, and is the vortex ring state above)
	if ws > 0.0 and vz > -0.25 * vh:
		var since := _clock - _wlast_t
		if _wlast_t < 0.0 or since >= WAKE_EVERY or (since >= WAKE_MOST and origin.distance_to(_wlast_p) >= 0.5 * _frame):
			_leave_puff(origin, up, vh, vz, vx)
			_wlast_t = _clock
			_wlast_p = origin

	# prop wash shake: a resonator around SHAKE_HZ driven by noise, at unit
	# variance, sized by how deep in the wake the quad is
	var amp := deg_to_rad(SHAKE_DEG) * wake * float(cfg["shake"])
	var w0 := TAU * SHAKE_HZ
	var steps := 4
	var h := dt / steps
	var drive := sqrt(4.0 * SHAKE_ZETA * w0 * w0 * w0)
	for s in steps:
		var noise_in := Vector2(_gauss(), _gauss()) * drive / sqrt(h)
		_sh[1] += (noise_in - 2.0 * SHAKE_ZETA * w0 * _sh[1] - w0 * w0 * _sh[0]) * h
		_sh[0] += _sh[1] * h
	_set_shake(body, _sh[0] * amp)


# Puts the jitter in place: the quad is turned by the change since the last
# tick, about its own roll (z) and pitch (x) axes
func _set_shake(body: RigidBody3D, target: Vector2) -> void:
	var d := target - shake_offset
	if d.length_squared() < 1e-14:
		return
	var b := body.global_transform.basis
	var rot := Basis(b.z.normalized(), d.x) * Basis(b.x.normalized(), d.y)
	body.global_transform = Transform3D(rot * b, body.global_position)
	shake_offset = target


func _unshake(body: RigidBody3D) -> void:
	_sh = [Vector2.ZERO, Vector2.ZERO]
	_set_shake(body, Vector2.ZERO)
