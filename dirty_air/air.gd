extends "res://dirty_air/air_original.gd"
func _exit_tree() -> void:
 if is_instance_valid(_player) and _player is RigidBody3D:
  _unshake(_player)
 super._exit_tree()
