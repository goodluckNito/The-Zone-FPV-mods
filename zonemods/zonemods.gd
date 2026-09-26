extends Node
## zonemods - loads any number of mods for The Zone FPV.
##
## Registered as an autoload by override.cfg next to the game's exe. It loads
## the mods named in override.cfg's [zonemods] mods= list, in that order, or,
## when that list is empty, every folder next to the exe that holds a
## zonemod.cfg, in name order.
##
## A mod is a folder with a zonemod.cfg:
##     [mod]
##     name="..."        shown in zonemods/status.txt
##     version="..."
##     entry="main.gd"   the script to run; it must extend Node
##     requires=1        the oldest zonemods version it works with
## The entry script is instanced once. If it has zm_init(core, dir), that runs
## at once - before the game loads its first scene, so resource packs loaded
## there take effect - and the node is then added as /root/ZoneMods/<folder>.
## Mods find each other with get_mod(<folder>) or get_mods().
##
## Settings: a mod ships its settings as settings.default.cfg, never as
## settings.cfg, so extracting an update over an install cannot overwrite what
## the player set. Before a mod loads, zonemods makes its settings.cfg from
## settings.default.cfg if there is none; otherwise it rebuilds settings.cfg
## from the (maybe newer) default - its settings, order and notes - with every
## value the player changed put back in, and anything of theirs the default no
## longer has kept at the end. settings.base.cfg records the default each
## settings.cfg was made from, to tell a value the player changed from one the
## mod's default changed.
##
## On and off: every mod's settings start with
##     [mod]
##     enabled=true
## and with enabled=false zonemods leaves that mod unloaded, as if it were not
## installed - so a player turns a mod off in its own settings.cfg instead of
## listing every other mod in override.cfg. A mod without the line is on.

const VERSION := 1

var _mods := {}
var _log := PackedStringArray()


func _init() -> void:
	_say("zonemods %d" % VERSION)
	for id in _mod_list():
		_load(id)
	_write_status()


## The folder next to the game's exe.
static func game_dir() -> String:
	return OS.get_executable_path().get_base_dir()


func get_mod(id: String) -> Node:
	return _mods.get(id)


func get_mods() -> Array:
	return _mods.values()


func _mod_list() -> PackedStringArray:
	var out := PackedStringArray()
	var listed := str(ProjectSettings.get_setting("zonemods/mods", "")).strip_edges()
	if listed != "":
		for s in listed.split(",", false):
			if s.strip_edges() != "":
				out.append(s.strip_edges())
		_say("mods listed in override.cfg: " + ", ".join(out))
		return out
	var d := DirAccess.open(game_dir())
	if d != null:
		for sub in d.get_directories():
			if FileAccess.file_exists(game_dir().path_join(sub).path_join("zonemod.cfg")):
				out.append(sub)
	out.sort()
	_say("mods found: " + (", ".join(out) if out.size() > 0 else "none"))
	return out


func _load(id: String) -> void:
	if not id.is_valid_filename() or id.begins_with("."):
		_say("SKIP %s - not a folder name" % id)
		return
	if _mods.has(id):
		_say("SKIP %s - listed twice" % id)
		return
	var dir := "res://%s/" % id
	var cfg := ConfigFile.new()
	if cfg.load(dir + "zonemod.cfg") != OK:
		_say("SKIP %s - no zonemod.cfg in that folder" % id)
		return
	var requires := int(cfg.get_value("mod", "requires", 1))
	if requires > VERSION:
		_say("SKIP %s - needs zonemods %d or newer (this is %d)" % [id, requires, VERSION])
		return
	_settings(id)
	if not _enabled(id):
		var what := "%s %s" % [cfg.get_value("mod", "name", id), cfg.get_value("mod", "version", "")]
		_say("OFF  %s - enabled=false in %s/settings.cfg" % [what, id])
		var f := FileAccess.open(game_dir().path_join(id).path_join("status.txt"), FileAccess.WRITE)
		if f != null:
			f.store_string("%s is off: enabled=false in settings.cfg. Set it to true and restart the game to turn it back on.\n" % what)
		return
	var entry := str(cfg.get_value("mod", "entry", "main.gd"))
	var script = load(dir + entry)
	if not (script is Script) or not script.can_instantiate():
		_say("SKIP %s - could not load %s" % [id, entry])
		return
	var node = script.new()
	if not (node is Node):
		if node is Object and not (node is RefCounted):
			node.free()
		_say("SKIP %s - %s does not extend Node" % [id, entry])
		return
	node.name = id
	if node.has_method("zm_init"):
		node.zm_init(self, dir)
	add_child(node)
	_mods[id] = node
	_say("OK   %s %s" % [cfg.get_value("mod", "name", id), cfg.get_value("mod", "version", "")])


