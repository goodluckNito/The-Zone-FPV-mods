extends Node
## pilot_audio: hear the quad from where the pilot stands.
##
## The game plays its motor sound as if you were on board: as loud 300 m away
## as on the pad. This puts the listener at the pilot - the spawn point, at
## head height, facing the way the spawn faces (the same spot the game's
## analog video link is measured from) - and works out what reaches them:
##   loudness     spreads out with distance, 6 dB quieter each time it doubles
##   air          the air soaks up the highs (ISO 9613-1 at 20 C, 70%
##                humidity): a low-pass that falls with distance
##   walls        rays from the pilot to the quad; anything in the way makes
##                it quieter and duller
##   delay        sound takes a moment to arrive (343 m/s): you hear where the
##                quad was, and the pitch shifts as it comes and goes (doppler)
##   stereo       left and right by where the quad is against the way the
##                pilot faces, and a little duller when it is behind
## Each sound gets an audio bus of its own with a low-pass and a panner; the
## game's own motor sound (Player/QuadAudio) is routed through one. The game
## keeps setting its pitch and loudness from the motors; this runs after it
## each physics tick and swaps in what the pilot hears. The sums run 100 times
## a second.
##
## listen_from="drone" moves the listener onto your own quad instead - its
## FPV camera, turning as it turns: your quad sounds as the game plays it,
## and other players' quads are heard from where you fly (doppler now counts
## your own speed too).
##
## In prop wash (dirty_air's wash_level, the same roughness its shake and
## flight_controller's gyro noise follow), the motor sound warbles - the
## motors hunting as the flight controller fights the dirty air: the pitch
## and loudness jitter around 6 and 30 Hz, sized by propwash_sound.
## Other players' quads warble the same way when they fall through their own
## wake (propwash_others): worked out from what the game receives for them -
## their attitude, their throttle and how they move - as dirty_air works out
## your own (the vortex ring state: falling at about half to 1.7 times their
## props' wake speed, worst at 1.1, unless they move across it).
## With prop_damage, a damaged prop - out of balance - makes the motor sound
## rough: a fast flutter of pitch and loudness, more the worse the prop and
## the faster it spins (prop_damage's vibration_level).
##
## Other players' quads (multiplayer) make no sound in the game. With
## multiplayer on, each gets the same motor sound, driven by the throttle the
## game receives for it the way the game drives your own, heard the same way.
## With more of them than multiplayer_max, the nearest are heard; one being
## heard is only swapped for one at least 20% nearer, and every sound fades
## in and out over a quarter of a second rather than starting or stopping
## dead. Their loudness goes on their players (which Godot ramps across each
## mix) and their buses are kept for reuse, so the audio layout does not
## change while they come and go.

const SOUND_SPEED := 343.0
const HISTORY_S := 5.0
const UPDATE_HZ := 100.0
const RAY_HZ := 30.0
const SMOOTH_S := 0.03
const BUS_LOCAL := "PilotAudio"
const BUS_REMOTE := "PilotAudioMP"
const FADE_S := 0.25                 # other players' sounds fade in and out
const KEEP := 0.8                    # a quad heard is counted this much nearer
const MAX_LISTENER_SPEED := 150.0    # faster than this between sums: a jump (respawn), not flight
# prop wash: at dirty_air's wash_level 1 (the heart of its wake) the motor
# sound's pitch wanders by this fraction (rms) and its loudness by this many dB
const WASH_PITCH := 0.045
const WASH_DB := 1.8
# a damaged prop, at prop_damage's vibration_level 1: flutter of the pitch
# (rms) and loudness (dB)
const ROUGH_PITCH := 0.012
const ROUGH_DB := 1.5
# other players' quads in their own wake: dirty_air's vortex ring state
const RHO := 1.225
const VRS_CENTRE := 1.1
const VRS_WIDTH := 0.45
# the game's drones, for other players' (they send which one): weight (g),
# thrust (g), prop diameter (mm) - default_vehicles.gd and drones/settings.cfg
const REMOTE_DRONES := {
	"65mm_freestyle": [28.0, 160.0, 31.0], "85mm_freestyle": [69.0, 400.0, 40.0],
	"2.5in_freestyle": [83.0, 550.0, 64.0], "3.5in_freestyle": [290.0, 1800.0, 89.0],
	"5in_freestyle": [680.0, 5500.0, 127.0], "beginner_5_in_quad": [680.0, 3000.0, 127.0],
	"5in_racer": [480.0, 6000.0, 127.0],
}
# the game's thrust per motor speed (player_rigid_body.gd's RPM_THRUST_CURVE),
# at 0, 10 .. 90% of top speed
const THRUST_CURVE := [0.1, 0.4, 0.5, 0.6, 0.7, 0.79, 0.84, 0.9, 0.95, 1.0]

# the game's motor model (player_rigid_body.gd), for other players' quads
const MOTOR_KV := 1400.0
const BAT_MAX_VOLTAGE := 22.2
const MAX_MOTOR_RPM := MOTOR_KV * BAT_MAX_VOLTAGE
const RPM_RATE := 170000.0          # rpm a second, up and down
const IDLE_RPM := 1200.0

