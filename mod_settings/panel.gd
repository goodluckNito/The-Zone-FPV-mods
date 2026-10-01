extends VBoxContainer
## mod_settings: every mod's settings as a form - a list of the mods, and the
## chosen one's settings: a toggle for true/false, a slider and number box
## for a number, a list for a choice, a text box for text. Built by main.gd,
## as a page over the pause menu and as the overlay the hotkey opens
## (compact: a list to pick the mod from, notes as tooltips). Typing in either
## goes to the box, not the game - main.gd keeps the game's keys out of it.
## Three or more sections in a row - a section per drone - show one at a time,
## picked from a list that starts on the drone being flown.

signal back

const DIM := Color(1, 1, 1, 0.62)
const WARN := Color(1.0, 0.78, 0.35)
const GOOD := Color(0.55, 0.9, 0.55)
const BAD := Color(1.0, 0.45, 0.4)

var host = null               # main.gd
var compact := false
var _mods: Array = []         # ids, in order
var _sel := ""
var _picker: OptionButton = null
var _list: VBoxContainer = null
var _body: VBoxContainer = null
var _scroll: ScrollContainer = null
var _notice: Label = null
var _saved: Label = null
var _pick := {}               # "mod:first section's item" -> the item index picked


func build(h, is_compact: bool, title_hint: String) -> void:
	host = h
	compact = is_compact
	add_theme_constant_override("separation", 8)
	var base := get_theme_default_font_size()
	var bar := HBoxContainer.new()
	bar.name = "Bar"
	bar.add_theme_constant_override("separation", 12)
	add_child(bar)
	if compact:
		var t := Label.new()
		t.text = "Mods" + (" - " + title_hint if title_hint != "" else "")
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.clip_text = true
		bar.add_child(t)
		var x := Button.new()
		x.text = " x "
		x.tooltip_text = "Close (saves)"
		x.pressed.connect(func(): back.emit())
		bar.add_child(x)
		_picker = OptionButton.new()
		_picker.item_selected.connect(func(i): _select(_mods[i]))
		add_child(_picker)
		bar = HBoxContainer.new()
		bar.name = "SaveBar"
		bar.add_theme_constant_override("separation", 12)
		add_child(bar)
	else:
		var b := Button.new()
		b.text = "< Go back"
		b.tooltip_text = "Back to the menu (saves)"
		b.pressed.connect(func(): back.emit())
		bar.add_child(b)
		var t := Label.new()
		t.text = "Mods"
		t.add_theme_font_size_override("font_size", int(base * 1.3))
		bar.add_child(t)
	_saved = Label.new()
	_saved.name = "Saved"
	_saved.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_saved.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_saved.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_saved.clip_text = true
	_saved.add_theme_font_size_override("font_size", maxi(int(base * 0.8), 11))
	bar.add_child(_saved)
	var save := Button.new()
	save.name = "Save"
	save.text = " Save "
	save.tooltip_text = "Changes are saved a moment after you make them; this saves them now"
	save.pressed.connect(func(): host.save_now())
	bar.add_child(save)
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.custom_minimum_size = Vector2(120, 0)
	_notice.add_theme_color_override("font_color", WARN)
	_notice.visible = false
	add_child(_notice)
	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 16)
	add_child(split)
	if not compact:
		var ls := ScrollContainer.new()
		ls.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		ls.custom_minimum_size = Vector2(190, 0)
		split.add_child(ls)
		_list = VBoxContainer.new()
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ls.add_child(_list)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	_scroll.add_child(_body)
	update_state()


## Lists the mods again and shows the chosen one's settings as they are now;
## opened afresh, each drone list starts on the drone being flown again
func refresh(fresh := false) -> void:
	if fresh:
		_pick.clear()
	_mods = host.mod_ids()
	if _sel == "" or not _sel in _mods:
		_sel = _mods[0] if not _mods.is_empty() else ""
	if _picker != null:
		_picker.clear()
		for id in _mods:
			_picker.add_item(host.mod_title(id))
		if _sel != "":
			_picker.select(_mods.find(_sel))
	if _list != null:
		for c in _list.get_children():
			_list.remove_child(c)
			c.queue_free()
		for id in _mods:
			var b := Button.new()
			b.text = host.mod_title(id)
			b.toggle_mode = true
			b.button_pressed = id == _sel
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(_select.bind(id))
			if not host.mod_loaded(id):
				b.modulate = DIM
			_list.add_child(b)
	var at := _scroll.scroll_vertical
	_show(_sel)
	_scroll.set_deferred("scroll_vertical", at)
	update_state()


