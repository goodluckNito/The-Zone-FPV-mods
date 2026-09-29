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
## animation of its own, so each one after the first gets a player of its own.
func _start(player: AnimationPlayer) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	var names := player.get_animation_list()
	names.erase("RESET")   # Godot's rest pose, not an animation to play
	for i in names.size():
		var anim := player.get_animation(names[i])
		anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		var p := player
		var anim_name: String = names[i]
		if i > 0:
			p = AnimationPlayer.new()
			p.set_meta("glb_animations", true)
			p.name = "%s_%d" % [player.name, i]
			p.root_node = player.root_node
			var lib := AnimationLibrary.new()
			anim_name = anim_name.get_file()
			lib.add_animation(anim_name, anim)
			p.add_animation_library("", lib)
			player.get_parent().add_child(p)
		p.speed_scale = speed
		p.play(anim_name)
		if sync_to_clock and loop and anim.length > 0.0:
			# everyone's clock says the same time, so every player in a
			# multiplayer race sees the same part of the loop
			p.seek(fmod(Time.get_unix_time_from_system() * speed, anim.length), true)
		print("[glb_animations] playing %s (%.1f s)" % [anim_name, anim.length])
