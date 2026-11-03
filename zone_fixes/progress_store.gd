extends RefCounted
static func is_completed(progress: Dictionary,id: String) -> bool:
 var entry=progress.get(id)
 return entry is Dictionary and entry.get("completed")==true
static func completed_only(progress: Dictionary) -> Dictionary:
 var out={}
 for id in progress:
  if id is String and id.length()<=128 and is_completed(progress,id): out[id]={"completed":true}
 return out
static func merge_completed(current: Dictionary,checkpoint: Dictionary) -> Dictionary:
 var result=current.duplicate(true)
 for id in completed_only(checkpoint):
  if not is_completed(result,id): result[id]={"completed":true}
 return result
static func next_track(tracks: Array,progress: Dictionary) -> Dictionary:
 for track in tracks:
  if track is Dictionary and track.has("id") and not is_completed(progress,str(track.id)): return track
 return {}
static func read_checkpoint(path: String) -> Dictionary:
 var file=ConfigFile.new()
 if file.load(path)!=OK: return {}
 var value=file.get_value("progress","completed",{})
 return completed_only(value) if value is Dictionary else {}
static func write_checkpoint(path: String,progress: Dictionary) -> Error:
 var error=DirAccess.make_dir_recursive_absolute(path.get_base_dir())
 if error!=OK: return error
 var file=ConfigFile.new()
 file.set_value("progress","completed",completed_only(progress))
 error=file.save(path+".tmp")
 if error!=OK: return error
 if read_checkpoint(path+".tmp")!=completed_only(progress): return ERR_FILE_CORRUPT
 return DirAccess.rename_absolute(path+".tmp",path)
