extends "res://flight_controller/base/player_rigid_body.gd"
## flight_controller: the game's quad (player_rigid_body.gd), flown by a
## flight controller. The game turns the quad with an idealised controller -
## a torque straight towards the stick's rate, whatever the throttle - and
## pushes it with one thrust at its centre. Here the quad has four motors,
## each with its own speed and thrust at its own corner, set by a
## Betaflight-style rate PID and mixer; the rotation comes from the
## differences between them (controller.gd). Everything else - the drone's
## settings, thrust curve, drag, wind, turtle mode, sound - is the game's
## own, from a copy of its script made at each launch.
## With mode_3d, the motors run both ways: the throttle as 3D mode reads it,
## the stick shown as it is, arming as 3D mode arms, other players sent the
## throttle as the motors have it (its main.gd), and controller.gd turning
## each motor round through a stop.

const ZM_FLIGHT_CONTROLLER := 1

var zm_fc = null                 # this quad's controller
var zm_fc_frame := -1            # the physics frame it last ran
var zm3_mod = null               # mode_3d


func _handle_rotation(delta: float, setpoint: Dictionary) -> float:
 var c = _zm_controller()
 if c == null:
  return super(delta, setpoint)
 zm_fc_frame = Engine.get_physics_frames()
 c.step(self, delta, setpoint)
 return 0.0


# The game's own motor step, for its single thrust at the centre: the
# controller's four motors' mean instead (the controller adds each motor's
# difference from it at its corner)
func calc_motor_rpm(current: float, wanted: float, delta: float) -> float:
 if zm_fc != null and zm_fc_frame == Engine.get_physics_frames():
  return zm_fc.mean_rpm
 return super(current, wanted, delta)


var _lab_have_original := false
var _lab_inertia := Vector3.ZERO
var _lab_material = null

func _zm_controller():
 var tree := get_tree()
 var mod = tree.root.get_node_or_null("ZoneMods/flight_controller") if tree != null else null
 if mod == null or not bool(mod.get("on")):
  lab_release_controller()
  return null
 if zm_fc == null:
  _lab_inertia = inertia
  _lab_material = physics_material_override
  _lab_have_original = true
  zm_fc = mod.new_controller()
 return zm_fc

func lab_release_controller() -> void:
 if _lab_have_original:
  inertia = _lab_inertia
  physics_material_override = _lab_material
  _lab_have_original = false
 zm_fc = null
 zm_fc_frame = -1


# mode_3d, when it has this quad run the motors both ways (not for the wing,
# which the game flies with a physics handler of its own)
func _zm3():
 if zm3_mod == null or not is_instance_valid(zm3_mod):
  var tree := get_tree()
  zm3_mod = tree.root.get_node_or_null("ZoneMods/mode_3d") if tree != null else null
 if zm3_mod == null or not bool(zm3_mod.get("via_fc")) or physics_handler != null:
  return null
 return zm3_mod


func apply_setpoint_latency(current_setpoint: Dictionary):
 var sp = super(current_setpoint)
 var m = _zm3()
 if m == null or not (sp is Dictionary):
  return sp
 return m.map_setpoint(self, sp)


func _check_arm_switch(setpoint: Dictionary):
 var m = _zm3()
 if m == null:
  super(setpoint)
  return
 stick_pos.z = float(m.state(self)["raw"])
 var keep = throttle_input
 if m.arm_blocked(self):
  throttle_input = 1.0
 super(setpoint)
 throttle_input = keep


func get_udp_position():
 var a = super()
 var m = _zm3()
 if m != null and a is Array and a.size() > 3 and a[3] is Vector4:
  a[3] = m.udp_stick(self, a[3])
 return a