# The frequency the air takes 3 dB off over a distance (ISO 9613-1, 20 C, 70%)
const AIR_D := [0.0, 10.0, 20.0, 40.0, 70.0, 100.0, 150.0, 200.0, 300.0, 500.0, 800.0, 1200.0, 2000.0]
const AIR_HZ := [20000.0, 16582.0, 11398.0, 7852.0, 5764.0, 4690.0, 3652.0, 3006.0, 2190.0, 1280.0, 690.0, 451.0, 303.0]
const WALL_CUTOFF := 1500.0          # what gets round a building

const DEFAULTS := {
	"pilot_height": 1.7,
	"facing_offset": 0.0,
	"full_volume_distance": 3.0,
	"falloff": 1.0,
	"quietest_db": -60.0,
	"air": true,
	"walls": true,
	"wall_db": 10.0,
	"delay_and_doppler": true,
	"stereo": true,
	"stereo_width": 0.8,
	"multiplayer": true,
	"multiplayer_max": 8,
	"mute_in_background": true,
	"listen_from": "spawn",
	"propwash_sound": 1.0,
	"propwash_others": true,
}


## One sound the pilot hears: the local quad or another player's.
class Src:
	var node: Node3D                 # the quad
	var player: AudioStreamPlayer
	var bus := ""
	var bus_i := -1
	var lp: AudioEffectLowPassFilter
	var pan: AudioEffectPanner
	var remote := false
	var ht := PackedFloat64Array()   # history: time, position, pitch, volume
	var hp := PackedVector3Array()
	var hpitch := PackedFloat32Array()
	var hvol := PackedFloat32Array()
	var gain := -60.0                # smoothed, dB
	var cutoff := 20000.0
	var panv := 0.0
	var set_gain := 1000.0           # what the bus has, to skip unchanged ones
	var set_cutoff := -1.0
	var set_pan := 1000.0
	var occl := 0.0                  # 0 clear .. 1 behind a wall
	var occl_target := 0.0
	var rpm := IDLE_RPM              # remote: motor speed
	var quiet_s := 0.0               # remote: time sat still at zero throttle
	var last_pos := Vector3.ZERO
	var have_pos := false
	var te := -1.0                   # when the sound heard last time left the quad
	var t_last := 0.0                # when that was worked out
	# the last results, for report()
	var distance := 0.0
	var pitch := 1.0
	var game_pitch := 1.0
	var doppler := 1.0
	var delay := 0.0
	var azimuth := 0.0
	var env := 0.0                   # remote: fading in and out, 0-1
	var leaving := false             # remote: no longer wanted, fading out
	var out_db := -80.0              # remote: what its player was last set to
	var vel := Vector3.ZERO          # remote: how it moves, from where it is seen
	var wl := 0.0                    # remote: how deep in its own wake, smoothed
	var jn := [0.0, 0.0, 0.0]        # remote: its prop-wash noise
	var wash := 0.0                  # remote: its pitch factor - 1 this time


var cfg := {}
var sources: Array = []              # Src; [0] is the local quad when there is one
var cost_us := 0.0                   # average time a physics tick takes here
var cuts := 0                        # for tests: sounds stopped while still audible
var buses_made := 0                  # for tests: audio buses created
var swaps := 0                       # for tests: other players' sounds started or dropped

# settings, read once
var _height := 1.7
var _facing_off := 0.0
var _ref := 3.0
var _falloff := 1.0
var _floor := -60.0
var _air := true
var _walls := true
var _wall_db := 10.0
var _delay := true
var _stereo := true
var _width := 0.8
var _mp := true
var _mp_max := 8
var _mute_bg := true
var _onboard := false                # listen_from="drone"
var _wash_amt := 1.0                 # propwash_sound
var _wash_others := true             # propwash_others

var _scene: Node = null
var _local: Src = null
var _qa: AudioStreamPlayer = null
var _qa_bus_orig := "Master"
var _written_pitch := -1.0
var _written_vol := -1000.0
var _game_pitch := 1.0
var _game_vol := 0.0
var _out_pitch := -1.0
var _out_vol := 0.0
var _t := 0.0
var _upd_t := 1.0
var _ray_t := 0.0
var _forward := Vector3(0, 0, -1)
var _right := Vector3(1, 0, 0)
var _listener_prev := Vector3.ZERO
var _listener_vel := Vector3.ZERO
var _have_prev := false
var _cam: Node3D = null              # the quad's FPV camera, listen_from="drone"
# prop wash
var _da: Node = null                 # dirty_air's Air node
var _da_look := 0
var _wl := 0.0                       # its wash_level, smoothed
var _jn := [0.0, 0.0, 0.0, 0.0, 0.0] # noise: pitch fast, pitch slow, loudness; a damaged prop's pitch, loudness
var _pd: Node = null                 # prop_damage's Props node
var _pd_look := 0
var _rough := 0.0                    # its vibration_level, smoothed
var _rng := RandomNumberGenerator.new()
var _src_pitch := 1.0                # the game's pitch and loudness, with the wash in
var _src_vol := 0.0
var wash_jitter := 0.0               # for tests and report(): the pitch factor - 1 this tick
var _stream: AudioStream = null
var _next_bus := 0
var _pool: Array = []                # remote buses not in use, kept for reuse
var _off := false
var _zs: Node = null
var _gs: Node = null
# _at()'s answer
var _a_pos := Vector3.ZERO
var _a_pitch := 1.0
var _a_vol := 0.0


