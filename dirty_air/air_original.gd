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
##     hover - measured on small props at constant rpm, 0.7 of hover at
##     1.2-1.3 vh (Veismann et al. 2023)
##   - each prop's thrust also fluctuates there, by 17% (ducted) or 30%
##     (open props) at its deepest (14-20% measured, as above). A quad
##     flying meets that earlier and over a wider band than a test stand
##     does, its props' speed changing (as in Propwash FPV's model), so the
##     fluctuation keeps its own, wider band about the same 1.1 vh: a 75 mm
##     whoop's blackbox has the uncommanded gyro already half of its
##     deepest by a third of vh, where the thrust loss above is still flat
##   - flying across the wake at vh or more clears both
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
## left it; the wake of a steady descent is the vortex ring state above, and
## the column stops being left behind where that band has half come in,
## rather than at a fixed rate of descent, so there is no band between the
## two in which a quad descending gently meets neither.
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
## Other pilots' dirty air (others_wake): other players' quads leave the
## same columns of air behind them, worked out from what the game receives
## for them - where they are, their attitude, their throttle and how they
## move (their thrust from the game's own figures for their drone). The
## nearest few within 40 m count; fly behind or under one and its air takes
## your lift and shakes you as your own does.
##
## Gusty wind (gusts): the air is not still. The game's wind (/set wind_speed
## in its chat) is one steady push the same everywhere, swelling slowly; off,
## there is none. This gives the air turbulence: random gusts along, across
## and up and down the
## wind, from the low-altitude model of MIL-F-8785C (a Dryden-type first-order
## filter per component, the gusts' size along the wind about 30 m, up and
## down about 5 m, swept past at the wind's speed and the quad's), about 22%
## of the wind's speed along and across it and 12% up and down at
## turbulence=1. With the game's wind off, what is left is air that is never
## perfectly still - a calm day outdoors still moves, and indoors the quad's
## own wash does not settle between passes: a floor under the gusts of a
## third of the props' hover wake speed, so it is each drone's own size, and
## with no mean to it, so the air moves without a wind to lean on. Its
## eddies are the ones above, wider than the frame, so it pushes and bobs
## the quad more than it rocks it; what rocking is left is set so that in
## clean air it comes to about what a real whoop's blackbox shows outdoors.
## In the
## lee of a building or wall (a ray 20 m upwind) the game's own wind drops
## (its shelter test) but the air churns: gusts of 30% of the open wind, in
## eddies the size of the gap to the obstacle. The up-and-down gusts reach the
## props, each with a part of its own where the eddies are small, bobbing and
## rocking the quad. The wind with its gusts is put where the game reads its
## wind (ZGamestate.current_wind_effect), so the game's own wind force, and
## the drift of the air left behind, follow it.
##
## wind_kph is the game's wind itself (ZSettings.WIND_SPEED_KPH, what
## /set wind_speed sets): a change in settings.cfg (mod_settings) sets the
## game's, as /set wind_speed would, and a change in the game (its chat) is
## written into settings.cfg, so the two always show the same. The game does
## not keep its wind when it closes, so at each start this takes the game's
## (none) too.
##
## Each physics tick it adds these as forces at the props of the quad the
## game flies (its RigidBody3D) - not while disarmed, paused or in turtle
## mode, and never to other players' quads.

const RHO := 1.225
const DEFAULTS := {"descent": 1.0, "wake": 1.0, "wash": 1.0, "shake": 0.0, "ground_effect": 1.0, "ceiling_effect": 1.0,
	"others_wake": false, "gusts": true, "wind_kph": 0, "turbulence": 1.0, "log_flight": false}
const BOOLS := ["others_wake", "gusts", "log_flight"]

# The flight log (log_flight): what the air did and how hard it shook the
# quad, in bins of the descent it was met at, so a flight here can be set
# beside a blackbox from a real quad. The rate is band-passed: above
# LOG_HP_HZ, which leaves the pilot's own input below it, and below a tenth
# of the tick rate or LOG_LP_HZ, whichever is lower, so the band is always
# one the tick rate can carry. The log says which band it used.
const LOG_LOW := -2.0           # the lowest Vz/vh binned
const LOG_STEP := 0.1
const LOG_BINS := 22
const LOG_HP_HZ := 8.0
const LOG_LP_HZ := 120.0
const LOG_LEAST := 10           # bins with fewer ticks than this are left out

