extends Control
## The same channel pairing and vertical direction as the game's flight overlay.
var values = {"throttle":0.0,"roll":0.0,"pitch":0.0,"yaw":0.0}
var mode = "mode_2"
var _history: Array = []

static func positions(mapped: Dictionary, stick_mode: String) -> Array:
 var left_y = "pitch" if stick_mode == "mode_1" else "throttle"
 var right_y = "throttle" if stick_mode == "mode_1" else "pitch"
 return [Vector2(float(mapped.get("yaw",0)), -float(mapped.get(left_y,0))),Vector2(float(mapped.get("roll",0)), -float(mapped.get(right_y,0)))]

func _init() -> void:
 custom_minimum_size = Vector2(314,150)
 mouse_filter = Control.MOUSE_FILTER_IGNORE

func update_values(mapped: Dictionary, stick_mode: String) -> void:
 values = mapped
 if mode != stick_mode:
  _history.clear()
 mode = stick_mode
 _history.append(positions(values,mode))
 if _history.size()>60: _history.pop_front()
 queue_redraw()

func _draw() -> void:
 var points = positions(values,mode)
 for side in 2:
  var rect = Rect2(Vector2(8+side*160,8),Vector2(134,134))
  draw_style_box(_style(),rect)
  var center = rect.get_center()
  draw_line(Vector2(center.x,rect.position.y),Vector2(center.x,rect.end.y),Color("344656"),1,true)
  draw_line(Vector2(rect.position.x,center.y),Vector2(rect.end.x,center.y),Color("344656"),1,true)
  var radius = rect.size*0.5-Vector2.ONE*8
  for i in range(1,_history.size()):
   draw_line(center+_history[i-1][side]*radius,center+_history[i][side]*radius,Color(0.57,0.9,0.78,0.35*float(i)/_history.size()),1.5,true)
  draw_circle(center+points[side]*radius,5,Color("91e6c6"),true,-1,true)

func _style() -> StyleBoxFlat:
 var style = StyleBoxFlat.new()
 style.bg_color=Color("101a25")
 style.border_color=Color("344656")
 style.set_border_width_all(1)
 style.set_corner_radius_all(8)
 return style
