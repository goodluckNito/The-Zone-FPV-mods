extends Control
## prop_damage: the props' state on screen, as Uncrashed shows it - the quad
## flown seen from above, front at the top, laid out as its props really are
## (from its body in the game: a 5"'s spread wide, a whoop's in their ducts),
## each prop's blades coloured by its wear: white when new, through yellow to
## red worn right through, gone (a red X) where one has broken off. A prop
## just hit flashes, so a crash that hits more than one shows which. Drawn
## over the game (not into the video picture), hidden while paused and, by
## default, until a prop is damaged. With display="auto" it steps aside while
## an OSD (fpv_osd) draws the quad into the picture in its own look.

const FLASH_S := 0.8
const FADE_S := 0.25
const NEW := Color(0.94, 0.96, 0.96)
const HALF := Color(1.0, 0.8, 0.15)
const WORN := Color(1.0, 0.16, 0.1)
const FRAME := Color(0.16, 0.17, 0.19)
const FRAME_EDGE := Color(0.8, 0.82, 0.85)
const DUCT := Color(0.22, 0.23, 0.26)
const SHADOW := Color(0, 0, 0, 0.45)
const BLADES := 3

var props: Node = null
var at := Vector2(0.92, 0.6)      # its middle, as a fraction of the picture
var scale_k := 1.0
var opacity := 0.85
var only_damaged := true
var step_aside := true            # while an OSD draws it (display="auto")
var shown := 0.0                  # 0 hidden .. 1 showing (for tests too)
var flash := [0.0, 0.0, 0.0, 0.0]
var _serial := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## A prop's colour for its wear (0-1): white, yellow at half, red worn through
static func wear_colour(w: float) -> Color:
	w = clampf(w, 0.0, 1.0)
	if w < 0.5:
		return NEW.lerp(HALF, w / 0.5)
	return HALF.lerp(WORN, (w - 0.5) / 0.5)


func _damaged() -> bool:
	for i in 4:
		if bool(props.broken[i]) or float(props.wear[i]) >= 0.005:
			return true
	return false


func _flying() -> bool:
	if props == null or not is_instance_valid(props) or str(props.get("drone_id")) == "-":
		return false
	var p = props.get("_player")
	if p == null or not is_instance_valid(p):
		return false
	var gs := get_node_or_null("/root/ZGamestate")
	return not (gs != null and gs.get("is_paused") == true)


func _process(dt: float) -> void:
	var want := 0.0
	var osd := step_aside and props != null and is_instance_valid(props) \
		and Time.get_ticks_msec() - int(props.get("osd_drawn_ms")) < 1000
	if _flying():
		want = 1.0 if (not only_damaged or _damaged()) and not osd else 0.0
		var serial := int(props.get("hit_serial"))
		if _serial >= 0 and serial != _serial:
			var h = props.get("last_hit")
			if h is Dictionary and h.has("prop"):
				flash[int(h["prop"])] = 1.0
		_serial = serial
	# the OSD has it: gone at once, not faded out over the OSD's own
	shown = 0.0 if osd else move_toward(shown, want, dt / FADE_S)
	for i in 4:
		flash[i] = maxf(float(flash[i]) - dt / FLASH_S, 0.0)
	visible = shown > 0.0 and opacity > 0.0
	if visible:
		queue_redraw()


# The picture's part of the window: the game letterboxes it to its aspect
# setting (4:3 unless set otherwise), as fpv_osd works it out
func _picture() -> Rect2:
	var ws := get_viewport_rect().size
	var ar := 4.0 / 3.0
	var zs := get_node_or_null("/root/ZSettings")
	if zs != null:
		match str(zs.get("ASPECT_RATIO")):
			"16_9":
				ar = 16.0 / 9.0
			"native":
				ar = ws.x / maxf(ws.y, 1.0)
	var w := minf(ws.y * ar, ws.x)
	return Rect2(Vector2((ws.x - w) * 0.5, 0.0), Vector2(w, ws.y))