# each drone's props and frame: drones/settings.cfg, shared with the
# other mods
const SPECS_PATH := "res://drones/specs.gd"

# Mean thrust at fixed rpm against the speed of descent along the thrust
# axis, in units of vh (x = Vz / vh, Vz < 0 descending)
const DESCENT := [[0.0, 1.0], [-0.5, 1.04], [-1.0, 1.08], [-1.5, 1.14], [-2.0, 1.39], [-2.5, 1.78]]
const DESCENT_MAX := 1.5
const VRS_CENTRE := -1.1
const VRS_WIDTH := 0.45         # the mean thrust loss: as measured on a test stand
# The fluctuation is felt over a wider band than the loss: a quad flying
# meets it earlier and more gently than a test stand does. Blackbox from a
# 75 mm whoop (40 mm props in ducts, 790 Hz) has the uncommanded gyro
# already half of its deepest value by a third of vh, where the loss curve
# above is still flat, so the two no longer share one width.
const VRS_WASH_WIDTH := 0.75
const VRS_HANDOVER := 0.5       # the wake is left behind until the band carries this much
const VRS_QUARTER := 1.1774     # sqrt(ln 4): where a band is a quarter as deep
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
const WAKE_SLOTS := 256           # the quad's own; as many again for other players' quads
const WAKE_LIFE := 2.5          # seconds
const WAKE_SLOWEST := 0.5       # m/s: slower than this, it is gone
const WAKE_EVERY := 1.0 / 30.0  # a puff at least this often while flying ...
const WAKE_MOST := 1.0 / 120.0  # ... at most this often, every half frame-width moved
# other players' quads
const OTHERS_MAX := 3
const OTHERS_RANGE := 40.0      # m
# the game's drones, for other players' (they send which one): weight (g),
# thrust (g) - default_vehicles.gd; their props are the drones mod's
const GAME_DRONES := {
	"65mm_freestyle": [28.0, 160.0], "85mm_freestyle": [69.0, 400.0], "2.5in_freestyle": [83.0, 550.0],
	"3.5in_freestyle": [290.0, 1800.0], "5in_freestyle": [680.0, 5500.0], "beginner_5_in_quad": [680.0, 3000.0],
	"5in_racer": [480.0, 6000.0],
}
# the game's thrust per motor speed (RPM_THRUST_CURVE), at 0, 10 .. 90% of top speed
const THRUST_CURVE := [0.1, 0.4, 0.5, 0.6, 0.7, 0.79, 0.84, 0.9, 0.95, 1.0]
const TOP_RPM := 1400.0 * 22.2
# gusty wind
const WIND_DIR := Vector3(0.70710678, 0.0, 0.70710678)   # the way the game's wind blows
const GUST_U := 0.22            # along and across the wind, rms over its speed
const GUST_W := 0.12            # up and down
const GUST_LU := 30.0           # m: the gusts' size along and across (MIL-F-8785C, ~5 m up)
const GUST_LW := 5.0            # m: up and down
const LEE_REACH := 20.0         # m upwind looked along for shelter
const LEE_GUST := 0.30          # gusts there, over the open wind's speed
# The room's own air, stirred by the quad and never settling: a floor under
# the wind's gusts, as a part of the props' hover wake speed, so each drone
# makes as much of it as it moves air. It has no mean, only gusts, so it
# churns the air without a wind to lean on.
# Still air's own gusts, over the props' hover wake speed. Measured: at a
# third of it the quad's pitch and roll in clean air came to half of what a
# real whoop's blackbox shows outdoors, and at this it comes to within a
# tenth of it (69 s and 44 s of flight, the band 8-63 Hz, against the same
# filter run over the blackbox at matched crossflow).
const AMBIENT_AIR := 1.05

