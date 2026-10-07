extends Node
## prop_damage: props that chip, bend and break when they hit things.
##
## Hits, each physics tick, while the props spin:
##   - the frame: the game reports where the quad touches something and how
##     hard (the contact impulses on its RigidBody3D, through the physics
##     server). Its collision shape is a ring of capsules under the props,
##     the props reaching past it, so a knock on that ring next to a motor is
##     that prop hitting first. A touch landing flat on the arms is not.
##   - the prop tips (tip_strikes): past the ring the props are not in the
##     game's collision shape at all - a tip clipping a pole or a branch goes
##     straight through. A thin disc at each prop is asked what it overlaps;
##     a prop newly in something is a clip, one held in it grinds.
## How much a hit wears a prop goes with how fast its blades turn (their
## energy: the motor's speed squared for a clip; for a knock on the frame,
## also how much the knock took off the quad's speed, a stopped prop still
## taking some) and how far into the thing the prop went. Props in ducts take
## a sixth of it. A very hard hit can break a prop off (breaking), and a prop
## worn right through breaks at its next hit.
##
## What a worn prop does:
##   - less thrust: its blade tips are gone, and they make most of a prop's
##     thrust (a blade's thrust grows with the cube of the radius) - up to
##     35% less, worn right through; a broken one none
##   - vibration: chips are never even, so the prop is out of balance - a
##     shake at the prop's speed, which the camera and the gyro feel (with
##     flight_controller, its D term turns that into twitchy, busy motors),
##     and pilot_audio's motor sound gets rough
##   - a clip at the tip kicks the quad: the thing hit pushes the blade back
##     against its spin, at the tip - a shove and a yaw twitch
## Without flight_controller the game's own rotation control holds the quad
## level against a weak corner (it is idealised), so a damaged prop mostly
## costs thrust; with it, the motors and PIDs work it out as a real quad
## does: the weak corner's motor spins up to make up, and runs out first in
## a punch.
##
## New props: at every respawn (fresh_props_on_respawn), and on picking
## another drone.

const NAMES := ["front left", "front right", "rear left", "rear right"]
const SHORT := ["FL", "FR", "RL", "RR"]
# the props' spin, in the same order: front-left and rear-right
# anticlockwise seen from above (flight_controller's quad X, props in)
const SPIN := [1, -1, -1, 1]
const DEFAULTS := {"durability": 1.0, "breaking": true, "tip_strikes": true, "kick": 1.0, "thrust_loss": 1.0,
	"vibration": 1.0, "fresh_props_on_respawn": true, "show_damage": true,
	"display": "auto", "display_x": 0.9, "display_y": 0.6, "display_size": 1.0, "display_opacity": 0.85,
	"display_only_damaged": true}
const MAX_MOTOR_RPM := 1400.0 * 22.2   # the game's (player_rigid_body.gd), when the quad does not say
const WORN_THRUST := 0.35       # thrust a prop worn right through has lost
const HIT_START := 0.1          # m/s off the quad's speed in a tick that starts a knock
const HIT_DV0 := 0.6            # a knock taking less than this off its speed is a touch
const HIT_K := 0.1              # wear per m/s past that, blades at full speed
const HIT_SEV := 6.0            # m/s past that, at full speed, for a hit as hard as a clip half in
const STILL := 0.15             # a stopped prop still takes this much of a knock
# a clip takes off what went into the thing hit: a chip a fraction c of the
# radius deep off one of three blades is about 4c/3 of the prop's thrust
# (a blade's thrust grows with the radius cubed), or 3.8 c of wear - at full
# speed; slower blades cut less cleanly (0.3 of it stopped)
const TIP_K := 3.8
const BOUNCE := 0.2             # props bounce the quad off what they hit this much
const PUSH_S := 0.03            # and push it out of something they are in within this long
const TIP_SPEED := 3.0          # m/s into the thing hit that doubles a clip's wear
const MAX_CHIP := 0.9           # one hit wears a prop at most this much
const BREAK_AT := 0.6           # a hit this hard can break a prop off (breaking) ...
const BREAK_SURE := 1.5         # ... and one this hard does (1: a clip half in, at full speed)
const DUCTED := 0.17            # props in ducts take this much of it
const KICK_DPS := 300.0         # yaw a full-speed clip half in kicks the quad round by (deg/s, kick=1) ...
const KICK_MAX_DV := 0.3        # ... shoving it at most this much (m/s)
const IMBALANCE := 2.0          # out of balance per wear a hit takes
const SHAKE_DEG := 0.3          # rms attitude shake, one prop fully out of balance at full speed
const SHAKE_HZ := 35.0
const SHAKE_ZETA := 0.25
const NOTE_S := 2.5
const CLIP_S := 0.04            # a clip is told (OSD, status) this long after it starts, or when it ends