## Reads settings.cfg [audio]. Returns lines for status.txt.
func setup(dir: String) -> String:
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK and c.has_section("audio"):
		for k in c.get_section_keys("audio"):
			if cfg.has(k):
				cfg[k] = c.get_value("audio", k)
	_height = float(cfg["pilot_height"])
	_facing_off = float(cfg["facing_offset"])
	_ref = maxf(float(cfg["full_volume_distance"]), 0.1)
	_falloff = float(cfg["falloff"])
	_floor = float(cfg["quietest_db"])
	_air = bool(cfg["air"])
	_walls = bool(cfg["walls"])
	_wall_db = float(cfg["wall_db"])
	_delay = bool(cfg["delay_and_doppler"])
	_stereo = bool(cfg["stereo"])
	_width = float(cfg["stereo_width"])
	_mp = bool(cfg["multiplayer"])
	_mp_max = int(cfg["multiplayer_max"])
	_mute_bg = bool(cfg["mute_in_background"])
	_onboard = str(cfg["listen_from"]).strip_edges().to_lower() == "drone"
	_wash_amt = maxf(float(cfg["propwash_sound"]), 0.0)
	_wash_others = bool(cfg["propwash_others"])
	_have_prev = false
	_listener_vel = Vector3.ZERO
	_cam = null
	# after the game's player has set the motor sound each physics tick
	process_physics_priority = 1000
	var parts := []
	if _onboard:
		parts.append("listening from the drone: its FPV camera (your quad as the game plays it; the spawn when there is no quad)")
	else:
		parts.append("pilot at the spawn point, %.1f m up, facing the spawn's way%s" % [_height,
			(" turned %+d degrees" % int(_facing_off)) if _facing_off != 0.0 else ""])
	parts.append("full volume within %.1f m, then %.1f dB quieter each time the distance doubles" % [_ref, 6.02 * _falloff])
	var fx := []
	if _air:
		fx.append("air")
	if _walls:
		fx.append("walls (%.0f dB)" % _wall_db)
	if _delay:
		fx.append("delay and doppler")
	if _stereo:
		fx.append("stereo (width %.2f)" % _width)
	parts.append("effects: " + (", ".join(fx) if not fx.is_empty() else "none"))
	parts.append(("multiplayer: other players' quads heard, up to %d" % _mp_max) if _mp else "multiplayer: off")
	parts.append(("prop wash: the motor sound warbles in dirty air (x%.2f; needs dirty_air)%s" % [_wash_amt,
		", other players' quads' too" if _wash_others and _mp else ""]) if _wash_amt > 0.0 else "prop wash: off")
	return "\n".join(parts)


func _physics_process(dt: float) -> void:
	if _off or dt <= 0.0:
		return
	var t0 := Time.get_ticks_usec()
	_t += dt
	_capture_local()
	_upd_t += dt
	if _upd_t >= 1.0 / UPDATE_HZ:
		var step := _upd_t
		_upd_t = 0.0
		var cs := get_tree().current_scene
		if cs != _scene:
			_scene = cs
			_drop_all()
		_attach_local()
		if _mp:
			_sync_remotes()
		else:
			_quiet_remotes()
		if not sources.is_empty():
			var pilot := _pilot()
			_track_listener(pilot, step)
			var do_rays := false
			_ray_t += step
			if _ray_t >= 1.0 / RAY_HZ:
				_ray_t = 0.0
				do_rays = _walls
			var focus := not _mute_bg or get_window().has_focus()
			for s in sources:
				_step(s, step, pilot, do_rays, focus)
			for s in sources.duplicate():
				if s.remote and s.leaving and s.env <= 0.0:
					sources.erase(s)
					_free_src(s)
	_write_local()
	cost_us += (float(Time.get_ticks_usec() - t0) - cost_us) * 0.01


# The game sets its motor sound's pitch and loudness every physics tick; this
# runs after it, keeps what it set, and puts back what the pilot hears.
func _capture_local() -> void:
	if _qa == null or not is_instance_valid(_qa):
		return
	# if the game did not set them this tick (paused), they are still ours
	var p := _qa.pitch_scale
	var v := _qa.volume_db
	if p != _written_pitch or v != _written_vol:
		_game_pitch = p
		_game_vol = v
	_wash(get_physics_process_delta_time())
	# every tick, so the pitch the pilot hears changes as smoothly as the game's
	if _delay and not _onboard and _local != null and is_instance_valid(_local.node):
		_record(_local, _local.node.global_position, _src_pitch, _src_vol)


