extends VBoxContainer
const UI = preload("ui.gd")
const Model = preload("controller_model.gd")
const Sticks = preload("stick_preview.gd")
const ACTION_NAMES = ["Throttle", "Roll", "Pitch", "Yaw", "Arm", "Turtle mode", "Respawn", "Flip over", "Trails", "Head tracker"]
var desk: Node
var model = Model.new()
var device_id = -1
var _device_name = ""
var _original_device_name = ""
var _original_overlay = ""
var _mode = "mode_2"
var _show_sticks = true
var _device: OptionButton
var _status: Label
var _sticks: Control
var _stick_caption: Label
var _rows = {}
var _input_adapter: RefCounted
var _refresh_clock = 0.0
var _devices: Array = []
var _reset_confirm: ConfirmationDialog
var _last_raw: Array = []
var _table: GridContainer

func build(owner_desk: Node) -> void:
 desk = owner_desk
 theme = UI.theme()
 theme.default_font_size = 15
 for kind in ["Button", "OptionButton", "CheckButton"]:
  for state in ["normal", "hover", "pressed", "disabled"]:
   var color = Color("202e3c") if state == "normal" else Color("2c4052")
   if state == "pressed": color = Color("375747")
   var style = UI.box(color,5,4)
   style.content_margin_left=8
   style.content_margin_right=8
   theme.set_stylebox(state,kind,style)
 add_theme_constant_override("separation",8)
 model.begin(desk.settings.get("INPUTS_V2"))
 _original_device_name = str(desk.settings.get("PREFERRED_CONTROLLER_DEVICE_NAME"))
 _device_name = _original_device_name
 _original_overlay = str(desk.settings.get("STICK_OVERLAY_MODE"))
 _mode = "mode_1" if _original_overlay == "mode_1" else "mode_2"
 _show_sticks = _original_overlay != "disabled"
 var script = load("res://gdutil/z_input.gd")
 if script != null: _input_adapter = script.new()
 var top = HBoxContainer.new()
 add_child(top)
 var left = VBoxContainer.new()
 left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 top.add_child(left)
 _device = OptionButton.new()
 _device.custom_minimum_size.y = 38
 _device.item_selected.connect(_select_device)
 left.add_child(_device)
 var modes = UI.row()
 left.add_child(modes)
 var mode = OptionButton.new()
 mode.add_item("Mode 2 · throttle left")
 mode.add_item("Mode 1 · throttle right")
 mode.select(1 if _mode == "mode_1" else 0)
 mode.item_selected.connect(func(i): _mode = "mode_1" if i == 1 else "mode_2"; _update_stick_caption())
 modes.add_child(mode)
 var show = CheckButton.new()
 show.text = "Show sticks in flight"
 show.button_pressed = _show_sticks
 show.toggled.connect(func(on): _show_sticks = on)
 modes.add_child(show)
 _status = UI.note("")
 left.add_child(_status)
 left.add_child(UI.note("Move the sticks to verify assignments before Apply. Axis numbers start at 1; channel numbers match the game's profile."))
 var preview = VBoxContainer.new()
 top.add_child(preview)
 _sticks = Sticks.new()
 preview.add_child(_sticks)
 _stick_caption = UI.label("",13,UI.MUTED)
 _stick_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
 preview.add_child(_stick_caption)
 _update_stick_caption()
 _refresh_devices()
 _table=GridContainer.new()
 _table.columns=8
 _table.add_theme_constant_override("v_separation",4)
 _table.add_theme_constant_override("h_separation",12)
 add_child(_table)
 for column in [["Action",130],["Assigned input",190],["Live input",130],["Value",60],["Direction",85],["",76],["",0],["",0]]:
  var label = UI.label(column[0],13,UI.MUTED)
  label.custom_minimum_size.x = column[1]
  if column[0]=="Live input": label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
  _table.add_child(label)
 for i in Model.ACTIONS.size():
  _build_row(Model.ACTIONS[i],ACTION_NAMES[i])
 var bottom = UI.row()
 add_child(bottom)
 bottom.add_child(_button("Reset all bindings…",func(): _reset_confirm.popup_centered()))
 bottom.add_child(UI.note("Clearing a row keeps the saved profile intact until Apply."))
 _reset_confirm=ConfirmationDialog.new()
 _reset_confirm.title="Reset controller bindings?"
 _reset_confirm.dialog_text="Clear all ten assignments and calibration values?\nYou can discard this change before Apply."
 _reset_confirm.confirmed.connect(func(): model.reset_all(); _refresh_rows())
 add_child(_reset_confirm)