var cfg := {}
# each prop, in the order of NAMES
var wear := [0.0, 0.0, 0.0, 0.0]          # 0 new .. 1 blade tips worn right through
var broken := [false, false, false, false]
var thrust_factor := [1.0, 1.0, 1.0, 1.0] # its thrust, against a new prop's
var imbalance := [0.0, 0.0, 0.0, 0.0]     # 0 balanced .. 1 badly out (times vibration)
var vibration_level := 0.0                # sum of imbalance x (speed / top speed)^2, this tick
var hits := 0                             # hits that did damage, since the last new props
var events: Array = []                    # the last hits, for tests and status.txt
var fresh := 0                            # times new props went on
var force := Vector3.ZERO                 # thrust taken off this tick (without flight_controller)
var shake_offset := Vector2.ZERO
var drone := {}
var drone_id := "-"
var note := ""
# for an OSD (fpv_osd): goes up with each hit worth telling, the last of them
# ({prop, short, wear, broken}); and when an OSD last said it is showing them
# itself (Time.get_ticks_msec()) - then the game's own message box is left alone
var hit_serial := 0
var last_hit := {}
var osd_taken_ms := -100000
# and when an OSD last said it is drawing the quad (display="auto", from
# osd_display()) - then the quad over the game steps aside
var osd_drawn_ms := -100000

var _core: Node = null
var _specs = null
var _spec_gen := -1
var _scene: Node = null
var _player: Node = null
var _t_retry := 0.0
var _rng := RandomNumberGenerator.new()
var _local := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]  # prop centres in the quad's frame
var _r := 0.06                  # prop radius (m)
var _prop_nodes := [null, null, null, null]
# which way round each prop's rim (RIM steps, from the quad's +x towards +z)
# sticks out past the quad's collision shape: only there can a tip be hit
# (inside it, the frame - or a duct - takes the knock)
const RIM := 24
var _exposed := [[], [], [], []]
var exposed_share := [0.0, 0.0, 0.0, 0.0]  # for status and tests: the share of each rim out in the open
var _imb := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
var _knock := [0.0, 0.0, 0.0, 0.0]        # a knock building up over a few ticks (m/s)
var _knock_spin := [0.0, 0.0, 0.0, 0.0]
var _in := [false, false, false, false]   # each prop's disc in something last tick
# a clip in progress at each prop (-1: none; -2: told, still in): how long,
# how deep at most, how hard it went in, which way the chip is, the wear
# before it and what it has taken
var _clip_t := [-1.0, -1.0, -1.0, -1.0]
var _clip_into := [0.0, 0.0, 0.0, 0.0]
var _clip_hard := [1.0, 1.0, 1.0, 1.0]
var _clip_v := [0.0, 0.0, 0.0, 0.0]
var _clip_e := [0.0, 0.0, 0.0, 0.0]
var _clip_dir := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
var _clip_was := [0.0, 0.0, 0.0, 0.0]
var _clip_took := [0.0, 0.0, 0.0, 0.0]
var _cut := [0.0, 0.0, 0.0, 0.0]          # how far each prop has been cut back (of the radius)
var _q: PhysicsShapeQueryParameters3D = null
var _disc: CylinderShape3D = null
var _sh := [Vector2.ZERO, Vector2.ZERO]
var _note_t := 0.0
var _clock := 0.0
# respawns, seen as battery_sag sees them
var _r_key := false
var _sw_last = null
var _last_pos := Vector3.ZERO
var _have_pos := false
var _spawn_last := Vector3.ZERO
var _have_spawn := false
var _at_spawn := false


