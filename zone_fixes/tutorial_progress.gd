extends Node
## Works with the game's completion records; never invents completed lessons.
const Store=preload("progress_store.gd")
var _settings: Node
var _pause: Node
var _play: Button
var _connections=[]
var _last={}
var _clock=0.0
var save_error=""
var _original_play_text=""
var _decorations={}
var _queued=false
var _container: Node
var _row_added: Callable
func _ready() -> void:
 _settings=get_node_or_null("/root/ZSettings")
 if _settings==null: return
 var recovered=Store.read_checkpoint("user://zone_fixes/progress.cfg")
 var merged=Store.merge_completed(_settings.get("LEVEL_COMPLETION"),recovered)
 _settings.set("LEVEL_COMPLETION",merged)
 _last={}
 _checkpoint()
 get_tree().node_added.connect(_node_added)
 _find_pause(get_tree().root)
func _node_added(node: Node) -> void:
 var script=node.get_script() as Script
 if script!=null and script.resource_path.get_basename()=="res://menus/pause_menu/pause_menu":
  _hook.call_deferred(node)
func _find_pause(node: Node) -> void:
 var script=node.get_script() as Script
 if script!=null and script.resource_path.get_basename()=="res://menus/pause_menu/pause_menu":
  _hook(node)
  return
 for child in node.get_children(): _find_pause(child)
func _hook(pause: Node) -> void:
 if not is_instance_valid(pause) or pause==_pause: return
 _pause=pause
 _play=pause.get_node_or_null("%PlayButton") as Button
 if _play==null: return
 _original_play_text=_play.text
 _connections=_play.pressed.get_connections()
 for connection in _connections: _play.pressed.disconnect(connection.callable)
 _play.pressed.connect(resume_tutorial)
 _pause.visibility_changed.connect(_queue_decorate)
 var container=_pause.get_node_or_null("%TrackListContainer")
 if container!=null:
  _container=container
  _row_added=func(_child): _queue_decorate()
  container.child_entered_tree.connect(_row_added)
 _decorate.call_deferred()
func resume_tutorial() -> void:
 var state=get_node_or_null("/root/ZGamestate")
 var level=state.get("selected_level") if state!=null else null
 if not level is Dictionary or not level.get("tracks") is Array:
  for connection in _connections:
   if connection.callable.is_valid(): connection.callable.call()
  return
 var handler=get_node_or_null("/root/IngameMain/TrackHandler")
 if handler==null: return
 if handler.get("_active_track")==null:
  var track=Store.next_track(level.tracks,_settings.get("LEVEL_COMPLETION"))
  if track.is_empty():
   state.call("set_paused",false)
   return
  handler.call("prime_race",track)
 state.call("set_paused",false)
func _queue_decorate() -> void:
 if _queued: return
 _queued=true
 _decorate.call_deferred()
func _decorate() -> void:
 _queued=false
 if not is_instance_valid(_pause) or not is_instance_valid(_play): return
 var state=get_node_or_null("/root/ZGamestate")
 var level=state.get("selected_level") if state!=null else null
 if not level is Dictionary or not level.get("tracks") is Array: return
 _play.text="Continue tutorial"
 var container=_pause.get_node_or_null("%TrackListContainer")
 if container==null: return
 var rows=container.get_children().filter(func(row): return not row.is_queued_for_deletion())
 var completed: Dictionary=_settings.get("LEVEL_COMPLETION")
 for key in _decorations.keys():
  if not is_instance_valid(_decorations[key].row.get_ref()): _decorations.erase(key)
 for i in mini(rows.size(),level.tracks.size()):
  var children=rows[i].get_children()
  if children.size()>2 and children[2] is Label:
   var key=rows[i].get_instance_id()
   if not _decorations.has(key):
    _decorations[key]={"row":weakref(rows[i]),"label":children[2].text,"disabled":children[3].disabled,"text":children[3].text,"callback":Callable()}
   var done=Store.is_completed(completed,str(level.tracks[i].id))
   children[2].text="Completed" if done else ""
   if done and children[3].disabled:
    var track=level.tracks[i]
    var callback=func():
     var handler=get_node_or_null("/root/IngameMain/TrackHandler")
     if handler!=null:
      state.call("set_paused",false)
      handler.call("prime_race",track)
    children[3].disabled=false
    children[3].text="Play again"
    children[3].pressed.connect(callback)
    _decorations[key].callback=callback
func _process(delta: float) -> void:
 _clock+=delta
 if _clock<0.25: return
 _clock=0
 _checkpoint()
func _checkpoint() -> void:
 if _settings==null: return
 var current=Store.merge_completed(_last,Store.completed_only(_settings.get("LEVEL_COMPLETION")))
 if current==_last: return
 var result=Store.write_checkpoint("user://zone_fixes/progress.cfg",current)
 if result==OK:
  _last=current.duplicate(true)
  save_error=""
 else:
  save_error="Could not checkpoint tutorial progress: "+error_string(result)
  push_warning(save_error)
func _exit_tree() -> void:
 _checkpoint()
 if is_instance_valid(_container) and _container.child_entered_tree.is_connected(_row_added): _container.child_entered_tree.disconnect(_row_added)
 if is_instance_valid(_pause) and _pause.visibility_changed.is_connected(_queue_decorate):
  _pause.visibility_changed.disconnect(_queue_decorate)
 for snapshot in _decorations.values():
  var row=snapshot.row.get_ref()
  if not is_instance_valid(row): continue
  row.get_child(2).text=snapshot.label
  var button=row.get_child(3)
  button.disabled=snapshot.disabled
  button.text=snapshot.text
  if snapshot.callback.is_valid() and button.pressed.is_connected(snapshot.callback): button.pressed.disconnect(snapshot.callback)
 if is_instance_valid(_play):
  _play.text=_original_play_text
  if _play.pressed.is_connected(resume_tutorial): _play.pressed.disconnect(resume_tutorial)
  for connection in _connections:
   if connection.callable.is_valid() and not _play.pressed.is_connected(connection.callable):
    _play.pressed.connect(connection.callable,connection.flags)