func _write_local() -> void:
	if _local == null or _qa == null or not is_instance_valid(_qa):
		return
	if _delay and not _onboard:
		if _local.te < 0.0:
			return
		# the game's pitch and loudness from when the sound left, with the
		# doppler worked out at the last sums
		_at(_local, _t - _local.delay)
		_out_pitch = maxf(_a_pitch * _local.doppler, 0.01)
		_out_vol = _a_vol
	elif (_wash_amt > 0.0 or _rough > 0.0) and (wash_jitter != 0.0 or _written_pitch >= 0.0):
		# heard as it is made: only the prop wash to put in
		_out_pitch = maxf(_src_pitch, 0.01)
		_out_vol = _src_vol
	else:
		return
	_qa.pitch_scale = _out_pitch
	_qa.volume_db = _out_vol
	_written_pitch = _qa.pitch_scale
	_written_vol = _qa.volume_db


# ---- the pilot ----

func _pilot() -> Vector3:
	if _onboard and _local != null and is_instance_valid(_local.node):
		var cam := _fpv_cam()
		var ct: Transform3D = cam.global_transform if cam != null else _local.node.global_transform
		var f := -ct.basis.z
		var r := ct.basis.x
		if f.length() > 0.01 and r.length() > 0.01:
			_forward = f.normalized()
			_right = r.normalized()
		return ct.origin
	if _gs == null or not is_instance_valid(_gs):
		_gs = get_node_or_null("/root/ZGamestate")
	var rt = _gs.get("respawn_transform") if _gs != null else null
	var t: Transform3D = rt if rt is Transform3D else Transform3D()
	var f := -t.basis.z
	f.y = 0.0
	if f.length() > 0.2:
		_forward = f.normalized().rotated(Vector3.UP, -deg_to_rad(_facing_off))
	_right = _forward.cross(Vector3.UP).normalized()
	return t.origin + Vector3(0, _height, 0)


# The quad's FPV camera (Player/Vehicle/CameraHolder/Camera3D in the game),
# else the camera its view shows.
func _fpv_cam() -> Node3D:
	if _cam != null and is_instance_valid(_cam) and _local != null and _local.node.is_ancestor_of(_cam):
		return _cam
	_cam = null
	var n := _local.node
	var c := n.get_node_or_null("Vehicle/CameraHolder/Camera3D") as Node3D
	if c == null:
		c = n.find_child("Camera3D", true, false) as Node3D
	if c == null and n.get_viewport() != null:
		c = n.get_viewport().get_camera_3d()
		if c != null:
			return c                 # not the quad's own: looked for again next time
	_cam = c
	return c


# How fast the listener moves, for the doppler of a quad heard from another.
func _track_listener(pos: Vector3, dt: float) -> void:
	if _have_prev and dt > 0.0:
		var v := (pos - _listener_prev) / dt
		if v.length() < MAX_LISTENER_SPEED:
			_listener_vel += (v - _listener_vel) * (1.0 - exp(-dt / 0.05))
		else:
			_listener_vel = Vector3.ZERO
	_listener_prev = pos
	_have_prev = true


# Prop wash: dirty_air's wash_level (0 in clean air, 1 in the heart of the
# quad's own wake) makes the motors hunt. Noise at about 30 Hz (the band
# Betaflight's tuning notes give for prop wash) and 6 Hz goes on the pitch,
# and some on the loudness, into _src_pitch and _src_vol.
func _wash(dt: float) -> void:
	_src_pitch = _game_pitch
	_src_vol = _game_vol
	wash_jitter = 0.0
	if dt <= 0.0:
		return
	var armed := true
	if _local != null and is_instance_valid(_local.node) and _local.node.has_method("is_armed"):
		armed = bool(_local.node.call("is_armed"))
	var wl := 0.0
	if _wash_amt > 0.0 and armed:
		var da := _dirty_air()
		if da != null:
			wl = clampf(float(da.get("wash_level")), 0.0, 1.5)
	_wl += (wl - _wl) * (1.0 - exp(-dt / 0.08))
	if _wl < 0.002:
		_wl = 0.0
	# a damaged prop
	var rough := 0.0
	if armed:
		var pd := _prop_damage()
		if pd != null:
			rough = clampf(float(pd.get("vibration_level")), 0.0, 4.0)
	_rough += (rough - _rough) * (1.0 - exp(-dt / 0.05))
	if _rough < 0.002:
		_rough = 0.0
	if _wl <= 0.0 and _rough <= 0.0:
		return
	for i in 5:
		var fc: float = [30.0, 6.0, 20.0, 45.0, 40.0][i]
		var a := 1.0 - exp(-TAU * fc * dt)
		_jn[i] += (_rng.randfn() * sqrt((2.0 - a) / a) - _jn[i]) * a
	var k := _wash_amt * _wl
	var r := sqrt(_rough)
	wash_jitter = clampf(WASH_PITCH * k * (0.75 * _jn[0] + 0.66 * _jn[1]) + ROUGH_PITCH * r * _jn[3], -0.3, 0.3)
	_src_pitch = _game_pitch * (1.0 + wash_jitter)
	_src_vol = _game_vol + WASH_DB * k * clampf(_jn[2], -3.0, 3.0) + ROUGH_DB * r * clampf(_jn[4], -3.0, 3.0)


