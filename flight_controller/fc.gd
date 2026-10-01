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

const ZM_FLIGHT_CONTROLLER := 1

var zm_fc = null                 # this quad's controller
var zm_fc_frame := -1            # the physics frame it last ran


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


func _zm_controller():
	if zm_fc == null:
		var tree := get_tree()
		var mod = tree.root.get_node_or_null("ZoneMods/flight_controller") if tree != null else null
		if mod == null or not bool(mod.get("on")):
			return null
		zm_fc = mod.new_controller()
	return zm_fc