## Reads settings.cfg [prop_damage]. Returns a line for status.txt.
func setup(dir: String, core: Node) -> String:
	_core = core
	_rng.randomize()
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK and c.has_section("prop_damage"):
		for k in c.get_section_keys("prop_damage"):
			if not cfg.has(k):
				continue
			var v = c.get_value("prop_damage", k)
			if DEFAULTS[k] is bool:
				cfg[k] = v if v is bool else str(v).strip_edges().to_lower() in ["true", "yes", "on", "1"]
			elif DEFAULTS[k] is String:
				cfg[k] = str(v).strip_edges().to_lower()
			else:
				cfg[k] = clampf(float(v), 0.0, 10.0)
	cfg["durability"] = maxf(float(cfg["durability"]), 0.05)
	cfg["display_x"] = clampf(float(cfg["display_x"]), 0.0, 1.0)
	cfg["display_y"] = clampf(float(cfg["display_y"]), 0.0, 1.0)
	cfg["display_size"] = clampf(float(cfg["display_size"]), 0.3, 4.0)
	cfg["display_opacity"] = clampf(float(cfg["display_opacity"]), 0.0, 1.0)
	match str(cfg["display"]):
		"drone":                    # what "auto" was called before 1.0 came out
			cfg["display"] = "auto"
		"color":
			cfg["display"] = "colour"
		"auto", "colour", "off":
			pass
		_:
			cfg["display"] = "auto"
	if is_inside_tree():
		_apply_display()
	var sp := "res://drones/specs.gd"
	_specs = load(sp) if ResourceLoader.exists(sp) else null
	_update_factors()
	return "durability %s, breaking %s, tip strikes %s (kick %s), thrust loss %s, vibration %s; new props %s; %s; %s" % [
		str(cfg["durability"]), "on" if cfg["breaking"] else "off", "on" if cfg["tip_strikes"] else "off", str(cfg["kick"]),
		str(cfg["thrust_loss"]), str(cfg["vibration"]),
		"at every respawn" if cfg["fresh_props_on_respawn"] else "only on picking a drone", "damage shown on the OSD" if cfg["show_damage"] else "no OSD line",
		("the props shown as a quad on screen, %s (at %s, %s of the picture; size %s, opacity %s%s)" % [
			"in the OSD's look with fpv_osd, in colour without" if cfg["display"] == "auto" else "in colour",
			str(cfg["display_x"]), str(cfg["display_y"]), str(cfg["display_size"]),
			str(cfg["display_opacity"]), "; once one is damaged" if cfg["display_only_damaged"] else ""]) if cfg["display"] != "off" else "no quad on screen"]


## New props all round
func new_props() -> void:
	for i in 4:
		wear[i] = 0.0
		broken[i] = false
		_imb[i] = Vector2.ZERO
		_knock[i] = 0.0
		_in[i] = false
		_clip_t[i] = -1.0
		_cut[i] = 0.0
		var n = _prop_nodes[i]
		if n != null and is_instance_valid(n) and n is Node3D:
			(n as Node3D).visible = true
	hits = 0
	fresh += 1
	_update_factors()


## A prop's quarter of the quad (the order of NAMES) from where it is in the
## quad's frame: forward is -z
static func corner(local: Vector3) -> int:
	return (1 if local.x > 0.0 else 0) + (2 if local.z > 0.0 else 0)


## The thrust of the prop at this point of the quad, against a new one's
## (flight_controller asks, for each of its motors)
func factor_at(local: Vector3) -> float:
	return float(thrust_factor[corner(local)])


func _update_factors() -> void:
	for i in 4:
		if broken[i]:
			thrust_factor[i] = 0.0
			imbalance[i] = 0.0
		else:
			thrust_factor[i] = clampf(1.0 - WORN_THRUST * float(cfg.get("thrust_loss", 1.0)) * float(wear[i]), 0.1, 1.0)
			imbalance[i] = minf((_imb[i] as Vector2).length(), 1.0) * float(cfg.get("vibration", 1.0))


func _vehicle_id() -> String:
	var gs := get_node_or_null("/root/ZGamestate")
	var v = gs.get("selected_vehicle_id") if gs != null else null
	return str(v) if v != null else ""


# The drone flown: its props' size (the drones mod's figures, or the 5"'s)
# and where they are - the game's own spinning props on its body, else a
# quad X of its wheelbase
func _use_drone(p: Node3D, vid: String) -> void:
	drone_id = vid
	drone = {}
	if _specs != null:
		_spec_gen = _specs.generation()
		drone = _specs.figures(vid, _core)
	var prop_mm := float(drone.get("prop_mm", 127.0))
	_r = clampf(prop_mm, 10.0, 400.0) / 2000.0
	var s := clampf(float(drone.get("wheelbase_mm", 225.0)), 20.0, 1000.0) / 1000.0 / (2.0 * sqrt(2.0))
	_local = [Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(-s, 0, s), Vector3(s, 0, s)]
	_prop_nodes = [null, null, null, null]
	var veh := p.get_node_or_null("Vehicle")
	if veh != null:
		var inv := p.global_transform.affine_inverse()
		var found := 0
		for n in veh.find_children("SpinningProp*", "", true, false):
			if n is Node3D:
				var lp: Vector3 = inv * (n as Node3D).global_position
				var c := corner(lp)
				if _prop_nodes[c] == null:
					_prop_nodes[c] = n
					_local[c] = lp
					found += 1
		if found < 4:
			_prop_nodes = [null, null, null, null]
			_local = [Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(-s, 0, s), Vector3(s, 0, s)]
	_find_exposed(p)
	new_props()
	fresh -= 1
	if _disc == null:
		_disc = CylinderShape3D.new()
	_disc.radius = _r
	_disc.height = 0.2 * _r + 0.004
	if get_parent() != null and get_parent().has_method("drone_changed"):
		var out := 0.0
		for i in 4:
			out += float(exposed_share[i]) * 0.25
		get_parent().call("drone_changed", "flying %s: %d mm props%s, new; %s; %d%% of their tips stick out past its collision shape" % [str(drone.get("name", vid)), int(round(prop_mm)),
			" in ducts" if bool(drone.get("ducted", false)) else "",
			"its props found on its body" if _prop_nodes[0] != null else "props placed from its wheelbase", int(round(100.0 * out))])