func _draw() -> void:
	var pic := _picture()
	var s := pic.size.y * 0.1 * scale_k        # half the drawing's size
	var c := pic.position + Vector2(clampf(at.x, 0.0, 1.0) * pic.size.x, clampf(at.y, 0.0, 1.0) * pic.size.y)
	c.x = clampf(c.x, pic.position.x + s, pic.position.x + pic.size.x - s)
	c.y = clampf(c.y, s, pic.size.y - s)
	var a := shown * clampf(opacity, 0.0, 1.0)
	# the props where they are on the quad (x right, z back = down the screen),
	# scaled so the whole quad fits in 2s
	var spots := []
	var r := 0.06
	var ducted := false
	var loc = props.get("_local")
	if loc is Array and loc.size() == 4:
		r = float(props.get("_r"))
		for v in loc:
			spots.append(Vector2((v as Vector3).x, (v as Vector3).z))
		ducted = bool((props.get("drone") as Dictionary).get("ducted", false)) if props.get("drone") is Dictionary else false
	else:
		spots = [Vector2(-0.09, -0.07), Vector2(0.09, -0.07), Vector2(-0.09, 0.07), Vector2(0.09, 0.07)]
	var ext := 0.0
	for p in spots:
		ext = maxf(ext, maxf(absf(p.x), absf(p.y)) + r * (1.25 if ducted else 1.0))
	var k := s / maxf(ext, 0.001)
	var lw := maxf(1.0, s * 0.055)
	var sh := Vector2(1, 1) * maxf(1.0, s * 0.03)
	var pts := []
	for p in spots:
		pts.append(c + (p as Vector2) * k)
	# a prop's radius on screen: its own, but never so big that two props
	# (or their ducts) touch - on a stretched 5" they nearly do for real
	var gap := s * 0.1
	var dmin := INF
	for i in 4:
		for j in range(i + 1, 4):
			dmin = minf(dmin, (pts[i] as Vector2).distance_to(pts[j]))
	var duct_k := 1.12 if ducted else 1.0
	var edge := lw * 1.4 if ducted else lw * 0.3      # what is drawn past the radius
	var pr := minf(r * k, (0.5 * (dmin - gap) - edge) / duct_k)
	var outer := pr * duct_k + edge
	# the frame: arms from the body to each motor, and the body with a nose
	for p in pts:
		draw_line(c + sh, p + sh, Color(SHADOW, SHADOW.a * a), lw * 2.2, true)
	for p in pts:
		draw_line(c, p, Color(FRAME_EDGE, a), lw * 2.2, true)
		draw_line(c, p, Color(FRAME, a), lw * 1.2, true)
	# the body: as wide as it can be with the props clear of it
	var inner := INF
	for p in pts:
		inner = minf(inner, absf((p as Vector2).x - c.x))
	var bw := clampf(inner - outer - gap, s * 0.05, s * 0.2)
	var bh := s * 0.36
	var body := Rect2(c - Vector2(bw, bh), Vector2(bw, bh) * 2.0)
	draw_rect(Rect2(body.position + sh, body.size), Color(SHADOW, SHADOW.a * a), true)
	draw_rect(body, Color(FRAME, a), true)
	draw_rect(body, Color(FRAME_EDGE, a), false, lw * 0.8)
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -bh - s * 0.16), c + Vector2(-bw * 0.7, -bh + s * 0.02), c + Vector2(bw * 0.7, -bh + s * 0.02)]),
		Color(FRAME_EDGE, a))
	# the props
	for i in 4:
		var p: Vector2 = pts[i]
		if ducted:
			draw_arc(p + sh, pr * 1.12, 0.0, TAU, 40, Color(SHADOW, SHADOW.a * a), lw * 2.2, true)
			draw_arc(p, pr * 1.12, 0.0, TAU, 40, Color(DUCT, a), lw * 2.2, true)
			draw_arc(p, pr * 1.12 + lw * 1.1, 0.0, TAU, 40, Color(FRAME_EDGE, 0.8 * a), maxf(1.0, lw * 0.5), true)
		if bool(props.broken[i]):
			# gone: its disc dashed in red, and an X
			for n in 12:
				var a0 := TAU * n / 12.0
				draw_arc(p, pr, a0, a0 + TAU / 24.0, 4, Color(WORN, 0.9 * a), lw * 0.8, true)
			var d := pr * 0.55
			draw_line(p + Vector2(-d, -d), p + Vector2(d, d), Color(WORN, a), lw * 1.6, true)
			draw_line(p + Vector2(-d, d), p + Vector2(d, -d), Color(WORN, a), lw * 1.6, true)
		else:
			var col := wear_colour(float(props.wear[i]))
			# the disc its blades sweep, faint, then the blades
			draw_circle(p, pr, Color(col, 0.22 * a))
			draw_arc(p, pr, 0.0, TAU, 40, Color(col, 0.55 * a), maxf(1.0, lw * 0.45), true)
			var turn := 0.5 + 0.9 * i
			for b in BLADES:
				var ang := turn + TAU * b / BLADES
				var dir := Vector2.from_angle(ang)
				var side := dir.orthogonal() * pr * 0.17
				var blade := PackedVector2Array([p + side * 0.6, p + dir * pr * 0.55 + side, p + dir * pr * 0.96, p + dir * pr * 0.55 - side * 0.7, p - side * 0.6])
				draw_colored_polygon(PackedVector2Array(Array(blade).map(func(v): return v + sh * 0.6)), Color(SHADOW, SHADOW.a * a))
				draw_colored_polygon(blade, Color(col, a))
		draw_circle(p, pr * 0.14, Color(0.12, 0.12, 0.14, a))
		draw_arc(p, pr * 0.14, 0.0, TAU, 16, Color(FRAME_EDGE, 0.8 * a), maxf(1.0, lw * 0.35), true)
		var f: float = flash[i]
		if f > 0.0:
			# a prop just hit lights up, and fades back to its colour
			draw_circle(p, pr, Color(1, 1, 1, 0.45 * f * a))
			draw_arc(p, pr * duct_k, 0.0, TAU, 40, Color(1, 1, 1, f * a), lw * (0.6 + 0.8 * f), true)
