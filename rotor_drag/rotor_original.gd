extends Node
## rotor_drag: spinning props in moving air - the drag they put on a quad
## moving across them, and the thrust they keep as it climbs.
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
##
## It also takes off the physics engine's own damping. Godot slows every
## moving body by a share of its speed each second - 0.1, its
## default_linear_damp - unless a game sets it otherwise, and the game
## leaves it: a drag on the quad that no real one has, on top of the air's.
## `engine_damping` sets it for the quad flown (0 = none; 0.1 = as the game
## has it).
##
## Climbing (`climb`): air coming through the props along their axis - a
## climb, and the part of fast forward flight that goes through them, tilted
## over. The game takes thrust off in a straight line from the first metre a
## second (half gone at the drone's top_speed), and on top of that counts the
## spinning props as more body drag along the axis (its corner drag: a
## full-throttle climb meets about 1.6 times the drag of a hover). A real
## prop barely loses thrust at first - its blades are partly stalled
## standing still, and the motor speeds up as the air unloads them - and
## loses it faster nearer its pitch speed; and that loss is all the props
## cost a climb. With climb on, the thrust falls as 1 - 0.5 (v/top_speed)^1.5:
## still half at top_speed, so every drone's top_speed keeps its meaning (and
## the game's floor of half beyond it), fitted to a Gemfan 1811's bench test
## (45 mm, 1.8" pitch, on a 1102 motor: a Meteor75 Pro II's) with a pitch-
## to-diameter-1 prop's thrust against advance ratio and the motor speeding
## up as the prop unloads - within 3% of that from 10 to 25 m/s; and the props'
## part of the body drag is taken back off while air comes through them from
## above. Falling through them is left as the game has it (dirty_air works on
## that).

const RHO := 1.225
const ETA_OPEN := 0.17
const ETA_DUCT := 0.25
const G := 9.8
# a prop's thrust against the airspeed through it, over the drone's top_speed
const CLIMB_EXP := 1.5

const DEFAULTS := {"strength": 1.0, "engine_damping": 0.0, "climb": true}

# each drone's props: drones/settings.cfg, shared with the other mods
const SPECS_PATH := "res://drones/specs.gd"

var cfg := {}
var drone := {}              # the one in use: the drones mod's figures for it
var drone_id := "-"
var _specs = null            # the drones mod's specs.gd, or null without it
var _spec_gen := -1
var force := Vector3.ZERO    # what was added on the last tick, for the tests
var climb_force := Vector3.ZERO  # the game's extra climb drag given back on the last tick
var _curve: Array = []       # the climb table put in place of the game's
var _game_consts := {}       # the game quad's DRAG_COEFFICIENT, AIR_DENSITY, MAX_MOTOR_RPM
var _const_of: Object = null
var _climb_note := ""        # why the climb table is left as the game has it, if it is
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
	cfg["engine_damping"] = clampf(float(cfg["engine_damping"]), 0.0, 1.0)
	cfg["climb"] = _bool(cfg["climb"])
	_specs = load(SPECS_PATH) if ResourceLoader.exists(SPECS_PATH) else null
	if _specs == null:
		return "not in effect: the drones folder is missing (it comes with this mod: extract the zip again)"
	return "strength %s; each drone's props from drones/settings.cfg; the engine's own damping %s a second (the game leaves Godot's 0.1); climbing: %s" % [
		str(cfg["strength"]), str(cfg["engine_damping"]),
		"the props keep their thrust as a prop does (half at the drone's top_speed) and the game's extra climb drag is taken off"
		if cfg["climb"] else "the game's own straight-line thrust loss and climb drag"]


static func _bool(v) -> bool:
	if typeof(v) == TYPE_BOOL:
		return v
	return not (str(v).strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower() in ["false", "no", "off", "0", ""])


## The thrust kept against the airspeed through the props, in the game's
## table form: entry i for i/100 of top_speed, half at top_speed and beyond
static func climb_table(n: int) -> Array:
	var out := []
	for i in n:
		out.append(1.0 - 0.5 * pow(minf(float(i) / 100.0, 1.0), CLIMB_EXP))
	return out


## The game's own table, extrapolate([1, 0.5], 100): a straight line
static func game_table(n: int) -> Array:
	var out := []
	for i in n:
		out.append(1.0 - 0.5 * minf(float(i) / 100.0, 1.0))
	return out


