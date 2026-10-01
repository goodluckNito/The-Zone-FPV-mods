extends Node
## mod_settings 1.0
##
## Every mod's settings in the game: a "Mods" page in the pause menu, and the
## same as an overlay a key opens while you fly, so you see a change as you
## make it. Loaded by zonemods (override.cfg in the game folder).
##
## It reads each mod's settings.default.cfg as a form (panel.gd, cfgdoc.gd)
## and writes what you change into that mod's settings.cfg, exactly as an edit
## by hand would - so zonemods keeps it across updates. Then, if the mod can
## take it while the game runs, it asks the mod to: a mod that has
##     func zm_apply_settings() -> void
## is called a moment after a change, and reads its settings.cfg again. A mod
## can list settings that still need a restart in
##     func zm_restart_keys() -> PackedStringArray    # "section/key", "section/*"
## Turning a mod on or off always needs one, as does anything of a mod
## without zm_apply_settings; the page marks those and says so.
## A mod whose settings do nothing just now (another mod has taken over)
## can say so, shown in place of the page's usual line, with
##     func zm_settings_status() -> String     # "" when they do
## and can show settings kept in another .cfg file of its folder on its page
## (the drones mod: the drones in my_drones.cfg), written into that file:
##     func zm_settings_more() -> Array
## items as cfgdoc.gd makes them, each with "file" (the file's name) and
## optionally "label" and "title" (a section's name); a restart key for one
## is "file|section/key". Three or more sections in a row (the game's drones,
## say) show one at a time, picked from a list that starts on the drone being
## flown - or the one it is built on, for a drone a mod adds (zm_vehicle).
##
## Uninstall: delete the mod_settings folder.

const VERSION := "1.0"
const DIR := "res://mod_settings/"
const DOC := preload("res://mod_settings/cfgdoc.gd")
const PANEL := preload("res://mod_settings/panel.gd")
const PAUSE_SCRIPT := "res://menus/pause_menu/pause_menu"
const DEFAULTS := {"hotkey": "F9", "overlay_width": 480}

var cfg := {}
var _core: Node = null
var _mods := {}               # id -> {name, version, def, model}
var _order: Array = []
var _pending := {}            # id -> {key_of(item): value as written}
var _restart := {}            # id -> {key_of(item): true}: changed, taking effect at the next start
var _names := {}              # the game's drones: id -> name, read when first wanted
var _timer: Timer = null
var _key := KEY_F9
var _pm: Control = null       # the game's pause menu
var _split: Control = null    # its menu and drone preview, hidden under the page
var _page: Control = null
var _page_box: PanelContainer = null
var _page_panel = null
var _main_menu: Control = null
var _layer: CanvasLayer = null
var _overlay = null
var _overlay_box: PanelContainer = null
var _guard: Node = null
var _saved_at := ""
var _save_error := ""
var _log := PackedStringArray()


## Sees the keys before the game does (the last node in the tree has _input
## first), so that typing into a box here does not reset the drone (R),
## open the chat (Enter) or pause (Esc)
class KeyGuard extends Node:
	var mod = null
	func _input(event: InputEvent) -> void:
		if mod != null and is_instance_valid(mod):
			mod.guard_key(event)


func zm_init(core: Node, _dir: String) -> void:
	_core = core
	_keep_last_status()
	_say("mod_settings %s" % VERSION)
	_read_settings()
	_discover()
	_write_status()


# after every mod's zm_init: which of them take changes at once
func _summary() -> void:
	var live := PackedStringArray()
	var later := PackedStringArray()
	for id in _order:
		if not mod_loaded(id):
			later.append("%s (not loaded)" % id)
		elif _node(id).has_method("zm_apply_settings"):
			live.append(id)
		else:
			later.append(id)
	_say("%d mods with settings - changes apply at once: %s; at the next start: %s" % [_order.size(),
		", ".join(live) if not live.is_empty() else "none", ", ".join(later) if not later.is_empty() else "none"])
	_say("the Mods page is in the pause menu; %s opens it while flying" % OS.get_keycode_string(_key))
	_write_status()


func _read_settings() -> void:
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(DIR + "settings.cfg") == OK and c.has_section("mod_settings"):
		for k in c.get_section_keys("mod_settings"):
			if cfg.has(k):
				cfg[k] = c.get_value("mod_settings", k)
	_key = OS.find_keycode_from_string(str(cfg["hotkey"]))
	if _key == KEY_NONE:
		_say("hotkey: no key called \"%s\"; F9 instead" % str(cfg["hotkey"]))
		_key = KEY_F9


