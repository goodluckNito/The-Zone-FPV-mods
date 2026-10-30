extends SceneTree
func _initialize() -> void:
 var root=get_script().resource_path.get_base_dir().get_base_dir()
 var store=load(root.path_join("zone_fixes/progress_store.gd"))
 var current={"one":{"completed":true},"metadata":{"note":"keep"},"unfinished":{"completed":false}}
 var saved={"two":{"completed":true},"unfinished":{"completed":false},"bad":true}
 var merged=store.merge_completed(current,saved)
 assert(merged.has("two") and merged.metadata.note=="keep")
 assert(not current.has("two") and not merged.has("bad"))
 assert(store.completed_only(merged).size()==2)
 assert(store.next_track([{"id":"one"},{"id":"two"},{"id":"three"}],merged).id=="three")
 assert(store.next_track([{"id":"one"}],merged).is_empty())
 var path="user://zone_fixes_test/progress.cfg"
 assert(store.write_checkpoint(path,current)==OK)
 assert(store.write_checkpoint(path,merged)==OK,"atomic replacement must work on an existing checkpoint")
 assert(store.read_checkpoint(path)==store.completed_only(merged))
 DirAccess.remove_absolute(path)
 DirAccess.remove_absolute(path.get_base_dir())
 for name in ["main","tutorial_progress","esc_navigation"]:
  var script=load(root.path_join("zone_fixes/"+name+".gd"))
  assert(script!=null and script.can_instantiate())
 print("PASS progress: completed-only recovery, nonmutation, next lesson, verified replacement; fixes parse")
 quit()