# For each prop, the points round its rim that are not inside the quad's
# collision shapes (with 3 mm to spare)
func _find_exposed(p: Node3D) -> void:
	var shapes := []
	var inv := p.global_transform.affine_inverse()
	for c in p.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape != null and not (c as CollisionShape3D).disabled:
			shapes.append([inv * (c as CollisionShape3D).global_transform, (c as CollisionShape3D).shape])
	for i in 4:
		var row := []
		var n := 0
		var cen: Vector3 = _local[i]
		for k in RIM:
			var a := TAU * k / RIM
			var pt := cen + Vector3(cos(a), 0.0, sin(a)) * _r
			var inside := false
			for sh in shapes:
				if _in_shape(sh[0], sh[1], pt, 0.003):
					inside = true
					break
			row.append(not inside)
			if not inside:
				n += 1
		_exposed[i] = row
		exposed_share[i] = float(n) / RIM


static func _in_shape(t: Transform3D, shape: Shape3D, pt: Vector3, margin: float) -> bool:
	var q := t.affine_inverse() * pt
	if shape is CapsuleShape3D:
		var cs := shape as CapsuleShape3D
		var h := maxf(cs.height * 0.5 - cs.radius, 0.0)
		return Vector3(0.0, clampf(q.y, -h, h), 0.0).distance_to(q) <= cs.radius + margin
	if shape is SphereShape3D:
		return q.length() <= (shape as SphereShape3D).radius + margin
	if shape is BoxShape3D:
		var e := (shape as BoxShape3D).size * 0.5 + Vector3.ONE * margin
		return absf(q.x) <= e.x and absf(q.y) <= e.y and absf(q.z) <= e.z
	if shape is CylinderShape3D:
		var cy := shape as CylinderShape3D
		return Vector2(q.x, q.z).length() <= cy.radius + margin and absf(q.y) <= cy.height * 0.5 + margin
	return false


# Whether the rim of prop i is out in the open at local direction radial
func _open_at(i: int, radial: Vector2) -> bool:
	var row: Array = _exposed[i]
	if row.size() != RIM:
		return true
	var a := fposmod(atan2(radial.y, radial.x), TAU)
	return bool(row[int(round(a / TAU * RIM)) % RIM])


