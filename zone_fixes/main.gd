extends Node
## Extend this registry with one small feature script and one config key.
const FEATURES={"tutorial_progress":preload("tutorial_progress.gd")}
var _dir=""
var _core: Node
var _features={}
func zm_init(core: Node,dir: String) -> void:
 _core=core
 _dir=dir
func _ready() -> void:
 zm_apply_settings()
func zm_apply_settings() -> void:
 var file=ConfigFile.new()
 file.load(_dir.path_join("settings.cfg"))
 for key in FEATURES:
  var wanted=bool(file.get_value("fixes",key,true))
  if wanted and not _features.has(key):
   var feature=FEATURES[key].new()
   feature.name=key
   _features[key]=feature
   add_child(feature)
  elif not wanted and _features.has(key):
   _features[key].free()
   _features.erase(key)
func zm_settings_status() -> String:
 return "Small game fixes. Each fix can be switched independently; flight physics stays unchanged."
