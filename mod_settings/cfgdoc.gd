extends RefCounted
## mod_settings: a mod's settings.default.cfg read as a form, and changed
## values written into its settings.cfg in the same format zonemods keeps.
##
## A settings file is sections of key=value lines with "; " notes. The notes
## straight above a key describe it; ";; ---- Title ----" starts a group; a
## note straight above a [section] describes the section; a paragraph of
## notes on its own (a blank line after it) is shown as text. The file's
## first paragraph is its heading, and not shown; any others before the
## first section are (a file with no [mod] switch at the top, say).

const SEC := "^\\[([^\\]]+)\\]\\s*$"
const KV := "^([A-Za-z0-9_]+)\\s*=\\s*(.*?)\\s*$"


## The form: a list of items, in the file's order -
##   {kind: "heading", text}
##   {kind: "section", section, text}
##   {kind: "note", section, text}
##   {kind: "value", section, key, default (as written), type, desc, options}
## type is TYPE_BOOL, TYPE_INT, TYPE_FLOAT or TYPE_STRING; options are the
## quoted choices a string's note lists, when it lists its own default.
static func parse(text: String) -> Array:
	var sec_re := RegEx.create_from_string(SEC)
	var kv_re := RegEx.create_from_string(KV)
	var items := []
	var pending := PackedStringArray()
	var sec := ""
	var seen_section := false
	var last_was_key := false
	var paras := 0              # paragraphs before the first section
	for raw in text.split("\n"):
		var l := raw.trim_suffix("\r")
		var t := l.strip_edges()
		var sm := sec_re.search(l)
		if sm != null:
			sec = sm.get_string(1)
			if not pending.is_empty() and (seen_section or paras > 0):
				items.append({"kind": "section", "section": sec, "text": _join(pending)})
			else:
				items.append({"kind": "section", "section": sec, "text": ""})
			seen_section = true
			pending.clear()
			last_was_key = false
			continue
		if not seen_section:
			# the heading, then any paragraphs shown as text
			if t.begins_with(";") and not t.begins_with(";;"):
				var c0 := l.strip_edges(true, false).trim_prefix(";")
				pending.append(c0.substr(1) if c0.begins_with(" ") else c0)
			elif t == "" and not pending.is_empty():
				if paras > 0:
					_flush(items, pending, "")
				pending.clear()
				paras += 1
			continue
		if t.begins_with(";;"):
			_flush(items, pending, sec)
			var h := t.trim_prefix(";;").strip_edges().trim_prefix("----").trim_suffix("----").strip_edges()
			if h != "":
				items.append({"kind": "heading", "section": sec, "text": h})
			last_was_key = false
			continue
		if t.begins_with(";"):
			var c := l.strip_edges(true, false).trim_prefix(";")
			if c.begins_with(" "):
				c = c.substr(1)
			pending.append(c)
			last_was_key = false
			continue
		if t == "":
			_flush(items, pending, sec)
			last_was_key = false
			continue
		var km := kv_re.search(l)
		if km == null:
			continue
		var d := km.get_string(2)
		var desc := _join(pending)
		pending.clear()
		var item := {"kind": "value", "section": sec, "key": km.get_string(1), "default": d,
			"type": type_of_raw(d), "desc": desc, "shares_note": desc == "" and last_was_key, "options": []}
		if item["type"] == TYPE_STRING:
			item["options"] = _options(desc, from_raw(d, TYPE_STRING))
		items.append(item)
		last_was_key = true
	_flush(items, pending, sec)
	return items


static func _flush(items: Array, pending: PackedStringArray, sec: String) -> void:
	if not pending.is_empty():
		items.append({"kind": "note", "section": sec, "text": _join(pending)})
		pending.clear()


## Note lines as text to show: a line indented by two spaces starts a line of
## its own (a list), one indented further carries on the line above, and the
## rest run on as a paragraph.
static func _join(lines: PackedStringArray) -> String:
	var out := PackedStringArray()
	var listing := false
	var spaces := RegEx.create_from_string(" {2,}")
	for l in lines:
		var lead := l.length() - l.strip_edges(true, false).length()
		var body := spaces.sub(l.strip_edges(), " ", true)
		if body == "":
			continue
		if out.is_empty():
			out.append(body)
			listing = lead >= 2
		elif lead >= 4 and listing:
			out[out.size() - 1] += " " + body
		elif lead >= 2:
			out.append("  " + body)
			listing = true
		elif listing:
			out.append(body)
			listing = false
		else:
			out[out.size() - 1] += " " + body
	return "\n".join(out)


static func _options(desc: String, value: String) -> Array:
	var re := RegEx.create_from_string("\"([^\"]*)\"")
	var out := []
	for m in re.search_all(desc):
		var o := m.get_string(1)
		if not o in out:
			out.append(o)
	if out.size() >= 2 and value in out:
		return out
	return []


static func type_of_raw(raw: String) -> int:
	var r := raw.strip_edges()
	if r == "true" or r == "false":
		return TYPE_BOOL
	if RegEx.create_from_string("^-?\\d+$").search(r) != null:
		return TYPE_INT
	if RegEx.create_from_string("^-?(\\d+\\.\\d*|\\.\\d+|\\d+(\\.\\d*)?e-?\\d+)$").search(r) != null:
		return TYPE_FLOAT
	return TYPE_STRING