# Another player's quad in its own wake: how deep (0-1), from its attitude,
# its throttle (its motors' speed, s.rpm, as the game's model has it) and how
# it moves - the vortex ring state as dirty_air has it, against the wake
# speed of its props at the thrust the game would give it
func _remote_wake(s: Src) -> float:
	var vid := str(s.node.get("_current_vehicle")) if s.node.get("_current_vehicle") != null else ""
	var d: Array = REMOTE_DRONES.get(vid, REMOTE_DRONES["5in_freestyle"])
	var r := clampf(s.rpm / MAX_MOTOR_RPM, 0.0, 1.0)
	var x := r * 10.0
	var i := mini(int(x), THRUST_CURVE.size() - 1)
	var c: float = THRUST_CURVE[i] if i >= THRUST_CURVE.size() - 1 else lerpf(THRUST_CURVE[i], THRUST_CURVE[i + 1], x - i)
	var thrust := float(d[1]) / 1000.0 * 9.8 * r * c
	var rad := float(d[2]) / 2000.0
	var vh := sqrt(maxf(thrust, 1e-3) / (2.0 * RHO * 4.0 * PI * rad * rad))
	var up := s.node.global_transform.basis.y.normalized()
	var air := s.vel
	if _gs == null or not is_instance_valid(_gs):
		_gs = get_node_or_null("/root/ZGamestate")
	var wind = _gs.get("current_wind_effect") if _gs != null else null
	if wind is Vector3:
		air -= wind
	var vz := air.dot(up)
	if vz >= 0.0:
		return 0.0
	var vx := (air - up * vz).length()
	return exp(-pow((-vz / vh - VRS_CENTRE) / VRS_WIDTH, 2.0)) * maxf(0.0, 1.0 - vx / vh)


func _prop_damage() -> Node:
	if _pd != null and is_instance_valid(_pd):
		return _pd
	_pd = null
	_pd_look -= 1
	if _pd_look <= 0:
		_pd_look = 240
		_pd = get_node_or_null("/root/ZoneMods/prop_damage/Props")
	return _pd


func _dirty_air() -> Node:
	if _da != null and is_instance_valid(_da):
		return _da
	_da = null
	_da_look -= 1
	if _da_look <= 0:
		_da_look = 240
		_da = get_node_or_null("/root/ZoneMods/dirty_air/Air")
	return _da


# ---- sources ----

func _new_bus(prefix: String) -> String:
	var name := prefix
	while AudioServer.get_bus_index(name) >= 0:
		_next_bus += 1
		name = "%s%d" % [prefix, _next_bus]
	AudioServer.add_bus()
	buses_made += 1
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, name)
	AudioServer.set_bus_send(i, "Master")
	return name


func _make_src(node: Node3D, remote: bool, prefix: String) -> Src:
	var s := Src.new()
	s.node = node
	s.remote = remote
	s.gain = _floor
	# a remote bus left by one that went is used again as it is
	while remote and not _pool.is_empty():
		s.bus = _pool.pop_back()
		s.bus_i = AudioServer.get_bus_index(s.bus)
		if s.bus_i > 0:
			s.lp = AudioServer.get_bus_effect(s.bus_i, 0) as AudioEffectLowPassFilter
			s.pan = AudioServer.get_bus_effect(s.bus_i, 1) as AudioEffectPanner
			if s.lp != null and s.pan != null:
				s.lp.cutoff_hz = 20000.0
				s.pan.pan = 0.0
				return s
	s.bus = _new_bus(prefix)
	s.bus_i = AudioServer.get_bus_index(s.bus)
	s.lp = AudioEffectLowPassFilter.new()
	s.lp.cutoff_hz = 20000.0
	s.lp.db = AudioEffectFilter.FILTER_12DB
	AudioServer.add_bus_effect(s.bus_i, s.lp, 0)
	s.pan = AudioEffectPanner.new()
	AudioServer.add_bus_effect(s.bus_i, s.pan, 1)
	# a remote's loudness goes on its player; the bus stays at 0 dB
	AudioServer.set_bus_volume_db(s.bus_i, 0.0 if remote else s.gain)
	return s


func _free_src(s: Src, keep_bus: bool = true) -> void:
	if s.remote and s.player != null and is_instance_valid(s.player):
		if s.player.playing and s.out_db + linear_to_db(maxf(s.env, 0.0001)) > -50.0:
			cuts += 1
		s.player.stop()
		s.player.queue_free()
	if s.remote and keep_bus:
		_pool.append(s.bus)
		return
	var i := AudioServer.get_bus_index(s.bus)
	if i > 0:
		AudioServer.remove_bus(i)
	# the others may have moved down
	for o in sources:
		o.bus_i = AudioServer.get_bus_index(o.bus)


func _attach_local() -> void:
	if _local != null and is_instance_valid(_local.node) and is_instance_valid(_qa):
		return
	if _local != null:
		sources.erase(_local)
		_free_src(_local)
		_local = null
	_qa = null
	if _scene == null:
		return
	var p := _scene.find_child("Player", true, false) as Node3D
	if p == null:
		return
	var qa := p.get_node_or_null("QuadAudio") as AudioStreamPlayer
	if qa == null:
		return
	_qa = qa
	_stream = qa.stream
	_game_pitch = qa.pitch_scale
	_game_vol = qa.volume_db
	_out_pitch = -1.0
	_written_pitch = -1.0
	_local = _make_src(p, false, BUS_LOCAL)
	_local.player = qa
	_qa_bus_orig = qa.bus
	AudioServer.set_bus_send(_local.bus_i, _qa_bus_orig)
	qa.bus = _local.bus
	sources.push_front(_local)