## Its own settings, changed on its own page: the key and the overlay's width
func zm_apply_settings() -> void:
	_read_settings()
	if _overlay_box != null:
		_overlay_box.offset_left = -clampf(float(cfg["overlay_width"]), 300.0, 1600.0) - 16.0
	_say("hotkey %s, overlay %d px wide" % [OS.get_keycode_string(_key), int(cfg["overlay_width"])])


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_summary()
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.25
	_timer.timeout.connect(_flush)
	add_child(_timer)
	get_tree().node_added.connect(_on_node_added)
	_guard = KeyGuard.new()
	_guard.name = "ModSettingsKeys"
	_guard.mod = self
	_guard.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().get_root().add_child.call_deferred(_guard)
	get_tree().get_root().size_changed.connect(_size_page)
	# the overlay: over the picture, on the right, hidden until the hotkey
	_layer = CanvasLayer.new()
	_layer.layer = 90
	_layer.visible = false
	add_child(_layer)
	_overlay_box = PanelContainer.new()
	_overlay_box.add_theme_stylebox_override("panel", _box_style(0.86))
	_overlay_box.anchor_left = 1.0
	_overlay_box.anchor_right = 1.0
	_overlay_box.anchor_top = 0.0
	_overlay_box.anchor_bottom = 1.0
	_overlay_box.offset_left = -clampf(float(cfg["overlay_width"]), 300.0, 1600.0) - 16.0
	_overlay_box.offset_right = -16.0
	_overlay_box.offset_top = 16.0
	_overlay_box.offset_bottom = -16.0
	_layer.add_child(_overlay_box)
	_overlay = PANEL.new()
	_overlay.build(self, true, OS.get_keycode_string(_key) + " closes")
	_overlay.back.connect(func(): show_overlay(false))
	_overlay_box.add_child(_overlay)


func _box_style(alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, alpha)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	return sb


func _notification(what: int) -> void:
	# nothing changed is lost to quitting straight after
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_flush(false)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == _key:
		show_overlay(not _layer.visible)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# the pause menu has its own page: the overlay goes while paused
	if _layer != null and _layer.visible:
		var gs := get_node_or_null("/root/ZGamestate")
		if gs != null and gs.get("is_paused") == true:
			show_overlay(false)


func show_overlay(on: bool) -> void:
	if on:
		_overlay.refresh(true)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_stop_typing(_overlay_box)
		_flush()
	_layer.visible = on


# ---- typing ----

## The text box being typed into, if it is one of this mod's
func _typing_into() -> LineEdit:
	var f := get_viewport().gui_get_focus_owner()
	if not (f is LineEdit) or not f.is_visible_in_tree() or not (f as LineEdit).editable:
		return null
	var mine := false
	for box in [_overlay_box, _page]:
		if box != null and is_instance_valid(box) and box.is_ancestor_of(f):
			mine = true
	if not mine:
		return null
	if f.has_method("is_editing") and not bool(f.call("is_editing")):
		return null
	return f


