extends Node
## analog400mw 2.0 loads through zonemods now. This file is only here so an
## override.cfg from an older version, which still points at it, says what to
## do instead of failing silently.


func _init() -> void:
	if ProjectSettings.has_setting("autoload/ZoneMods"):
		return
	var msg := "analog400mw 2.0 is not loaded: override.cfg in the game folder is from an older version. Replace it with the one from the analog400mw zip."
	print("[analog400mw] " + msg)
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("analog400mw/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string(msg + "\n")