func _physics_process(dt: float) -> void:
	force = Vector3.ZERO
	vibration_level = 0.0
	if dt <= 0.0:
		return
	_clock += dt
	if _note_t > 0.0:
		_note_t -= dt
		if _note_t <= 0.0:
			_osd("")
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
	if not (p is RigidBody3D) or p.get("physics_handler") != null:
		return
	if not (p.get("_SETTINGS") is Dictionary):
		return
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return
	var body := p as RigidBody3D
	# the game has its quad report one contact (it only asks whether it
	# touches anything); a few, so a knock on a prop is not lost to the floor
	if body.max_contacts_reported < 4 or not body.contact_monitor:
		body.contact_monitor = true
		body.max_contacts_reported = maxi(body.max_contacts_reported, 4)
	var vid := _vehicle_id()
	if vid != drone_id or (_specs != null and _specs.generation() != _spec_gen):
		_use_drone(body, vid)
	var armed: bool = p.has_method("is_armed") and bool(p.call("is_armed"))
	_check_respawn(body, armed)
	var fc = p.get("zm_fc")
	# each prop's blade energy, against full throttle's: its speed squared,
	# which is its thrust against full thrust
	var spin := [0.0, 0.0, 0.0, 0.0]
	if armed and p.get("turtle_mode_active") != true and p.has_method("get_thrust_at_rpm"):
		var full := 0.0
		var stt = p.get("_SETTINGS")
		if stt is Dictionary and stt.has("adjustable_settings"):
			full = float(stt["adjustable_settings"].get("thrust", 0.0)) / 1000.0 * 9.8
		for i in 4:
			var rpm := float(p.get("current_motor_rpm"))
			if fc != null:
				rpm = float(fc.rpm[_fc_index(fc, i)])
			if full > 0.0:
				spin[i] = clampf(float(p.call("get_thrust_at_rpm", rpm)) / full, 0.0, 1.2)
	var xf := body.global_transform
	var inv := xf.affine_inverse()
	var ducted := bool(drone.get("ducted", false))
	var toughness := float(cfg["durability"]) / (DUCTED if ducted else 1.0)

	# knocks on the frame next to a prop
	var st := PhysicsServer3D.body_get_direct_state(body.get_rid())
	var dv := [0.0, 0.0, 0.0, 0.0]
	if st != null:
		var m := maxf(body.mass, 0.001)
		for k in st.get_contact_count():
			var lp: Vector3 = inv * st.get_contact_local_position(k)
			var nl: Vector3 = (xf.basis.inverse() * st.get_contact_local_normal(k)).normalized()
			var dvk := st.get_contact_impulse(k).length() / m
			for i in 4:
				var c: Vector3 = _local[i]
				var h := Vector2(lp.x - c.x, lp.z - c.z).length()
				if h > 1.3 * _r:
					continue
				# flat on the arms under the props: a landing, not the prop
				if lp.y < c.y - 0.15 * _r and absf(nl.y) > 0.7:
					continue
				if lp.y < c.y - 0.6 * _r - 0.01:
					continue
				dv[i] += dvk
	for i in 4:
		if dv[i] >= HIT_START or (_knock[i] > 0.0 and dv[i] >= 0.25 * HIT_START):
			_knock[i] += dv[i]
			_knock_spin[i] = maxf(_knock_spin[i], spin[i])
		elif _knock[i] > 0.0:
			# the knock is over: how much it took off the quad's speed
			var total: float = _knock[i]
			_knock[i] = 0.0
			if total > HIT_DV0 and not broken[i]:
				var sp: float = STILL + (1.0 - STILL) * _knock_spin[i]
				var was: float = wear[i]
				var d := _wear(i, minf(HIT_K * sp * (total - HIT_DV0) / toughness, MAX_CHIP), Vector2.from_angle(_rng.randf() * TAU))
				_hit(i, "knocked at %.1f m/s, at %d%% thrust" % [total, int(round(100.0 * _knock_spin[i]))],
					sp * (total - HIT_DV0) / HIT_SEV / toughness, was, d)
			_knock_spin[i] = 0.0

	# the tips, past the frame
	if bool(cfg["tip_strikes"]) and armed:
		var space := body.get_world_3d().direct_space_state if body.get_world_3d() != null else null
		if space != null:
			if _q == null:
				_q = PhysicsShapeQueryParameters3D.new()
			_q.shape = _disc
			_q.collision_mask = body.collision_mask
			_q.exclude = [body.get_rid()]
			for i in 4:
				var hit := {}
				if not broken[i] and spin[i] >= 0.005:
					_q.transform = Transform3D(xf.basis.orthonormalized(), xf * (_local[i] as Vector3))
					hit = space.get_rest_info(_q)
				if hit.is_empty():
					_in[i] = false
					if _clip_t[i] >= 0.0 or _clip_t[i] == -2.0:
						_clip_done(i)
					continue
				var c: Vector3 = _local[i]
				var pt: Vector3 = hit["point"]
				var lp: Vector3 = inv * pt
				var radial := Vector2(lp.x - c.x, lp.z - c.z)
				if not _open_at(i, radial):
					# where the frame (or a duct) is round the prop: it takes it
					_in[i] = false
					if _clip_t[i] >= 0.0 or _clip_t[i] == -2.0:
						_clip_done(i)
					continue
				var into := clampf(1.0 - radial.length() / _r, 0.03, 1.0)
				var e: float = spin[i]
				var cut := 0.3 + 0.7 * minf(e, 1.0)
				if not _in[i] and _clip_t[i] == -1.0:
					# a new clip: the quad's own speed into the thing adds to the blades'
					var com := body.global_position + (st.center_of_mass if st != null else Vector3.ZERO)
					var vp := body.linear_velocity + body.angular_velocity.cross(pt - com)
					var nrm: Vector3 = hit["normal"]
					var vc: Vector3 = hit["linear_velocity"]
					var v_in := maxf(0.0, -(vp - vc).dot(nrm.normalized())) if nrm.length() > 0.1 else 0.0
					_clip_t[i] = 0.0
					_clip_into[i] = 0.0
					_clip_v[i] = v_in
					_clip_hard[i] = minf(1.0 + v_in / TIP_SPEED, 3.0)
					_clip_e[i] = e
					_clip_dir[i] = Vector2.from_angle(_rng.randf() * TAU)
					_clip_was[i] = wear[i]
					_clip_took[i] = 0.0
				_in[i] = true
				if into > float(_clip_into[i]):
					_clip_into[i] = into
				# as far as the blades reach past where they were cut back
				# before, they are cut back again, and the thing pushes them
				# back against their spin
				var deeper := into - float(_cut[i])
				if deeper > 0.0:
					_cut[i] = into
					var d := TIP_K * deeper * cut * float(_clip_hard[i]) / toughness
					_clip_took[i] = float(_clip_took[i]) + _wear(i, minf(d, MAX_CHIP), _clip_dir[i])
					_kick(body, st, i, pt, radial, deeper, cut)
				# and the props, hard at that speed, push the quad off it: it
				# bounces off a wall its props reach, as a real quad does
				_bounce(body, st, pt, hit, into)
				if _clip_t[i] >= 0.0:
					_clip_t[i] = float(_clip_t[i]) + dt
					if _clip_t[i] >= CLIP_S:
						_clip_done(i)
						_clip_t[i] = -2.0     # told: the rest of this one is not told again
	else:
		_in = [false, false, false, false]

	# what the damage does
	_update_factors()
	var lvl := 0.0
	for i in 4:
		lvl += float(imbalance[i]) * spin[i]
	vibration_level = lvl
	if fc == null and armed and p.get("turtle_mode_active") != true and p.has_method("get_thrust_at_rpm"):
		# the game's thrust is at the centre, a quarter each prop's
		var quarter := maxf(float(p.call("get_thrust_at_rpm", float(p.get("current_motor_rpm")))), 0.0) * 0.25
		var up := xf.basis.y.normalized()
		for i in 4:
			var lost: float = quarter * (1.0 - float(thrust_factor[i]))
			if lost > 0.0:
				var f := -up * lost
				body.apply_force(f, xf.basis * (_local[i] as Vector3))
				force += f
	_shake(body, dt, lvl if armed else 0.0)