# Other players' quads: the children of the game's LOSQuads node, the nearest
# multiplayer_max of them that are showing. One already heard is counted a
# little nearer, so two at about the same distance do not keep trading
# places; one no longer wanted fades out, then goes.
func _sync_remotes() -> void:
	var holder := _scene.get_node_or_null("LOSQuads") if _scene != null else null
	var want := []
	if holder != null and holder.get_child_count() > 0:
		for q in holder.get_children():
			if q is Node3D and (q as Node3D).is_visible_in_tree() and "stick_position" in q:
				want.append(q)
		if want.size() > _mp_max:
			var pilot := _pilot()
			var heard := {}
			for s in sources:
				if s.remote and not s.leaving:
					heard[s.node] = true
			var keyed := []
			for q in want:
				var d2: float = (q as Node3D).global_position.distance_squared_to(pilot)
				keyed.append([d2 * (KEEP * KEEP) if heard.has(q) else d2, q])
			keyed.sort_custom(func(a, b): return a[0] < b[0])
			want = []
			for i in _mp_max:
				want.append(keyed[i][1])
	var have := {}
	for s in sources:
		if not s.remote:
			continue
		if not is_instance_valid(s.node) or not want.has(s.node):
			if not s.leaving:
				s.leaving = true
				swaps += 1
		else:
			s.leaving = false
			have[s.node] = true
	for q in want:
		if have.has(q):
			continue
		var stream := _stream if _stream != null else load("res://audio/test_audio_short.mp3") as AudioStream
		if stream == null:
			return
		var s := _make_src(q, true, BUS_REMOTE)
		s.player = AudioStreamPlayer.new()
		s.player.name = "Remote_" + str(q.name)
		s.player.stream = stream
		s.player.bus = s.bus
		s.player.volume_db = -80.0
		add_child(s.player)
		sources.append(s)


# multiplayer turned off while the game runs (mod_settings): the other
# players' quads still heard fade out and go, as one that leaves does
func _quiet_remotes() -> void:
	for s in sources:
		if s.remote and not s.leaving:
			s.leaving = true


func _drop_all() -> void:
	if _qa != null and is_instance_valid(_qa):
		_qa.bus = _qa_bus_orig
	for s in sources.duplicate():
		sources.erase(s)
		_free_src(s, false)
	for b in _pool:
		var i := AudioServer.get_bus_index(b)
		if i > 0:
			AudioServer.remove_bus(i)
	_pool.clear()
	_qa = null
	_local = null


func _exit_tree() -> void:
	_drop_all()


# ---- the sums ----

