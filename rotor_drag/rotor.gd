extends "res://rotor_drag/rotor_original.gd"
## Remember the actual pre-mod state, including another map's overrides.
var _previous={}
func _remember(body: RigidBody3D) -> void:
 var id=body.get_instance_id()
 if not _previous.has(id):
  _previous[id]={"body":weakref(body),"damp":body.linear_damp,"mode":body.linear_damp_mode,"curve":body.get("SPEED_THRUST_CURVE")}
func _set_damping(body: RigidBody3D) -> void:
 _remember(body)
 super._set_damping(body)
func _set_curve(player: Object) -> void:
 if player is RigidBody3D: _remember(player)
 super._set_curve(player)
func _exit_tree() -> void:
 for state in _previous.values():
  var body=state.body.get_ref()
  if body==null: continue
  body.linear_damp=state.damp
  body.linear_damp_mode=state.mode
  if is_same(body.get("SPEED_THRUST_CURVE"),_curve): body.set("SPEED_THRUST_CURVE",state.curve)