# flight_controller's motor for the prop at corner i
func _fc_index(fc, i: int) -> int:
	var pos = fc.prm.get("pos") if fc.prm is Dictionary else null
	if pos is Array and pos.size() == 4:
		for j in 4:
			if corner(pos[j]) == i:
				return j
	return i


# Wear d on prop i, the chip on the side dir: chips are never even, so each
# puts the prop further out of balance (or, now and then, back towards it).
# Returns the wear taken.
func _wear(i: int, d: float, dir: Vector2) -> float:
	if d <= 0.0 or broken[i]:
		return 0.0
	var was: float = wear[i]
	wear[i] = minf(was + d, 1.0)
	_imb[i] = (_imb[i] as Vector2) + dir * (float(wear[i]) - was) * IMBALANCE
	_update_factors()
	return float(wear[i]) - was


# A clip at prop i over (or told CLIP_S after it began): how hard it was, as
# deep as it went
func _clip_done(i: int) -> void:
	if _clip_t[i] == -2.0:
		_clip_t[i] = -1.0
		return
	_clip_t[i] = -1.0
	var into: float = _clip_into[i]
	var tough := float(cfg["durability"]) / (DUCTED if bool(drone.get("ducted", false)) else 1.0)
	_hit(i, "tip clipped %d%% of the way in at %.1f m/s, at %d%% thrust" % [int(round(100.0 * into)), _clip_v[i], int(round(100.0 * float(_clip_e[i])))],
		float(_clip_e[i]) * float(_clip_hard[i]) * (into / 0.5) / maxf(tough, 0.01), _clip_was[i], _clip_took[i])


# A hit on prop i that wore it d, as hard as sev (1: a clip half in at full
# speed), the prop worn was before it: one hard enough can break the prop
# off, and any real hit on one worn right through does. Told on the OSD and
# in status.txt.
func _hit(i: int, what: String, sev: float, was: float, d: float) -> void:
	if broken[i]:
		return
	var breaks := false
	if bool(cfg["breaking"]):
		if was >= 1.0 and d + sev > 0.05:
			breaks = true
		elif sev >= BREAK_AT:
			breaks = _rng.randf() < smoothstep(BREAK_AT, BREAK_SURE, sev)
	if breaks:
		broken[i] = true
		_in[i] = false
		var n = _prop_nodes[i]
		if n != null and is_instance_valid(n) and n is Node3D:
			(n as Node3D).visible = false
		_update_factors()
	elif d < 0.005:
		return               # a touch that took nothing off: not worth telling
	hits += 1
	hit_serial += 1
	last_hit = {"prop": i, "short": SHORT[i], "wear": wear[i], "broken": breaks}
	var line := "%s prop %s: %s" % [NAMES[i], what, "BROKEN off" if breaks else "%d%% worn (thrust -%d%%)" % [
		int(round(100.0 * wear[i])), int(round(100.0 * (1.0 - float(thrust_factor[i]))))]]
	events.append({"prop": i, "wear": wear[i], "d": d, "sev": sev, "broken": breaks, "what": what, "t": _clock})
	if events.size() > 40:
		events.pop_front()
	if bool(cfg["show_damage"]) and Time.get_ticks_msec() - osd_taken_ms > 1000:
		_osd(("%s PROP BROKEN" % NAMES[i].to_upper()) if breaks else ("%s PROP %d%%" % [NAMES[i].to_upper(), int(round(100.0 * wear[i]))]))
		_note_t = NOTE_S
	if get_parent() != null and get_parent().has_method("prop_hit"):
		get_parent().call("prop_hit", line)