## A value as written, as the type its default has
static func from_raw(raw: String, type: int):
	var r := raw.strip_edges()
	match type:
		TYPE_BOOL:
			return r.to_lower() in ["true", "yes", "on", "1"]
		TYPE_INT:
			return int(r.to_float()) if r.is_valid_float() else 0
		TYPE_FLOAT:
			return r.to_float() if r.is_valid_float() else 0.0
	if r.length() >= 2 and r.begins_with("\"") and r.ends_with("\""):
		return r.substr(1, r.length() - 2).c_unescape()
	return r


## A value written as settings.cfg has it (and Godot's ConfigFile reads it)
static func to_raw(value, type: int) -> String:
	match type:
		TYPE_BOOL:
			return "true" if bool(value) else "false"
		TYPE_INT:
			return str(int(round(float(value))))
		TYPE_FLOAT:
			var s := String.num(float(value), 4)
			if not ("." in s or "e" in s or "inf" in s or "nan" in s):
				s += ".0"
			return s
	return "\"" + str(value).c_escape() + "\""


## "section/key" -> the value as written, for every key=value line
static func values(text: String) -> Dictionary:
	var sec_re := RegEx.create_from_string(SEC)
	var kv_re := RegEx.create_from_string(KV)
	var out := {}
	var sec := ""
	for raw in text.split("\n"):
		var l := raw.trim_suffix("\r")
		var sm := sec_re.search(l)
		if sm != null:
			sec = sm.get_string(1)
			continue
		var km := kv_re.search(l)
		if km != null:
			out[sec + "/" + km.get_string(1)] = km.get_string(2)
	return out


## The text with these "section/key" values put in: each on its own line,
## a key the text has no line for added at the end of its section (or in a
## new section at the end), everything else - notes, order, line endings -
## as it was
static func with_values(text: String, changes: Dictionary) -> String:
	var sec_re := RegEx.create_from_string(SEC)
	var kv_re := RegEx.create_from_string(KV)
	var crlf := text.contains("\r\n")
	var lines := text.replace("\r\n", "\n").split("\n")
	var done := {}
	var sec := ""
	var last_line := {}          # section -> index of its last key line
	for i in lines.size():
		var sm := sec_re.search(lines[i])
		if sm != null:
			sec = sm.get_string(1)
			last_line[sec] = i
			continue
		var km := kv_re.search(lines[i])
		if km == null:
			continue
		var k := sec + "/" + km.get_string(1)
		last_line[sec] = i
		if changes.has(k):
			lines[i] = km.get_string(1) + "=" + str(changes[k])
			done[k] = true
	var out := Array(lines)
	var tail := {}
	# keys with no line yet: after their section's last key, from the bottom up
	var add := []
	for k in changes:
		if done.has(k):
			continue
		var parts := str(k).split("/", true, 1)
		if last_line.has(parts[0]):
			add.append([int(last_line[parts[0]]), parts[1] + "=" + str(changes[k])])
		else:
			if not tail.has(parts[0]):
				tail[parts[0]] = []
			tail[parts[0]].append(parts[1] + "=" + str(changes[k]))
	add.sort_custom(func(a, b): return a[0] > b[0])
	for a in add:
		out.insert(a[0] + 1, a[1])
	for s in tail:
		if not out.is_empty() and str(out[out.size() - 1]) != "":
			out.append("")
		out.append("[%s]" % s)
		out.append("")
		for kv in tail[s]:
			out.append(kv)
	var res := "\n".join(PackedStringArray(out))
	return res.replace("\n", "\r\n") if crlf else res


## Words written as they are said, and the units a number's key can end in
const WORDS := {"mah": "mAh", "mohm": "mOhm", "amps": "A", "hz": "Hz", "db": "dB", "percent": "%",
	"lihv": "LiHV", "lipo": "LiPo", "fov": "FOV", "osd": "OSD", "rssi": "RSSI", "lq": "LQ", "hud": "HUD",
	"pids": "PIDs", "fpv": "FPV", "vtx": "VTX", "inav": "INAV", "kv": "KV", "tpa": "TPA", "iterm": "I term",
	"dterm": "D term", "p": "P", "i": "I", "d": "D", "f": "F"}
const UNITS := ["mm", "ms", "mah", "mohm", "amps", "hz", "db", "percent"]


## "hit_rate" -> "Hit rate"; a number's unit in brackets: "prop_mm" ->
## "Prop (mm)", "capacity_mah" -> "Capacity (mAh)"
static func label(key: String, type := TYPE_NIL) -> String:
	var words := Array(key.split("_", false))
	if words.is_empty():
		return key
	var unit := ""
	if (type == TYPE_INT or type == TYPE_FLOAT) and words.size() > 1 and str(words[-1]) in UNITS:
		unit = str(WORDS.get(words[-1], words[-1]))
		words.pop_back()
	var cap := not WORDS.has(words[0])
	for i in words.size():
		words[i] = WORDS.get(words[i], words[i])
	var s := " ".join(PackedStringArray(words))
	if cap:
		s = s.substr(0, 1).to_upper() + s.substr(1)
	return s + (" (%s)" % unit if unit != "" else "")