var cfg := {}
var _specs = null            # the drones mod's specs.gd, or null without it
var _spec_gen := -1
var drone := {}
var drone_id := "-"
# what the last tick did, for the tests and status
var wake := 0.0                 # how deep in its own wake, for the thrust loss (0-1)
var wake_wash := 0.0            # the same, over the wider band the fluctuation is felt over (0-1)
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
var others_puffs := 0           # of them, left by other players' quads
var others_seen := 0            # other players' quads leaving air for you
var gust_wind := Vector3.ZERO   # the wind, gusts and all (m/s), this tick
var mean_wind := Vector3.ZERO   # the wind the gusts are on (m/s)
var lee := 0.0                  # 0 in the open .. 1 sheltered from the wind
var prop_gust := [0.0, 0.0, 0.0, 0.0]   # the up-and-down gust at each prop (m/s)

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
# the flight log: ticks, wash_level, vrs_sigma and the square of the
# band-passed pitch and roll rate, summed per bin of Vz/vh
var _log_path := ""
var _lg_n: Array = []
var _lg_wl: Array = []
var _lg_sig: Array = []
var _lg_r2: Array = []
var _lg_vx: Array = []          # vx/vh: flying across clears the wake
var _lg_time := 0.0
var _lg_ticks := 0
var _lg_hp := Vector2.ZERO      # what is below the band, in two stages
var _lg_hp2 := Vector2.ZERO
var _lg_lp := Vector2.ZERO      # what is in it
var _near := PackedInt32Array()  # puffs close enough to matter, looked for every few ticks
var _gust := [0.0, 0.0, 0.0, 0.0]
var _gust_all := 0.0
var _last_pos := Vector3.ZERO
var _slots := WAKE_SLOTS        # puffs in use: twice as many with others_wake
var _onext := WAKE_SLOTS
var _others := {}               # other players' quads: instance id -> what is known of them
var _turb := Vector3.ZERO       # the gusts: along, across, up (m/s)
var _turb_p := [0.0, 0.0, 0.0, 0.0]   # each prop's own part of the up-and-down gust
var _lee_target := 0.0
var _lee_gap := 10.0
var _lee_t := 0.0
var _wind_written = null        # what was put in the game's wind last tick
# wind_kph and the game's wind (ZSettings.WIND_SPEED_KPH), kept the same:
var _wind_sync = null           # what both last said (km/h), null before the first look
var _wind_push = null           # a new wind_kph from settings.cfg, for the game
var _wind_t := 0.0
var _cfg_path := ""             # settings.cfg in the game folder
const WIND_MAX := 50            # the game's /set wind_speed takes 0-50, whole km/h
var _wind_base := Vector3.ZERO
var _gust_vec := Vector3.ZERO   # the gusts on the mean wind (m/s)


## Reads settings.cfg [dirty_air]; the drones' props and frames are
## the drones mod's. Returns a line for status.txt.
func setup(dir: String, core: Node) -> String:
	_core = core
	_rng.randomize()
	var here := OS.get_executable_path().get_base_dir().path_join(dir.trim_suffix("/").get_file())
	_cfg_path = here.path_join("settings.cfg")
	_log_path = here.path_join("flight.txt")
	_lg_reset()
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK and c.has_section("dirty_air"):
		for k in c.get_section_keys("dirty_air"):
			if not cfg.has(k):
				continue
			var v = c.get_value("dirty_air", k)
			if k in BOOLS:
				cfg[k] = v if v is bool else str(v).strip_edges().to_lower() in ["true", "yes", "on", "1"]
			elif k == "wind_kph":
				cfg[k] = clampi(int(round(float(v))), 0, WIND_MAX)
			else:
				cfg[k] = clampf(float(v), 0.0, 5.0)
	_slots = WAKE_SLOTS * (2 if cfg["others_wake"] else 1)
	if not cfg["gusts"]:
		_restore_wind()
	# a wind_kph changed since the game's was last read: for the game
	if _wind_sync != null and int(cfg["wind_kph"]) != int(_wind_sync):
		_wind_push = int(cfg["wind_kph"])
	if is_inside_tree():
		_sync_wind()
	_specs = load(SPECS_PATH) if ResourceLoader.exists(SPECS_PATH) else null
	if _specs == null:
		return "not in effect: the drones folder is missing (it comes with this mod: extract the zip again)"
	return "descent %s, wake %s, wash %s, shake %s, ground effect %s, ceiling effect %s; each drone's props and frame from drones/settings.cfg; other pilots' air %s; gusty wind %s" % [
		str(cfg["descent"]), str(cfg["wake"]), str(cfg["wash"]), str(cfg["shake"]), str(cfg["ground_effect"]), str(cfg["ceiling_effect"]),
		("on (the nearest %d within %d m)" % [OTHERS_MAX, int(OTHERS_RANGE)]) if cfg["others_wake"] else "off",
		("on (turbulence %s), on the game's wind" % str(cfg["turbulence"])) if cfg["gusts"] else "off"] \
		+ "; wind_kph is the game's wind (/set wind_speed)"


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