# The quad's thrust against airspeed: this mod's table with climb on, the
# game's with it off. Only a table that is the game's (or this one) is
# replaced: anything else is a game update or another mod's, and is left.
func _set_curve(p: Object) -> void:
	var cur = p.get("SPEED_THRUST_CURVE")
	if not (cur is Array) or (cur as Array).size() < 100:
		_note_climb("the game's quad has no table of thrust against airspeed this knows: left as the game has it")
		return
	var a: Array = cur
	if bool(cfg["climb"]):
		if is_same(a, _curve):
			return
		if not _is_game_table(a):
			_note_climb("the game's table of thrust against airspeed is not the straight line this replaces: left as it is")
			return
		if _curve.size() != a.size():
			_curve = climb_table(a.size())
		p.set("SPEED_THRUST_CURVE", _curve)
		_climb_note = ""
	elif is_same(a, _curve):
		p.set("SPEED_THRUST_CURVE", game_table(a.size()))


static func _is_game_table(a: Array) -> bool:
	for i in [0, 25, 50, 75, 99]:
		if not (a[i] is float or a[i] is int) or absf(float(a[i]) - (1.0 - 0.5 * float(i) / 100.0)) > 0.002:
			return false
	return true


func _note_climb(s: String) -> void:
	if s == _climb_note:
		return
	_climb_note = s
	if get_parent() != null and get_parent().has_method("drone_changed"):
		get_parent().call("drone_changed", "climbing: " + s)


# The game's body drag along the props' axis counts the spinning props once
# more (times 1 + corner drag x rpm share): while the air comes through them
# from above, that part is given back, as the climb table above already
# takes what the props cost a climb. Worked out as the game works its drag
# out, on the same speed and motor speed.
func _climb_drag(p: Object, body: RigidBody3D) -> Vector3:
	var v := body.linear_velocity
	var speed := v.length()
	if speed <= 0.0:
		return Vector3.ZERO
	var axial := v.dot(body.basis.y)
	if axial <= 0.0:
		return Vector3.ZERO
	var st = p.get("_SETTINGS")
	if not (st is Dictionary) or not (st.get("adjustable_settings") is Dictionary) or not (st.get("internal_settings") is Dictionary):
		return Vector3.ZERO
	var adj: Dictionary = st["adjustable_settings"]
	var inn: Dictionary = st["internal_settings"]
	var k := _consts(p)
	var cs_y := float(inn.get("surface_area_y", 0.0)) * float(adj.get("surface_area_y_multi", 100.0)) / 100.0
	var r := float(p.get("current_motor_rpm")) / maxf(float(k["MAX_MOTOR_RPM"]), 1.0)
	var extra := 0.5 * float(k["DRAG_COEFFICIENT"]) * float(k["AIR_DENSITY"]) * cs_y \
		* float(inn.get("corner_drag_factor", 0.0)) * r * (axial / speed) * speed * speed
	return v / speed * maxf(extra, 0.0)


func _consts(p: Object) -> Dictionary:
	if _const_of != p:
		_const_of = p
		var m := {}
		var sc = p.get_script()
		if sc is Script:
			m = (sc as Script).get_script_constant_map()
		_game_consts = {"DRAG_COEFFICIENT": m.get("DRAG_COEFFICIENT", 0.38), "AIR_DENSITY": m.get("AIR_DENSITY", 1.225),
			"MAX_MOTOR_RPM": m.get("MAX_MOTOR_RPM", 1400.0 * 22.2)}
	return _game_consts


# The engine's damping on the quad: engine_damping in place of Godot's
# default (0.1 a second), set when it differs - a new quad (a respawn, another
# map) or a change in the game
func _set_damping(body: RigidBody3D) -> void:
	var d := float(cfg["engine_damping"])
	if body.linear_damp_mode != RigidBody3D.DAMP_MODE_REPLACE or not is_equal_approx(body.linear_damp, d):
		body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		body.linear_damp = d


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
	climb_force = Vector3.ZERO
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
	_set_damping(p as RigidBody3D)
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
	_set_curve(p)
	if dt <= 0.0:
		return
	if not (p.has_method("is_armed") and bool(p.call("is_armed"))) or p.get("turtle_mode_active") == true:
		return
	var body := p as RigidBody3D
	if bool(cfg["climb"]) and _climb_note == "":
		climb_force = _climb_drag(p, body)
		if climb_force != Vector3.ZERO:
			body.apply_central_force(climb_force)
	if _coef <= 0.0:
		return
	var thrust := maxf(float(p.call("get_thrust_at_rpm", float(p.get("current_motor_rpm")))), 0.0)
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
