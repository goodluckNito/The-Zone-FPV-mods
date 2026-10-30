extends Node
## One Escape step returns to the parent menu; only the pause hub resumes.
var _guard: Node
var _pause: Node
var _buttons: Array[Node]=[]
var _return_from_desk=false
class Guard extends Node:
 var router: Node
 func _input(event: InputEvent) -> void:
  if router.handle_key(event): get_viewport().set_input_as_handled()
func _ready() -> void:
 _guard=Guard.new()
 _guard.router=self
 _guard.name="ZoneEscapeKeys"
 get_tree().root.add_child.call_deferred(_guard)
 get_tree().node_added.connect(_node_added)
 _scan(get_tree().root)
func _node_added(node: Node) -> void:
 if is_instance_valid(_guard) and node!=_guard and node.get_parent()==get_tree().root:
  get_tree().root.move_child.call_deferred(_guard,-1)
 var script=node.get_script() as Script
 if script!=null and script.resource_path.get_basename()=="res://menus/pause_menu/pause_menu":
  _hook.call_deferred(node)
func _scan(node: Node) -> void:
 _node_added(node)
 for child in node.get_children(): _scan(child)
func _hook(pause: Node) -> void:
 if not is_instance_valid(pause) or pause==_pause: return
 _pause=pause
 var menu=pause.get_node_or_null("%MainMenu")
 if menu==null: return
 var desk=get_node_or_null("/root/ZoneDesk")
 if desk!=null:
  for entry in [["Controller","controller"],["Display & sound","graphics"]]:
   var button=Button.new()
   button.text=entry[0]
   var page=entry[1]
   button.pressed.connect(func(): desk.show_page(page))
   menu.add_child(button)
   _buttons.append(button)
func handle_key(event: InputEvent) -> bool:
 if not event is InputEventKey or not event.pressed or event.echo or event.keycode!=KEY_ESCAPE: return false
 var state=get_node_or_null("/root/ZGamestate")
 var ingame=get_node_or_null("/root/IngameMain")
 var desk=get_node_or_null("/root/ZoneDesk")
 var manager=get_node_or_null("/root/ZoneMods/mod_settings")
 # Assignments and modal confirmations consume Escape before navigation.
 if desk!=null and desk.get("_shell").visible:
  var page=desk.get("_page")
  if page!=null and page.has_method("cancel_detection") and page.cancel_detection(): return true
  for key in ["_discard","_reload"]:
   var dialog=desk.get(key)
   if dialog.visible:
    dialog.hide()
    return true
  desk.set("_resume_on_close",false)
  _return_from_desk=ingame!=null
  desk.request_close()
  if not desk.get("_shell").visible: _show_hub()
  return true
 if manager!=null:
  var focus=get_viewport().gui_get_focus_owner()
  if focus is LineEdit and focus.is_visible_in_tree() and focus.is_editing():
   focus.unedit()
   focus.release_focus()
   return true
  var catalog=manager.get("_catalog_layer")
  if catalog!=null and catalog.visible:
   manager.set("_catalog_resume",false)
   manager.close_catalog()
   _show_hub()
   return true
  var overlay=manager.get("_layer")
  if overlay!=null and overlay.visible:
   manager.show_overlay(false)
   _show_hub()
   return true
 if ingame==null or state==null:
  if desk!=null:
   desk.show_page("controller")
   return true
  return false
 var chat=ingame.get_node_or_null("%ChatInput")
 if chat!=null and chat.is_editing():
  chat.release_focus()
  return true
 if state.is_paused and is_instance_valid(_pause):
  for path in ["%Rates","%CameraSettings","%Physics","%GameSettings","%Racing"]:
   var page=_pause.get_node_or_null(path)
   if page!=null and page.visible:
    var back=page.get("go_back")
    if back is Callable and back.is_valid():
     back.call()
     return true
  # mod_settings' original full page also has a Back signal.
  if manager!=null:
   var page=manager.get("_page")
   if page!=null and page.visible:
    manager.call("_close_page")
    return true
 state.set_paused(not state.is_paused)
 return true
func _show_hub() -> void:
 var state=get_node_or_null("/root/ZGamestate")
 var ingame=get_node_or_null("/root/IngameMain")
 if ingame==null or state==null: return
 state.set_paused(true)
 var layer=ingame.get_node_or_null("PauseLayer")
 if layer!=null: layer.visible=true
 if is_instance_valid(_pause):
  for path in ["%Rates","%CameraSettings","%Physics","%GameSettings","%Racing"]:
   var page=_pause.get_node_or_null(path)
   if page!=null: page.visible=false
  _pause.get_node("%MainMenu").visible=true
  _pause.get_node("%PlayButton").disabled=false
 Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
func _process(_delta: float) -> void:
 # Existing mods also keep their guards last. Cooperate via their guard_key
 # bridge rather than continually moving three guards around the root.
 if _return_from_desk:
  var desk=get_node_or_null("/root/ZoneDesk")
  if desk==null or not desk.get("_shell").visible:
   _return_from_desk=false
   _show_hub()
func _exit_tree() -> void:
 if is_instance_valid(_guard): _guard.queue_free()
 for button in _buttons:
  if is_instance_valid(button): button.queue_free()