func _step(s: Src, dt: float, pilot: Vector3, do_rays: bool, focus: bool) -> void:
	if not is_instance_valid(s.player):
		return
	if not is_instance_valid(s.node):
		# a player who left: fade out where it was
		if s.remote:
			s.leaving = true
			s.env = move_toward(s.env, 0.0, dt / FADE_S)
			s.player.volume_db = s.out_db + linear_to_db(maxf(s.env, 0.0001))
		return
	var pos := s.node.global_position
	var pitch := 1.0
	var vol := 0.0
	if s.remote:
		# the game's motor model, driven by the throttle it receives
		var st = s.node.get("stick_position")
		var thr := clampf((float(st.z) + 1.0) * 0.5, 0.0, 1.0) if st is Vector4 else 0.0
		s.rpm = move_toward(s.rpm, maxf(MAX_MOTOR_RPM * thr, IDLE_RPM), RPM_RATE * dt)
		pitch = s.rpm / (MAX_MOTOR_RPM * 0.9) + 0.3
		if _zs == null or not is_instance_valid(_zs):
			_zs = get_node_or_null("/root/ZSettings")
		var master = _zs.get("AUDIO_VOLUME") if _zs != null else null
		vol = -10.0 + 10.0 * (s.rpm / MAX_MOTOR_RPM + 0.3) + linear_to_db(maxf(float(master) if master != null else 0.1, 0.0001))
		# the game does not say whether they are armed: sat still at zero
		# throttle for a moment counts as disarmed
		var moved := pos.distance_to(s.last_pos) / dt if s.have_pos else 0.0
		if s.have_pos and moved < MAX_LISTENER_SPEED:
			s.vel += ((pos - s.last_pos) / dt - s.vel) * (1.0 - exp(-dt / 0.1))
		else:
			s.vel = Vector3.ZERO
		# falling through its own wake, its motors hunt too
		s.wash = 0.0
		if _wash_amt > 0.0 and _wash_others:
			var w := _remote_wake(s) if thr > 0.02 else 0.0
			s.wl += (w - s.wl) * (1.0 - exp(-dt / 0.08))
			if s.wl > 0.002:
				for j in 3:
					var fcj: float = [30.0, 6.0, 20.0][j]
					var aj := 1.0 - exp(-TAU * fcj * dt)
					s.jn[j] += (_rng.randfn() * sqrt((2.0 - aj) / aj) - s.jn[j]) * aj
				var kw := _wash_amt * s.wl
				s.wash = clampf(WASH_PITCH * kw * (0.75 * s.jn[0] + 0.66 * s.jn[1]), -0.3, 0.3)
				pitch *= 1.0 + s.wash
				vol += WASH_DB * kw * clampf(s.jn[2], -3.0, 3.0)
			else:
				s.wl = 0.0
		s.quiet_s = s.quiet_s + dt if thr < 0.05 and moved < 0.3 else 0.0
		var on := focus and s.quiet_s < 1.5 and not s.leaving
		if on and not s.player.playing:
			# start somewhere in the loop, so two quads are not in step, and
			# fade in
			s.env = 0.0
			s.player.volume_db = -80.0
			s.player.play(randf() * maxf(s.player.stream.get_length() - 1.0, 0.0))
		s.env = move_toward(s.env, 1.0 if on else 0.0, dt / FADE_S)
		if s.env <= 0.0 and s.player.playing:
			s.player.stop()
	else:
		pitch = _game_pitch
		vol = _game_vol
		if _onboard:
			# your own quad, heard from on it: as the game plays it
			s.last_pos = pos
			s.have_pos = true
			s.game_pitch = pitch
			s.pitch = _src_pitch
			s.doppler = 1.0
			s.delay = 0.0
			s.distance = 0.0
			s.azimuth = 0.0
			s.occl = 0.0
			s.occl_target = 0.0
			_apply(s, dt, 0.0, 20000.0, 0.0, vol)
			return
	s.last_pos = pos
	s.have_pos = true
	s.game_pitch = pitch
	# what reaches the pilot now left the quad a moment ago
	var src := pos
	s.doppler = 1.0
	s.delay = 0.0
	if _delay:
		if s.remote:
			_record(s, pos, pitch, vol)
		var te := _emitted(s, pilot)
		_at(s, te)
		src = _a_pos
		pitch = _a_pitch
		vol = _a_vol
		s.delay = _t - te
		_at(s, te - 0.05)
		var vel := (src - _a_pos) / 0.05
		# faster than any quad flies: a respawn, not flight
		if vel.length_squared() < 22500.0:
			var away := (src - pilot).normalized()
			# a listener on a quad moving towards it hears it higher too
			s.doppler = clampf((SOUND_SPEED + _listener_vel.dot(away)) / maxf(SOUND_SPEED + vel.dot(away), 1.0), 0.5, 2.0)
	s.pitch = maxf(pitch * s.doppler, 0.01)
	if s.remote:
		s.player.pitch_scale = s.pitch
	# where it is against the pilot
	var d := src - pilot
	var dist := d.length()
	s.distance = dist
	var hx := d.dot(_right)
	var hz := d.dot(_forward)
	var hfrac := sqrt(hx * hx + hz * hz) / maxf(dist, 0.001)
	var az := atan2(hx, hz)                    # 0 ahead, +90 right, 180 behind
	s.azimuth = rad_to_deg(az)
	var behind := maxf(0.0, -cos(az)) * hfrac if _stereo else 0.0
	# walls
	if do_rays:
		s.occl_target = _blocked(s, pilot, src)
	elif not _walls:
		s.occl_target = 0.0
	s.occl += (s.occl_target - s.occl) * (1.0 - exp(-dt / 0.15))
	# loudness
	var g := -20.0 * _falloff * log(maxf(dist, _ref) / _ref) / log(10.0)
	g -= _wall_db * s.occl + 2.0 * behind
	g = maxf(g, _floor)
	# tone
	var fc := _air_cutoff(dist) if _air else 20000.0
	if s.occl > 0.001:
		fc = exp(lerpf(log(fc), log(minf(fc, WALL_CUTOFF)), s.occl))
	fc *= 1.0 - 0.3 * behind
	# stereo
	var p := clampf(_width * sin(az) * hfrac, -1.0, 1.0) if _stereo else 0.0
	_apply(s, dt, g, fc, p, vol)


# Smooth towards loudness g (dB), cutoff fc and pan p, and set what changed.
# Another player's loudness goes on its player, ramped by Godot across each
# mix, with the fade on top.
func _apply(s: Src, dt: float, g: float, fc: float, p: float, vol: float) -> void:
	var k := 1.0 - exp(-dt / SMOOTH_S)
	s.gain += (g - s.gain) * k
	s.cutoff = exp(lerpf(log(s.cutoff), log(fc), k))
	s.panv += (p - s.panv) * k
	if s.remote:
		s.out_db = vol + s.gain
		s.player.volume_db = s.out_db + linear_to_db(maxf(s.env, 0.0001))
	elif absf(s.gain - s.set_gain) > 0.05 and s.bus_i > 0:
		s.set_gain = s.gain
		AudioServer.set_bus_volume_db(s.bus_i, s.gain)
	if absf(s.cutoff - s.set_cutoff) > s.set_cutoff * 0.005:
		s.set_cutoff = clampf(s.cutoff, 20.0, 20000.0)
		s.lp.cutoff_hz = s.set_cutoff
	if absf(s.panv - s.set_pan) > 0.003:
		s.set_pan = s.panv
		s.pan.pan = s.panv


