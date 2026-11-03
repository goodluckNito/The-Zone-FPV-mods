extends SceneTree
func _initialize() -> void:
 var root=get_script().resource_path.get_base_dir().get_base_dir()
 var script=load(root.path_join("zone_desk/stick_preview.gd"))
 if script==null:
  quit(1)
  return
 var input={"yaw":0.3,"throttle":-1.0,"roll":-0.6,"pitch":0.8}
 var two=script.positions(input,"mode_2")
 var one=script.positions(input,"mode_1")
 assert(two==[Vector2(0.3,1.0),Vector2(-0.6,-0.8)],"Mode 2 must match native flight pairing and vertical signs")
 assert(one==[Vector2(0.3,-0.8),Vector2(-0.6,1.0)],"Mode 1 must swap vertical channels only")
 assert(script.positions({},"mode_2")==[Vector2.ZERO,Vector2.ZERO],"Disconnected inputs must center both sticks")
 print("PASS: stick preview matches native Mode 1 / Mode 2 channel orientation")
 quit()