# Empties the flight log's bins, for the next flight
func _lg_reset() -> void:
	_lg_n = []
	_lg_wl = []
	_lg_sig = []
	_lg_r2 = []
	_lg_vx = []
	for i in LOG_BINS:
		_lg_n.append(0)
		_lg_wl.append(0.0)
		_lg_sig.append(0.0)
		_lg_r2.append(0.0)
		_lg_vx.append(0.0)
	_lg_time = 0.0
	_lg_ticks = 0
	_lg_hp = Vector2.ZERO
	_lg_hp2 = Vector2.ZERO
	_lg_lp = Vector2.ZERO


# One tick into the flight log: the quad's own pitch and roll rate, with the
# pilot's input filtered out below the band and the tick rate's own steps
# above it, binned by the descent it was met at.
func _lg_tick(body: RigidBody3D, basis: Basis, dt: float, across: float) -> void:
	var w: Vector3 = body.angular_velocity * basis
	var rate := Vector2(w.x, w.z)
	# two high-pass stages: one leaves too much of the pilot's own input in
	var a := 1.0 - exp(-TAU * LOG_HP_HZ * dt)
	_lg_hp += (rate - _lg_hp) * a
	var once := rate - _lg_hp
	_lg_hp2 += (once - _lg_hp2) * a
	var top := minf(LOG_LP_HZ, 0.25 / maxf(dt, 1e-5))
	_lg_lp += ((once - _lg_hp2) - _lg_lp) * (1.0 - exp(-TAU * top * dt))
	var i := clampi(int(floor((_x - LOG_LOW) / LOG_STEP)), 0, LOG_BINS - 1)
	_lg_n[i] = int(_lg_n[i]) + 1
	_lg_wl[i] = float(_lg_wl[i]) + wash_level
	_lg_sig[i] = float(_lg_sig[i]) + vrs_sigma
	_lg_r2[i] = float(_lg_r2[i]) + _lg_lp.length_squared()
	_lg_vx[i] = float(_lg_vx[i]) + across
	_lg_time += dt
	_lg_ticks += 1


# Writes the flight log on disarming: a line per bin of the descent, with the
# wake's own figures and the rate it shook the quad at. Appended, so flights
# at different settings can be set side by side.
func _lg_write() -> void:
	if _log_path == "" or _lg_ticks < 60:
		return
	var fs := float(_lg_ticks) / maxf(_lg_time, 1e-6)
	var top := minf(LOG_LP_HZ, 0.25 * fs)
	var out := PackedStringArray()
	out.append("")
	out.append("--- %s: %.1f s armed, %.0f ticks a second, band %.0f-%.0f Hz%s" % [
		str(drone.get("name", drone_id)), _lg_time, fs, LOG_HP_HZ, top,
		"" if top >= 2.0 * LOG_HP_HZ else "  (the ticks are too few for the whole band:"
			+ " the rate below is only the low end of the prop wash)"])
	out.append("    descent %s, wake %s, wash %s, shake %s; its own wash %s and wake %s" % [
		str(cfg["descent"]), str(cfg["wake"]), str(cfg["wash"]), str(cfg["shake"]),
		str(drone.get("wash", 1.0)), str(drone.get("wake", 1.0))])
	out.append("    gusty wind %s, turbulence %s, wind %s kph" % [
		"on" if cfg["gusts"] else "off", str(cfg["turbulence"]), str(cfg["wind_kph"])])
	out.append("         Vz/vh      s   vx/vh   wash_level     sigma    pitch and roll")
	for i in LOG_BINS:
		var n := int(_lg_n[i])
		if n < LOG_LEAST:
			continue
		var lo := LOG_LOW + i * LOG_STEP
		out.append("  %+5.2f..%+5.2f %6.2f %7.2f %12.3f %8.2f%% %10.1f deg/s" % [
			lo, lo + LOG_STEP, float(n) / fs, float(_lg_vx[i]) / n,
			float(_lg_wl[i]) / n, float(_lg_sig[i]) / n * 100.0,
			rad_to_deg(sqrt(float(_lg_r2[i]) / (2.0 * n)))])
	var f := FileAccess.open(_log_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_log_path, FileAccess.WRITE)
	else:
		f.seek_end()
	if f == null:
		return
	f.store_string("\n".join(out) + "\n")


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
	var n := 2 * WAKE_SLOTS
	_wp.resize(n)
	_wd.resize(n)
	_wr.resize(n)
	_wu.resize(n)
	_wt.resize(n)
	_wt.fill(-1.0)
	_wfree.resize(n)
	_near = PackedInt32Array()
	_wlast_t = -1.0
	puffs = 0
	others_puffs = 0