func _record(s: Src, pos: Vector3, pitch: float, vol: float) -> void:
	s.ht.append(_t)
	s.hp.append(pos)
	s.hpitch.append(pitch)
	s.hvol.append(vol)
	if s.ht.size() > 64 and _t - s.ht[0] > HISTORY_S + 1.0:
		var cut := s.ht.bsearch(_t - HISTORY_S)
		s.ht = s.ht.slice(cut)
		s.hp = s.hp.slice(cut)
		s.hpitch = s.hpitch.slice(cut)
		s.hvol = s.hvol.slice(cut)


# Position, pitch and volume at time te, from the history, into _a_*.
func _at(s: Src, te: float) -> void:
	var n := s.ht.size()
	if n == 0:
		return
	if te <= s.ht[0]:
		_a_pos = s.hp[0]
		_a_pitch = s.hpitch[0]
		_a_vol = s.hvol[0]
		return
	if te >= s.ht[n - 1]:
		_a_pos = s.hp[n - 1]
		_a_pitch = s.hpitch[n - 1]
		_a_vol = s.hvol[n - 1]
		return
	var i := s.ht.bsearch(te)
	var t0 := s.ht[i - 1]
	var w := (te - t0) / maxf(s.ht[i] - t0, 1e-9)
	_a_pos = s.hp[i - 1].lerp(s.hp[i], w)
	_a_pitch = lerpf(s.hpitch[i - 1], s.hpitch[i], w)
	_a_vol = lerpf(s.hvol[i - 1], s.hvol[i], w)


# When the sound reaching the pilot now left the quad: the te where
# t - te = distance at te / speed of sound. Last time's answer moved on,
# refined by iterating, settles in a step or two while the quad flies; after
# a jump away (a respawn far off) there is no exact answer, so it takes the
# last sound that has arrived.
func _emitted(s: Src, pilot: Vector3) -> float:
	if s.ht.is_empty():
		return _t
	var te := _t - s.hp[s.hp.size() - 1].distance_to(pilot) / SOUND_SPEED
	if s.te > 0.0 and absf(s.te - te) < 0.5:
		te = s.te + (_t - s.t_last)
	for i in 5:
		_at(s, te)
		var nt := _t - _a_pos.distance_to(pilot) / SOUND_SPEED
		if absf(nt - te) < 1e-4:
			s.te = nt
			s.t_last = _t
			return nt
		te = nt
	var lo := maxf(_t - HISTORY_S, s.ht[0])
	var hi := _t
	for i in 24:
		var m := (lo + hi) * 0.5
		_at(s, m)
		if _t - m >= _a_pos.distance_to(pilot) / SOUND_SPEED:
			lo = m
		else:
			hi = m
	s.te = lo
	s.t_last = _t
	return lo


func _air_cutoff(d: float) -> float:
	var n := AIR_D.size()
	for i in range(1, n):
		if d <= AIR_D[i]:
			var w: float = (d - AIR_D[i - 1]) / (AIR_D[i] - AIR_D[i - 1])
			return exp(lerpf(log(AIR_HZ[i - 1]), log(AIR_HZ[i]), w))
	return AIR_HZ[n - 1]


# How much of the way from the pilot to the quad is blocked: three rays, to
# the quad and to points a metre above and beside it.
func _blocked(s: Src, pilot: Vector3, src: Vector3) -> float:
	var world := s.node.get_world_3d()
	if world == null:
		return 0.0
	var space := world.direct_space_state
	if space == null:
		return 0.0
	var ex: Array[RID] = []
	for o in sources:
		if is_instance_valid(o.node) and o.node is CollisionObject3D:
			ex.append((o.node as CollisionObject3D).get_rid())
	var side := _right
	var hits := 0
	for off in [Vector3.ZERO, Vector3.UP, side]:
		var to: Vector3 = src + off
		var dir := to - pilot
		if dir.length() < 1.0:
			continue
		# stop short of the quad, so the ground it sits on does not count
		to -= dir.normalized() * 0.5
		var q := PhysicsRayQueryParameters3D.create(pilot, to)
		q.exclude = ex
		if not space.intersect_ray(q).is_empty():
			hits += 1
	return hits / 3.0


## The sounds and what the pilot hears of each, for tests and the status file.
func report() -> Array:
	var out := []
	for s in sources:
		out.append({"distance": s.distance, "gain_db": s.gain, "cutoff_hz": s.set_cutoff, "pan": s.panv,
			"pitch": s.pitch, "game_pitch": s.game_pitch, "doppler": s.doppler, "delay": s.delay,
			"walls": s.occl, "azimuth": s.azimuth, "remote": s.remote,
			"listener": "drone" if _onboard else "spawn",
			"wash": wash_jitter if not s.remote else s.wash, "wake": s.wl if s.remote else _wl,
			"playing": s.player.playing if is_instance_valid(s.player) else false})
	return out
