extends SceneTree
# Run once with a Godot 4 editor binary, not the exported game executable.
func _initialize() -> void:
 var folder=get_script().resource_path.get_base_dir()
 var pack=folder.get_base_dir().path_join("analog400mw/shader.pck")
 if not ProjectSettings.load_resource_pack(pack,true):
  push_error("Could not read the public analog400mw shader pack: "+pack)
  quit(1)
  return
 var text=FileAccess.get_file_as_string("res://ingame/ingame_main.gdshader")
 if not text.begins_with("shader_type canvas_item;"):
  push_error("Unexpected shader pack contents")
  quit(1)
  return
 var output=FileAccess.open(folder.path_join("assets/nito.gdshader"),FileAccess.WRITE)
 if output==null:
  push_error("Cannot write generated video shader")
  quit(1)
  return
 output.store_string(text)
 output.close()
 print("Prepared video_profiles/assets/nito.gdshader from the public mod pack")
 quit()
