extends "res://prop_damage/props_original.gd"
var _previous={}
func _physics_process(delta: float) -> void:
 var scene=get_tree().current_scene
 var body=_player if is_instance_valid(_player) else (scene.find_child("Player",true,false) if scene!=null else null)
 if body is RigidBody3D and not _previous.has(body.get_instance_id()):
  _previous[body.get_instance_id()]={"body":weakref(body),"contacts":body.max_contacts_reported,"monitor":body.contact_monitor}
 super._physics_process(delta)
func _exit_tree() -> void:
 for state in _previous.values():
  var body=state.body.get_ref()
  if body==null: continue
  body.max_contacts_reported=state.contacts
  body.contact_monitor=state.monitor
 super._exit_tree()
