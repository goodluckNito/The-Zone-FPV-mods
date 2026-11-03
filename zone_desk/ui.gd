extends RefCounted
## Shared native controls. Sizes are logical pixels; Godot handles display DPI.

const INK = Color("e9eff5")
const MUTED = Color("91a3b4")
const ACCENT = Color("91e6c6")
const PANEL = Color("141e29")

static func box(color: Color, radius: int = 12, margin: int = 16) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(margin)
	return s

static func theme() -> Theme:
	var t = Theme.new()
	var font = SystemFont.new()
	font.font_names = PackedStringArray(["Inter", "SF Pro Text", "Helvetica Neue"])
	t.default_font = font
	t.default_font_size = 17
	for kind in ["Label", "Button", "CheckButton", "OptionButton", "LineEdit"]:
		t.set_color("font_color", kind, INK)
		t.set_color("font_hover_color", kind, INK)
	for kind in ["Button", "OptionButton"]:
		t.set_stylebox("normal", kind, box(Color("202e3c"), 8, 12))
		t.set_stylebox("hover", kind, box(Color("2c4052"), 8, 12))
		t.set_stylebox("pressed", kind, box(Color("375747"), 8, 12))
		var focus = box(Color(0, 0, 0, 0), 8, 0)
		focus.border_color = ACCENT
		focus.set_border_width_all(2)
		t.set_stylebox("focus", kind, focus)
	t.set_stylebox("panel", "PanelContainer", box(PANEL))
	t.set_constant("separation", "VBoxContainer", 12)
	t.set_constant("separation", "HBoxContainer", 12)
	return t

static func label(text: String, size: int = 17, color: Color = INK) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

static func note(text: String) -> Label:
	var l = label(text, 15, MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

static func button(text: String, action: Callable, primary: bool = false) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size.y = 42
	b.pressed.connect(action)
	if primary:
		b.add_theme_stylebox_override("normal", box(ACCENT, 8, 12))
		b.add_theme_color_override("font_color", Color("10251e"))
	return b

static func row() -> HBoxContainer:
	return HBoxContainer.new()

static func card(parent: Node, title: String, description: String = "") -> VBoxContainer:
	var panel = PanelContainer.new()
	parent.add_child(panel)
	var content = VBoxContainer.new()
	panel.add_child(content)
	content.add_child(label(title, 20))
	if not description.is_empty():
		content.add_child(note(description))
	return content

static func choice(parent: Node, title: String, labels: Array, values: Array, selected: Variant, change: Callable) -> OptionButton:
	var r = row()
	parent.add_child(r)
	var name_label = label(title)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(name_label)
	var option = OptionButton.new()
	option.custom_minimum_size = Vector2(220, 42)
	for i in labels.size():
		option.add_item(str(labels[i]))
		if values[i] == selected:
			option.select(i)
	option.item_selected.connect(func(i): change.call(values[i]))
	r.add_child(option)
	return option
