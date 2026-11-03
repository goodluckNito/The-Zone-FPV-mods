extends Node
## Native additive menu. The game's scenes and flight model stay in their PCK.
const UI = preload("ui.gd")
const ControllerPage = preload("controller_page.gd")
const GraphicsPage = preload("graphics_page.gd")
var settings: Node
var _shell: Control
var _content: VBoxContainer
var _heading: Label
var _status: Label
var _telemetry: Label
var _nav = {}
var _page: Control
var _current = "controller"
var _resume_on_close = false
var _clock = 0.0
var _discard: ConfirmationDialog
var _reload: ConfirmationDialog
var _pending_page = ""
var _scroll: ScrollContainer

class KeyGuard extends Node:
 var desk: Node
 func _input(event: InputEvent) -> void:
  desk.guard_key(event)

func _ready() -> void:
 settings = get_node_or_null("/root/ZSettings")
 if settings == null:
  push_error("Zone Desk: game settings unavailable")
  return
 print("ZONE_DESK_READY version=0.1")
 _build_shell()
 get_tree().node_added.connect(_node_added)
 var guard = KeyGuard.new()
 guard.name = "ZoneDeskKeys"
 guard.desk = self
 get_tree().root.add_child.call_deferred(guard)
 get_tree().node_added.connect(func(node):
  if node.get_parent() == get_tree().root and node != guard:
   get_tree().root.move_child.call_deferred(guard, -1)
 )

func _build_shell() -> void:
 var layer = CanvasLayer.new()
 layer.layer = 200
 add_child(layer)
 _shell = Control.new()
 _shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 _shell.theme = UI.theme()
 _shell.visible = false
 layer.add_child(_shell)
 var bg = ColorRect.new()
 bg.color = Color("0b1119")
 bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 _shell.add_child(bg)
 var margin = MarginContainer.new()
 margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 for edge in ["left", "right", "top", "bottom"]:
  margin.add_theme_constant_override("margin_" + edge, 26)
 _shell.add_child(margin)
 var layout = VBoxContainer.new()
 margin.add_child(layout)
 var top = UI.row()
 layout.add_child(top)
 var brand = UI.label("ZONE  /  FLIGHT DESK", 22, UI.ACCENT)
 brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 top.add_child(brand)
 _telemetry = UI.label("", 15, UI.MUTED)
 top.add_child(_telemetry)
 top.add_child(UI.button("Close  ·  F10", request_close))
 layout.add_child(HSeparator.new())
 var main = UI.row()
 main.size_flags_vertical = Control.SIZE_EXPAND_FILL
 layout.add_child(main)
 var side = VBoxContainer.new()
 side.custom_minimum_size.x = 190
 main.add_child(side)
 side.add_child(UI.label("SETUP", 12, UI.MUTED))
 for entry in [["controller", "Controller"], ["graphics", "Display & sound"], ["flight", "Drone & camera"], ["mods", "Installed mods"]]:
  var id = entry[0]
  var button = UI.button(entry[1], func(): request_page(id))
  button.alignment = HORIZONTAL_ALIGNMENT_LEFT
  side.add_child(button)
  _nav[id] = button
 var stretch = Control.new()
 stretch.size_flags_vertical = Control.SIZE_EXPAND_FILL
 side.add_child(stretch)
 side.add_child(UI.note("F10 opens this desk before or during a flight.\n\nEsc cancels an assignment first, then closes the desk."))
 var body = VBoxContainer.new()
 body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 main.add_child(body)
 _heading = UI.label("Controller", 34)
 body.add_child(_heading)
 var scroll = ScrollContainer.new()
 _scroll = scroll
 scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
 scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
 body.add_child(scroll)
 _content = VBoxContainer.new()
 _content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 scroll.add_child(_content)
 layout.add_child(HSeparator.new())
 var bottom = UI.row()
 layout.add_child(bottom)
 _status = UI.note("Changes stay in this session until Apply.")
 bottom.add_child(_status)
 bottom.add_child(UI.button("Discard & close", discard_close))
 bottom.add_child(UI.button("Apply changes", apply_changes, true))
 _discard = ConfirmationDialog.new()
 _discard.title = "Discard unapplied changes?"
 _discard.dialog_text = "Your saved settings will stay unchanged."
 _discard.confirmed.connect(func():
  if _pending_page == "":
   discard_close()
  else:
   var next = _pending_page
   _pending_page = ""
   show_page(next)
 )
 _shell.add_child(_discard)
 _reload = ConfirmationDialog.new()
 _reload.title = "Reload current map?"
 _reload.dialog_text = "Apply settings and restart this map from spawn?"
 _reload.confirmed.connect(func():
  if apply_changes():
   _resume_on_close = false
   discard_close()
   get_tree().change_scene_to_file("res://ingame/ingame_main.tscn")
 )
 _shell.add_child(_reload)