## Leaves a puff of wake at the quad, blowing along -up at twice the air's
## speed through the props: momentum theory, for a climb c and a speed
## across the props vx. Another player's (other) goes in the other half of
## the ring, and is in your way at once (frame: its size).
func _leave_puff(at: Vector3, up: Vector3, vh: float, c: float, vx: float, other: bool = false, frame: float = 0.0) -> void:
	var cc := maxf(c, 0.0)
	var vi := vh
	for n in 8:
		vi = 0.5 * (vi + vh * vh / maxf(sqrt(vx * vx + (cc + vi) * (cc + vi)), 1e-3))
	var u0 := 2.0 * vi
	if u0 < 2.0 * WAKE_SLOWEST:
		return
	var n := _wnext
	if other:
		n = _onext
		_onext = WAKE_SLOTS + (_onext + 1 - WAKE_SLOTS) % WAKE_SLOTS
	else:
		_wnext = (_wnext + 1) % WAKE_SLOTS
	_wp[n] = at
	_wd[n] = -up
	_wr[n] = frame if other else _frame
	_wu[n] = u0
	_wt[n] = _clock
	_wfree[n] = 1 if other else 0


## Goes through the puffs: drops the spent ones, frees the ones the quad has
## left, and keeps those near enough to reach it in the next few ticks. A
## puff is a slice of a turbulent round jet: its half-width r grows with the
## distance it has travelled and its speed falls as 1/r, so that
## r^2 = r0^2 + 2 k u0 r0 t.
func _scan(pos: Vector3, speed: float, wind: Vector3, dt: float) -> void:
	_near.clear()
	puffs = 0
	others_puffs = 0
	for n in _slots:
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
		if n >= WAKE_SLOTS:
			others_puffs += 1
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
				drone["name"], describe(drone), vh,
				(-VRS_CENTRE - VRS_QUARTER * VRS_WASH_WIDTH) * vh,
				(-VRS_CENTRE + VRS_QUARTER * VRS_WASH_WIDTH) * vh,
				-VRS_CENTRE * vh, str(drone.get("wash", 1.0)), str(drone.get("wake", 1.0))])
	if dt <= 0.0:
		return
	_clock += dt
	_tick += 1
	var origin := body.global_position
	if origin.distance_to(_last_pos) > 3.0 + 2.0 * body.linear_velocity.length() * dt:
		clear_wake()   # a respawn: the air here is not the quad's
	_last_pos = origin
	if cfg["gusts"]:
		_gusts(body, gs, dt)
	elif _wind_written != null:
		_restore_wind()
	if cfg["others_wake"] and float(cfg["wake"]) > 0.0:
		var w0 = gs.get("current_wind_effect") if gs != null else null
		_others_step(dt, origin, w0 if w0 is Vector3 else Vector3.ZERO)
	elif not _others.is_empty():
		_others.clear()
		others_seen = 0
	var armed: bool = p.has_method("is_armed") and bool(p.call("is_armed")) and p.get("turtle_mode_active") != true
	if not armed:
		if _flying:
			if bool(cfg["log_flight"]):
				_lg_write()
			_lg_reset()
		wake = 0.0
		wake_wash = 0.0
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
	# mode_3d: props turning backwards push the other way, and less
	var z3 = p.get_meta("zm3") if p.has_meta("zm3") else null
	if z3 is Dictionary and int(z3.get("sign", 1)) < 0:
		up = -up
		thrust *= float(z3.get("k", 1.0))
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
	wake_wash = 0.0
	if _x < 0.0:
		var across := 1.0 / (1.0 + pow(vx / vh, 2.0))
		mean = 1.0 + (descent_curve(_x) - 1.0) * across
		# flying across the wake at vh or more clears it, for both bands
		var swept := maxf(0.0, 1.0 - vx / vh)
		wake = exp(-pow((_x - VRS_CENTRE) / VRS_WIDTH, 2.0)) * swept
		wake_wash = exp(-pow((_x - VRS_CENTRE) / VRS_WASH_WIDTH, 2.0)) * swept
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
	var sigma := VRS_SIGMA * rough * wake_wash * strength * wash
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
		if cfg["gusts"]:
			# the wind's gusts through this prop: rising air through it is
			# more thrust, as a descent would be
			var ga: float = (_gust_vec + Vector3.UP * float(_turb_p[i])).dot(up)
			prop_gust[i] = ga
			ratio *= clampf(1.0 + K_INFLOW * ga / vh, 0.5, 1.5)
		var extra: float = thrust * 0.25 * (ratio - 1.0)
		if extra != 0.0:
			var f := up * extra
			body.apply_force(f, at - origin)
			force += f
			torque += (at - origin).cross(f)

	wash_level = clampf((sigma + gusts) / (VRS_SIGMA * rough), 0.0, 2.0)

	if bool(cfg["log_flight"]):
		_lg_tick(body, basis, dt, vx / vh)

	# leave some wake: as the props sink into it the vortex ring state above
	# takes over, so hand over to it where it has come in rather than at a
	# fixed rate of descent - stopping at a quarter of vh left a band, which
	# a quad descending gently flies in, where neither acted. Flying across,
	# which clears the band, leaves the wake behind as before.
	if ws > 0.0 and wake_wash < VRS_HANDOVER:
		var since := _clock - _wlast_t
		if _wlast_t < 0.0 or since >= WAKE_EVERY or (since >= WAKE_MOST and origin.distance_to(_wlast_p) >= 0.5 * _frame):
			_leave_puff(origin, up, vh, vz, vx)
			_wlast_t = _clock
			_wlast_p = origin

	# prop wash shake: a resonator around SHAKE_HZ driven by noise, at unit
	# variance, sized by how deep in the wake the quad is
	var amp := deg_to_rad(SHAKE_DEG) * wake_wash * float(cfg["shake"])
	var w0 := TAU * SHAKE_HZ
	var steps := 4
	var h := dt / steps
	var drive := sqrt(4.0 * SHAKE_ZETA * w0 * w0 * w0)
	for s in steps:
		var noise_in := Vector2(_gauss(), _gauss()) * drive / sqrt(h)
		_sh[1] += (noise_in - 2.0 * SHAKE_ZETA * w0 * _sh[1] - w0 * w0 * _sh[0]) * h
		_sh[0] += _sh[1] * h
	_set_shake(body, _sh[0] * amp)