## A key while a box here is being typed into: the characters are typed into
## it here, so the game (R: reset, T: flip, S/X: spawn point, Enter: chat,
## Esc: pause) and other mods never see them; Backspace, arrows and the like
## go to the box as usual
func guard_key(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	var le := _typing_into()
	if le == null:
		return
	var vp := get_viewport()
	if k.keycode == KEY_ESCAPE or k.is_action_pressed("ui_cancel"):
		vp.set_input_as_handled()
		_done_typing(le)
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		vp.set_input_as_handled()
		le.text_submitted.emit(le.text)
		_done_typing(le)
		return
	if k.ctrl_pressed or k.meta_pressed or k.alt_pressed:
		# the game takes R, T, S and X whatever else is held
		if k.keycode in [KEY_R, KEY_T, KEY_S, KEY_X]:
			vp.set_input_as_handled()
			if k.keycode == KEY_X and le.has_selection():
				DisplayServer.clipboard_set(le.get_selected_text())
				_type(le, "")
		return
	if k.unicode >= 32:
		vp.set_input_as_handled()
		_type(le, String.chr(k.unicode))


func _type(le: LineEdit, s: String) -> void:
	if le.has_selection():
		var a := le.get_selection_from_column()
		var b := le.get_selection_to_column()
		le.deselect()
		le.delete_text(a, b)
		le.caret_column = a
	if s != "":
		le.insert_text_at_caret(s)


func _done_typing(le: LineEdit) -> void:
	if le.has_method("unedit"):
		le.call("unedit")
	le.release_focus()


func _stop_typing(box: Control) -> void:
	var f := get_viewport().gui_get_focus_owner()
	if f != null and box != null and is_instance_valid(box) and box.is_ancestor_of(f):
		f.release_focus()


# ---- the pause menu's page ----

func _on_node_added(node: Node) -> void:
	var s: Script = node.get_script()
	if s != null and s.resource_path.get_basename() == PAUSE_SCRIPT:
		_hook_pause.call_deferred(node)
	# the key guard stays the last thing in the tree (a new scene comes after it)
	if _guard != null and node != _guard and node.get_parent() == get_tree().get_root():
		_guard_last.call_deferred()


func _guard_last() -> void:
	var root := get_tree().get_root()
	if is_instance_valid(_guard) and _guard.get_parent() == root and _guard.get_index() != root.get_child_count() - 1:
		root.move_child(_guard, -1)


## Adds a "Mods" button under Game Settings, opening a page over the whole
## pause menu (the game gives its own pages half the screen, beside the
## drone; this one needs the room)
func _hook_pause(pm: Node) -> void:
	if not is_instance_valid(pm) or pm.has_meta("mod_settings"):
		return
	pm.set_meta("mod_settings", true)
	var main_menu := pm.get_node_or_null("%MainMenu") as Control
	var split := pm.get_node_or_null("HSplitContainer") as Control
	if main_menu == null or split == null or not pm is Control:
		_say("pause menu: not as expected (no MainMenu or HSplitContainer) - use %s" % OS.get_keycode_string(_key))
		_write_status()
		return
	_pm = pm
	_split = split
	_main_menu = main_menu
	var after := main_menu.get_node_or_null("GameSettings") as Button
	# a copy of Game Settings' button, so it looks the same - without its
	# connections
	var btn: Button = after.duplicate(0) if after != null else Button.new()
	btn.name = "Mods"
	btn.text = " Mods "
	btn.unique_name_in_owner = false
	btn.visible = true
	main_menu.add_child(btn)
	if after != null:
		main_menu.move_child(btn, after.get_index() + 1)
	_page = Control.new()
	_page.name = "ModSettings"
	_page.visible = false
	_page.mouse_filter = Control.MOUSE_FILTER_STOP
	pm.add_child(_page)
	_page_box = PanelContainer.new()
	_page_box.add_theme_stylebox_override("panel", _box_style(0.72))
	_page.add_child(_page_box)
	_page_panel = PANEL.new()
	_page_panel.build(self, false, "")
	_page_box.add_child(_page_panel)
	_page_panel.back.connect(_close_page)
	btn.pressed.connect(_open_page)
	_pm.visibility_changed.connect(_on_pause_shown)
	_say("pause menu: Mods page added")
	_write_status()


func _open_page() -> void:
	if not _page_ok():
		return
	_size_page()
	_page_panel.refresh(true)
	_split.visible = false
	_page.visible = true


func _close_page() -> void:
	if not _page_ok():
		return
	_stop_typing(_page)
	_flush()
	_page.visible = false
	_split.visible = true
	if is_instance_valid(_main_menu):
		_main_menu.visible = true


# resumed: what was changed is saved; paused again: the page shows the
# settings as they are now (the overlay may have changed some)
func _on_pause_shown() -> void:
	if not _page_ok():
		return
	if not _pm.is_visible_in_tree():
		_stop_typing(_page)
		_flush()
	elif _page.visible:
		_size_page()
		_page_panel.refresh()


func _page_ok() -> bool:
	return _page != null and is_instance_valid(_page) and is_instance_valid(_split) and is_instance_valid(_pm)


## The whole window, the panel inside it at most 1500 px wide
func _size_page() -> void:
	if not _page_ok():
		return
	var vs := get_viewport().get_visible_rect().size
	_page.global_position = Vector2.ZERO
	_page.size = vs
	var m := clampf(vs.y * 0.045, 12.0, 48.0)
	var w := minf(vs.x - 2.0 * m, 1500.0)
	_page_box.position = Vector2(roundf((vs.x - w) / 2.0), m)
	_page_box.size = Vector2(w, vs.y - 2.0 * m)


# ---- the mods and their settings ----

## Every folder next to the game with a zonemod.cfg and settings - loaded
## or not, so a mod that is off can be turned on here
func _discover() -> void:
	var gd := OS.get_executable_path().get_base_dir()
	var dirs := Array(DirAccess.get_directories_at(gd))
	dirs.sort()
	for sub in dirs:
		var zc := gd.path_join(sub).path_join("zonemod.cfg")
		var dp := gd.path_join(sub).path_join("settings.default.cfg")
		if not FileAccess.file_exists(zc) or not FileAccess.file_exists(dp):
			continue
		var z := ConfigFile.new()
		z.load(zc)
		var def := FileAccess.get_file_as_string(dp)
		_mods[sub] = {"name": str(z.get_value("mod", "name", sub)), "version": str(z.get_value("mod", "version", "")),
			"def": def, "model": DOC.parse(def)}
		_order.append(sub)


func _node(id: String) -> Node:
	if _core == null or not _core.has_method("get_mod"):
		return null
	var n = _core.call("get_mod", id)
	return n if n is Node and is_instance_valid(n) else null


func _path(id: String) -> String:
	return OS.get_executable_path().get_base_dir().path_join(id).path_join("settings.cfg")


func mod_ids() -> Array:
	return _order.duplicate()


func mod_title(id: String) -> String:
	var m: Dictionary = _mods[id]
	return "%s %s" % [m["name"], m["version"]]


func mod_name(id: String) -> String:
	return str(_mods[id]["name"])


func mod_loaded(id: String) -> bool:
	return _node(id) != null


## The form: settings.default.cfg's, then any the mod adds from its other
## files (zm_settings_more)
func model(id: String) -> Array:
	var items: Array = _mods[id]["model"]
	var n := _node(id)
	if n == null or not n.has_method("zm_settings_more"):
		return items
	var more = n.call("zm_settings_more")
	if not (more is Array) or more.is_empty():
		return items
	var out := items.duplicate()
	for it in more:
		if it is Dictionary and _plain_file(str(it.get("file", ""))) and it.has("section") \
				and (str(it.get("kind", "value")) != "value" or it.has("key")):
			out.append(_complete(it))
	return out


# a file in the mod's own folder, by name, and not its settings
static func _plain_file(f: String) -> bool:
	return f != "" and f == f.get_file() and not f.begins_with(".") and f.get_extension() == "cfg" \
		and not f.begins_with("settings.")


static func _complete(it: Dictionary) -> Dictionary:
	var d := it.duplicate()
	d["kind"] = str(d.get("kind", "value"))
	d["section"] = str(d["section"])
	d["text"] = str(d.get("text", ""))
	if d["kind"] == "value":
		d["key"] = str(d["key"])
		d["default"] = str(d.get("default", ""))
		if not d.has("type"):
			d["type"] = DOC.type_of_raw(d["default"])
		d["desc"] = str(d.get("desc", ""))
		d["shares_note"] = bool(d.get("shares_note", false))
		if not (d.get("options") is Array):
			d["options"] = []
	return d


## An item's value, as values() keys it: "section/key" in settings.cfg,
## "file|section/key" in another file
static func key_of(item: Dictionary) -> String:
	var f := str(item.get("file", ""))
	return (f + "|" if f != "" else "") + str(item["section"]) + "/" + str(item["key"])


func label_for(item: Dictionary) -> String:
	if str(item.get("label", "")) != "":
		return str(item["label"])
	return DOC.label(item["key"], int(item.get("type", TYPE_NIL)))


func _file_path(id: String, file: String) -> String:
	return _path(id) if file == "" else OS.get_executable_path().get_base_dir().path_join(id).path_join(file)


## What the settings files say now, with the changes not yet written on top
func values(id: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(_path(id)) if FileAccess.file_exists(_path(id)) else str(_mods[id]["def"])
	var v := DOC.values(text)
	var files := {}
	for item in model(id):
		var f := str(item.get("file", ""))
		if f != "" and not files.has(f):
			files[f] = true
			var p := _file_path(id, f)
			if FileAccess.file_exists(p):
				var fv := DOC.values(FileAccess.get_file_as_string(p))
				for k in fv:
					v[f + "|" + k] = fv[k]
	if _pending.has(id):
		for k in _pending[id]:
			v[k] = _pending[id][k]
	return v


## The game's drones, id -> name, for the list a mod's drone sections are
## picked from. Read when first wanted - long after the drones mod has put its
## list in, so its drones are there too.
func drone_name(id: String) -> String:
	if _names.is_empty():
		_names["-"] = ""
		var p := "res://common/default_vehicles.gd"
		if ResourceLoader.exists(p) or FileAccess.file_exists(p + ".remap"):
			var s = load(p)
			if s is Script and s.has_method("get_vehicles"):
				var list = s.call("get_vehicles")
				if list is Array:
					for v in list:
						if v is Dictionary and v.has("id"):
							_names[str(v["id"])] = str(v.get("name", v["id"]))
	return str(_names.get(id, ""))


## The drone being flown: {"id", "name", "base"} - base and name for a drone a
## mod adds (its zm_vehicle), so the page can show what it is built on
func flown() -> Dictionary:
	var gs := get_node_or_null("/root/ZGamestate")
	var v = gs.get("selected_vehicle_id") if gs != null else null
	var out := {"id": str(v) if v != null else "", "name": "", "base": ""}
	if out["id"] == "" or _core == null or not _core.has_method("get_mods"):
		return out
	for m in _core.call("get_mods"):
		if is_instance_valid(m) and m.has_method("zm_vehicle"):
			var d = m.call("zm_vehicle", out["id"])
			if d is Dictionary and not d.is_empty():
				out["name"] = str(d.get("name", out["id"]))
				out["base"] = str(d.get("base", ""))
				break
	return out


func mod_status(id: String) -> String:
	var n := _node(id)
	# a mod can say why its settings do nothing just now
	if n != null and n.has_method("zm_settings_status"):
		var note := str(n.call("zm_settings_status"))
		if note != "":
			return note
	if n == null:
		var on := str(values(id).get("mod/enabled", "true")).to_lower() != "false"
		return "Not loaded (%s). Changes here take effect when the game is next started." % ("off" if not on else "see zonemods/status.txt")
	if n.has_method("zm_apply_settings"):
		return "Changes take effect at once, except those marked restart."
	return "Changes take effect when the game is next started."


func is_live(id: String, sec: String, key: String, file := "") -> bool:
	if sec == "mod" and key == "enabled" and file == "":
		return false
	var n := _node(id)
	if n == null or not n.has_method("zm_apply_settings"):
		return false
	if n.has_method("zm_restart_keys"):
		var pre := (file + "|" if file != "" else "") + sec + "/"
		var keys = n.call("zm_restart_keys")
		for k in keys:
			var s := str(k)
			if s == pre + key or s == pre + "*":
				return false
	return true


## A file setting (a font, say): the files of that kind in the mod's folder
## and its fonts folder; or, for a value in a folder of the mod's
## ("crosshairs/reticle.png"), the files of that kind in that folder
func files_for(id: String, value: String) -> Array:
	var ext := value.get_extension().to_lower()
	var sub := value.get_base_dir()
	if ext == "" or ext.length() > 4 or sub.contains("/") or sub.begins_with(".") or sub.contains(":"):
		return []
	var out := []
	var base := OS.get_executable_path().get_base_dir().path_join(id)
	for s in ([sub] if sub != "" else ["", "fonts"]):
		var d := base.path_join(s)
		if not DirAccess.dir_exists_absolute(d):
			continue
		for f in DirAccess.get_files_at(d):
			var n: String = (s + "/" + f) if sub != "" else f
			if f.get_extension().to_lower() == ext and not n in out:
				out.append(n)
	out.sort()
	return out if value in out else []


## A change from the page: written and applied a moment after the last one,
## so dragging a slider does not write the file at every step
func set_value(id: String, sec: String, key: String, raw: String, file := "") -> void:
	if not _pending.has(id):
		_pending[id] = {}
	var k := (file + "|" if file != "" else "") + sec + "/" + key
	_pending[id][k] = raw
	if not is_live(id, sec, key, file):
		if not _restart.has(id):
			_restart[id] = {}
		_restart[id][k] = true
	if _timer != null and _timer.is_inside_tree():
		_timer.start()
	else:
		_flush()
	_update_panels()


func reset_mod(id: String) -> void:
	for item in _mods[id]["model"]:
		if item["kind"] == "value" and not (item["section"] == "mod" and item["key"] == "enabled"):
			set_value(id, item["section"], item["key"], item["default"])
	_flush()


## The Save button: what is waiting, written now
func save_now() -> void:
	_flush()
	if _save_error == "":
		_saved_at = Time.get_time_string_from_system()
	_update_panels()


## For the line by the Save button
func save_state() -> Dictionary:
	if _save_error != "":
		return {"ok": false, "pending": not _pending.is_empty(), "text": "NOT SAVED - " + _save_error,
			"tip": "See mod_settings/status.txt in the game folder"}
	if not _pending.is_empty():
		return {"ok": true, "pending": true, "text": "Saving...", "tip": ""}
	if _saved_at == "":
		return {"ok": true, "pending": true, "text": "Changes save as you make them",
			"tip": "Into each mod's settings.cfg, a moment after each change"}
	return {"ok": true, "pending": false, "text": "Saved %s" % _saved_at,
		"tip": "Written into each mod's settings.cfg in the game folder"}


## Writes the changes waiting, checks they read back, and then has each mod
## that can take them read its settings again
func _flush(apply := true) -> void:
	if _timer != null:
		_timer.stop()
	if _pending.is_empty():
		return
	var done := {}
	var failed := PackedStringArray()
	for id in _pending.keys():
		var changes: Dictionary = _pending[id]
		# by file: settings.cfg, and any other the mod's page shows
		var by_file := {}
		for k in changes:
			var sk := str(k)
			var f := sk.get_slice("|", 0) if sk.contains("|") else ""
			if f != "":
				sk = sk.substr(f.length() + 1)
			if not by_file.has(f):
				by_file[f] = {}
			by_file[f][sk] = changes[k]
		var p := _path(id)
		var err := ""
		for f in by_file:
			p = _file_path(id, f)
			var text := ""
			if FileAccess.file_exists(p):
				text = FileAccess.get_file_as_string(p)
			elif f == "":
				text = str(_mods[id]["def"])
			else:
				err = "it is not there"
				break
			err = _write(p, DOC.with_values(text, by_file[f]))
			if err == "":
				var back := DOC.values(FileAccess.get_file_as_string(p))
				for k in by_file[f]:
					if str(back.get(k, "")) != str(by_file[f][k]):
						err = "%s reads back as %s" % [k, str(back.get(k, "nothing"))]
						break
			if err != "":
				break
		if err != "":
			failed.append("%s: %s" % [id, err])
			_say("%s: NOT SAVED (%s) - %s" % [id, p, err])
			continue
		done[id] = changes
		_say("%s: %s" % [id, ", ".join(PackedStringArray(changes.keys().map(func(k): return "%s=%s" % [k, changes[k]])))])
	for id in done:
		_pending.erase(id)
	_save_error = "; ".join(failed)
	if not done.is_empty() and failed.is_empty():
		_saved_at = Time.get_time_string_from_system()
	_write_status()
	if apply:
		for id in done:
			var any_live := false
			for k in done[id]:
				var sk := str(k)
				var f := sk.get_slice("|", 0) if sk.contains("|") else ""
				var parts := sk.substr(f.length() + 1 if f != "" else 0).split("/", true, 1)
				if is_live(id, parts[0], parts[1], f):
					any_live = true
			var n := _node(id)
			if any_live and n != null:
				n.call("zm_apply_settings")
	_update_panels()


func _write(p: String, text: String) -> String:
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return "could not open it to write (%s)" % error_string(FileAccess.get_open_error())
	f.store_string(text)
	var e := f.get_error()
	f.close()
	return "" if e == OK else "could not write it (%s)" % error_string(e)


func _update_panels() -> void:
	for p in [_overlay, _page_panel]:
		if p != null and is_instance_valid(p) and p.is_inside_tree():
			p.update_state()


func restart_notice() -> String:
	var parts := PackedStringArray()
	for id in _order:
		if _restart.has(id) and not _restart[id].is_empty():
			parts.append(_mods[id]["name"])
	if parts.is_empty():
		return ""
	return "Restart the game for the changes marked restart to take effect: " + ", ".join(parts) + "."


func _say(s: String) -> void:
	_log.append(s)
	if _log.size() > 400:
		_log = _log.slice(_log.size() - 300)
	print("[mod_settings] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("mod_settings/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")


# the last run's status.txt, kept as status.last.txt
func _keep_last_status() -> void:
	var d := OS.get_executable_path().get_base_dir().path_join("mod_settings")
	if FileAccess.file_exists(d.path_join("status.txt")):
		var f := FileAccess.open(d.path_join("status.last.txt"), FileAccess.WRITE)
		if f != null:
			f.store_string(FileAccess.get_file_as_string(d.path_join("status.txt")))