# A clip at the tip of prop i at pt, its blades going deeper by into (of the
# radius): the thing hit pushes them back against their spin there - a
# shove, and a turn about the quad's centre, KICK_DPS for a clip half in at
# full speed (cut 1); a shove of at most KICK_MAX_DV
func _kick(body: RigidBody3D, st: PhysicsDirectBodyState3D, i: int, pt: Vector3, radial: Vector2, into: float, spin: float) -> void:
	var k := float(cfg["kick"])
	if k <= 0.0 or radial.length() < 1e-4 or st == null:
		return
	var up := body.global_transform.basis.y.normalized()
	var e := body.global_transform.basis * Vector3(radial.x, 0.0, radial.y).normalized()
	# the blade moves along up x e for a prop turning anticlockwise from above
	var dir := -up.cross(e) * float(SPIN[i])
	var com := body.global_position + st.center_of_mass
	var turn := absf((pt - com).cross(dir).dot(up))
	var inv_i := maxf(st.inverse_inertia.y, 1e-6)
	var want := deg_to_rad(KICK_DPS) * k * spin * (into / 0.5)
	var j := want / maxf(turn * inv_i, 1e-6)
	j = minf(j, body.mass * KICK_MAX_DV * k)
	body.apply_impulse(dir * j, pt - body.global_position)


# The props are stiff at speed: one reaching into something pushes the quad
# off it, as a collision at pt would (the quad's collision shape stops short
# of the props): what it was moving in at goes, a little bounces back, and
# whatever of the prop is in, it is pushed out of over PUSH_S
func _bounce(body: RigidBody3D, st: PhysicsDirectBodyState3D, pt: Vector3, hit: Dictionary, into: float) -> void:
	if st == null:
		return
	var n: Vector3 = hit["normal"]
	if n.length() < 0.1:
		return
	n = n.normalized()
	var com := body.global_position + st.center_of_mass
	var r := pt - com
	var vp := body.linear_velocity + body.angular_velocity.cross(r)
	var vc: Vector3 = hit["linear_velocity"]
	var vn := (vp - vc).dot(n)                 # > 0: moving off it
	var want := into * _r / PUSH_S + BOUNCE * maxf(-vn, 0.0)
	if vn >= want:
		return
	# the quad's mass against a push at pt along n, turning it as well
	var rn := body.global_transform.basis.inverse() * r.cross(n)
	var ii := st.inverse_inertia
	var k := 1.0 / maxf(body.mass, 1e-4) + rn.x * rn.x * ii.x + rn.y * rn.y * ii.y + rn.z * rn.z * ii.z
	body.apply_impulse(n * (want - vn) / k, pt - body.global_position)


# The shake of props out of balance: a resonator at SHAKE_HZ driven by
# noise, sized by the imbalance and the props' speed
func _shake(body: RigidBody3D, dt: float, lvl: float) -> void:
	var amp := deg_to_rad(SHAKE_DEG) * sqrt(maxf(lvl, 0.0))
	if amp <= 0.0 and shake_offset == Vector2.ZERO:
		_sh = [Vector2.ZERO, Vector2.ZERO]
		return
	var w0 := TAU * SHAKE_HZ
	var steps := 4
	var h := dt / steps
	var drive := sqrt(4.0 * SHAKE_ZETA * w0 * w0 * w0)
	for s in steps:
		var n := Vector2(_rng.randfn(), _rng.randfn()) * drive / sqrt(h)
		_sh[1] += (n - 2.0 * SHAKE_ZETA * w0 * _sh[1] - w0 * w0 * _sh[0]) * h
		_sh[0] += _sh[1] * h
	var target: Vector2 = _sh[0] * amp
	if amp <= 0.0:
		target = Vector2.ZERO
		_sh = [Vector2.ZERO, Vector2.ZERO]
	var d := target - shake_offset
	if d.length_squared() < 1e-14:
		return
	var b := body.global_transform.basis
	var rot := Basis(b.z.normalized(), d.x) * Basis(b.x.normalized(), d.y)
	body.global_transform = Transform3D(rot * b, body.global_position)
	shake_offset = target


func _osd(s: String) -> void:
	note = s
	var gs := get_node_or_null("/root/ZGamestate")
	var o = gs.get("OSD_VALUES") if gs != null else null
	if o is Dictionary:
		if s == "":
			o.erase("prop_damage")
		else:
			o["prop_damage"] = s