# Gusty wind: the gusts' three parts (along, across, up), each a first-order
# filter of noise - the Dryden form of MIL-F-8785C's low-altitude
# turbulence - its time the gusts' size over the speed they sweep past at;
# on the game's wind (none with it off), which in the lee of something
# upwind churns. Into the game's wind.
func _gusts(body: RigidBody3D, gs: Node, dt: float) -> void:
	if gs == null:
		return
	var zs := get_node_or_null("/root/ZSettings")
	var game_kph = zs.get("WIND_SPEED_KPH") if zs != null else null
	var game_on: bool = game_kph != null and float(game_kph) > 0.0
	# Air is never perfectly still: even a calm day outdoors moves, and
	# indoors the quad's own wash does not settle between passes. That is a
	# floor under the wind's own gusts, a part of the props' hover wake
	# speed, so it is the drone's own size - and with no mean to it, so the
	# air moves without a wind to lean on. Its eddies are the ones above,
	# wider than the frame, so it pushes and bobs the quad more than it
	# rocks it: the props meet nearly the same air, about a seventh of it
	# apart (a turbulent cascade over the gap between them gives a fifth).
	var room := AMBIENT_AIR * hover_wake(float(body.mass))
	if not game_on and room <= 0.0:
		if _wind_written != null:
			_restore_wind()
		return
	var cur = gs.get("current_wind_effect")
	var cur_v: Vector3 = cur if cur is Vector3 else Vector3.ZERO
	# the game sets its wind each frame (to nothing, with its wind off); in
	# between it is still what was put there last tick
	if _wind_written == null or not cur_v.is_equal_approx(_wind_written):
		_wind_base = cur_v if game_on else Vector3.ZERO
	var dir := WIND_DIR
	var flat := Vector3(_wind_base.x, 0.0, _wind_base.z)
	if flat.length() > 0.01:
		dir = flat.normalized()
	var pos := body.global_position
	_lee_t -= dt
	if _lee_t <= 0.0:
		_lee_t = 0.1
		var space := body.get_world_3d().direct_space_state if body.get_world_3d() != null else null
		if space != null:
			if _ray == null:
				_ray = PhysicsRayQueryParameters3D.new()
			_ray.exclude = [body.get_rid()]
			_ray.from = pos
			_ray.to = pos - dir * LEE_REACH + Vector3.UP
			var hit := space.intersect_ray(_ray)
			_lee_target = 0.0 if hit.is_empty() else 1.0
			if not hit.is_empty():
				_lee_gap = clampf(pos.distance_to(hit["position"]), 2.0, 10.0)
	lee += (_lee_target - lee) * (1.0 - exp(-dt / 0.4))
	# the game shelters its own wind (to a twentieth, behind something
	# upwind); the gusts go with the open wind's speed
	var mean := _wind_base
	var kph := float(game_kph) if game_on else 0.0
	var open := maxf(maxf(_wind_base.length(), kph / 3.6 * sqrt(2.0)), room)
	var turb := float(cfg["turbulence"])
	var su := lerpf(GUST_U, LEE_GUST, lee) * open * turb
	var sw := lerpf(GUST_W, LEE_GUST, lee) * open * turb
	var lu := lerpf(GUST_LU, _lee_gap, lee)
	var lw := lerpf(GUST_LW, _lee_gap, lee)
	# the eddies go by at the open wind's speed (in a building's lee they
	# churn at the pace of the wind round it) or the quad's through them
	var sweep := maxf(maxf((body.linear_velocity - mean).length(), open), 1.0)
	var ku := minf(dt * sweep / lu, 1.0)
	var kw := minf(dt * sweep / lw, 1.0)
	_turb.x += -_turb.x * ku + su * sqrt(2.0 * ku) * _gauss()
	_turb.y += -_turb.y * ku + su * sqrt(2.0 * ku) * _gauss()
	_turb.z += -_turb.z * kw + sw * sqrt(2.0 * kw) * _gauss()
	var across := dir.cross(Vector3.UP).normalized()
	_gust_vec = dir * _turb.x + across * _turb.y + Vector3.UP * _turb.z
	gust_wind = mean + _gust_vec
	mean_wind = mean
	gs.set("current_wind_effect", gust_wind)
	_wind_written = gust_wind
	# each prop's own part of the up-and-down gusts, where the eddies are not
	# much bigger than the frame
	var gap := 2.0 * absf((_local[0] as Vector3).x) if not _local.is_empty() else 0.1
	var own := sw * sqrt(maxf(1.0 - exp(-2.0 * gap / lw), 0.0))
	var kp := minf(dt * sweep / maxf(0.5 * lw, minf(0.5, lw)), 1.0)
	for i in 4:
		_turb_p[i] += -float(_turb_p[i]) * kp + own * sqrt(2.0 * kp) * _gauss()