func _select(id: String) -> void:
	_sel = id
	if _picker != null and _mods.find(id) >= 0 and _picker.selected != _mods.find(id):
		_picker.select(_mods.find(id))
	if _list != null:
		for i in _list.get_child_count():
			(_list.get_child(i) as Button).button_pressed = i < _mods.size() and _mods[i] == id
	_show(id)
	_scroll.scroll_vertical = 0


## The line at the top: what is saved, and which mods wait for a restart
func update_state() -> void:
	var t: String = host.restart_notice()
	_notice.text = t
	_notice.visible = t != ""
	var s: Dictionary = host.save_state()
	_saved.text = s["text"]
	_saved.tooltip_text = s.get("tip", "")
	_saved.add_theme_color_override("font_color", GOOD if s["ok"] and not s["pending"] else (DIM if s["ok"] else BAD))


func update_notice() -> void:
	update_state()


func _show(id: String) -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	if id == "":
		return
	var base := get_theme_default_font_size()
	var head := Label.new()
	head.text = host.mod_title(id)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size = Vector2(120, 0)
	head.add_theme_font_size_override("font_size", int(base * 1.3))
	_body.add_child(head)
	var st := Label.new()
	st.text = host.mod_status(id)
	st.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	st.custom_minimum_size = Vector2(120, 0)
	st.modulate = DIM
	_body.add_child(st)
	var tools := HBoxContainer.new()
	tools.name = "Tools"
	var reset := Button.new()
	reset.name = "Reset"
	reset.text = "Reset to defaults"
	reset.tooltip_text = "Every setting in this mod's settings.cfg back to its default (on/off stays as it is)"
	reset.pressed.connect(func():
		host.reset_mod(id)
		_show(id))
	tools.add_child(reset)
	_body.add_child(tools)
	var vals: Dictionary = host.values(id)
	var items: Array = host.model(id)
	var run_of := {}              # a section's item index -> its run
	for r in _runs(id, items):
		for i in r["sections"]:
			run_of[i] = r
	var run = null                # the run the items are in, or null
	var hidden := false           # in a section of a run that is not the one picked
	for i in items.size():
		var item: Dictionary = items[i]
		match item["kind"]:
			"heading":
				run = null
				hidden = false
				_body.add_child(HSeparator.new())
				var h := Label.new()
				h.text = item["text"]
				h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				h.custom_minimum_size = Vector2(120, 0)
				h.add_theme_font_size_override("font_size", int(base * 1.12))
				_body.add_child(h)
			"section":
				run = run_of.get(i)
				hidden = false
				if item["section"] == "mod":
					continue
				if run != null:
					if i == run["sections"][0]:
						_drone_list(id, run, items)
					hidden = i != run["chosen"]
				elif item["text"] != "":
					var s := Label.new()
					s.text = "[%s]  %s" % [item["section"], item["text"]]
					s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
					s.custom_minimum_size = Vector2(120, 0)
					s.add_theme_font_size_override("font_size", int(base * 1.05))
					_body.add_child(s)
			"note":
				if compact or hidden:
					continue
				_body.add_child(_desc(item["text"]))
			"group":
				# a few settings of a section together, under a small title
				if hidden:
					continue
				var g := Label.new()
				g.text = item["text"]
				g.add_theme_font_size_override("font_size", int(base * 0.95))
				g.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
				_body.add_child(g)
			"value":
				if hidden:
					continue
				var it := item
				if run != null and item["desc"] == "" and run["notes"].has(item["key"]):
					# a drone's setting: the note the same setting has for another
					it = item.duplicate()
					it["desc"] = run["notes"][item["key"]]
					it["shares_note"] = false
				_body.add_child(_row(id, it, vals.get(host.key_of(item), item["default"])))


## Three or more sections in a row, with nothing between them but their own
## settings and notes: {sections (item indexes), key, notes (key -> the note
## the first section with that setting has), chosen}
func _runs(id: String, items: Array) -> Array:
	var runs := []
	var cur := []
	for i in items.size():
		var k: String = items[i]["kind"]
		if k == "heading" or (k == "section" and items[i]["section"] == "mod"):
			_add_run(id, items, runs, cur)
			cur = []
		elif k == "section":
			cur.append(i)
	_add_run(id, items, runs, cur)
	return runs


