extends Node
const Model=preload("res://video_profiles/video_model.gd")
var _dir=""
var _backend: Node
var _values={}

func zm_init(_core: Node,dir: String) -> void:
 _dir=dir
 zm_apply_settings()

func zm_apply_settings() -> void:
 var file=ConfigFile.new()
 if file.load(_dir.path_join("settings.cfg"))!=OK: return
 _values={}
 for key in file.get_section_keys("video"):
  _values[key]=file.get_value("video",key)
 _apply()

var settings: Node
func _ready() -> void:
 settings=get_node_or_null("/root/ZSettings")
 if settings==null: return
 _backend=load("res://video_profiles/video_backend.gd").new()
 add_child(_backend)
 _backend.setup(self)
 _apply()
func ingame() -> Node:
 return get_node_or_null("/root/IngameMain")

func _apply() -> void:
 if _backend==null: return
 var value=Model.choose(Model.DEFAULTS,str(_values.get("profile","nito")))
 for key in ["glare","softness","auto_signal","quality","minimum","range"]:
  if _values.has(key): value[key]=_values[key]
 for pair in [["noise","noise_factor"],["sharpness","sharpness_factor"],["color","colour_factor"]]:
  value[pair[0]]=float(value[pair[0]])*float(_values.get(pair[1],1.0))
 _backend.call("set_active",true)
 _backend.call("update",value)

func zm_settings_status() -> String:
 return "Профиль меняет картинку сразу. Это визуальные стили, не модели конкретных VTX. OSD на отдельной странице FPV OSD."

func _exit_tree() -> void:
 if is_instance_valid(_backend): _backend.call("set_active",false)
