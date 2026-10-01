extends Node
## rotor_drag: the drag spinning props put on a quad moving across them.
##
## A prop draws air in and throws it out along its axis. Air arriving across
## the prop - the quad moving sideways or forwards, or wind - has that
## sideways motion taken out of it, and the quad is pushed back: a force
## against the airspeed across the props, growing with that airspeed (not
## its square, as the game's body drag does) and with how much air the props
## move. Momentum theory gives the air moved as sqrt(rho * A * T / 2) kg/s
## for open props of total disc area A making thrust T, and sqrt(rho * A * T)
## in ducts, which send the whole flow out along the axis. Part of that
## momentum is felt as drag:
##   open props  0.17 - what a Crazyflie 2.0's measured rotor drag (Forster,
##               2015) is of this figure
##   ducts       0.25 - a quarter of the full ducted-fan figure (twice what
##               open props of the same size give): a whoop's ducts are
##               short and open at the bottom. Set against a real Meteor75
##               Pro II: at 0.5 the game's stopped shorter than the real one,
##               with none it slid further
## `strength` scales both.
##
## At the few metres a second of a whoop course this is most of what slows a
## quad; flat out, tilted far over, most of the air goes through the props
## along their axis and it changes the top speed little.
##
## Each physics tick it adds the force to the quad the game flies (its
## RigidBody3D), next to the game's own thrust, drag and wind - not while
## disarmed (props stopped), paused or in turtle mode, and never to other
## players' quads.

const RHO := 1.225
const ETA_OPEN := 0.17
const ETA_DUCT := 0.25
const G := 9.8

const DEFAULTS := {"strength": 1.0}

# each drone's props: drones/settings.cfg, shared with the other mods
const SPECS_PATH := "res://drones/specs.gd"

var cfg := {}
var drone := {}              # the one in use: the drones mod's figures for it
var drone_id := "-"
var _specs = null            # the drones mod's specs.gd, or null without it
var _spec_gen := -1
var force := Vector3.ZERO    # what was added on the last tick, for the tests
var _coef := 0.0             # N per (m/s) per sqrt(N of thrust)
var _core: Node = null
var _scene: Node = null
var _player: Node = null
var _t_retry := 0.0


## Reads settings.cfg [rotor_drag]; the drones' props are the drones mod's.
## Returns a line for status.txt.
func setup(dir: String, core: Node) -> String:
	_core = core
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK and c.has_section("rotor_drag"):
		for k in c.get_section_keys("rotor_drag"):
			if cfg.has(k):
				cfg[k] = c.get_value("rotor_drag", k)
	cfg["strength"] = clampf(float(cfg["strength"]), 0.0, 5.0)
	_specs = load(SPECS_PATH) if ResourceLoader.exists(SPECS_PATH) else null
	if _specs == null:
		return "not in effect: the drones folder is missing (it comes with this mod: extract the zip again)"
	return "strength %s; each drone's props from drones/settings.cfg" % str(cfg["strength"])


## "31 mm props in ducts"
static func describe(d: Dictionary) -> String:
	return "%d mm props%s" % [int(round(float(d["prop_mm"]))), " in ducts" if bool(d["ducted"]) else ""]


## The props for a drone: the drones mod's figures for it (an added
## drone's from its block, the rest from the drone it is built on)
func use_drone(vehicle_id: String) -> void:
	drone_id = vehicle_id
	_spec_gen = _specs.generation()
	drone = _specs.figures(vehicle_id, _core)
	var mm := clampf(float(drone["prop_mm"]), 10.0, 400.0)
	var area := 4.0 * PI * pow(mm / 2000.0, 2.0)
	var ducted := bool(drone["ducted"])
	_coef = float(cfg["strength"]) * (ETA_DUCT if ducted else ETA_OPEN) * sqrt(RHO * area * (1.0 if ducted else 0.5))


## Rotor drag while hovering, per second (the braking of 1 m/s across the
## props, in m/s^2), for a quad of this weight
func per_second_at_hover(mass_kg: float) -> float:
	return _coef * sqrt(mass_kg * G) / maxf(mass_kg, 0.001)


func _vehicle_id() -> String:
	var gs := get_node_or_null("/root/ZGamestate")
	var v = gs.get("selected_vehicle_id") if gs != null else null
	return str(v) if v != null else ""


func _physics_process(dt: float) -> void:
	force = Vector3.ZERO
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
	# the game's own quad only: a RigidBody3D with the quad flight model (a
	# wing has a physics_handler of its own)
	if not (p is RigidBody3D) or p.get("physics_handler") != null or not p.has_method("get_thrust_at_rpm"):
		return
	# the game loads the drone's settings on its first tick of a flight, and
	# drops them while paused: its thrust cannot be asked for until then
	if not (p.get("_SETTINGS") is Dictionary):
		return
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return
	if _specs == null:
		return
	var vid := _vehicle_id()
	if vid != drone_id or _specs.generation() != _spec_gen:
		use_drone(vid)
		if get_parent() != null and get_parent().has_method("drone_changed"):
			get_parent().call("drone_changed", "flying %s: %s, rotor drag %.2f per second at hover" % [
				drone["name"], describe(drone), per_second_at_hover(float((p as RigidBody3D).mass))])
	if _coef <= 0.0 or dt <= 0.0:
		return
	if not (p.has_method("is_armed") and bool(p.call("is_armed"))) or p.get("turtle_mode_active") == true:
		return
	var thrust := maxf(float(p.call("get_thrust_at_rpm", float(p.get("current_motor_rpm")))), 0.0)
	var body := p as RigidBody3D
	var wind = gs.get("current_wind_effect") if gs != null else null
	var air: Vector3 = body.linear_velocity - (wind if wind is Vector3 else Vector3.ZERO)
	var up := body.global_transform.basis.y.normalized()
	var across := air - up * air.dot(up)
	var f := -across * (_coef * sqrt(thrust))
	# never more than stops the motion across the props in this one tick
	var most := body.mass * across.length() / dt
	if f.length() > most:
		f = f.normalized() * most
	body.apply_central_force(f)
	force = f