# A respawn: the game's R key; the radio's respawn switch; the quad arriving
# exactly on the respawn point, or moving more than 4 m in one tick (as
# battery_sag sees them). The spawn point moving onto the quad - S, X - is
# not one.
func _check_respawn(p: Node3D, armed: bool) -> void:
	var pos := p.global_position
	var at_spawn := false
	var moved := false
	var gs := get_node_or_null("/root/ZGamestate")
	var rt = gs.get("respawn_transform") if gs != null else null
	if rt is Transform3D:
		at_spawn = pos.distance_to(rt.origin) < 0.05
		moved = _have_spawn and rt.origin.distance_to(_spawn_last) > 0.001
		_spawn_last = rt.origin
		_have_spawn = true
	var cs := get_tree().current_scene
	var sw = cs.get("_respawn_switch_cycled") if cs != null else null
	var radio: bool = sw is bool and _sw_last is bool and _sw_last and not sw
	_sw_last = sw
	var jumped := _have_pos and pos.distance_to(_last_pos) > 4.0
	var arrived := _have_pos and at_spawn and not _at_spawn and not moved
	var respawned := _r_key or radio or jumped or arrived
	_r_key = false
	if respawned and bool(cfg["fresh_props_on_respawn"]) and (hits > 0 or wear.any(func(w): return w > 0.0)):
		new_props()
		if get_parent() != null and get_parent().has_method("prop_hit"):
			get_parent().call("prop_hit", "respawn: new props")
	_at_spawn = at_spawn
	_last_pos = pos
	_have_pos = true


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_R and not _typing():
		_r_key = true


func _typing() -> bool:
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return true
	var cs := get_tree().current_scene
	var chat := cs.get_node_or_null("%ChatInput") if cs != null else null
	return chat != null and chat.has_method("is_editing") and bool(chat.call("is_editing"))


var display: Control = null
var _layer: CanvasLayer = null


func _ready() -> void:
	_apply_display()


# display="auto" or "colour": the quad on screen (display.gd), over the game
# - with "auto", only while no OSD draws it (osd_display())
func _apply_display() -> void:
	var on := str(cfg.get("display", "auto")) != "off"
	if not on:
		if _layer != null and is_instance_valid(_layer):
			_layer.queue_free()
		_layer = null
		display = null
		return
	if display == null or not is_instance_valid(display):
		var sc = load("res://prop_damage/display.gd")
		if not (sc is Script):
			return
		_layer = CanvasLayer.new()
		_layer.name = "PropsDisplay"
		_layer.layer = 90
		add_child(_layer)
		display = sc.new()
		display.name = "Quad"
		_layer.add_child(display)
	display.set("props", self)
	display.set("at", Vector2(float(cfg["display_x"]), float(cfg["display_y"])))
	display.set("scale_k", float(cfg["display_size"]))
	display.set("opacity", float(cfg["display_opacity"]))
	display.set("only_damaged", bool(cfg["display_only_damaged"]))
	display.set("step_aside", str(cfg["display"]) == "auto")


## For an OSD drawn into the video picture (fpv_osd): with display="auto",
## what it needs to draw the quad in its own look - where, how big and how
## solid (fractions of the picture, as display_x/y/size/opacity), whether
## only once a prop is damaged, whether flying, and the props where they sit
## on the quad seen from above (x right, y back, in metres) with their radius
## and whether they are in ducts. Wear and broken are read as they are. {}
## with any other display: then it draws nothing. An OSD drawing it sets
## osd_drawn_ms, and the quad over the game steps aside.
func osd_display() -> Dictionary:
	if str(cfg.get("display", "auto")) != "auto":
		return {}
	var spots := []
	for v in _local:
		spots.append(Vector2((v as Vector3).x, (v as Vector3).z))
	return {"x": float(cfg["display_x"]), "y": float(cfg["display_y"]), "size": float(cfg["display_size"]),
		"opacity": float(cfg["display_opacity"]), "only_damaged": bool(cfg["display_only_damaged"]),
		"flying": drone_id != "-" and _player != null and is_instance_valid(_player),
		"props": spots, "r": _r, "ducted": bool(drone.get("ducted", false))}


## Each prop's state, for tests and status.txt
func report() -> Dictionary:
	return {"wear": wear.duplicate(), "broken": broken.duplicate(), "thrust": thrust_factor.duplicate(),
		"imbalance": imbalance.duplicate(), "vibration": vibration_level, "hits": hits, "fresh": fresh, "exposed": exposed_share.duplicate(),
		"note": note, "events": events.duplicate(true), "local": _local.map(func(v): return [v.x, v.y, v.z]), "radius": _r}


func _exit_tree() -> void:
	_osd("")