# Gusts off (or the mod going): the game's wind as the game has it
func _restore_wind() -> void:
	if _wind_written != null and is_inside_tree():
		var gs := get_node_or_null("/root/ZGamestate")
		var cur = gs.get("current_wind_effect") if gs != null else null
		if cur is Vector3 and (cur as Vector3).is_equal_approx(_wind_written):
			gs.set("current_wind_effect", _wind_base)
	_wind_written = null
	gust_wind = Vector3.ZERO
	mean_wind = Vector3.ZERO
	_gust_vec = Vector3.ZERO
	_turb = Vector3.ZERO
	_turb_p = [0.0, 0.0, 0.0, 0.0]
	lee = 0.0
	prop_gust = [0.0, 0.0, 0.0, 0.0]


# Other players' quads (the children of the game's LOSQuads with a
# stick_position): the nearest OTHERS_MAX within OTHERS_RANGE leave their air
# behind as your quad does - their thrust from their throttle on the game's
# figures for their drone, their speed from how they move
func _others_step(dt: float, origin: Vector3, windv: Vector3) -> void:
	others_seen = 0
	var holder := _scene.get_node_or_null("LOSQuads") if _scene != null else null
	if holder == null:
		_others.clear()
		return
	var cands := []
	for q in holder.get_children():
		if q is Node3D and (q as Node3D).is_visible_in_tree() and "stick_position" in q:
			var d2 := (q as Node3D).global_position.distance_squared_to(origin)
			if d2 < OTHERS_RANGE * OTHERS_RANGE:
				cands.append([d2, q])
	cands.sort_custom(func(a, b): return a[0] < b[0])
	var keep := {}
	for k in mini(cands.size(), OTHERS_MAX):
		var q: Node3D = cands[k][1]
		var id := q.get_instance_id()
		keep[id] = true
		var pos := q.global_position
		if not _others.has(id):
			_others[id] = {"pos": pos, "vel": Vector3.ZERO, "last_t": -1.0, "last_p": pos}
			continue
		var o: Dictionary = _others[id]
		var raw: Vector3 = (pos - (o["pos"] as Vector3)) / dt
		if raw.length() > 150.0:
			o["vel"] = Vector3.ZERO
		else:
			o["vel"] = (o["vel"] as Vector3) + (raw - (o["vel"] as Vector3)) * (1.0 - exp(-dt / 0.1))
		o["pos"] = pos
		var st = q.get("stick_position")
		var thr := clampf((float(st.z) + 1.0) * 0.5, 0.0, 1.0) if st is Vector4 else 0.0
		if thr < 0.02:
			continue
		others_seen += 1
		var cv = q.get("_current_vehicle")
		var vid := str(cv) if cv != null else ""
		if not GAME_DRONES.has(vid):
			vid = "5in_freestyle"
		var gd: Array = GAME_DRONES[vid]
		var fig: Dictionary = _specs.figures(vid, _core)
		var r := clampf(float(fig["prop_mm"]), 10.0, 400.0) / 2000.0
		var half := clampf(float(fig["wheelbase_mm"]), 20.0, 1000.0) / 2000.0
		var x := thr * 10.0
		var ci := mini(int(x), THRUST_CURVE.size() - 1)
		var c: float = THRUST_CURVE[ci] if ci >= THRUST_CURVE.size() - 1 else lerpf(THRUST_CURVE[ci], THRUST_CURVE[ci + 1], x - ci)
		var thrust := float(gd[1]) / 1000.0 * 9.8 * thr * c
		var vh := sqrt(maxf(thrust, 1e-3) / (2.0 * RHO * 4.0 * PI * r * r))
		var up := q.global_transform.basis.y.normalized()
		var air: Vector3 = (o["vel"] as Vector3) - windv
		var vz := air.dot(up)
		var vx := (air - up * vz).length()
		if vz <= -0.25 * vh:
			continue
		var since: float = _clock - float(o["last_t"])
		if float(o["last_t"]) < 0.0 or since >= WAKE_EVERY or (since >= WAKE_MOST and pos.distance_to(o["last_p"]) >= 0.5 * (half + r)):
			_leave_puff(pos, up, vh, vz, vx, true, half + r)
			o["last_t"] = _clock
			o["last_p"] = pos
	for id in _others.keys():
		if not keep.has(id):
			_others.erase(id)


