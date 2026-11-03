extends "res://zonemods/zonemods.gd"
## Live lifecycle for the explicitly audited Lab mods. Unknown/resource-list
## mods retain upstream startup behavior instead of pretending to unload.
const LIVE=["zone_fixes","video_profiles","fpv_osd","dirty_air","rotor_drag","battery_sag","prop_damage","pilot_audio"]

func _enabled(id: String) -> bool:
 # Prepare the pass-through wrapper before the game's player is cached.
 return true if id=="flight_controller" else super._enabled(id)

func get_mod(id: String) -> Node:
 var node=super.get_mod(id)
 if node!=null and id=="flight_controller" and not bool(node.get("on")): return null
 return node

func get_mods() -> Array:
 return _mods.values().filter(func(node): return is_instance_valid(node) and get_mod(str(node.name))!=null)

func can_toggle(id: String) -> bool:
 if id in LIVE: return true
 if id=="flight_controller":
  var node=_mods.get(id)
  return is_instance_valid(node) and bool(node.get("lab_ready"))
 if id=="drones":
  var node=_mods.get(id)
  if is_instance_valid(node) and bool(node.get("_on")): return false
  var custom=ConfigFile.new()
  return custom.load("res://drones/my_drones.cfg")!=OK or custom.get_sections().is_empty()
 return false

func set_mod_enabled(id: String,enabled: bool) -> String:
 if not can_toggle(id): return "Этот мод меняет ресурсы при запуске: нужен перезапуск."
 if id=="flight_controller":
  return "" if _mods[id].call("lab_set_enabled",enabled) else "Не удалось переключить полётный контроллер."
 var node=_mods.get(id)
 if enabled:
  if is_instance_valid(node): return ""
  _load(id)
  if not is_instance_valid(_mods.get(id)): return "Не удалось загрузить мод. См. zonemods/status.txt."
  _say("LIVE ON  "+id)
  _write_status()
  return ""
 if is_instance_valid(node):
  _mods.erase(id)
  # free(), rather than a disabled process, also clears cached references in
  # other mods and runs every child's _exit_tree restoration immediately.
  node.free()
  _say("LIVE OFF "+id)
 _write_status()
 return ""