func _settings(id: String) -> void:
	var dir := game_dir().path_join(id)
	var def_p := dir.path_join("settings.default.cfg")
	if not FileAccess.file_exists(def_p):
		return
	var def_text := FileAccess.get_file_as_string(def_p)
	var usr_p := dir.path_join("settings.cfg")
	var base_p := dir.path_join("settings.base.cfg")
	var out := def_text
	var what := "settings.cfg made from settings.default.cfg"
	if FileAccess.file_exists(usr_p):
		var usr_text := FileAccess.get_file_as_string(usr_p)
		var usr := _cfg_values(usr_text)
		var base = _cfg_values(FileAccess.get_file_as_string(base_p)) if FileAccess.file_exists(base_p) else null
		var keep := {}
		for k in usr:
			if base == null or not base.has(k) or base[k] != usr[k]:
				keep[k] = usr[k]
		# in the line endings the file has now, so an editor's choice is kept
		var src := def_text.replace("\r\n", "\n")
		if usr_text.contains("\r\n"):
			src = src.replace("\n", "\r\n")
		out = _cfg_rebuild(src, keep)
		if out == usr_text:
			what = ""
		else:
			var dv := _cfg_values(def_text)
			var added := 0
			for k in dv:
				if not usr.has(k):
					added += 1
			what = "settings.cfg brought up to date: %d of your settings kept, %d new" % [keep.size(), added]
	if what != "":
		var f := FileAccess.open(usr_p, FileAccess.WRITE)
		if f == null:
			_say("     %s: could not write settings.cfg (%s)" % [id, error_string(FileAccess.get_open_error())])
			return
		f.store_string(out)
		f.close()
		_say("     %s: %s" % [id, what])
	if not FileAccess.file_exists(base_p) or FileAccess.get_file_as_string(base_p) != def_text:
		var b := FileAccess.open(base_p, FileAccess.WRITE)
		if b != null:
			b.store_string(def_text)


# settings.cfg's [mod] enabled=: anything but false/no/off/0 is on
func _enabled(id: String) -> bool:
	var p := game_dir().path_join(id).path_join("settings.cfg")
	if not FileAccess.file_exists(p):
		return true
	var v := str(_cfg_values(FileAccess.get_file_as_string(p)).get("mod/enabled", "true"))
	v = v.strip_edges().trim_prefix("\"").trim_suffix("\"").strip_edges().to_lower()
	return not (v in ["false", "no", "off", "0"])


# "section/key" -> the value as written, for every key=value line
static func _cfg_values(text: String) -> Dictionary:
	var out := {}
	var sec := ""
	for line in text.split("\n"):
		var l := line.trim_suffix("\r")
		var sm := _SEC.search(l)
		if sm != null:
			sec = sm.get_string(1)
			continue
		var km := _KV.search(l)
		if km != null:
			out[sec + "/" + km.get_string(1)] = km.get_string(2)
	return out


# The default's text with the given values put in, and those it has no line
# for added at the end
static func _cfg_rebuild(def_text: String, keep: Dictionary) -> String:
	var nl := "\r\n" if def_text.contains("\r\n") else "\n"
	var lines := def_text.split("\n")
	var used := {}
	var sec := ""
	for i in lines.size():
		var l := lines[i].trim_suffix("\r")
		var sm := _SEC.search(l)
		if sm != null:
			sec = sm.get_string(1)
			continue
		var km := _KV.search(l)
		if km != null and keep.has(sec + "/" + km.get_string(1)):
			var k := sec + "/" + km.get_string(1)
			lines[i] = km.get_string(1) + "=" + str(keep[k]) + ("\r" if lines[i].ends_with("\r") else "")
			used[k] = true
	var text := "\n".join(lines)
	var rest := {}
	for k in keep:
		if not used.has(k):
			var parts: PackedStringArray = str(k).split("/", true, 1)
			if not rest.has(parts[0]):
				rest[parts[0]] = []
			rest[parts[0]].append(parts[1] + "=" + str(keep[k]))
	if rest.is_empty():
		return text
	if not text.ends_with(nl):
		text += nl
	text += nl + "; ---- Kept from your settings.cfg: not in this version's defaults ----" + nl
	for s in rest:
		text += nl + ("[%s]" % s if s != "" else "") + nl
		for kv in rest[s]:
			text += str(kv) + nl
	return text


static var _SEC := RegEx.create_from_string("^\\[([^\\]]+)\\]\\s*$")
static var _KV := RegEx.create_from_string("^([A-Za-z0-9_]+)\\s*=\\s*(.*?)\\s*$")


func _say(s: String) -> void:
	_log.append(s)
	print("[zonemods] " + s)


func _write_status() -> void:
	var f := FileAccess.open(game_dir().path_join("zonemods/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