func ingame() -> Node:
 return get_node_or_null("/root/IngameMain")

func _state() -> Node:
 return get_node_or_null("/root/ZGamestate")

func _node_added(node: Node) -> void:
 var script = node.get_script() as Script
 if script == null:
  return
 var path = script.resource_path.get_basename()
 if path == "res://menus/title_screen":
  _hook_title.call_deferred(node)
 elif path == "res://menus/pause_menu/pause_menu":
  _hook_pause.call_deferred(node)

func _replace_button(button: Button, title: String, page: String) -> void:
 if button == null:
  return
 for connection in button.pressed.get_connections():
  button.pressed.disconnect(connection.callable)
 button.text = title
 button.pressed.connect(func(): show_page(page))

func _hook_title(node: Node) -> void:
 _replace_button(node.get_node_or_null("%ButtonContainer/ControllerSetup"), "Controller", "controller")
 _replace_button(node.get_node_or_null("%ButtonContainer/Settings"), "Flight Desk  ·  F10", "graphics")
 var buttons=node.get_node_or_null("%ButtonContainer")
 if buttons!=null and not buttons.has_node("ModCatalogButton"):
  var button=UI.button("Моды  ·  F6",open_mods)
  button.name="ModCatalogButton"
  buttons.add_child(button)

func _hook_pause(node: Node) -> void:
 var menu = node.get_node_or_null("%MainMenu")
 if menu == null or menu.has_node("ZoneDeskButton"):
  return
 var button = UI.button("Flight Desk  ·  F10", func(): show_page("controller"))
 button.name = "ZoneDeskButton"
 menu.add_child(button)

func guard_key(event: InputEvent) -> void:
 var router=get_node_or_null("/root/ZoneMods/zone_fixes/esc_navigation")
 if router!=null and router.handle_key(event):
  get_viewport().set_input_as_handled()
  return
 if not event is InputEventKey or not event.pressed or event.echo:
  return
 if event.keycode == KEY_F10:
  if _shell.visible:
   request_close()
  else:
   show_page(_current)
  get_viewport().set_input_as_handled()
 elif _shell.visible and event.keycode == KEY_ESCAPE:
  if _page is ControllerPage and _page.cancel_detection():
   pass
  elif _discard.visible:
   _discard.hide()
  elif _reload.visible:
   _reload.hide()
  else:
   request_close()
  get_viewport().set_input_as_handled()

func request_page(id: String) -> void:
 if id == _current:
  return
 if _has_changes():
  _pending_page = id
  _discard.popup_centered()
 else:
  show_page(id)

func show_page(id: String) -> void:
 var manager=get_node_or_null("/root/ZoneMods/mod_settings")
 if manager!=null and manager.get("_catalog_layer")!=null and manager.get("_catalog_layer").visible: manager.call("close_catalog")
 if not _shell.visible:
  var state = _state()
  _resume_on_close = ingame() != null and state != null and not state.get("is_paused")
  if ingame() != null and state != null:
   state.call("set_paused", true)
  Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
 _shell.visible = true
 _current = id
 _page = null
 for child in _content.get_children():
  _content.remove_child(child)
  child.queue_free()
 for key in _nav:
  _nav[key].modulate = UI.ACCENT if key == id else Color.WHITE
 match id:
  "controller":
   _heading.text = "Controller"
   _page = ControllerPage.new()
  "graphics":
   _heading.text = "Display & sound"
   _page = GraphicsPage.new()
  "flight":
   _heading.text = "Drone & camera"
   _build_flight()
  "mods":
   _heading.text = "Installed mods"
   _build_mods()
 if _page != null:
  _content.add_child(_page)
  _page.build(self)
 _scroll.set_deferred("scroll_vertical", 0)
 _status.text = "Changes stay in this session until Apply."

