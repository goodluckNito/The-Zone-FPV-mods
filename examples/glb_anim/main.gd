extends Node
## glb_animations - an example mod for zonemods: plays the animations in a
## map's .glb, which the game loads but never starts.
##
## The game loads a custom map (custom_maps/<name>/<name>.glb) with Godot's
## GLTFDocument. That turns the file's animations into an AnimationPlayer
## node inside the map, but nothing calls play() on it, so the map stands
## still. This mod watches for AnimationPlayers joining the scene tree
## inside a custom map, and starts every animation they hold.
##
## Copy this folder to start a mod of your own: rename it, and change the
## name in zonemod.cfg and in settings.default.cfg.

# the game's script on the node custom maps are loaded under
const MAP_SCRIPT := "res://custommaps/handler/custom_map_root.gd"

var loop := true
var speed := 1.0
var sync_to_clock := true


## zonemods calls this first, once, before the game loads its first scene.
## dir is "res://glb_animations/"; settings.cfg has already been made (or
## brought up to date) from settings.default.cfg, so read it here.
func zm_init(_core: Node, dir: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(dir + "settings.cfg") == OK:
		loop = bool(cfg.get_value("glb_animations", "loop", loop))
		speed = float(cfg.get_value("glb_animations", "speed", speed))
		sync_to_clock = bool(cfg.get_value("glb_animations", "sync_to_clock", sync_to_clock))
	print("[glb_animations] loop %s, speed %s, sync to clock %s" % [loop, speed, sync_to_clock])


## Then zonemods adds this node to the tree, as /root/ZoneMods/glb_animations,
## and it runs like any other node for as long as the game does.
func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is AnimationPlayer and not node.has_meta("glb_animations") and _in_custom_map(node):
		# after the map has finished loading
		_start.call_deferred(node)


func _in_custom_map(node: Node) -> bool:
	var n := node.get_parent()
	while n != null:
		var s: Script = n.get_script()
		if s != null and s.resource_path.get_basename() == MAP_SCRIPT.get_basename():
			return true
		n = n.get_parent()
	return false


## Plays every animation the player holds. An AnimationPlayer plays one
## animation at a time, and Blender exports each object's action as an
## animation of its own - so animations that move different objects each get
## a player and play at once, and ones that move the same objects (a door's
## open and close) take turns on one, in the order that runs on smoothly.
func _start(player: AnimationPlayer) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	var names := Array(player.get_animation_list())
	names.erase("RESET")   # Godot's rest pose, not an animation to play
	var groups := _groups(player, names)
	for i in groups.size():
		var seq: Array = _order(player, groups[i])
		var p := player
		if i > 0:
			# a player of its own, with just these animations
			p = AnimationPlayer.new()
			p.set_meta("glb_animations", true)
			p.name = "%s_%d" % [player.name, i]
			p.root_node = player.root_node
			var lib := AnimationLibrary.new()
			var own := []
			for n in seq:
				lib.add_animation(String(n).get_file(), player.get_animation(n))
				own.append(String(n).get_file())
			p.add_animation_library("", lib)
			player.get_parent().add_child(p)
			seq = own
		_play(p, seq)
		print("[glb_animations] playing %s" % " > ".join(seq))


func _play(p: AnimationPlayer, seq: Array) -> void:
	p.speed_scale = speed
	var clock := Time.get_unix_time_from_system() * speed
	if seq.size() == 1:
		var anim := p.get_animation(seq[0])
		anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		p.play(seq[0])
		if sync_to_clock and loop and anim.length > 0.0:
			# everyone's clock says the same time, so every player in a
			# multiplayer race sees the same part of the loop
			p.seek(fmod(clock, anim.length), true)
		return
	# several in turn: each once, then the next
	var total := 0.0
	for n in seq:
		p.get_animation(n).loop_mode = Animation.LOOP_NONE
		total += p.get_animation(n).length
	var at := 0
	var offset := 0.0
	if sync_to_clock and loop and total > 0.0:
		offset = fmod(clock, total)
		while at < seq.size() - 1 and offset >= p.get_animation(seq[at]).length:
			offset -= p.get_animation(seq[at]).length
			at += 1
	p.animation_finished.connect(_next.bind(p, seq))
	p.play(seq[at])
	if offset > 0.0:
		p.seek(offset, true)


func _next(finished: StringName, p: AnimationPlayer, seq: Array) -> void:
	var i := seq.find(String(finished))
	if i < 0 or (i == seq.size() - 1 and not loop):
		return
	p.play(seq[(i + 1) % seq.size()])


## The animations, grouped by the nodes they move: two that move any of the
## same nodes go in one group
func _groups(player: AnimationPlayer, names: Array) -> Array:
	var groups := []   # [names, nodes moved]
	for n in names:
		var anim := player.get_animation(n)
		var nodes := {}
		for t in anim.get_track_count():
			nodes[String(anim.track_get_path(t).get_concatenated_names())] = true
		var mine := [[n], nodes]
		for g in groups.duplicate():
			for k in nodes:
				if g[1].has(k):
					mine[0] = g[0] + mine[0]
					mine[1].merge(g[1])
					groups.erase(g)
					break
		groups.append(mine)
	return groups.map(func(g): return g[0])


## The order of a group's animations that runs on most smoothly, each
## starting where the one before it ends (and the last where the first
## begins): tried every way for up to 6
func _order(player: AnimationPlayer, names: Array) -> Array:
	if names.size() < 3 or names.size() > 6:
		return names
	var best := names
	var best_gap := INF
	for rest in _permutations(names.slice(1)):
		var seq: Array = [names[0]] + rest
		var gap := 0.0
		for i in seq.size():
			gap += _gap(player.get_animation(seq[i]), player.get_animation(seq[(i + 1) % seq.size()]))
		if gap < best_gap:
			best_gap = gap
			best = seq
	return best


## How far b's first pose is from a's last, over the tracks both have
static func _gap(a: Animation, b: Animation) -> float:
	var gap := 0.0
	for tb in b.get_track_count():
		var ta := a.find_track(b.track_get_path(tb), b.track_get_type(tb))
		if ta < 0:
			continue
		match b.track_get_type(tb):
			Animation.TYPE_POSITION_3D:
				gap += a.position_track_interpolate(ta, a.length).distance_to(b.position_track_interpolate(tb, 0.0))
			Animation.TYPE_ROTATION_3D:
				gap += a.rotation_track_interpolate(ta, a.length).angle_to(b.rotation_track_interpolate(tb, 0.0))
			Animation.TYPE_SCALE_3D:
				gap += a.scale_track_interpolate(ta, a.length).distance_to(b.scale_track_interpolate(tb, 0.0))
	return gap


static func _permutations(items: Array) -> Array:
	if items.size() <= 1:
		return [items]
	var out := []
	for i in items.size():
		var rest := items.duplicate()
		rest.remove_at(i)
		for p in _permutations(rest):
			out.append([items[i]] + p)
	return out