func _update_stick_caption() -> void:
 if _stick_caption!=null:
  _stick_caption.text="Yaw / Pitch          Roll / Throttle" if _mode=="mode_1" else "Yaw / Throttle          Roll / Pitch"

func _build_row(action: String,title: String) -> void:
 var row = _table
 var name_label=UI.label(title,16)
 name_label.custom_minimum_size.x=130
 row.add_child(name_label)
 var source=UI.label("",15,UI.ACCENT)
 source.custom_minimum_size.x=190
 row.add_child(source)
 var bar=ProgressBar.new()
 bar.min_value=-1
 bar.max_value=1
 bar.show_percentage=false
 bar.custom_minimum_size=Vector2(100,12)
 bar.size_flags_horizontal=Control.SIZE_EXPAND_FILL
 bar.size_flags_vertical=Control.SIZE_SHRINK_CENTER
 row.add_child(bar)
 var value=UI.label("+0.00",15,UI.MUTED)
 value.custom_minimum_size.x=60
 row.add_child(value)
 var invert=CheckButton.new()
 invert.text="Invert"
 invert.custom_minimum_size.x=85
 invert.button_pressed=model.get_config(action).inverted
 invert.toggled.connect(func(on): model.set_inverted(action,on))
 row.add_child(invert)
 var assign=_button("Assign",func(): _detect(action))
 assign.custom_minimum_size.x=76
 row.add_child(assign)
 row.add_child(_button("Clear",func(): model.reset_binding(action); _refresh_rows()))
 var more=MenuButton.new()
 more.text="···"
 more.tooltip_text="Calibration, half range and switch mode"
 var popup=more.get_popup()
 popup.add_check_item("Half range",0)
 popup.add_check_item("Toggle switch",1)
 popup.add_item("Use current position as center",2)
 popup.add_item("Reset calibration",3)
 popup.about_to_popup.connect(func():
  var config=model.get_config(action)
  popup.set_item_checked(0,config.half_range)
  popup.set_item_checked(1,config.is_toggle)
  popup.set_item_disabled(2,not model.binding_available(action,_last_raw))
 )
 popup.id_pressed.connect(func(id):
  var config=model.get_config(action)
  match id:
   0: model.set_half_range(action,not config.half_range)
   1: model.set_toggle(action,not config.is_toggle)
   2:
    if model.binding_available(action,_last_raw):
     var center=remap(float(_last_raw[config.channel]),config.min,config.max,-1.0,1.0)
     if not model.set_range(action,config.min,config.max,center): _status.text="Center is at an endpoint. Move this stick to its resting center first."
   3: model.set_range(action,-1,1,0)
  _refresh_rows()
 )
 row.add_child(more)
 _rows[action]={"source":source,"bar":bar,"value":value,"assign":assign,"invert":invert}
 _refresh_rows()

func _button(title: String, action: Callable) -> Button:
 var button=UI.button(title,action)
 button.custom_minimum_size.y=32
 return button

