extends "res://flight_controller/original_main.gd"
## The compatible wrapper is mounted once, with the controller initially gated
## by the saved setting. Off always delegates to the original game methods.
var lab_ready=false
func _ready() -> void:
 super._ready()
 lab_ready=on
 var saved=ConfigFile.new()
 saved.load(DIR+"settings.cfg")
 lab_set_enabled(bool(saved.get_value("mod","enabled",false)))
func lab_set_enabled(enabled: bool) -> bool:
 if enabled and not lab_ready: return false
 on=enabled and lab_ready
 if not on:
  var scene=get_tree().current_scene
  if scene!=null:
   for body in scene.find_children("*","RigidBody3D",true,false):
    if body.has_method("lab_release_controller"): body.call("lab_release_controller")
 _say("live controller: "+("on" if on else "off, using the original game controller"))
 _write_status()
 return true
func zm_settings_status() -> String:
 return "Переключение на штатный контроллер и обратно применяется сразу." if lab_ready else "Контроллер несовместим с этой сборкой. См. flight_controller/status.txt."