func _build_flight() -> void:
 var card = UI.card(_content, "Flight tuning", "Open the game's existing tuning pages. Flight Desk leaves the flight model unchanged.")
 var pause = _find_script(get_tree().root, "res://menus/pause_menu/pause_menu")
 if pause == null:
  card.add_child(UI.note("Enter a map to tune its drone, rates and camera. Controller and display settings are available before flying."))
  return
 for item in [["Physics", "Drone settings"], ["Rates", "Stick rates"], ["Camera", "Camera tuning"], ["GameSettings", "OSD & game settings"]]:
  var native_button = pause.get_node_or_null("%MainMenu/" + item[0]) as Button
  if native_button != null and native_button.visible:
   card.add_child(UI.button(item[1], func(): _resume_on_close = false; discard_close(); native_button.pressed.emit()))

func _find_script(node: Node, path: String) -> Node:
 var script = node.get_script() as Script
 if script != null and script.resource_path.get_basename() == path:
  return node
 for child in node.get_children():
  var found = _find_script(child, path)
  if found != null:
   return found
 return null

func open_mods() -> void:
 var manager=get_node_or_null("/root/ZoneMods/mod_settings")
 if manager!=null:
  if manager.has_method("open_catalog"): manager.call("open_catalog")
  else: manager.call("show_overlay",true)

func _build_mods() -> void:
 var card=UI.card(_content,"Моды","Каталог, включение и настройки в готовом mod_settings.")
 card.add_child(UI.button("Открыть каталог  ·  F6",func(): discard_close(); open_mods()))

func _has_changes() -> bool:
 return _page != null and _page.is_changed()

func request_close() -> void:
 if _has_changes():
  _pending_page = ""
  _discard.popup_centered()
 else:
  discard_close()

func discard_close() -> void:
 _shell.visible = false
 _discard.hide()
 # Stop hidden preview updates and release the detached edit session.
 for child in _content.get_children():
  _content.remove_child(child)
  child.queue_free()
 _page = null
 if _resume_on_close and _state() != null:
  _state().call("set_paused", false)
 _resume_on_close = false

func apply_changes() -> bool:
 if _page == null:
  _status.text = "No changes on this page."
  return true
 var check = FileAccess.open("user://zone_desk_write_check", FileAccess.WRITE)
 if check == null:
  _status.text = "Could not save: profile directory is not writable."
  return false
 check.close()
 DirAccess.remove_absolute(OS.get_user_data_dir().path_join("zone_desk_write_check"))
 _page.apply()
 settings.call("save_to_disk")
 var saved = ConfigFile.new()
 if saved.load("user://settings.cfg") != OK:
  _status.text = "Applied, but saving could not be verified."
  return false
 if _page is ControllerPage and saved.get_value("general", "INPUTS_V2", {}) != _page.model.get_configs():
  _status.text = "Applied, but the saved controller profile differs."
  return false
 _page.mark_saved()
 _status.text = "Saved. Texture, shadow and lighting changes need map reload."
 var title = _find_script(get_tree().root, "res://menus/title_screen")
 if title != null:
  for name in ["Play", "PlayTutorial"]:
   var button = title.get_node_or_null("%ButtonContainer/" + name)
   if button != null:
    button.disabled = not bool(settings.get("CONTROLLER_SETUP_V2_COMPLETED"))
 return true

func confirm_reload() -> void:
 _reload.popup_centered()

func _process(delta: float) -> void:
 _clock += delta
 if _clock < 0.5 or _telemetry == null:
  return
 _clock = 0.0
 _telemetry.text = "%d FPS  ·  %d controllers" % [Engine.get_frames_per_second(), Input.get_connected_joypads().size()]