func _refresh_devices() -> void:
 var ids=Input.get_connected_joypads()
 _devices=Array(ids)
 _device.clear()
 device_id=-1
 if ids.is_empty():
  _device.add_item("No controller connected · connect USB joystick")
  _device.disabled=true
  _status.text="Connect your radio in joystick / simulator mode. Saved assignments can still be inspected and cleared."
  return
 _device.disabled=false
 for id in ids:
  var title=Input.get_joy_name(id)
  if title=="": title=Input.get_joy_guid(id)
  _device.add_item(title)
  _device.set_item_metadata(_device.item_count-1,id)
  if title==_device_name or device_id==-1:
   _device.select(_device.item_count-1)
   device_id=id
 _status.text="Connected · move one input at a time."

func _select_device(index: int) -> void:
 model.cancel_detection()
 device_id=int(_device.get_item_metadata(index))
 _device_name=_device.get_item_text(index)
 _refresh_rows()

func _raw_inputs() -> Array:
 if device_id<0 or not device_id in Input.get_connected_joypads(): return []
 var out:Array=[]
 for axis in 10: out.append(Input.get_joy_axis(device_id,axis))
 for button in JoyButton.JOY_BUTTON_SDL_MAX: out.append(1.0 if Input.is_joy_button_pressed(device_id,button) else -1.0)
 return out

func _detect(action: String) -> void:
 if model.get_detecting_action()==action:
  cancel_detection()
  return
 if model.start_detection(action,_raw_inputs(),device_id):
  _status.text="Move the input for %s. Esc cancels and preserves the previous binding." % action
 else: _status.text="Connect and select a controller before assigning an input."
 _refresh_rows()

func cancel_detection() -> bool:
 if model.get_detecting_action()=="": return false
 model.cancel_detection()
 _status.text="Assignment cancelled. Previous binding preserved."
 _refresh_rows()
 return true

func _refresh_rows() -> void:
 for action in Model.ACTIONS:
  if not _rows.has(action): continue
  var widgets=_rows[action]
  var config=model.get_config(action)
  widgets.source.text=model.source_label(action)
  widgets.source.tooltip_text="Range %.2f … %.2f · center %.2f%s%s" % [config.min,config.max,config.center," · half range" if config.half_range else ""," · toggle" if config.is_toggle else ""]
  widgets.assign.text="Cancel" if model.get_detecting_action()==action else "Assign"
  widgets.invert.set_pressed_no_signal(config.inverted)

func _process(delta: float) -> void:
 _refresh_clock+=delta
 if _refresh_clock<0.025: return
 var elapsed=_refresh_clock
 _refresh_clock=0.0
 if Array(Input.get_connected_joypads())!=_devices:
  model.cancel_detection()
  _refresh_devices()
  _refresh_rows()
 var raw=_raw_inputs()
 _last_raw=raw
 var result=model.update_detection(raw,elapsed,device_id)
 if result.status not in ["idle","waiting"]:
  _status.text=("Assigned "+model.source_label(result.action)) if result.status=="assigned" else "Assignment stopped. Previous binding preserved."
  _refresh_rows()
 var mapped={}
 for action in Model.ACTIONS:
  var value=0.0
  if _input_adapter!=null and model.binding_available(action,raw): value=float(_input_adapter.apply_config(model.get_config(action),raw))
  mapped[action]=value
  _rows[action].bar.value=value
  _rows[action].value.text="%+.2f" % value
 _sticks.update_values(mapped,_mode)

func _overlay_value() -> String:
 return _mode if _show_sticks else "disabled"

func is_changed() -> bool:
 return model.changed() or _device_name!=_original_device_name or _overlay_value()!=_original_overlay

func apply() -> void:
 desk.settings.set("INPUTS_V2",model.get_configs())
 desk.settings.set("STICK_OVERLAY_MODE",_overlay_value())
 if _device_name!="": desk.settings.set("PREFERRED_CONTROLLER_DEVICE_NAME",_device_name)
 var ready=true
 for action in ["throttle","roll","pitch","yaw"]: ready=ready and model.get_config(action).channel>=0
 desk.settings.set("CONTROLLER_SETUP_V2_COMPLETED",ready)

func mark_saved() -> void:
 model.mark_saved()
 _original_device_name=_device_name
 _original_overlay=_overlay_value()