func _add_run(id: String, items: Array, runs: Array, secs: Array) -> void:
	if secs.size() < 3:
		return
	var notes := {}
	var last := items.size()
	for i in range(secs[0], last):
		var it: Dictionary = items[i]
		if it["kind"] == "heading" or (it["kind"] == "section" and not i in secs):
			break
		if it["kind"] == "value" and it["desc"] != "" and not notes.has(it["key"]):
			notes[it["key"]] = it["desc"]
	var key := "%s:%d" % [id, secs[0]]
	var chosen := int(_pick.get(key, -1))
	if not chosen in secs:
		chosen = _flown_in(items, secs)
	runs.append({"sections": secs.duplicate(), "key": key, "notes": notes, "chosen": chosen})


# the section of the drone being flown, or of the drone it is built on; the
# first if neither is there
func _flown_in(items: Array, secs: Array) -> int:
	var f: Dictionary = host.flown()
	for want in [f["id"], f["base"]]:
		if want == "":
			continue
		for i in secs:
			if items[i]["section"] == want:
				return i
	return secs[0]


## A section's name for the list: its own, the game's name for that drone,
## the start of its note ("65mm Whoop - ..."), or its [name]
func _title(item: Dictionary) -> String:
	if str(item.get("title", "")) != "":
		return str(item["title"])
	var n: String = host.drone_name(item["section"])
	if n != "":
		return n
	var t: String = str(item.get("text", "")).get_slice("\n", 0)
	var dash := t.find(" - ")
	if dash > 0 and dash <= 40:
		return t.substr(0, dash)
	if t != "" and t.length() <= 40:
		return t.trim_suffix(".")
	return item["section"]


# the list to pick a section from, and the picked one's note under it
func _drone_list(id: String, run: Dictionary, items: Array) -> void:
	var f: Dictionary = host.flown()
	var secs: Array = run["sections"]
	var row := HBoxContainer.new()
	row.name = "PickRow"
	row.add_theme_constant_override("separation", 10)
	var lbl := Label.new()
	lbl.text = "Drone" if secs.any(func(i): return host.drone_name(items[i]["section"]) != "") else "Show"
	lbl.add_theme_font_size_override("font_size", int(get_theme_default_font_size() * 1.12))
	row.add_child(lbl)
	var o := OptionButton.new()
	o.name = "Pick"
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.fit_to_longest_item = false
	o.add_theme_font_size_override("font_size", int(get_theme_default_font_size() * 1.12))
	row.add_child(o)
	# the drone flown, or - not in the list - the one it is built on
	var here := secs.any(func(i): return items[i]["section"] == f["id"])
	for i in secs:
		var it: Dictionary = items[i]
		var t := _title(it)
		if it["section"] == f["id"]:
			t += "  (flying)"
		elif not here and f["base"] != "" and it["section"] == f["base"] and f["name"] != "":
			t += "  (the %s you fly is built on it)" % f["name"]
		o.add_item(t)
	o.select(secs.find(run["chosen"]))
	o.item_selected.connect(func(n):
		_pick[run["key"]] = secs[n]
		var at := _scroll.scroll_vertical
		_show(id)
		_scroll.set_deferred("scroll_vertical", at))
	_body.add_child(HSeparator.new())
	_body.add_child(row)
	var it: Dictionary = items[run["chosen"]]
	var text: String = str(it.get("text", ""))
	var title := _title(it)
	if text.begins_with(title + " - "):
		text = text.substr(title.length() + 3)
	elif text.trim_suffix(".") == title:
		text = ""
	if text == "":
		return
	if compact:
		o.tooltip_text = text
	else:
		var d := _desc(text)
		d.name = "PickNote"
		_body.add_child(d)


func _desc(text: String) -> Label:
	var d := Label.new()
	d.text = text
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.modulate = DIM
	d.add_theme_font_size_override("font_size", maxi(int(get_theme_default_font_size() * 0.78), 11))
	d.custom_minimum_size = Vector2(120, 0)
	return d