func _exit_tree() -> void:
	_restore_wind()


# wind_kph and the game's wind, every half second: a new wind_kph (from
# settings.cfg) sets the game's, as /set wind_speed does; a change of the
# game's (its chat) goes into settings.cfg; and at the start the game's own
# (it starts with none) is written there
func _process(dt: float) -> void:
	_wind_t -= dt
	if _wind_t <= 0.0:
		_wind_t = 0.5
		_sync_wind()


func _sync_wind() -> void:
	var zs := get_node_or_null("/root/ZSettings")
	if zs == null or zs.get("WIND_SPEED_KPH") == null:
		return
	var game := int(zs.get("WIND_SPEED_KPH"))
	if _wind_push != null:
		var w := clampi(int(_wind_push), 0, WIND_MAX)
		_wind_push = null
		_wind_sync = w
		if w != game:
			zs.set("WIND_SPEED_KPH", w)
		_write_wind(w)          # past 50 there: as the game took it
		return
	if _wind_sync == null or game != int(_wind_sync):
		_wind_sync = game
		cfg["wind_kph"] = game
		_write_wind(game)


# wind_kph=<kph> into settings.cfg, the rest of it as it is
func _write_wind(kph: int) -> void:
	if _cfg_path == "" or not FileAccess.file_exists(_cfg_path):
		return
	var text := FileAccess.get_file_as_string(_cfg_path)
	var re := RegEx.create_from_string("(?m)^[ \\t]*wind_kph[ \\t]*=[^\\r\\n]*")
	var m := re.search(text)
	var line := "wind_kph=%d" % kph
	if m != null and m.get_string() == line:
		return
	if m != null:
		text = text.substr(0, m.get_start()) + line + text.substr(m.get_end())
	else:
		text += ("" if text.ends_with("\n") else "\n") + line + "\n"
	var f := FileAccess.open(_cfg_path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


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