# Each control is set to its value before it is connected, so only the
# player's changes are sent
func _row(id: String, item: Dictionary, raw: String) -> Control:
	var box := VBoxContainer.new()
	box.name = ("%s__%s" % [item["section"], item["key"]]).validate_node_name()
	box.add_theme_constant_override("separation", 2)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var sec: String = item["section"]
	var key: String = item["key"]
	var is_switch: bool = sec == "mod" and key == "enabled" and str(item.get("file", "")) == ""
	var lbl := Label.new()
	lbl.text = "On" if is_switch else host.label_for(item)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(150 if compact else 220, 0)
	lbl.clip_text = compact
	row.add_child(lbl)
	var file := str(item.get("file", ""))
	var live: bool = host.is_live(id, sec, key, file)
	if not live:
		var r := Label.new()
		r.name = "Restart"
		r.text = "restart"
		r.modulate = DIM
		r.add_theme_font_size_override("font_size", maxi(int(get_theme_default_font_size() * 0.7), 10))
		r.tooltip_text = "Takes effect when the game is next started"
		r.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(r)
	var tip: String = item["desc"]
	if is_switch:
		tip = "Turn %s on or off. Takes effect when the game is next started." % host.mod_name(id)
	var type: int = item["type"]
	var value = preload("cfgdoc.gd").from_raw(raw, type)
	var send := func(v):
		host.set_value(id, sec, key, preload("cfgdoc.gd").to_raw(v, type), file)
	match type:
		TYPE_BOOL:
			var c := CheckButton.new()
			c.name = "Value"
			c.button_pressed = bool(value)
			c.toggled.connect(func(on): send.call(on))
			row.add_child(c)
		TYPE_INT, TYPE_FLOAT:
			_number(row, item, float(value), send)
		_:
			var files: Array = host.files_for(id, str(value)) if item["options"].is_empty() else []
			var opts: Array = item["options"] if not item["options"].is_empty() else files
			if not opts.is_empty():
				var o := OptionButton.new()
				o.name = "Value"
				var list := opts.duplicate()
				if not str(value) in list:
					list.append(str(value))
				var names: Dictionary = item.get("option_names", {}) if item.get("option_names") is Dictionary else {}
				for s in list:
					o.add_item(str(names.get(s, s)) if s != "" else "(none)")
				o.select(list.find(str(value)))
				o.item_selected.connect(func(i): send.call(list[i]))
				o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(o)
			else:
				var e := LineEdit.new()
				e.name = "Value"
				e.text = str(value)
				e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				e.custom_minimum_size = Vector2(160, 0)
				e.placeholder_text = "(empty)"
				var last := [e.text]
				var commit := func(s: String):
					if s != last[0]:
						last[0] = s
						send.call(s)
				e.text_submitted.connect(func(s): commit.call(s))
				e.focus_exited.connect(func(): commit.call(e.text))
				row.add_child(e)
	if compact:
		lbl.tooltip_text = tip
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	elif tip != "" and not item["shares_note"]:
		box.add_child(_desc(tip))
	return box


## A slider over a sensible range and a number box that takes any value;
## the slider stretches to a value typed past its end
func _number(row: HBoxContainer, item: Dictionary, v: float, send: Callable) -> void:
	var d := float(preload("cfgdoc.gd").from_raw(item["default"], item["type"]))
	var is_int: bool = item["type"] == TYPE_INT
	var top := maxf(absf(d) * 2.0, 10.0 if is_int else 1.0)
	var low := -top if d < 0.0 or v < 0.0 else 0.0
	top = maxf(top, v)
	low = minf(low, v)
	var step := 1.0 if is_int or absf(d) >= 20.0 else (0.05 if absf(d) >= 1.0 else 0.01)
	var sl := HSlider.new()
	sl.name = "Slider"
	sl.min_value = low
	sl.max_value = top
	sl.step = step
	sl.value = v
	sl.custom_minimum_size = Vector2(110 if compact else 180, 0)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sp := SpinBox.new()
	sp.name = "Value"
	sp.allow_greater = true
	sp.allow_lesser = true
	sp.min_value = low
	sp.max_value = top
	sp.step = step
	sp.value = v
	sp.custom_minimum_size = Vector2(96, 0)
	sp.select_all_on_focus = true
	sl.value_changed.connect(func(x):
		sp.set_value_no_signal(x)
		send.call(int(round(x)) if is_int else x))
	sp.value_changed.connect(func(x):
		if x > sl.max_value:
			sl.max_value = x
		if x < sl.min_value:
			sl.min_value = x
		sl.set_value_no_signal(x)
		send.call(int(round(x)) if is_int else x))
	# what is typed counts when you press Enter or click away, as the box's own
	sp.get_line_edit().focus_exited.connect(func(): sp.apply())
	row.add_child(sl)
	row.add_child(sp)
