extends Node
## fpv_osd: a Betaflight-style on-screen display for The Zone FPV.
##
## It is drawn into the picture just before the game's post-process, so an
## analog video effect (analog400mw's, or the game's own) blurs, fringes,
## tears and breaks it up the way it does an OSD added on the quad. Fonts
## are Betaflight .mcm files (MAX7456, 12x18 per character).
##
## Battery: if another zonemods mod has a zm_battery() method (battery_sag
## does), its pack is shown. Otherwise the readout is display only: a pack
## (cells, mAh and chemistry from settings.cfg) drained and sagged by throttle.
## zm_battery() returns a Dictionary:
##     cell_voltage  volts per cell under load (float)
##     mah_used      (float)
##     cells         (int, optional - settings.cfg's battery_cells otherwise)
##     current       amps (float, optional)
##     lihv          (bool, optional - settings.cfg's battery_lihv otherwise)
##     capacity_mah  (float, optional)
##
## Battery warnings and the post-flight stats screen follow Betaflight's own
## code (sensors/battery.c, osd/osd_warnings.c, osd/osd.c): the voltage shown
## and warned on is smoothed the same way, LOW BATTERY and LAND NOW come from
## the same state machine, and the stats screen has Betaflight's lines,
## labels, layout and ways of clearing it.
##
## Each part - horizon, sidebars, crosshair, sticks - can be drawn as
## Betaflight, BrainFPV or INAV draws it, mixed as the player likes. INAV's
## parts (its horizon, scrolling sidebars, crosshairs, HUD, vario and the
## rest) use INAV's own font, as its characters are its own. QUICKSILVER's
## fuel gauge can go with any of them.
##
## Copyright (C) 2026 Nito. GPL-3.0-or-later: see LICENSE.txt. Parts are
## translated from Betaflight, BrainFPV's Betaflight fork and INAV (all
## GPL-3.0) and QUICKSILVER (MIT).

const COLS := 30
const ROWS := 13            # the MAX7456's NTSC grid
const GW := 12
const GH := 18

# Betaflight's character codes, shared by every Betaflight .mcm font
const SYM_RSSI := 0x01
const SYM_THR := 0x04
const SYM_VOLT := 0x06
const SYM_MAH := 0x07
const SYM_M := 0x0C
const SYM_AH_RIGHT := 0x02
const SYM_AH_LEFT := 0x03
const SYM_AH_DECORATION := 0x13
const SYM_AH_CENTER_LINE := 0x72
const SYM_AH_BAR9_0 := 0x80
const SYM_LINK_QUALITY := 0x7B
const SYM_KM := 0x7D
const SYM_ALTITUDE := 0x7F
const SYM_BATT_FULL := 0x90
const SYM_BATT_EMPTY := 0x96
const SYM_AMP := 0x9A
const SYM_FLY_M := 0x9C
const SYM_KPH := 0x9E
const SYM_OVER_HOME := 0x05
const SYM_HOMEFLAG := 0x11
const SYM_HEADING_N := 0x18
const SYM_HEADING_S := 0x19
const SYM_HEADING_E := 0x1A
const SYM_HEADING_W := 0x1B
const SYM_HEADING_DIVIDED_LINE := 0x1C
const SYM_HEADING_LINE := 0x1D
const SYM_ARROW_SOUTH := 0x60        # 16 arrows, turning clockwise from south
const SYM_ARROW_EAST := 0x64
const SYM_ARROW_NORTH := 0x68
const SYM_ARROW_WEST := 0x6C
const SYM_SPEED := 0x70              # a little gauge; QUICKSILVER's ICON_GAUGE
# Betaflight's compass bar (osd_elements.c compassBar): nine characters of it,
# starting at the heading's sixteenth of a turn
const COMPASS_BAR := [SYM_HEADING_W,
	SYM_HEADING_LINE, SYM_HEADING_DIVIDED_LINE, SYM_HEADING_LINE, SYM_HEADING_N,
	SYM_HEADING_LINE, SYM_HEADING_DIVIDED_LINE, SYM_HEADING_LINE, SYM_HEADING_E,
	SYM_HEADING_LINE, SYM_HEADING_DIVIDED_LINE, SYM_HEADING_LINE, SYM_HEADING_S,
	SYM_HEADING_LINE, SYM_HEADING_DIVIDED_LINE, SYM_HEADING_LINE, SYM_HEADING_W,
	SYM_HEADING_LINE, SYM_HEADING_DIVIDED_LINE, SYM_HEADING_LINE, SYM_HEADING_N,
	SYM_HEADING_LINE, SYM_HEADING_DIVIDED_LINE, SYM_HEADING_LINE]
const COMPASS_COL := 10              # its left end; the heading is col 14

# INAV's character codes (drivers/osd_symbols.h) - an INAV font has 512
const I_HOME := 0x10
const I_AH_DECORATION_UP := 0x15
const I_AH_DECORATION_DOWN := 0x16
const I_DECORATION := 0x17           # 8 little arrows, clockwise from up
const I_ZERO_HALF_TRAILING_DOT := 0xA1
const I_ZERO_HALF_LEADING_DOT := 0xB1
const I_AH_LEFT := 0x12C
const I_AH_RIGHT := 0x12D
const I_AH_DECORATION_MIN := 0x12E
const I_AH_DECORATION := 0x131
const I_AH_DECORATION_MAX := 0x133
const I_AH_DECORATION_COUNT := 6
const I_AH_CH_LEFT := 0x13A
const I_AH_CH_RIGHT := 0x13B
const I_AH_H_START := 0x14C          # 9 heights of a level line
const I_AH_V_START := 0x15A          # 6 positions of an upright one
const I_HUD_SIGNAL_0 := 0x160
const I_AH_CH_CENTER := 0x166
const I_AH_CH_TYPE3 := 0x190         # then 4..8, three characters each
const I_AH_CH_AIRCRAFT0 := 0x1A2     # five characters
const I_HUD_ARROWS_L1 := 0x1AE
const I_HUD_ARROWS_L3 := 0x1B0
const I_HUD_ARROWS_R1 := 0x1B1
const I_HUD_ARROWS_R3 := 0x1B3
const I_HUD_ARROWS_U1 := 0x1B4
const I_HUD_ARROWS_D1 := 0x1B7
const I_HUD_CARDINAL := 0x1BA        # 12, where it is, in 30 degree steps
const I_MS := 0x8F
const I_GFORCE := 0xBC
const I_VARIO_UP_2A := 0x155
const I_VARIO_UP_1A := 0x156
const I_VARIO_DOWN_1A := 0x157
const I_VARIO_DOWN_2A := 0x158
const I_THR_GAUGE_EMPTY := 0x16B
const I_THR_GAUGE_HALF := 0x16C
const I_THR_GAUGE_FULL := 0x16D
# its artificial horizon: 11 x 9 characters round the crosshair
const I_AHI_WIDTH := 11
const I_AHI_HEIGHT := 9
const I_AHI_H_SYM_COUNT := 9
const I_AHI_V_SYM_COUNT := 6
const I_AH_SIDEBAR_WIDTH := 7
const I_ASPECT := 12.0 / 18.46       # NTSC characters are taller than wide
# the middle of INAV's grid: column 15, row 6 of 30 x 13
const I_MID_COL := 15
const I_MID_ROW := 6
const I_HOMING_H := [6, 16, 38]      # OSD_HOMING_LIM_H1..3, degrees
const I_HOMING_V := [5, 10, 15]      # OSD_HOMING_LIM_V1..3
const HUD_RADAR_MAX := 4

const DEFAULTS := {
	"style": "betaflight",
	"font": "betaflight_default.mcm",
	"inav_font": "inav_default.mcm",
	"craft_name": "",
	"battery_mah": 450,
	"battery_cells": 1,
	"battery_lihv": true,
	"battery_voltage": "cell",
	"new_pack_on_respawn": "disarmed",
	"low_battery_voltage": 3.50,
	"land_now_voltage": 3.30,
	"low_battery_delay": 0.0,
	"land_now_delay": 0.0,
	"low_battery_percent": 0,
	"over_cap_mah": 0,
	"timer_alarm": 0.0,
	"show_lq": true,
	"show_rssi": false,
	"show_timer": true,
	"show_battery": true,
	"show_mah": true,
	"show_current": false,
	"show_throttle": false,
	"show_speed": false,
	"show_altitude": false,
	"show_sticks": false,
	"sticks_style": "brainfpv",       # or "auto", "betaflight"
	"sticks_mode": 2,
	"sticks_size": 1.0,
	"sticks_x": 9.0,
	"sticks_y": 17.0,
	"sticks_row": 6,
	"sticks_inset": 1,
	"show_crosshair": false,        # early test builds; crosshair="betaflight" now
	"crosshair": "off",
	"crosshair_size": 1.0,
	"crosshair_offset": 0.0,
	"show_horizon": false,
	"horizon_style": "auto",
	"horizon_pitch_interval": 0,
	"show_horizon_sidebars": false,
	"sidebars_style": "auto",
	"sidebars_scroll_left": "none",
	"sidebars_scroll_right": "none",
	"sidebars_arrows": false,
	"sidebars_height": 3,
	"show_compass": false,
	"show_home": false,
	"hud_homepoint": false,
	"hud_homing": false,
	"hud_radar": 0,
	"hud_radar_range_min": 3,
	"hud_radar_range_max": 4000,
	"hud_margin_h": 3,
	"hud_margin_v": 3,
	"show_vario": false,
	"show_vario_number": false,
	"show_g_force": false,
	"g_force_alarm": 5.0,
	"show_throttle_gauge": false,
	"horizon_max_pitch": 20,
	"horizon_max_roll": 40,
	"horizon_invert": false,
	"horizon_uptilt": false,
	"horizon_steps": 2,
	"show_altitude_scale": false,
	"show_speed_scale": false,
	"show_warnings": true,
	"show_fuel_gauge": false,
	"warnings_use_fuel_gauge": false,
	"show_flip_arrow": false,
	"show_up_down": false,
	"show_in_digital": true,
	"rc_link": "elrs",
	"rc_power": 100,
	"hide_game_messages": true,
	"stats": true,
	"stats_on_respawn": false,
	"stat_cell_voltage": true,
	"stat_date_time": false,
	"stat_on_time": false,
	"stat_armed_time": true,
	"stat_max_altitude": false,
	"stat_max_speed": true,
	"stat_max_distance": false,
	"stat_flight_distance": false,
	"stat_min_battery": true,
	"stat_end_battery": false,
	"stat_battery": false,
	"stat_min_rssi": false,
	"stat_max_current": true,
	"stat_used_mah": true,
	"stat_max_g_force": false,
	"stat_min_link_quality": true,
	"stat_min_rssi_dbm": false,
	"stat_total_flights": false,
	"stat_total_time": false,
	"stat_total_distance": false,
	"stat_watt_hours": false,
	"stat_full_throttle_time": false,
	"stat_full_throttle_count": false,
	"stat_avg_throttle": false,
}

# The stats screen's lines in Betaflight's order (osdStatsDisplayOrder)
const STAT_ORDER := ["stat_date_time", "stat_on_time", "stat_armed_time", "stat_max_altitude",
	"stat_max_speed", "stat_max_distance", "stat_flight_distance", "stat_min_battery",
	"stat_end_battery", "stat_battery", "stat_min_rssi", "stat_max_current", "stat_used_mah",
	"stat_max_g_force", "stat_min_link_quality", "stat_min_rssi_dbm", "stat_total_flights",
	"stat_total_time", "stat_total_distance", "stat_watt_hours", "stat_full_throttle_time",
	"stat_full_throttle_count", "stat_avg_throttle"]
const TOTALS_KEYS := ["stat_total_flights", "stat_total_time", "stat_total_distance"]

# Crosshairs: Betaflight's (from the font, so a custom font's own shows), or
# one drawn in the OSD's white-with-black-edge style, at the picture's centre
const CROSSHAIRS := ["off", "auto", "betaflight", "brainfpv", "inav", "inav_aircraft", "inav_type3",
	"inav_type4", "inav_type5", "inav_type6", "inav_type7", "inav_type8",
	"plus", "gap", "cross", "dot", "circle", "chevron"]
# style: the text, how often it is redrawn, and what "auto" means below
const STYLES := ["betaflight", "brainfpv"]
# each part's own choices
const HORIZON_STYLES := ["auto", "betaflight", "brainfpv", "inav"]
const SIDEBAR_STYLES := ["auto", "betaflight", "inav"]
const STICK_STYLES := ["auto", "betaflight", "brainfpv"]
const SIDEBAR_SCROLLS := ["none", "altitude", "speed", "home_distance"]
const CX := COLS * GW / 2            # the picture's centre, in OSD pixels
const CY := ROWS * GH / 2
const AH_ROW := 2                    # Betaflight's horizon: 9 characters wide, rows 2-11
# Betaflight's stick overlay: a 7 x 5 box of lines with the stick as a dot
# that moves in thirds of a character up and down
const STICK_W := 7
const STICK_H := 5
const SYM_STICK_HIGH := 0x08         # the dot at the top, middle, bottom of a cell
const SYM_STICK_CENTER := 0x0B
const SYM_STICK_VERTICAL := 0x16
const SYM_STICK_HORIZONTAL := 0x17
# which stick_pos axis (roll, pitch, throttle, yaw) each box shows, by radio
# mode: [left vertical, left horizontal, right vertical, right horizontal]
const RADIO_MODES := [[1, 3, 2, 0], [2, 3, 1, 0], [1, 0, 2, 3], [2, 0, 1, 3]]
const AH_SYMBOL_COUNT := 9

# BrainFPV's graphical OSD (the RADIX's, from its open-source Betaflight fork,
# src/main/brainfpv): it draws into a 352 x 240 picture of its own, about the
# size of a Betaflight OSD's 30 x 12 characters, so its pixels are drawn one
# for one into this OSD's 360 x 234. It redraws the whole OSD every other
# video field, 30 times a second. Colours as in its code.
const GR_RIGHT := COLS * GW - 1          # GRAPHICS_RIGHT
const GR_BOTTOM := ROWS * GH - 1         # GRAPHICS_BOTTOM
const C_BLACK := Color(0, 0, 0, 1)
const C_WHITE := Color(1, 1, 1, 1)
const BFPV_STICK_WIDTH := 2              # draw_stick
const BFPV_STICK_LENGTH := 20
const BFPV_STICK_BOX := 4
const GAME_STICK_PX := 128.0             # the game's stick overlay, each box (stick_overlay.tscn)
const OSD_GRID := Vector4(0.04, 0.03, 0.96, 0.97)   # osd_overlay.gdshader's grid, picture UV
const HORIZON_FAR := 2000.0             # metres out, for the horizon's direction
const BFPV_PITCH_STEP := 10              # simple_artificial_horizon
const BFPV_AH_MAX_PITCH := 30

# resting voltage of a cell against state of charge
const LIHV := [[0.0, 3.20], [0.05, 3.45], [0.10, 3.55], [0.20, 3.64], [0.30, 3.71],
	[0.40, 3.77], [0.50, 3.82], [0.60, 3.89], [0.70, 3.97], [0.80, 4.06],
	[0.90, 4.17], [1.00, 4.33]]
const LIPO := [[0.0, 3.20], [0.05, 3.43], [0.10, 3.53], [0.20, 3.63], [0.30, 3.70],
	[0.40, 3.75], [0.50, 3.80], [0.60, 3.85], [0.70, 3.91], [0.80, 3.98],
	[0.90, 4.08], [1.00, 4.19]]

# Betaflight smooths the pack voltage it shows and warns on with a low-pass of
# 1/3 Hz (vbat_display_lpf_period 30): a time constant of about half a second.
const VBAT_TAU := 3.0 / TAU
const VBAT_HYSTERESIS := 0.01    # volts, the whole pack (vbat_hysteresis 1)
enum { BAT_OK, BAT_WARNING, BAT_CRITICAL }
# Accelerometer smoothing for the g-force stat (acc_lpf_hz 10) and the range
# of a flight controller's accelerometer
const ACC_LPF_HZ := 10.0
const ACC_MAX_G := 16.0
const STATS_SHOW_S := 60.0
const TOTALS_MIN_S := 10.0       # a flight counts towards the totals from 10 s armed

# The control link, apart from the video: ExpressLRS 2.4 GHz at 250 Hz. What
# reaches the receiver is the transmit power, less the free-space loss to the
# quad, a fade margin for flying near the ground, and what the walls in
# between take (each wall 4 dB plus 12 dB a metre of it, up to 1 m; 40 dB at
# most, as some gets round). The receiver hears down to -108 dBm; its link
# quality falls off over the last few dB.
const RC_MHZ := 2440.0
const RC_ANT_DB := 4.0            # both antennas together
const RC_FADE_DB := 10.0
const RC_SENS_DBM := -108.0       # ExpressLRS 250 Hz
const RC_WALL_DB := 4.0
const RC_WALL_DB_M := 12.0
const RC_WALLS_MAX_DB := 40.0
const RC_PILOT_H := 1.5           # the radio, at chest height
const CRASH_FLIP_WARNING := "> CRASH FLIP <"   # Betaflight 4.5

var cfg := {}
var lines := PackedStringArray()    # the last OSD as text, for tests
var warning := ""                   # the warning showing, blinking or not, for tests
var bat_state := BAT_OK             # for tests
var stats_visible := false
var g_force := 1.0

var _dir := ""
var _core: Node = null
var _font: Image = null
var _img: Image = null
var _tex: ImageTexture = null
var _cells := PackedByteArray()
var extras: Array = []              # drawn over the grid last time, for tests: [what, code, x, y]
var _over: Array = []               # [code, x, y] font glyphs to draw at pixel positions
var _over_late: Array = []          # the same, drawn over the crosshair
var _xhair: Image = null
var _xhair_style := "off"
var _style := "betaflight"
var _sticks_style := "brainfpv"
var _hz_style := "betaflight"
var _sb_style := "betaflight"
var _inav: Image = null          # INAV's font, for its parts
var _ibusy := {}                 # INAV grid cells drawn this time
var _sb_state := [{}, {}]        # INAV's scrolling sidebars, left and right
var _radar_slot := {}            # other players' quads: their letter, A-D
var _abusy := {}                 # INAV's own-place elements, by cell
var _small8: Image = null      # BrainFPV's small fonts: outlined 8x8 and 8x10
var _font810: Image = null
var _win_h := 1080.0
var _pic := Vector4(0.0, 0.0, 1.0, 1.0) # the picture on screen, screen UV
var _fe_k := 0.5                        # the post-process's fisheye
var _fe_crop := 0.25
var _game_stick_px := GAME_STICK_PX

var _scene: Node = null
var _pp: CanvasItem = null
var _player: Node = null
var _overlay: ColorRect = null
var _game_box: CanvasItem = null
var _game_sticks: CanvasItem = null
var _game_left: Control = null
var _span := 55.0
var _t_draw := 0.0
var _off := false
var _t_retry := 0.0
var _now := 0.0

var _armed := false
var _armed_msg_until := -1.0
var _fly_time := 0.0
var _on_time := 0.0
var _home := Vector3.ZERO
var _last_pos := Vector3.ZERO
var _have_pos := false
var _at_spawn := false
var _spawn_last := Vector3.ZERO
var _have_spawn := false
var _r_key := false
var _sw_last = null
var _lost_s := 0.0
var _rc_db := -40.0            # the control link at the receiver, dBm, smoothed
var _rc_have := false
var _rc_walls_db := 0.0
var _rc_t := 1.0
var _rc_elrs := true

var _mah := 0.0
var _mah_prev := 0.0
var _wh := 0.0
var _v := 4.33          # per cell
var _vp := 0.0
var _amps := 0.0
var _shown_cells := 1
var _cells_prev := 0
var _shown_lihv := true
var _from_mod := false  # the battery comes from another mod
var _capacity := 0.0

# battery warnings
var _vf := 0.0          # per cell, smoothed like Betaflight's
var _vf_ready := false
var _vstate := BAT_OK
var _cstate := BAT_OK
var _t_vchange := 0.0
var _fresh_pack := false

# QUICKSILVER's fuel gauge (io/vbat.c): the pack's voltage with the sag from
# throttle added back, stepped at its 1 kHz
const QS_DT := 0.001
const QS_CF1 := 0.25                  # its li-ion recovery term
const QS_SAG_A := 0.0304590           # pt1 5 Hz at 1 kHz (sag_filter)
const QS_THR_A := 0.2737757           # pt1 60 Hz at 1 kHz (thrsum_filter)
const QS_DECAY_K := 0.9996667         # lpfcalc(0.001, 18): the 18 s decay
const QS_HP_K := 0.9880716            # lpfcalc(12 ms, 6 s): vbat_auto_vdrop's high-pass
const QS_SCORE_K := 0.9988007         # lpfcalc(12 ms, 60 s): its score filter
var fuel_gauge := 0.0                 # volts a cell (vbat_compensated_cell_avg)
var fuel_vdrop := 0.0                 # the sag at full throttle it has learnt
var _fg_warn := 0.0                   # the gauge smoothed as Betaflight smooths its voltage
var _qs_ready := false
var _qs_acc := 0.0
var _qs_sag := 0.0
var _qs_decay := 0.0
var _qs_thr := 0.0
var _qs_z := 0
var _qs_min := 0
var _qs_lastin := PackedFloat64Array()
var _qs_lastout := PackedFloat64Array()
var _qs_score := PackedFloat64Array()

# the flight's numbers, and the stats screen
var _st := {}
var _st_pending := false
var _shown := {}
var _stats_until := 0.0
var _stats_while_armed := false
var _stats_anchor := Vector3.ZERO
var _totals := {"flights": 0, "time_s": 0.0, "distance_m": 0.0}
var _stat_keys: Array = []

# g-force, from the quad's velocity each physics tick
var _g_have := false
var _g_pos := Vector3.ZERO
var _g_vel := Vector3.ZERO
var _g_acc := Vector3(0, 9.81, 0)


## Reads settings.cfg [osd] and the font. Returns lines for status.txt.
func setup(dir: String, core: Node) -> String:
	_dir = dir
	_core = core
	cfg = DEFAULTS.duplicate()
	var c := ConfigFile.new()
	if c.load(dir + "settings.cfg") == OK and c.has_section("osd"):
		for k in c.get_section_keys("osd"):
			if cfg.has(k):
				cfg[k] = c.get_value("osd", k)
	var font_name := str(cfg["font"])
	var note := ""
	_font = load_mcm(dir + "fonts/" + font_name)
	if _font == null and font_name != DEFAULTS["font"]:
		note = " - could not read fonts/%s" % font_name
		font_name = DEFAULTS["font"]
		_font = load_mcm(dir + "fonts/" + font_name)
	if _font == null:
		_off = true
		return "osd: off - no readable .mcm font in the fonts folder"
	_img = Image.create_empty(COLS * GW, ROWS * GH, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	_cells.resize(COLS * ROWS)
	var xnote := ""
	_rc_elrs = str(cfg["rc_link"]).strip_edges().to_lower() != "video"
	_style = _choice("style", STYLES, "betaflight")
	# each part's own style; "auto" is style's own version of it (BrainFPV's
	# sidebars are Betaflight's)
	_hz_style = _choice("horizon_style", HORIZON_STYLES, "auto")
	if _hz_style == "auto":
		_hz_style = _style
	_sticks_style = _choice("sticks_style", STICK_STYLES, "brainfpv")
	if _sticks_style == "auto":
		_sticks_style = _style
	_sb_style = _choice("sidebars_style", SIDEBAR_STYLES, "auto")
	if _sb_style == "auto":
		_sb_style = "betaflight"
	_xhair_style = str(cfg["crosshair"]).strip_edges().to_lower()
	if _xhair_style == "off" and bool(cfg["show_crosshair"]):
		_xhair_style = "betaflight"
	if not _xhair_style in CROSSHAIRS:
		xnote += " - no crosshair called \"%s\"; one of %s" % [_xhair_style, ", ".join(CROSSHAIRS)]
		_xhair_style = "off"
	if _xhair_style == "auto":
		_xhair_style = _style
	for k in ["sidebars_scroll_left", "sidebars_scroll_right"]:
		_choice(k, SIDEBAR_SCROLLS, "none")
	xnote += _bad
	if _brainfpv_drawn() or (bool(cfg["show_sticks"]) and _sticks_style == "brainfpv"):
		_small8 = load_font_png(dir + "fonts/brainfpv_8x8.png", 8, 8)
		_font810 = load_font_png(dir + "fonts/brainfpv_8x10.png", 8, 10)
		if _brainfpv_drawn() and (_small8 == null or _font810 == null):
			xnote += " - fonts/brainfpv_8x8.png or brainfpv_8x10.png missing, so no numbers on the horizon and scales"
	var inav_note := ""
	if _uses_inav():
		var inav_name := str(cfg["inav_font"])
		_inav = load_mcm(dir + "fonts/" + inav_name)
		if _inav == null or _inav.get_height() < 32 * GH:
			_inav = null
			inav_note = " - fonts/%s is not a 512-character INAV font, so INAV's parts are off" % inav_name
	_xhair = make_crosshair(_xhair_style, float(cfg["crosshair_size"]), _font, _inav)
	for k in STAT_ORDER:
		if bool(cfg[k]):
			_stat_keys.append(k)
	_load_totals()
	_new_pack()
	_stats_reset()
	var xh := "style: %s; crosshair: %s" % [_style, _xhair_style]
	if _xhair_style != "off":
		xh += ", size %s" % str(snappedf(float(cfg["crosshair_size"]), 0.01))
		if float(cfg["crosshair_offset"]) != 0.0:
			xh += ", %+g%% of the picture up" % float(cfg["crosshair_offset"])
	var hz := []
	var on_cam := " on the real horizon (camera uptilt allowed for)" if bool(cfg["horizon_uptilt"]) else ""
	if bool(cfg["show_horizon"]) and _hz_style == "brainfpv":
		hz.append("BrainFPV's pitch ladder (+-%d degrees)%s" % [clampi(int(cfg["horizon_steps"]), 0, 9) * BFPV_PITCH_STEP, on_cam])
	elif bool(cfg["show_horizon"]) and _hz_style == "inav":
		var pi := clampi(int(cfg["horizon_pitch_interval"]), 0, 30)
		hz.append("INAV's artificial horizon (%d degrees pitch full scale%s%s%s)" % [int(cfg["horizon_max_pitch"]),
			", a line every %d degrees" % pi if pi > 0 else "", ", roll reversed" if bool(cfg["horizon_invert"]) else "",
			", less the camera's uptilt" if bool(cfg["horizon_uptilt"]) else ""])
	elif bool(cfg["show_horizon"]) and bool(cfg["horizon_uptilt"]):
		hz.append("artificial horizon" + on_cam)
	elif bool(cfg["show_horizon"]):
		hz.append("artificial horizon (%d degrees pitch, %d roll full scale%s)" % [int(cfg["horizon_max_pitch"]), int(cfg["horizon_max_roll"]), ", inverted" if bool(cfg["horizon_invert"]) else ""])
	if bool(cfg["show_horizon_sidebars"]) and _sb_style == "inav":
		var sc := [str(cfg["sidebars_scroll_left"]), str(cfg["sidebars_scroll_right"])]
		hz.append("INAV's sidebars (scrolling with %s and %s%s)" % [sc[0], sc[1], ", arrows" if bool(cfg["sidebars_arrows"]) else ""])
	elif bool(cfg["show_horizon_sidebars"]):
		hz.append("sidebars")
	xh += xnote + inav_note + "; horizon: " + (" and ".join(hz) if not hz.is_empty() else "off")
	var sc2 := []
	if bool(cfg["show_altitude_scale"]):
		sc2.append("altitude")
	if bool(cfg["show_speed_scale"]):
		sc2.append("speed")
	xh += "; scales: " + (" and ".join(sc2) if not sc2.is_empty() else "off")
	if not bool(cfg["show_sticks"]):
		xh += "; sticks: off"
	elif _sticks_style == "brainfpv":
		xh += "; sticks: brainfpv, mode %d, size %s, at %s%% in and %s%% up" % [clampi(int(cfg["sticks_mode"]), 1, 4), str(snappedf(float(cfg["sticks_size"]), 0.01)), str(snappedf(float(cfg["sticks_x"]), 0.1)), str(snappedf(float(cfg["sticks_y"]), 0.1))]
	else:
		xh += "; sticks: betaflight, mode %d, rows %d-%d" % [clampi(int(cfg["sticks_mode"]), 1, 4), int(cfg["sticks_row"]), int(cfg["sticks_row"]) + STICK_H - 1]
	xh += "; compass: %s" % ("on" if bool(cfg["show_compass"]) else "off")
	xh += "; home: %s" % ("arrow and distance" if bool(cfg["show_home"]) else "off")
	var hud := []
	if bool(cfg["hud_homepoint"]):
		hud.append("home point")
	if bool(cfg["hud_homing"]):
		hud.append("homing arrows")
	if _radar_n() > 0:
		hud.append("radar, %d nearest other players %d-%d m out" % [_radar_n(), int(cfg["hud_radar_range_min"]), int(cfg["hud_radar_range_max"])])
	xh += "; hud: " + (", ".join(hud) if not hud.is_empty() else "off")
	var more := []
	for k in ["vario", "vario_number", "g_force", "throttle_gauge"]:
		if bool(cfg["show_" + k]):
			more.append(k.replace("_", " "))
	xh += "; inav: " + (", ".join(more) if not more.is_empty() else "off")
	xh += "; fuel gauge: %s" % ("on" if bool(cfg["show_fuel_gauge"]) else "off")
	xh += "; flip arrow: %s" % ("on" if bool(cfg["show_flip_arrow"]) else "off")
	xh += "; up/down: %s" % (("on, by the camera" if bool(cfg["horizon_uptilt"]) else "on") if bool(cfg["show_up_down"]) else "off")
	xh += "; redrawn %d times a second" % _rate()
	var rc := ("link: its own control link, ExpressLRS 2.4 GHz at %d mW" % _rc_power()) if _rc_elrs else "link: follows the video signal"
	return "\n".join(["osd: font %s%s" % [font_name, note], xh, rc, _describe_warnings(), _describe_stats()])


var _bad := ""


# A setting that has to be one of a list; a note in status.txt when it is not
func _choice(key: String, allowed: Array, fallback: String) -> String:
	var v := str(cfg[key]).strip_edges().to_lower()
	if v in allowed:
		return v
	var msg := " - no %s \"%s\", so %s" % [key, v, fallback]
	if not _bad.contains(msg):
		_bad += msg
	return fallback


# BrainFPV's drawn parts, redrawn 30 times a second as its OSD is
func _brainfpv_drawn() -> bool:
	return _style == "brainfpv" or (bool(cfg["show_horizon"]) and _hz_style == "brainfpv") \
		or bool(cfg["show_altitude_scale"]) or bool(cfg["show_speed_scale"])


func _uses_inav() -> bool:
	return (bool(cfg["show_horizon"]) and _hz_style == "inav") \
		or (bool(cfg["show_horizon_sidebars"]) and _sb_style == "inav") \
		or _xhair_style.begins_with("inav") or bool(cfg["hud_homepoint"]) or bool(cfg["hud_homing"]) \
		or _radar_n() > 0 or bool(cfg["show_vario"]) or bool(cfg["show_vario_number"]) \
		or bool(cfg["show_g_force"]) or bool(cfg["show_throttle_gauge"])


func _radar_n() -> int:
	return clampi(int(cfg["hud_radar"]), 0, HUD_RADAR_MAX)


func _describe_warnings() -> String:
	var parts := []
	var lo := _volts("low_battery_voltage")
	var ln := _volts("land_now_voltage")
	var lo_d := float(cfg["low_battery_delay"])
	var ln_d := float(cfg["land_now_delay"])
	var on := " on the fuel gauge" if bool(cfg["warnings_use_fuel_gauge"]) else ""
	parts.append(("LOW BATTERY below %.2f V a cell" % lo + on + (" for %.1f s" % lo_d if lo_d > 0.0 else "")) if lo > 0.0 else "LOW BATTERY by voltage off")
	parts.append(("LAND NOW below %.2f V" % ln + on + (" for %.1f s" % ln_d if ln_d > 0.0 else "")) if ln > 0.0 else "LAND NOW by voltage off")
	if int(cfg["low_battery_percent"]) > 0:
		parts.append("LOW BATTERY at %d%% left" % int(cfg["low_battery_percent"]))
	if int(cfg["over_cap_mah"]) > 0:
		parts.append("OVER CAP at %d mAh" % int(cfg["over_cap_mah"]))
	if float(cfg["timer_alarm"]) > 0.0:
		parts.append("timer blinks after %s min" % str(snappedf(float(cfg["timer_alarm"]), 0.01)))
	return "warnings: " + ", ".join(parts)


func _describe_stats() -> String:
	if not bool(cfg["stats"]) or _stat_keys.is_empty():
		return "stats: off"
	var names := []
	for k in _stat_keys:
		names.append(k.trim_prefix("stat_"))
	var when := "after disarming" + (" or respawning" if bool(cfg["stats_on_respawn"]) else "")
	var s := "stats: %s - %s" % [when, ", ".join(names)]
	if _stat_keys.size() > ROWS:
		s += " (only the first %d fit)" % ROWS
	return s


## A crosshair to lay over the OSD, centred on its middle: Betaflight's three
## characters from the font, INAV's three (or five) from its font, or a shape
## drawn white with a black edge like the font's characters. size scales it.
## null for "off".
static func make_crosshair(style: String, size: float, font: Image, inav: Image = null) -> Image:
	var sz := clampf(size, 0.25, 4.0)
	if style == "off" or font == null:
		return null
	if style.begins_with("inav"):
		# osdHudDrawCrosshair: the middle character on the crosshair
		if inav == null:
			return null
		var codes := [I_AH_CH_LEFT, I_AH_CH_CENTER, I_AH_CH_RIGHT]
		if style == "inav_aircraft":
			codes = [I_AH_CH_AIRCRAFT0, I_AH_CH_AIRCRAFT0 + 1, I_AH_CH_AIRCRAFT0 + 2, I_AH_CH_AIRCRAFT0 + 3, I_AH_CH_AIRCRAFT0 + 4]
		elif style.begins_with("inav_type"):
			var base := I_AH_CH_TYPE3 + (int(style.trim_prefix("inav_type")) - 3) * 3
			codes = [base, base + 1, base + 2]
		var ic := Image.create_empty(codes.size() * GW, GH, false, Image.FORMAT_RGBA8)
		for i in codes.size():
			ic.blit_rect(inav, Rect2i((codes[i] % 16) * GW, (codes[i] / 16) * GH, GW, GH), Vector2i(i * GW, 0))
		if sz != 1.0:
			ic.resize(maxi(roundi(codes.size() * GW * sz), 1), maxi(roundi(GH * sz), 1), Image.INTERPOLATE_NEAREST)
		return ic
	if style == "brainfpv":
		# osdBackgroundCrosshairs_BrainFPV: two wings and a fin, white lines
		# outlined black, the middle at (12, 9)
		var b := Image.create_empty(24, 18, false, Image.FORMAT_RGBA8)
		var cx := 12
		var cy := 9
		for seg in [[cx - 10, cx - 3], [cx + 4, cx + 11]]:
			for x in range(seg[0] + 1, seg[1]):
				b.set_pixel(x, cy - 1, Color(0, 0, 0, 1))
				b.set_pixel(x, cy + 1, Color(0, 0, 0, 1))
				b.set_pixel(x, cy, Color(1, 1, 1, 1))
		for y in range(cy - 8 + 1, cy - 3):
			b.set_pixel(cx - 1, y, Color(0, 0, 0, 1))
			b.set_pixel(cx + 1, y, Color(0, 0, 0, 1))
			b.set_pixel(cx, y, Color(1, 1, 1, 1))
		if sz != 1.0:
			b.resize(maxi(roundi(24 * sz), 1), maxi(roundi(18 * sz), 1), Image.INTERPOLATE_NEAREST)
		return b
	if style == "betaflight":
		var bf := Image.create_empty(3 * GW, GH, false, Image.FORMAT_RGBA8)
		for i in 3:
			var code := SYM_AH_CENTER_LINE + i
			bf.blit_rect(font, Rect2i((code % 16) * GW, (code / 16) * GH, GW, GH), Vector2i(i * GW, 0))
		if sz != 1.0:
			bf.resize(maxi(roundi(3 * GW * sz), 1), maxi(roundi(GH * sz), 1), Image.INTERPOLATE_NEAREST)
		return bf
	var arm := 8.0 * sz
	var h := maxf(roundf(2.0 * sz), 1.0) * 0.5      # half the line thickness
	var r := int(ceil(arm + h)) + 2
	var n := 2 * r
	var mask := PackedByteArray()
	mask.resize(n * n)
	for py in n:
		for px in n:
			# centred between pixels, so an even-width line sits evenly
			var dx := px - r + 0.5
			var dy := py - r + 0.5
			var ax := absf(dx)
			var ay := absf(dy)
			var on := false
			match style:
				"plus":
					on = (ay <= h and ax <= arm) or (ax <= h and ay <= arm)
				"gap":
					var g := 3.0 * sz
					on = (ay <= h and ax > g and ax <= arm) or (ax <= h and ay > g and ay <= arm) or (ax <= h and ay <= h)
				"cross":
					on = maxf(ax, ay) <= arm * 0.75 and (absf(dx - dy) / sqrt(2.0) <= h or absf(dx + dy) / sqrt(2.0) <= h)
				"dot":
					on = dx * dx + dy * dy <= (h + 1.0 * sz) * (h + 1.0 * sz)
				"circle":
					var d := sqrt(dx * dx + dy * dy)
					on = absf(d - arm * 0.8) <= h * 0.75 or d <= h + 0.3
				"chevron":
					on = dy >= -h and dy <= arm * 0.7 and absf(ax - dy) / sqrt(2.0) <= h
			mask[py * n + px] = 1 if on else 0
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	var white := Color(1, 1, 1, 1)
	var black := Color(0, 0, 0, 1)
	for py in n:
		for px in n:
			if mask[py * n + px] == 1:
				img.set_pixel(px, py, white)
				continue
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					var qx := px + ox
					var qy := py + oy
					if qx >= 0 and qx < n and qy >= 0 and qy < n and mask[qy * n + qx] == 1:
						img.set_pixel(px, py, black)
	return img


## One of BrainFPV's small fonts: a 16x16 grid of w x h characters, clear,
## black, grey or white. null if it cannot be read.
static func load_font_png(path: String, w: int, h: int) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.get_width() != 16 * w or img.get_height() != 16 * h:
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


## A Betaflight / MAX7456 .mcm font as a grid of 12x18 characters, 16 across
## and 16 down (256, as Betaflight's) or 32 down (512, as INAV's): white where
## the font is white, black where it is black, clear elsewhere.
static func load_mcm(path: String) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var rows := PackedStringArray()
	for l in f.get_as_text().split("\n"):
		var s := l.strip_edges()
		if s != "":
			rows.append(s)
	if rows.size() < 1 + 256 * 64 or rows[0] != "MAX7456":
		return null
	var count := 512 if rows.size() >= 1 + 512 * 64 else 256
	var img := Image.create_empty(16 * GW, count / 16 * GH, false, Image.FORMAT_RGBA8)
	var white := Color(1, 1, 1, 1)
	var black := Color(0, 0, 0, 1)
	for g in count:
		var ox := (g % 16) * GW
		var oy := (g / 16) * GH
		for p in GW * GH:
			var byte := rows[1 + g * 64 + p / 4]
			if byte.length() != 8:
				return null
			var b := byte.substr((p % 4) * 2, 2)
			if b == "00":
				img.set_pixel(ox + p % GW, oy + p / GW, black)
			elif b == "10":
				img.set_pixel(ox + p % GW, oy + p / GW, white)
	return img


func _process(delta: float) -> void:
	if _off:
		return
	_now += delta
	var cs := get_tree().current_scene
	_t_retry += delta
	if cs != _scene or (_overlay == null and _t_retry > 1.0):
		_scene = cs
		_t_retry = 0.0
		_attach()
	if _overlay == null or not is_instance_valid(_overlay) or not is_instance_valid(_pp):
		_overlay = null
		return
	_track(delta)
	_sync_overlay()
	_t_draw += delta
	if _t_draw >= 1.0 / float(_rate()):
		_t_draw = 0.0
		_compose()


# The game's respawn key, taken as ingame_main.gd takes it: R, unless the
# game is paused or you are typing in the chat.
func _input(event: InputEvent) -> void:
	if _off or not (event is InputEventKey) or not event.pressed or (event as InputEventKey).keycode != KEY_R:
		return
	var gs := get_node_or_null("/root/ZGamestate")
	if gs != null and gs.get("is_paused") == true:
		return
	var chat := _scene.get_node_or_null("%ChatInput") if _scene != null and is_instance_valid(_scene) else null
	if chat != null and chat.has_method("is_editing") and bool(chat.call("is_editing")):
		return
	_r_key = true


# How often the OSD is redrawn: about 15 times a second as a Betaflight OSD
# chip is, or 30 - every other video field - with any of BrainFPV's parts.
func _rate() -> int:
	if _brainfpv_drawn() or (bool(cfg["show_sticks"]) and _sticks_style == "brainfpv"):
		return 30
	return 15


# The g-force a flight controller's accelerometer would read: the change in
# the quad's velocity each physics tick plus gravity, smoothed like
# Betaflight's accelerometer.
func _physics_process(dt: float) -> void:
	if _off or dt <= 0.0 or _player == null or not is_instance_valid(_player) or not (_player is Node3D):
		_g_have = false
		return
	var pos := (_player as Node3D).global_position
	if _rc_elrs:
		_rc_t += dt
		if _rc_t >= 0.2:
			_rc_t = 0.0
			_rc_walls_db = _rc_walls(_rc_pilot(), pos)
	var v = _player.get("linear_velocity")
	var vel: Vector3 = v if v is Vector3 else ((pos - _g_pos) / dt if _g_have else Vector3.ZERO)
	# a respawn or flip-over moves the quad without flying it there
	var jump := _g_have and pos.distance_to(_g_pos) > maxf(vel.length(), _g_vel.length()) * dt * 2.0 + 0.5
	if not _g_have or jump:
		_g_have = true
		_g_pos = pos
		_g_vel = vel
		_g_acc = Vector3(0, 9.81, 0)
		return
	var a := (vel - _g_vel) / dt + Vector3(0, 9.81, 0)
	_g_acc += (a - _g_acc) * (1.0 - exp(-dt * TAU * ACC_LPF_HZ))
	g_force = minf(_g_acc.length() / 9.81, ACC_MAX_G)
	_g_pos = pos
	_g_vel = vel
	if _armed:
		_st["max_g"] = maxf(float(_st["max_g"]), g_force)


# Put the OSD layer between the 3D view and the game's post-process rect, so
# the post-process picks it up with the rest of the picture.
func _attach() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_pp = null
	_player = null
	_game_box = null
	_game_sticks = null
	_game_left = null
	if _scene == null:
		return
	_pp = _scene.get_node_or_null("%PostProcessingShader") as CanvasItem
	if _pp == null or _pp.get_parent() == null:
		_pp = null
		return
	_player = _scene.find_child("Player", true, false)
	var sh = load(_dir + "osd_overlay.gdshader")
	if not (sh is Shader):
		return
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("osd_tex", _tex)
	_overlay = ColorRect.new()
	_overlay.name = "AnalogOSD"
	_overlay.material = mat
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var parent := _pp.get_parent()
	parent.add_child(_overlay)
	parent.move_child(_overlay, _pp.get_index())
	var m = _pp.material
	if m is ShaderMaterial and m.shader != null:
		var d = RenderingServer.shader_get_parameter_default(m.shader.get_rid(), "degrade_span")
		if d != null:
			_span = maxf(float(d), 1.0)
	_have_pos = false
	_g_have = false
	stats_visible = false
	_new_pack()


func _sync_overlay() -> void:
	var ws := _overlay.get_viewport().get_visible_rect().size
	_overlay.global_position = Vector2.ZERO
	_overlay.size = ws
	var om := _overlay.material as ShaderMaterial
	var analog := true
	var m = _pp.material
	if m is ShaderMaterial:
		var a = m.get_shader_parameter("is_analog")
		if a != null:
			analog = bool(a)
		for k in ["fisheye_strength", "fisheye_crop"]:
			var v = m.get_shader_parameter(k)
			if v != null:
				om.set_shader_parameter(k, v)
				if k == "fisheye_strength":
					_fe_k = float(v)
				else:
					_fe_crop = float(v)
	_overlay.visible = analog or bool(cfg["show_in_digital"])
	# The game's grey message box (DISARMED, "Press R to reset..."). The game
	# sets its visibility every frame, so it is faded out instead; it comes
	# back whenever this OSD is not showing.
	if _game_box == null or not is_instance_valid(_game_box):
		_game_box = _scene.get_node_or_null("%OSDContainer") as CanvasItem
	if _game_box != null:
		_game_box.modulate.a = 0.0 if bool(cfg["hide_game_messages"]) and _overlay.visible else 1.0
	# the game's own stick overlay, while this one stands in for it
	if _game_sticks == null or not is_instance_valid(_game_sticks):
		_game_sticks = _scene.get_node_or_null("%StickOverlayContainer") as CanvasItem
	if _game_sticks != null:
		_game_sticks.modulate.a = 0.0 if bool(cfg["show_sticks"]) and _overlay.visible else 1.0
	_win_h = maxf(ws.y, 1.0)
	if _game_left == null or not is_instance_valid(_game_left):
		_game_left = _scene.get_node_or_null("%StickOverlayLeft") as Control
	if _game_left != null and _game_left.size.y > 1.0:
		_game_stick_px = _game_left.size.y
	# the game letterboxes the picture to its aspect-ratio setting
	var ar := 4.0 / 3.0
	var zs := get_node_or_null("/root/ZSettings")
	if zs != null:
		match str(zs.get("ASPECT_RATIO")):
			"16_9":
				ar = 16.0 / 9.0
			"native":
				ar = ws.x / maxf(ws.y, 1.0)
	var w := minf(ws.y * ar, ws.x)
	var x0 := (ws.x - w) * 0.5 / maxf(ws.x, 1.0)
	_pic = Vector4(x0, 0.0, 1.0 - x0, 1.0)
	om.set_shader_parameter("pic", _pic)


func _track(delta: float) -> void:
	var armed := false
	var p := _player if _player != null and is_instance_valid(_player) else null
	if p != null and p.has_method("is_armed"):
		armed = bool(p.call("is_armed"))
	var pos := (p as Node3D).global_position if p is Node3D else Vector3.ZERO
	if armed and not _armed:
		# arming: Betaflight clears the stats screen and starts a new flight
		_armed_msg_until = _now + 1.5
		_home = pos
		stats_visible = false
		_stats_reset()
		_st_pending = false
	elif _armed and not armed:
		_end_flight(true, false, pos)
	_armed = armed
	_on_time += delta
	if armed:
		_fly_time += delta
	var respawned := false
	if p is Node3D:
		# a respawn: the game's R key; the radio's respawn switch (the game's
		# _respawn_switch_cycled flipping off as it respawns); the quad
		# arriving exactly on the game's respawn point, or anything else that
		# moves it more than 4 m in one frame. The spawn point moving onto the
		# quad - S saving where you are, X, a race track - is not one.
		var at_spawn := false
		var moved := false
		var gs := get_node_or_null("/root/ZGamestate")
		var rt = gs.get("respawn_transform") if gs != null else null
		if rt is Transform3D:
			at_spawn = pos.distance_to(rt.origin) < 0.05
			moved = _have_spawn and rt.origin.distance_to(_spawn_last) > 0.001
			_spawn_last = rt.origin
			_have_spawn = true
		var sw = _scene.get("_respawn_switch_cycled") if _scene != null and is_instance_valid(_scene) else null
		var radio: bool = sw is bool and _sw_last is bool and _sw_last and not sw
		_sw_last = sw
		var jumped := _have_pos and pos.distance_to(_last_pos) > 4.0
		var arrived := _have_pos and at_spawn and not _at_spawn and not moved
		if _r_key or radio or jumped or arrived:
			respawned = true
			_respawned(armed, pos)
		elif _have_pos and armed:
			_st["dist"] = float(_st["dist"]) + Vector2(pos.x - _last_pos.x, pos.z - _last_pos.z).length()
		_at_spawn = at_spawn
		_last_pos = pos
		_have_pos = true
	_r_key = false
	# link figures follow the signal with a short lag, like a receiver's average
	_lost_s += (_lost() - _lost_s) * clampf(delta / 0.4, 0.0, 1.0)
	if _rc_elrs and p is Node3D:
		var target := _rc_target((p as Node3D).global_position)
		if not _rc_have:
			_rc_db = target
			_rc_have = true
		_rc_db += (target - _rc_db) * clampf(delta / 0.4, 0.0, 1.0)
	var thr := _throttle()
	_battery(delta, thr, armed)
	_battery_filter(delta)
	if bool(cfg["show_fuel_gauge"]) or bool(cfg["warnings_use_fuel_gauge"]):
		_fuel_gauge(delta, thr if armed else 0.0)
	_battery_warnings()
	if armed and not respawned:
		_stats_update(delta, thr, pos)
	if stats_visible:
		_stats_maybe_clear(armed, thr, pos)


func _respawned(armed: bool, pos: Vector3) -> void:
	_end_flight(bool(cfg["stats_on_respawn"]), armed, pos)
	if armed:
		_stats_reset()
		_st_pending = false
	_fly_time = 0.0
	_home = pos
	match str(cfg["new_pack_on_respawn"]):
		"always":
			_new_pack()
		"never":
			pass
		_:
			if not armed:
				_new_pack()


func _throttle() -> float:
	if _player == null or not is_instance_valid(_player):
		return 0.0
	var t = _player.get("throttle_input")
	return clampf(float(t), 0.0, 1.0) if t != null else 0.0


func _pitch_stick() -> float:
	if _player == null or not is_instance_valid(_player):
		return 0.0
	var s = _player.get("stick_pos")
	return float(s.y) if s is Vector4 else 0.0


func _new_pack() -> void:
	_mah = 0.0
	_vp = 0.0
	_amps = 0.0
	_v = _ocv(1.0)
	_fly_time = 0.0


func _cell_count() -> int:
	return clampi(int(cfg["battery_cells"]), 1, 8)


func _ocv(soc: float) -> float:
	var curve: Array = LIHV if bool(cfg["battery_lihv"]) else LIPO
	for i in range(1, curve.size()):
		if soc <= curve[i][0]:
			var a = curve[i - 1]
			var b = curve[i]
			return lerpf(a[1], b[1], (soc - a[0]) / (b[0] - a[0]))
	return curve[-1][1]


# Current scales with the pack (same C-rates for a 1S 450 as a 4S 1500), so
# flight time and sag per cell stay about the same whatever is set.
func _battery(dt: float, thr: float, armed: bool) -> void:
	var prov := battery_provider()
	_from_mod = not prov.is_empty()
	if _from_mod:
		_v = float(prov.get("cell_voltage", _v))
		_mah = float(prov.get("mah_used", _mah))
		_amps = float(prov.get("current", 0.0))
		_shown_cells = clampi(int(prov.get("cells", _cell_count())), 1, 8)
		_shown_lihv = bool(prov.get("lihv", cfg["battery_lihv"]))
		_capacity = float(prov.get("capacity_mah", 0.0))
		return
	var n := _cell_count()
	_shown_cells = n
	_shown_lihv = bool(cfg["battery_lihv"])
	var cap := maxf(float(cfg["battery_mah"]), 50.0) / 1000.0
	_capacity = cap * 1000.0
	var amps := 2.0 / maxf(_v * n, 1.0)          # flight controller and VTX, ~2 W
	if armed:
		amps += cap * (2.0 + 34.0 * pow(thr, 1.6))
	_amps = amps
	_mah += amps * dt / 3.6
	var soc := clampf(1.0 - _mah / (cap * 1000.0), 0.0, 1.0)
	var r_cell := 0.045 * 0.45 / cap              # 45 mOhm for a 450 mAh cell
	_vp += (amps * r_cell * 0.27 - _vp) * clampf(dt / 3.0, 0.0, 1.0)
	var target := _ocv(soc) - amps * r_cell - _vp
	_v += (target - _v) * clampf(dt * 8.0, 0.0, 1.0)


## The first loaded mod that reports a battery, or {}.
func battery_provider() -> Dictionary:
	if _core == null or not _core.has_method("get_mods"):
		return {}
	for m in _core.call("get_mods"):
		if m != get_parent() and is_instance_valid(m) and m.has_method("zm_battery"):
			var d = m.call("zm_battery")
			if d is Dictionary:
				return d
	return {}


# The voltage Betaflight shows and warns on: the pack's, low-passed. A new
# pack (the mAh count going back, or a different cell count) starts it afresh,
# as plugging one in does.
func _battery_filter(dt: float) -> void:
	var fresh := not _vf_ready or _mah < _mah_prev - 0.5 or _shown_cells != _cells_prev
	_fresh_pack = fresh
	if fresh:
		_vf = _v
		_vf_ready = true
		_vstate = BAT_OK
		_t_vchange = _now
		_on_time = 0.0
		_wh = 0.0
	else:
		_vf += (_v - _vf) * (1.0 - exp(-dt / VBAT_TAU))
		if _mah > _mah_prev:
			_wh += _vf * float(_shown_cells) * (_mah - _mah_prev) / 1000.0
	_mah_prev = _mah
	_cells_prev = _shown_cells


# QUICKSILVER's fuel gauge (vbat_calc and vbat_auto_vdrop), a step every
# millisecond as its 1 kHz task. The pack voltage is filtered at 5 Hz, a
# little of the slow li-ion recovery is added (CF1), and the sag is put back
# as a factor times the throttle - the motors' average output, which is the
# throttle here. The factor is learnt in flight: twelve candidates, 0 to
# 1.1 V at full throttle, each high-passed so the pack draining drops out,
# and the one that leaves the least wobble wins, plus 0.1 V as QUICKSILVER
# adds. It learns only above 10% throttle. A fresh pack starts it over, as
# plugging one in restarts the flight controller.
func _fuel_gauge(dt: float, thr: float) -> void:
	var cells := float(maxi(_shown_cells, 1))
	var vpack := _v * cells
	if not _qs_ready or _fresh_pack:
		_qs_ready = true
		_qs_acc = 0.0
		_qs_sag = vpack
		_qs_decay = vpack
		_qs_thr = 0.0
		_qs_z = 0
		_qs_min = 0
		_qs_lastin.resize(12)
		_qs_lastout.resize(12)
		_qs_score.resize(12)
		_qs_lastin.fill(0.0)
		_qs_lastout.fill(0.0)
		_qs_score.fill(0.0)
		fuel_gauge = _v
		_fg_warn = _v
	_qs_acc += dt
	var steps := 0
	var comp := fuel_gauge * cells
	while _qs_acc >= QS_DT and steps < 250:
		_qs_acc -= QS_DT
		steps += 1
		_qs_sag += QS_SAG_A * (vpack - _qs_sag)
		_qs_decay = _qs_decay * QS_DECAY_K + _qs_sag * (1.0 - QS_DECAY_K)
		_qs_thr += QS_THR_A * (thr - _qs_thr)
		var temp := _qs_sag * (1.0 + QS_CF1) - _qs_decay * QS_CF1
		comp = temp + _qs_vdrop(_qs_thr, temp) * _qs_thr
	if steps >= 250:
		_qs_acc = 0.0
	fuel_gauge = comp / cells
	fuel_vdrop = _qs_min * 0.1
	# for warnings_use_fuel_gauge: Betaflight's warnings expect its smoothed
	# voltage, and the gauge jumps for a moment when the motors spin up or down
	_fg_warn += (fuel_gauge - _fg_warn) * (1.0 - exp(-dt / VBAT_TAU))


func _qs_vdrop(thrfilt: float, tempvolt: float) -> float:
	if thrfilt <= 0.1:
		return _qs_min * 0.1
	var z := _qs_z
	var vcomp := tempvolt + float(z) * 0.1 * thrfilt
	var ans := vcomp - _qs_lastin[z] + QS_HP_K * _qs_lastout[z]
	_qs_lastin[z] = vcomp
	_qs_lastout[z] = ans
	_qs_score[z] = _qs_score[z] * QS_SCORE_K + ans * ans * (1.0 - QS_SCORE_K)
	_qs_z += 1
	if _qs_z >= 12:
		_qs_z = 0
		# as QUICKSILVER: when the first is the lowest the choice stays as it was
		var mn := _qs_score[0]
		for i in 12:
			if _qs_score[i] < mn:
				mn = _qs_score[i]
				_qs_min = i + 1
	return _qs_min * 0.1


# Volts a cell from settings.cfg; Betaflight writes 3.50 V as 350.
func _volts(key: String) -> float:
	var v := float(cfg[key])
	return v / 100.0 if v >= 10.0 else maxf(v, 0.0)


# Betaflight's battery state (batteryUpdateVoltageState and
# batteryUpdateConsumptionState): OK, WARNING (LOW BATTERY) or CRITICAL
# (LAND NOW), by the smoothed voltage and optionally by the mAh left.
func _battery_warnings() -> void:
	var n := float(_shown_cells)
	var vp := (_fg_warn if bool(cfg["warnings_use_fuel_gauge"]) and _qs_ready else _vf) * n
	var lo := _volts("low_battery_voltage")
	var ln := _volts("land_now_voltage")
	# with LOW BATTERY off, LAND NOW still goes through the warning state
	var lo_eff := maxf(lo, ln) if lo > 0.0 else ln
	var warn_v := lo_eff * n
	var crit_v := ln * n
	match _vstate:
		BAT_OK:
			if lo_eff > 0.0 and vp <= warn_v - VBAT_HYSTERESIS:
				if _now - _t_vchange >= float(cfg["low_battery_delay"]):
					_vstate = BAT_WARNING
			else:
				_t_vchange = _now
		BAT_WARNING:
			if ln > 0.0 and vp <= crit_v - VBAT_HYSTERESIS:
				if _now - _t_vchange >= float(cfg["land_now_delay"]):
					_vstate = BAT_CRITICAL
			else:
				if vp > warn_v:
					_vstate = BAT_OK
				_t_vchange = _now
		BAT_CRITICAL:
			if vp > crit_v:
				_vstate = BAT_WARNING
				_t_vchange = _now
	_cstate = BAT_OK
	var pct := int(cfg["low_battery_percent"])
	if pct > 0 and _capacity > 0.0:
		var left := int(clampf((_capacity - _mah) * 100.0 / _capacity, 0.0, 100.0))
		if left <= 0:
			_cstate = BAT_CRITICAL
		elif left <= pct:
			_cstate = BAT_WARNING
	bat_state = maxi(_vstate, _cstate)


func _low_battery() -> bool:
	if bat_state != BAT_WARNING:
		return false
	return _cstate == BAT_WARNING or (_vstate == BAT_WARNING and _volts("low_battery_voltage") > 0.0)


func _over_cap() -> bool:
	return int(cfg["over_cap_mah"]) > 0 and _mah >= float(cfg["over_cap_mah"])


func _timer_alarm() -> bool:
	return float(cfg["timer_alarm"]) > 0.0 and _fly_time >= float(cfg["timer_alarm"]) * 60.0


func _lost() -> float:
	var q = null
	if _pp != null and _pp.material is ShaderMaterial:
		q = (_pp.material as ShaderMaterial).get_shader_parameter("signal_quality")
	return clampf((100.0 - (float(q) if q != null else 100.0)) / _span, 0.0, 1.0)


# Link quality. The control link's: 100 until the signal is within a few dB of
# what the receiver can hear, then down to 0 (RXLOSS) over the last 7 dB.
# With rc_link="video", the video signal's: 100 close in, easing down over the
# whole range to 0 where the picture is gone (in the open: ~90 at 40 m, ~50
# at 85 m, 0 at 120 m).
func _lq() -> int:
	if _rc_elrs:
		return int(round(100.0 * smoothstep(-4.0, 3.0, _rc_db - RC_SENS_DBM)))
	if _lost_s <= 0.1:
		return 100
	return int(round(100.0 * (1.0 - pow(minf((_lost_s - 0.1) / 0.9, 1.0), 1.6))))


func _rssi_dbm() -> int:
	if _rc_elrs:
		return int(round(clampf(_rc_db, -130.0, -1.0)))
	return int(round(-38.0 - 67.0 * pow(_lost_s, 0.85)))


func _rc_power() -> int:
	return clampi(int(cfg["rc_power"]), 1, 2000)


# Where you stand with the radio: the spawn point, at chest height
func _rc_pilot() -> Vector3:
	var gs := get_node_or_null("/root/ZGamestate")
	var rt = gs.get("respawn_transform") if gs != null else null
	return (rt.origin if rt is Transform3D else Vector3.ZERO) + Vector3(0.0, RC_PILOT_H, 0.0)


# What reaches the receiver on the quad, dBm
func _rc_target(quad: Vector3) -> float:
	var d := maxf(_rc_pilot().distance_to(quad), 1.0)
	var fspl := 20.0 * log(d) / log(10.0) + 20.0 * log(RC_MHZ) / log(10.0) - 27.55
	return 10.0 * log(float(_rc_power())) / log(10.0) + RC_ANT_DB - fspl - RC_FADE_DB - _rc_walls_db


# The walls between the radio and the quad, as the game measures them for the
# video: a ray each way, and each wall's thickness between where the two
# rays go into it
func _rc_walls(a: Vector3, b: Vector3) -> float:
	var world := (_player as Node3D).get_world_3d()
	if world == null or world.direct_space_state == null:
		return 0.0
	var space := world.direct_space_state
	var d := b - a
	if d.length() < 1.5:
		return 0.0
	b -= d.normalized() * 0.5        # not the ground the quad sits on
	var fwd := _rc_hits(space, a, b)
	var back := _rc_hits(space, b, a)
	var db := 0.0
	for rid in fwd:
		if back.has(rid):
			db += RC_WALL_DB + RC_WALL_DB_M * minf((fwd[rid] as Vector3).distance_to(back[rid]), 1.0)
	return minf(db, RC_WALLS_MAX_DB)


func _rc_hits(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var out := {}
	var ex: Array[RID] = []
	if _player is CollisionObject3D:
		ex.append((_player as CollisionObject3D).get_rid())
	for i in 24:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = ex
		var r := space.intersect_ray(q)
		if r.is_empty():
			break
		ex.append(r["rid"])
		var c = r["collider"]
		if c is StaticBody3D or c is CSGShape3D:
			out[r["rid"]] = r["position"]
	return out


# RSSI as a percentage, the way Betaflight turns a CRSF/ELRS receiver's dBm
# into one (-130 dBm = 0%, 0 dBm = 100%)
func _rssi_pct() -> int:
	return int(clampf((float(_rssi_dbm()) + 130.0) / 130.0 * 100.0, 0.0, 100.0))


# ---- post-flight stats ----

func _stats_reset() -> void:
	_st = {"armed_time": 0.0, "max_alt": 0.0, "max_speed": 0.0, "max_dist": 0.0, "dist": 0.0,
		"min_v": 99.0, "max_amps": 0.0, "min_rssi": 100, "min_lq": 100, "min_dbm": 0,
		"max_g": 0.0, "thr_raised": false, "full_time": 0.0, "full_count": 0, "was_full": false,
		"thr_sum": 0.0, "thr_time": 0.0}


func _stats_update(dt: float, thr: float, pos: Vector3) -> void:
	_st_pending = true
	_st["armed_time"] = float(_st["armed_time"]) + dt
	_st["max_alt"] = maxf(float(_st["max_alt"]), pos.y - _home.y)
	if _player != null and is_instance_valid(_player) and _player.has_method("get_speed_kph"):
		_st["max_speed"] = maxf(float(_st["max_speed"]), float(_player.call("get_speed_kph")))
	_st["max_dist"] = maxf(float(_st["max_dist"]), Vector2(pos.x - _home.x, pos.z - _home.z).length())
	_st["min_v"] = minf(float(_st["min_v"]), _vf)
	_st["max_amps"] = maxf(float(_st["max_amps"]), _amps)
	_st["min_rssi"] = mini(int(_st["min_rssi"]), _rssi_pct())
	_st["min_lq"] = mini(int(_st["min_lq"]), _lq())
	_st["min_dbm"] = mini(int(_st["min_dbm"]), _rssi_dbm())
	# Betaflight's RC stats: counted from the first time the throttle goes
	# past 15% after arming, not in crash-flip mode
	var pct := int(round(thr * 100.0))
	if not _turtle():
		if pct >= 15:
			_st["thr_raised"] = true
		if bool(_st["thr_raised"]):
			_st["thr_sum"] = float(_st["thr_sum"]) + pct * dt
			_st["thr_time"] = float(_st["thr_time"]) + dt
			var full := pct >= 100
			if full:
				_st["full_time"] = float(_st["full_time"]) + dt
				if not bool(_st["was_full"]):
					_st["full_count"] = int(_st["full_count"]) + 1
			_st["was_full"] = full


# The end of a flight: disarming, or a respawn. Adds it to the totals and,
# when show is set, freezes the flight's numbers and puts the stats screen up.
func _end_flight(show: bool, while_armed: bool, pos: Vector3) -> void:
	if not _st_pending:
		return
	_st_pending = false
	# a respawn with the quad never flown is not a flight
	if while_armed and not bool(_st["thr_raised"]):
		return
	var flight_s := float(_st["armed_time"])
	if flight_s >= TOTALS_MIN_S and _wants_totals():
		_totals["flights"] = int(_totals["flights"]) + 1
		_totals["time_s"] = float(_totals["time_s"]) + flight_s
		_totals["distance_m"] = float(_totals["distance_m"]) + float(_st["dist"])
		_save_totals()
	if not show or not bool(cfg["stats"]) or _stat_keys.is_empty() or _lq() <= 0:
		return   # Betaflight shows no stats after a failsafe either
	_shown = _st.duplicate()
	_shown["end_v"] = _vf
	_shown["mah"] = _mah
	_shown["wh"] = _wh
	_shown["on_time"] = _on_time
	_shown["fly_time"] = _fly_time
	_shown["cells"] = _shown_cells
	_shown["totals"] = _totals.duplicate()
	_shown["date"] = Time.get_datetime_dict_from_system()
	stats_visible = true
	_stats_until = _now + STATS_SHOW_S
	_stats_while_armed = while_armed
	_stats_anchor = pos


# Betaflight clears the stats after 60 s, or when the throttle or the pitch
# stick goes more than halfway up, or crash-flip mode comes on (arming clears
# them too). Stats put up by a respawn with the quad armed also go when it
# moves off the spot.
func _stats_maybe_clear(armed: bool, thr: float, pos: Vector3) -> void:
	var clear := _now >= _stats_until or thr > 0.75 or _turtle()
	if not armed and _pitch_stick() > 0.5:
		clear = true
	if _stats_while_armed and (not armed or pos.distance_to(_stats_anchor) > 1.0):
		clear = true
	if clear:
		stats_visible = false


func _turtle() -> bool:
	var gs := get_node_or_null("/root/ZGamestate")
	var osdv = gs.get("OSD_VALUES") if gs != null else null
	return osdv is Dictionary and str(osdv.get("turtle_mode", "")) != ""


func _wants_totals() -> bool:
	for k in TOTALS_KEYS:
		if bool(cfg[k]):
			return true
	return false


func _totals_path() -> String:
	return OS.get_executable_path().get_base_dir().path_join(_dir.trim_prefix("res://").path_join("totals.cfg"))


func _load_totals() -> void:
	if not _wants_totals():
		return
	var c := ConfigFile.new()
	if c.load(_totals_path()) == OK:
		for k in _totals:
			_totals[k] = c.get_value("totals", k, _totals[k])


func _save_totals() -> void:
	var c := ConfigFile.new()
	for k in _totals:
		c.set_value("totals", k, _totals[k])
	c.save(_totals_path())


func _mmss(s: float) -> String:
	var t := int(s)
	return "%02d:%02d" % [mini(t / 60, 99), t % 60]


# Betaflight's osdFormatDistanceString, metric: whole metres, then km with two
# decimals (one from 10 km), cut rather than rounded
func _distance(m: float) -> String:
	if m < 1000.0:
		return "%d" % int(m) + char(SYM_M)
	var km := m / 1000.0
	if km >= 10.0:
		return "%.1f" % (floor(km * 10.0) / 10.0) + char(SYM_KM)
	return "%.2f" % (floor(km * 100.0) / 100.0) + char(SYM_KM)


func _stat_line(k: String) -> Array:
	var s := _shown
	var per_cell := bool(cfg["stat_cell_voltage"])
	var n := 1.0 if per_cell else float(s["cells"])
	match k:
		"stat_date_time":
			var d: Dictionary = s["date"]
			return ["%04d-%02d-%02d %02d:%02d:%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]], ""]
		"stat_on_time":
			return ["ON TIME", _mmss(float(s["on_time"]))]
		"stat_armed_time":
			return ["TOTAL ARM", _mmss(float(s["fly_time"]))]
		"stat_max_altitude":
			return ["MAX ALTITUDE", "%.1f" % float(s["max_alt"]) + char(SYM_M)]
		"stat_max_speed":
			return ["MAX SPEED", "%d" % int(round(float(s["max_speed"]))) + char(SYM_KPH)]
		"stat_max_distance":
			return ["MAX DISTANCE", _distance(float(s["max_dist"]))]
		"stat_flight_distance":
			return ["FLIGHT DISTANCE", _distance(float(s["dist"]))]
		"stat_min_battery":
			var mv := float(s["min_v"]) if float(s["min_v"]) < 90.0 else float(s["end_v"])
			return ["MIN AVG CELL" if per_cell else "MIN BATTERY", "%.2f" % (mv * n) + char(SYM_VOLT)]
		"stat_end_battery":
			return ["END AVG CELL" if per_cell else "END BATTERY", "%.2f" % (float(s["end_v"]) * n) + char(SYM_VOLT)]
		"stat_battery":
			# the pack now, as it recovers
			return ["AVG BATT CELL" if per_cell else "BATTERY", "%.2f" % (_vf * (1.0 if per_cell else float(_shown_cells))) + char(SYM_VOLT)]
		"stat_min_rssi":
			return ["MIN RSSI", "%d%%" % int(s["min_rssi"])]
		"stat_max_current":
			return ["MAX CURRENT", "%.2f" % (floor(float(s["max_amps"]) * 100.0) / 100.0) + char(SYM_AMP)]
		"stat_used_mah":
			return ["USED MAH", "%d" % int(s["mah"]) + char(SYM_MAH)]
		"stat_max_g_force":
			return ["MAX G-FORCE", "%.1fG" % float(s["max_g"])]
		"stat_min_link_quality":
			return ["MIN LINK", "%d%%" % int(s["min_lq"])]
		"stat_min_rssi_dbm":
			return ["MIN RSSI DBM", "%3d" % int(s["min_dbm"])]
		"stat_total_flights":
			return ["TOTAL FLIGHTS", "%d" % int(s["totals"]["flights"])]
		"stat_total_time":
			var mins := int(float(s["totals"]["time_s"])) / 60
			return ["TOTAL FLIGHT TIME", "%d:%02dH" % [mins / 60, mins % 60]]
		"stat_total_distance":
			return ["TOTAL DISTANCE", "%d" % (int(float(s["totals"]["distance_m"])) / 1000) + char(SYM_KM)]
		"stat_watt_hours":
			return ["USED WATT HOURS", "%.2f" % float(s["wh"])]
		"stat_full_throttle_time":
			return ["100% THRT TIME", _mmss(float(s["full_time"]))]
		"stat_full_throttle_count":
			return ["100% THRT COUNT", "%d" % int(s["full_count"])]
		"stat_avg_throttle":
			var tt := float(s["thr_time"])
			return ["AVG THROTTLE", "%d" % (int(float(s["thr_sum"]) / tt + 0.5) if tt > 0.0 else 0)]
	return ["", ""]


# Betaflight's layout (osdRenderStatsContinue, osdDisplayStatisticLabel):
# centred up and down, "--- STATS ---" on top when there is room, the label
# 13 columns left of the middle, the colon 5 right and the value 7 right.
func _compose_stats() -> void:
	var rows := _stat_keys.slice(0, ROWS)
	var shown := rows.size()
	var label := shown < ROWS
	var row := (ROWS - (shown + (1 if label else 0))) / 2
	var mid := COLS / 2
	if label:
		_text(mid - 6, row, "--- STATS ---")
		row += 1
	for k in rows:
		var l := _stat_line(k)
		_text(mid - 13, row, l[0])
		if l[1] != "":
			_text(mid + 5, row, ":")
			_text(mid + 7, row, l[1])
		row += 1


func _text(col: int, row: int, s: String) -> void:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x61 and c <= 0x7A:
			c -= 0x20                # the font has capitals only
		_sym(col + i, row, c & 0xFF)


func _sym(col: int, row: int, code: int) -> void:
	if col >= 0 and col < COLS and row >= 0 and row < ROWS:
		_cells[row * COLS + col] = code


func _center(row: int, s: String) -> void:
	_text((COLS - s.length()) / 2, row, s)


func _compose() -> void:
	_cells.fill(0x20)
	_over.clear()
	_over_late.clear()
	_ibusy.clear()
	_abusy.clear()
	if stats_visible:
		_compose_stats()
		_draw_cells(false)
		return
	# Betaflight blinks at 2 Hz, half on and half off
	var blink := fmod(_now, 0.5) < 0.25
	var lq := _lq()
	if cfg["show_lq"]:
		_sym(1, 0, SYM_LINK_QUALITY)
		_text(2, 0, "%3d" % lq)
	if cfg["show_rssi"]:
		_sym(6, 0, SYM_RSSI)
		_text(7, 0, "%d" % _rssi_dbm())
	if cfg["show_timer"] and (blink or not _timer_alarm()):
		var t := int(_fly_time)
		_sym(23, 0, SYM_FLY_M)
		_text(24, 0, "%02d:%02d" % [mini(t / 60, 99), t % 60])
	if cfg["show_speed"] and _player != null and is_instance_valid(_player) and _player.has_method("get_speed_kph"):
		_text(1, 1, "%3d" % int(round(float(_player.call("get_speed_kph")))))
		_sym(4, 1, SYM_KPH)
	if cfg["show_altitude"] and _player is Node3D:
		var alt := (_player as Node3D).global_position.y - _home.y
		_sym(22, 1, SYM_ALTITUDE)
		_text(23, 1, "%5.1f" % clampf(alt, -99.9, 999.9))
		_sym(28, 1, SYM_M)
	if bool(cfg["show_compass"]):
		_compass()
	if bool(cfg["show_home"]):
		_home_bf()
	if bool(cfg["show_sticks"]) and _sticks_style == "betaflight":
		_sticks()
	if bool(cfg["show_horizon"]) or bool(cfg["show_horizon_sidebars"]):
		_horizon()
	if _inav != null:
		_inav_elements(blink)
	if _inav != null and (bool(cfg["hud_homepoint"]) or bool(cfg["hud_homing"]) or _radar_n() > 0):
		_inav_hud()
	if bool(cfg["show_up_down"]):
		_up_down()
	if bool(cfg["show_flip_arrow"]):
		_flip_arrow()
	warning = ""
	if cfg["show_warnings"]:
		# in Betaflight's order of priority
		var w := ""
		var blinking := false
		var gs := get_node_or_null("/root/ZGamestate")
		var osdv = gs.get("OSD_VALUES") if gs != null else null
		# first, why it cannot arm - shown while the arm switch is on (armed,
		# or trying to arm), a new reason every half second when there are
		# more than one
		var trying := osdv is Dictionary and str(osdv.get("arm_warning", "")) != ""
		var why := []
		if lq <= 0 and (_armed or trying):
			why.append("RXLOSS")
		if trying:
			why.append("THROTTLE")
		if not why.is_empty():
			w = why[int(_now / 0.5) % why.size()]
		elif _turtle():
			w = CRASH_FLIP_WARNING
		elif bat_state == BAT_CRITICAL:
			w = "LAND NOW"
			blinking = true
		elif _low_battery():
			w = "LOW BATTERY"
			blinking = true
		elif _armed and _over_cap():
			w = "OVER CAP"
			blinking = true
		elif _now < _armed_msg_until:
			w = "ARMED"
		elif not _armed and bool(cfg["hide_game_messages"]):
			w = "DISARMED"
		warning = w
		if w != "" and (blink or not blinking):
			_center(9, w)
	if cfg["show_throttle"]:
		_sym(1, 11, SYM_THR)
		_text(2, 11, "%3d" % int(round(_throttle() * 100.0)))
	if bool(cfg["show_fuel_gauge"]) and _qs_ready:
		# QUICKSILVER's OSD_FUELGAUGE_VOLTS: four wide, one decimal, then its gauge
		var fv := fuel_gauge if str(cfg["battery_voltage"]) == "cell" else fuel_gauge * float(_shown_cells)
		_text(6, 11, _qs_float(fv, 4, 1))
		_sym(10, 11, SYM_SPEED)
	# the voltage blinks while LOW BATTERY or LAND NOW is up, as Betaflight's does
	if cfg["show_battery"] and (blink or bat_state == BAT_OK):
		# the icon goes by volts per cell, like Betaflight's
		var top := (4.30 if _shown_lihv else 4.15)
		var level := clampf((_vf - 3.3) / (top - 3.3), 0.0, 1.0)
		_sym(1, 12, SYM_BATT_EMPTY - int(round(level * float(SYM_BATT_EMPTY - SYM_BATT_FULL))))
		var volts := _vf if str(cfg["battery_voltage"]) == "cell" else _vf * float(_shown_cells)
		var vt := ("%.2f" % volts) if volts < 9.995 else ("%.1f" % minf(volts, 99.9))
		_text(2, 12, vt)
		_sym(2 + vt.length(), 12, SYM_VOLT)
	if str(cfg["craft_name"]) != "":
		_center(12, str(cfg["craft_name"]).left(15))
	if cfg["show_mah"] and (blink or not _over_cap()):
		_text(24, 12, "%4d" % mini(int(_mah), 9999))
		_sym(28, 12, SYM_MAH)
	if cfg["show_current"]:
		_text(23, 11, "%5.1f" % clampf(_amps, 0.0, 999.9))
		_sym(28, 11, SYM_AMP)
	_draw_cells(true)


# QUICKSILVER's osd_write_float: right-aligned in width, the decimals cut to
# fit, and cut off rather than rounded
static func _qs_float(val: float, width: int, precision: int) -> String:
	var neg := val < 0.0
	var digits := 1
	var w := int(absf(val))
	while w > 0:
		w /= 10
		digits += 1
	if neg:
		digits += 1
	precision = 0 if digits > width else clampi(width - digits, 0, precision)
	var v := int(absf(val) * pow(10.0, precision))
	var out := ""
	for i in precision:
		out = str(v % 10) + out
		v /= 10
	if precision > 0:
		out = "." + out
	out = str(v) + out
	if neg:
		out = "-" + out
	return out.lpad(width)


# Betaflight's flip arrow (osdElementCrashFlipArrow): the way to flip the quad
# back over, while crash-flip mode (the game's turtle mode) is on or while
# disarmed and more than small_angle (25 degrees) off level. Above the
# warnings, in the middle.
func _flip_arrow() -> void:
	if not (_player is Node3D) or not is_instance_valid(_player):
		return
	var att := _attitude()
	var roll := att.x / 10
	var pitch := att.y / 10
	if absi(roll) > 90:
		roll = (-180 if roll < 0 else 180) - roll
	var upright := (_player as Node3D).global_transform.basis.orthonormalized().y.y > cos(deg_to_rad(25.0))
	if not (_turtle() or (not _armed and not upright)) or upright or (roll == 0 and pitch == 0):
		return
	var sym: int
	if absi(pitch) < 2 * absi(roll) and absi(roll) < 2 * absi(pitch):
		if pitch > 0:
			sym = SYM_ARROW_WEST + 2 if roll > 0 else SYM_ARROW_EAST - 2
		else:
			sym = SYM_ARROW_WEST - 2 if roll > 0 else SYM_ARROW_EAST + 2
	elif absi(pitch) > absi(roll):
		sym = SYM_ARROW_SOUTH if pitch > 0 else SYM_ARROW_NORTH
	else:
		sym = SYM_ARROW_WEST if roll > 0 else SYM_ARROW_EAST
	_over.append([sym, CX - GW / 2, 8 * GH, "flip_arrow", _font])


# Betaflight's up/down reference (osdElementUpDownReference): while the nose
# points within about 25 degrees of straight up or straight down, a U or a D
# where straight up or down is, from the crosshair - 14 columns or 8 rows for
# 45 degrees, as Betaflight has it. It goes by the quad's own axes, as the
# flight controller does; with horizon_uptilt, by the camera's.
func _up_down() -> void:
	if not (_player is Node3D) or not is_instance_valid(_player):
		return
	var b := (_player as Node3D).global_transform.basis.orthonormalized()
	if bool(cfg["horizon_uptilt"]):
		var cam := _camera()
		if cam != null:
			b = cam.global_transform.basis.orthonormalized()
	# straight down in the quad's axes: forward, left and up
	var fwd := b.z.y
	var left := b.x.y
	var up := -b.y.y
	const SINE_25 := 0.42261826
	if absf(up) >= SINE_25 or absf(left) >= SINE_25:
		return
	var theta: float
	var psi: float
	var sym: int
	if fwd > 0.0:
		# nose down: where straight down is
		theta = -up
		psi = -left
		sym = 0x44
	else:
		theta = up
		psi = left
		sym = 0x55
	var ox := roundi(psi / (PI / 4.0) * 14.0)
	var oy := roundi(theta / (PI / 4.0) * 8.0)
	var x := CX - GW / 2 + ox * GW
	var y := _cross_y() - GH / 2 + oy * GH
	if x < 0 or y < 0 or x > COLS * GW - GW or y > ROWS * GH - GH:
		return
	_over_late.append([sym, x, y, "up_down", _font])


# The quad's attitude as Betaflight has it, in tenths of a degree: roll to the
# right and pitch nose-down positive.
func _attitude() -> Vector2i:
	if _player == null or not is_instance_valid(_player) or not (_player is Node3D):
		return Vector2i.ZERO
	var b := (_player as Node3D).global_transform.basis.orthonormalized()
	var fwd := -b.z
	var pitch := rad_to_deg(asin(clampf(-fwd.y, -1.0, 1.0)))
	var roll := rad_to_deg(atan2(-b.x.y, b.y.y))
	return Vector2i(roundi(roll * 10.0), roundi(pitch * 10.0))


# Betaflight's stick overlay (osdBackgroundStickOverlay, osdElementStickOverlay):
# a box for each stick, sticks_inset columns in from each side.
func _sticks() -> void:
	var sp = _player.get("stick_pos") if _player != null and is_instance_valid(_player) else null
	var st: Vector4 = sp if sp is Vector4 else Vector4(0, 0, -1, 0)
	var mode: Array = RADIO_MODES[clampi(int(cfg["sticks_mode"]), 1, 4) - 1]
	var row := clampi(int(cfg["sticks_row"]), 0, ROWS - STICK_H)
	var inset := clampi(int(cfg["sticks_inset"]), 0, COLS / 2 - STICK_W)
	_stick_box(inset, row, st[mode[0]], st[mode[1]])
	_stick_box(COLS - inset - STICK_W, row, st[mode[2]], st[mode[3]])


func _stick_box(col: int, row: int, vertical: float, horizontal: float) -> void:
	var mid := (STICK_W - 1) / 2
	for y in STICK_H:
		if y != (STICK_H - 1) / 2:
			_sym(col + mid, row + y, SYM_STICK_VERTICAL)
	for x in STICK_W:
		_sym(col + x, row + (STICK_H - 1) / 2, SYM_STICK_CENTER if x == mid else SYM_STICK_HORIZONTAL)
	# as Betaflight works it out from the channel's 1000-2000 us
	var h := clampi(roundi(1500.0 + 500.0 * clampf(horizontal, -1.0, 1.0)), 1000, 1999)
	var v := clampi(roundi(1500.0 + 500.0 * clampf(vertical, -1.0, 1.0)), 1000, 1999)
	var cx := (h - 1000) * STICK_W / 1000
	var cy := STICK_H * 3 - 1 - (v - 1000) * STICK_H * 3 / 1000
	_sym(col + cx, row + cy / 3, SYM_STICK_HIGH + cy % 3)


# Betaflight's artificial horizon (osdElementArtificialHorizon) and horizon
# sidebars (osdBackgroundHorizonSidebars), the same characters in the same
# places, centred on the picture's middle like the crosshair.
func _horizon() -> void:
	var x0 := CX - GW / 2               # the middle column's left edge
	# INAV draws its horizon first and its sidebars over it
	if bool(cfg["show_horizon"]) and _hz_style == "inav" and _inav != null:
		_inav_ahi()
	if bool(cfg["show_horizon_sidebars"]) and _sb_style == "inav":
		if _inav != null:
			_inav_sidebars()
	elif bool(cfg["show_horizon_sidebars"]):
		for y in range(-3, 4):
			_over.append([SYM_AH_DECORATION, x0 - 7 * GW, (6 + y) * GH, "sidebar"])
			_over.append([SYM_AH_DECORATION, x0 + 7 * GW, (6 + y) * GH, "sidebar"])
		_over.append([SYM_AH_LEFT, x0 - 6 * GW, 6 * GH, "level"])
		_over.append([SYM_AH_RIGHT, x0 + 6 * GW, 6 * GH, "level"])
	if bool(cfg["show_horizon"]) and _hz_style == "betaflight" and bool(cfg["horizon_uptilt"]):
		# on the real horizon: each of the nine characters at the height the
		# horizon crosses its column, in the same ninths of a row - anywhere
		# on the screen, not just Betaflight's nine rows, so it is there when
		# the real horizon is low in the picture
		var hzn := _true_horizon()
		if not hzn.is_empty():
			for x in range(-4, 5):
				var hy = _poly_y(hzn["line"], float(x0 + x * GW + GW / 2))
				if hy == null:
					continue
				var yn := roundi((float(hy) - 0.5) / 2.0)
				if yn >= 0 and yn < ROWS * AH_SYMBOL_COUNT:
					_over.append([SYM_AH_BAR9_0 + yn % AH_SYMBOL_COUNT, x0 + x * GW, (yn / AH_SYMBOL_COUNT) * GH, "horizon"])
	elif bool(cfg["show_horizon"]) and _hz_style == "betaflight":
		var att := _attitude()
		var max_p := int(cfg["horizon_max_pitch"]) * 10
		var max_r := int(cfg["horizon_max_roll"]) * 10
		var sgn := -1 if bool(cfg["horizon_invert"]) else 1
		var roll := clampi(att.x * sgn, -max_r, max_r)
		var pitch := clampi(att.y * sgn, -max_p, max_p)
		if max_p > 0:
			pitch = (pitch * 25) / max_p
		pitch -= 41                      # 4 * AH_SYMBOL_COUNT + 5: level sits mid-row 6
		for x in range(-4, 5):
			var y := ((-roll * x) / 64) - pitch
			if y >= 0 and y <= 81:
				_over.append([SYM_AH_BAR9_0 + y % AH_SYMBOL_COUNT, x0 + x * GW, (AH_ROW + y / AH_SYMBOL_COUNT) * GH, "horizon"])


# ---- heading, home ----
# North is the map's -z, and headings turn clockwise from it, as a compass's.

func _heading_deg() -> float:
	if not (_player is Node3D) or not is_instance_valid(_player):
		return 0.0
	var f := -(_player as Node3D).global_transform.basis.z
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


func _bearing(from: Vector3, to: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(to.x - from.x, -(to.z - from.z))), 360.0)


# osdGetHeadingIntoDiscreteDirections: 0..directions-1, sector 0 centred on 0
static func _discrete(heading: int, directions: int) -> int:
	return ((posmod(heading, 360) + 360) * directions + 180) / 360 % directions


# osdGetDirectionSymbolFromHeading: one of the 16 arrows, pointing that way
# on the screen when the heading is relative to the quad's
static func _dir_symbol(heading: int) -> int:
	var h := _discrete(heading, 16)
	return SYM_ARROW_SOUTH + (16 - h + 8) % 16


# Betaflight's compass bar (osdElementCompassBar). INAV's heading graph is the
# same nine characters in the same order, so there is one of them here.
func _compass() -> void:
	var hd := int(_heading_deg())
	var start := _discrete(hd, 16)
	for k in 9:
		_sym(COMPASS_COL + k, 0, COMPASS_BAR[start + k])


# Home, for the home arrow and the HUD: the game's spawn point as it
# is now, so moving it (S, X) moves home at once; where you armed or last
# respawned if there is none
func _nav_home() -> Vector3:
	var gs := get_node_or_null("/root/ZGamestate")
	var rt = gs.get("respawn_transform") if gs != null else null
	return rt.origin if rt is Transform3D else _home


# Betaflight's home arrow and home distance (osdElementGpsHomeDirection and
# osdElementGpsHomeDistance)
func _home_bf() -> void:
	if not (_player is Node3D) or not is_instance_valid(_player):
		return
	var pos := (_player as Node3D).global_position
	var home := _nav_home()
	var d := int(Vector2(home.x - pos.x, home.z - pos.z).length())
	if d > 0:
		_sym(13, 1, _dir_symbol(int(_bearing(pos, home)) - int(_heading_deg())))
	else:
		_sym(13, 1, SYM_OVER_HOME)
	_sym(14, 1, SYM_HOMEFLAG)
	_text(15, 1, _distance(float(d)))


# The camera's uptilt on the quad you are flying, degrees up
func _cam_uptilt() -> float:
	var cam := _camera()
	if cam == null or not (_player is Node3D):
		return 0.0
	var b := (_player as Node3D).global_transform.basis.orthonormalized()
	return rad_to_deg(asin(clampf((-cam.global_transform.basis.z).dot(b.y), -1.0, 1.0)))


# ---- INAV's parts ----
# INAV draws round the crosshair on its grid of characters, its middle at
# column 15, row 6. Here that middle character sits on the crosshair, as the
# rest of the OSD's crosshair parts do; cells are given as columns and rows
# of that grid.

func _ipx(col: int, row: int) -> Vector2i:
	return Vector2i(CX - GW / 2 + (col - I_MID_COL) * GW, _cross_y() - GH / 2 + (row - I_MID_ROW) * GH)


# Whether a cell has something in it: another INAV character this time, or
# the text under it
func _busy(col: int, row: int) -> bool:
	if _ibusy.has(Vector2i(col, row)):
		return true
	var p := _ipx(col, row)
	var r := roundi(float(p.y) / GH)
	if r < 0 or r >= ROWS:
		return false
	for c in [floori(float(p.x) / GW), floori(float(p.x + GW - 1) / GW)]:
		if c >= 0 and c < COLS and (_cells[r * COLS + c] != 0x20 or _abusy.has(Vector2i(c, r))):
			return true
	return false


# An element at INAV's own place for it: a cell of the OSD's grid
func _iabs(col: int, row: int, code: int, what: String) -> void:
	if col < 0 or col >= COLS or row < 0 or row >= ROWS:
		return
	_over.append([code, col * GW, row * GH, what, _inav])
	_abusy[Vector2i(col, row)] = true


# displayWriteChar / osdHudWrite: crush = over whatever is there
func _iput(col: int, row: int, code: int, what: String, crush: bool = true) -> bool:
	if col < 0 or col >= COLS or row < 0 or row >= ROWS:
		return false
	if not crush and _busy(col, row):
		return false
	var p := _ipx(col, row)
	_over.append([code, p.x, p.y, what, _inav])
	_ibusy[Vector2i(col, row)] = true
	return true


# osdGridDrawArtificialHorizon: a line of characters through the crosshair,
# level ones while it is flatter than 45 degrees and upright ones past that,
# so it never breaks up at a steep bank. With horizon_pitch_interval, the line
# nearest the crosshair is the one for that many degrees up or down, its ends
# bent the way you are going. Characters only go where nothing else is.
func _inav_ahi() -> void:
	var att := _attitude()
	var roll := deg_to_rad(att.x / 10.0)
	var pitch := deg_to_rad(att.y / 10.0)
	if bool(cfg["horizon_uptilt"]):
		pitch -= deg_to_rad(_cam_uptilt())            # osd_ahi_camera_uptilt_comp
	if bool(cfg["horizon_invert"]):
		roll = -roll                                   # osd_ahi_reverse_roll
	var p2c := (I_AHI_HEIGHT / 2 + 0.5) / deg_to_rad(clampf(float(cfg["horizon_max_pitch"]), 10.0, 90.0))
	var ky := sin(roll)
	var kx := cos(roll)
	var datum := 0
	var interval := clampi(int(cfg["horizon_pitch_interval"]), 0, 30)
	if interval > 0:
		datum = interval * int(rad_to_deg(pitch) / interval)
		pitch -= deg_to_rad(datum)
	if absf(ky) < absf(kx):
		var factor := datum / 20
		for dx in range(-I_AHI_WIDTH / 2, I_AHI_WIDTH / 2 + 1):
			var end_off := 0
			if datum != 0 and absi(dx) == I_AHI_WIDTH / 2:
				end_off = -(factor + 3 * signi(datum))
			var fy := (I_ASPECT * dx) * (ky / kx) + (pitch + deg_to_rad(end_off)) * p2c + 0.49
			var dy := floori(fy)
			if dy >= -I_AHI_HEIGHT / 2 and dy <= I_AHI_HEIGHT / 2:
				var c := I_AH_H_START + (I_AHI_H_SYM_COUNT - 1) - int((fy - dy) * I_AHI_H_SYM_COUNT)
				_iput(I_MID_COL + dx, I_MID_ROW - dy, c, "inav_ahi", false)
	else:
		for dy in range(-I_AHI_HEIGHT / 2, I_AHI_HEIGHT / 2 + 1):
			var fx := ((dy / I_ASPECT) - pitch * p2c) * (kx / ky) + 0.5
			var dx := floori(fx)
			if dx >= -I_AHI_WIDTH / 2 and dx <= I_AHI_WIDTH / 2:
				_iput(I_MID_COL + dx, I_MID_ROW - dy, I_AH_V_START + int((fx - dx) * I_AHI_V_SYM_COUNT), "inav_ahi", false)


# osdGridDrawSidebars: seven columns either side, sidebars_height rows up and
# down; each can scroll with the altitude, the speed or the distance home,
# with arrows for which way it is going
func _inav_sidebars() -> void:
	var hw := I_AH_SIDEBAR_WIDTH
	var hh := clampi(int(cfg["sidebars_height"]), 0, 5)
	var lt := _sb_update(_sb_state[0], str(cfg["sidebars_scroll_left"]).to_lower())
	var rt := _sb_update(_sb_state[1], str(cfg["sidebars_scroll_right"]).to_lower())
	if bool(cfg["sidebars_arrows"]):
		for side in [[_sb_state[0], -hw], [_sb_state[1], hw]]:
			var arrow := int(side[0].get("arrow", 0))
			if arrow == 1:
				_iput(I_MID_COL + side[1], I_MID_ROW - hh - 1, I_AH_DECORATION_UP, "inav_arrow")
			elif arrow == 2:
				_iput(I_MID_COL + side[1], I_MID_ROW + hh + 1, I_AH_DECORATION_DOWN, "inav_arrow")
	if hh > 0:
		for y in range(-hh, hh + 1):
			_iput(I_MID_COL - hw, I_MID_ROW + y, lt, "inav_sidebar")
			_iput(I_MID_COL + hw, I_MID_ROW + y, rt, "inav_sidebar")
	_iput(I_MID_COL - hw + 1, I_MID_ROW, I_AH_RIGHT, "inav_level")
	_iput(I_MID_COL + hw - 1, I_MID_ROW, I_AH_LEFT, "inav_level")


# osdUpdateSidebar: the tick character, stepped one of six for every 20 cm of
# altitude, 20 cm/s of speed or 5 m nearer or farther from home; the arrow
# looks at the change every tenth of a second and goes after four still ones
func _sb_update(st: Dictionary, scroll: String) -> int:
	var dec := I_AH_DECORATION
	var offset := 0
	var steps := 0
	var p := _player as Node3D if _player is Node3D and is_instance_valid(_player) else null
	match scroll:
		"altitude":
			offset = int(((p.global_position.y - _home.y) if p else 0.0) * 100.0)
			steps = offset / 20
		"speed":
			offset = int(float(_player.call("get_speed_kph")) / 3.6 * 100.0) if p and p.has_method("get_speed_kph") else 0
			steps = offset / 20
		"home_distance":
			var hm := _nav_home()
			offset = int(Vector2(hm.x - p.global_position.x, hm.z - p.global_position.z).length()) if p else 0
			steps = offset / 5
		_:
			st["arrow"] = 0
			st["offset"] = 0
			return dec
	if offset != 0:
		dec -= steps % I_AH_DECORATION_COUNT
		if dec > I_AH_DECORATION_MAX:
			dec -= I_AH_DECORATION_COUNT
		elif dec < I_AH_DECORATION_MIN:
			dec += I_AH_DECORATION_COUNT
	if _now - float(st.get("updated", -1.0)) > 0.1:
		var prev := int(st.get("offset", 0))
		if offset > prev:
			st["arrow"] = 1
			st["idle"] = 0
		elif offset < prev:
			st["arrow"] = 2
			st["idle"] = 0
		elif int(st.get("idle", 0)) > 3:
			st["arrow"] = 0
		else:
			st["idle"] = int(st.get("idle", 0)) + 1
		st["offset"] = offset
		st["updated"] = _now
	return dec


static func _wrap180(a: int) -> int:
	while a < -179:
		a += 360
	while a > 180:
		a -= 360
	return a


static func _wrap360(a: int) -> int:
	while a < 0:
		a += 360
	while a > 360:
		a -= 360
	return a


# osdFormatCentiNumber, metric, as the HUD uses it: right-aligned in length
# characters; too long for that and it goes to km, the decimal point folded
# into INAV's dotted digits
static func _inav_centi(centi: int, scale: int, max_dec: int, max_scaled_dec: int, length: int) -> Array:
	var out := []
	var neg := centi < 0
	if neg:
		centi = -centi
		length -= 1
	var ip := centi / 100
	var millis := (centi % 100) * 10
	var digits := str(ip).length()
	var remaining := length - digits
	var decimals := max_dec
	if remaining < 0 and scale > 0:
		decimals = max_scaled_dec
		ip = ip / scale
		millis = ((centi % (100 * scale)) * 10) / scale
		digits = str(ip).length()
		remaining = length - digits
	decimals = mini(remaining, mini(decimals, 3))
	remaining -= decimals
	while remaining > 0:
		out.append(0x20)
		remaining -= 1
	if neg:
		out.append(0x2D)
	for ch in str(ip):
		out.append(ch.unicode_at(0))
	if decimals > 0:
		out[out.size() - 1] += I_ZERO_HALF_TRAILING_DOT - 0x30
		var factor := 3
		while decimals < factor:
			factor -= 1
			millis /= 10
		var ds := str(millis)
		var first := out.size()
		for i in decimals - ds.length():
			out.append(0x30)
		for ch in ds:
			out.append(ch.unicode_at(0))
		out[first] += I_ZERO_HALF_LEADING_DOT - 0x30
	return out


# Other players' quads: the game's LOSQuads, the ones showing
func _peers() -> Array:
	var out := []
	var holder := _scene.get_node_or_null("LOSQuads") if _scene != null and is_instance_valid(_scene) else null
	if holder == null:
		return out
	for q in holder.get_children():
		if q is Node3D and (q as Node3D).is_visible_in_tree() and "stick_position" in q:
			out.append(q)
	return out


# INAV's HUD (the crosshair element's osd_hud.c parts): homing arrows round
# the crosshair, the home point where it is in the picture, and other
# players' quads as INAV shows aircraft from its radar, A to D
func _inav_hud() -> void:
	if not (_player is Node3D) or not is_instance_valid(_player):
		return
	var pos := (_player as Node3D).global_position
	var hd := int(_heading_deg())
	var home := _nav_home()
	var home_dist := int(Vector2(home.x - pos.x, home.z - pos.z).length())
	var home_dir := int(_bearing(pos, home))
	var alt := int(pos.y - home.y)
	# (INAV has no direction home while on it)
	if bool(cfg["hud_homing"]) and home_dist > 0:
		_hud_homing(home_dir, hd, alt, home_dist)
	if bool(cfg["hud_homepoint"]) and home_dist > 0:
		_hud_poi(home, home_dist, home_dir, -alt, 0, I_HOME, 0, 0)
	var n := _radar_n()
	if n <= 0:
		_radar_slot.clear()
		return
	# the nearest n in range keep their letters; a new one takes the first free
	var near := []
	for q in _peers():
		var qp := (q as Node3D).global_position
		var d := Vector2(qp.x - pos.x, qp.z - pos.z).length()
		if d >= float(cfg["hud_radar_range_min"]) and d <= float(cfg["hud_radar_range_max"]):
			near.append([d, q])
	near.sort_custom(func(a, b): return a[0] < b[0])
	near = near.slice(0, n)
	var keep := {}
	for e in near:
		keep[e[1]] = true
	for q in _radar_slot.keys():
		if not keep.has(q) or not is_instance_valid(q):
			_radar_slot.erase(q)
	for e in near:
		if not _radar_slot.has(e[1]):
			var used := _radar_slot.values()
			for i in n:
				if not i in used:
					_radar_slot[e[1]] = i
					break
	var order := []
	for e in near:
		order.append([_radar_slot.get(e[1], 0), e])
	order.sort_custom(func(a, b): return a[0] < b[0])
	for o in order:
		var q: Node3D = o[1][1]
		var qp := q.global_position
		var f := -q.global_transform.basis.z
		var q_hd := int(fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0))
		_hud_poi(qp, int(o[1][0]), int(_bearing(pos, qp)), int(qp.y - pos.y), 1, 0x41 + int(o[0]), q_hd, 4)


# osdHudDrawHoming: arrows either side of the crosshair, more of them the
# further round home is, and above or below it for how far up or down it is
# while it is ahead
func _hud_homing(home_dir: int, hd: int, alt: int, dist: int) -> void:
	var l := -1
	var r := -1
	var u := -1
	var dn := -1
	var e := _wrap180(home_dir - hd)
	var H := I_HOMING_H
	if e <= -162 or e >= 162:
		l = I_HUD_ARROWS_L3; r = I_HUD_ARROWS_R3
	elif e > -162 and e <= -126:
		l = I_HUD_ARROWS_L3; r = I_HUD_ARROWS_R1 + 1
	elif e > -126 and e <= -90:
		l = I_HUD_ARROWS_L3; r = I_HUD_ARROWS_R1
	elif e > -90 and e <= -H[2]:
		l = I_HUD_ARROWS_L3
	elif e > -H[2] and e <= -H[1]:
		l = I_HUD_ARROWS_L1 + 1
	elif e > -H[1] and e <= -H[0]:
		l = I_HUD_ARROWS_L1
	elif e >= H[0] and e < H[1]:
		r = I_HUD_ARROWS_R1
	elif e >= H[1] and e < H[2]:
		r = I_HUD_ARROWS_R1 + 1
	elif e >= H[2] and e < 90:
		r = I_HUD_ARROWS_R3
	elif e >= 90 and e < 126:
		l = I_HUD_ARROWS_L1; r = I_HUD_ARROWS_R3
	elif e >= 126 and e < 162:
		l = I_HUD_ARROWS_L1 + 1; r = I_HUD_ARROWS_R3
	if absi(e) < 90:
		var home_angle := rad_to_deg(atan2(float(alt), float(dist)))
		var v := int(home_angle - _attitude().y / 10 + int(_cam_uptilt()))
		var V := I_HOMING_V
		if v > -V[1] and v <= -V[0]:
			u = I_HUD_ARROWS_U1
		elif v > -V[2] and v <= -V[1]:
			u = I_HUD_ARROWS_U1 + 1
		elif v <= -V[2]:
			u = I_HUD_ARROWS_U1 + 2
		elif v >= V[0] and v < V[1]:
			dn = I_HUD_ARROWS_D1
		elif v >= V[1] and v < V[2]:
			dn = I_HUD_ARROWS_D1 + 1
		elif v >= V[2]:
			dn = I_HUD_ARROWS_D1 + 2
	for a in [[l, -2, 0], [r, 2, 0], [u, 0, -1], [dn, 0, 1]]:
		if a[0] >= 0:
			_iput(I_MID_COL + a[1], I_MID_ROW + a[2], a[0], "hud_homing")


# osdHudDrawPoi: a marker where the point is in the picture - found here
# through the game's camera, where INAV works it out from its field-of-view
# settings - kept inside the HUD's margins. Out of the picture it goes to the
# side it is round, with arrows, stacked below any already there. Under it
# its distance, or for another quad its height above or below you and its
# distance in turn, 3 s each; beside a quad, which way it is heading, where it
# is round you, and its signal (always full here).
func _hud_poi(world: Vector3, dist: int, dir: int, alt: int, type: int, symbol: int, heading: int, sig: int) -> void:
	var min_x := clampi(int(cfg["hud_margin_h"]), 0, 4) + 2
	var max_x := COLS - clampi(int(cfg["hud_margin_h"]), 0, 4) - 3
	var min_y := clampi(int(cfg["hud_margin_v"]), 1, 3)
	var max_y := ROWS - clampi(int(cfg["hud_margin_v"]), 1, 3) - 2
	var hd := int(_heading_deg())
	var err_x := _wrap180(dir - hd)
	var px := -1
	var py := -1
	var oos := true
	var cam := _camera()
	if cam != null:
		var q = _to_osd(cam, Vector2(cam.get_viewport().get_visible_rect().size), world)
		if q != null:
			px = I_MID_COL + roundi((q.x - CX) / GW)
			if px >= min_x and px <= max_x:
				oos = false
				py = clampi(I_MID_ROW + roundi((q.y - _cross_y()) / GH), min_y, max_y - 1)
	if oos or type == 1:
		if oos:
			px = max_x if err_x > 0 else min_x
			py = I_MID_ROW - 1
		if _busy(px, py):
			py = I_MID_ROW - 3
			while _busy(px, py) and py < max_y - 3:
				py += 2
		if type == 1:
			var d := clampi((err_x + 180) / 30, 0, 12)
			_iput(px + 2, py, I_HUD_CARDINAL + (0 if d == 12 else d), "hud_radar")
		elif err_x > 0:
			_iput(px + 2, py, I_HUD_ARROWS_R3 - clampi((180 - err_x) / 45, 0, 2), "hud_home")
		else:
			_iput(px - 2, py, I_HUD_ARROWS_L3 - clampi((180 + err_x) / 45, 0, 2), "hud_home")
	var what := "hud_radar" if type == 1 else "hud_home"
	_iput(px, py, symbol, what)
	if type == 1:
		_iput(px - 1, py, I_DECORATION + ((_wrap360(heading - hd) + 22) / 45) % 8, what)
		_iput(px + 1, py, I_HUD_SIGNAL_0 + clampi(sig, 0, 4), what)
	var buff := []
	if type > 0 and int(_now) % 6 < 3:
		buff = [I_AH_DECORATION_UP if alt >= 0 else I_AH_DECORATION_DOWN]
		for ch in "%3d" % absi(clampi(alt, -999, 999)):
			buff.append(ch.unicode_at(0))
	else:
		buff = _inav_centi(dist * 100, 1000, 0, 4 if type == 1 else 3, 4 if type == 1 else 3)
	for i in buff.size():
		if buff[i] != 0x20:
			_iput(px - 1 + i, py + 1, buff[i], what)


# ---- more of INAV's elements, at INAV's places for them ----

func _inav_elements(blink: bool) -> void:
	var vz := _g_vel.y if _g_have else 0.0          # m/s, up
	if bool(cfg["show_vario"]):
		_inav_vario(vz * 100.0)
	if bool(cfg["show_vario_number"]):
		# OSD_VERTICAL_SPEED_INDICATOR (24, 7): m/s, one decimal
		var b := _inav_centi(int(vz * 100.0), 0, 1, 0, 3)
		b.append(I_MS)
		for i in b.size():
			if b[i] != 0x20:
				_iabs(24 + i, 7, b[i], "vario_number")
	if bool(cfg["show_g_force"]):
		# OSD_GFORCE (12, 4): blinks above g_force_alarm (osd_gforce_alarm)
		if blink or g_force <= float(cfg["g_force_alarm"]):
			var b := [I_GFORCE] + _inav_centi(int(g_force * 100.0), 0, 2, 0, 3)
			for i in b.size():
				if b[i] != 0x20:
					_iabs(12 + i, 4, b[i], "g_force")
	if bool(cfg["show_throttle_gauge"]):
		_inav_throttle_gauge(clampi(int(round(_throttle() * 100.0)), 0, 100))


# osdGridDrawVario, at (23, 5): a column of five, an arrow for every 0.5 m/s
# up or down (OSD_VARIO_CM_S_PER_ARROW), doubled every 1 m/s
func _inav_vario(zvel: float) -> void:
	var v := int(zvel / 50.0)
	var ch := [-1, -1, -1, -1, -1]
	if v >= 6:
		ch[0] = I_VARIO_UP_2A
	elif v == 5:
		ch[0] = I_VARIO_UP_1A
	if v >= 4:
		ch[1] = I_VARIO_UP_2A
	elif v == 3:
		ch[1] = I_VARIO_UP_1A
	if v >= 2:
		ch[2] = I_VARIO_UP_2A
	elif v == 1:
		ch[2] = I_VARIO_UP_1A
	if v <= -2:
		ch[2] = I_VARIO_DOWN_2A
	elif v == -1:
		ch[2] = I_VARIO_DOWN_1A
	if v <= -4:
		ch[3] = I_VARIO_DOWN_2A
	elif v == -3:
		ch[3] = I_VARIO_DOWN_1A
	if v <= -6:
		ch[4] = I_VARIO_DOWN_2A
	elif v == -5:
		ch[4] = I_VARIO_DOWN_1A
	for i in 5:
		if ch[i] >= 0:
			_iabs(23, 5 + i, ch[i], "vario")


# osdGridDrawThrottleGauge: a column of five filling from the bottom, half a
# character for every 10% of throttle; at (6, 5) here, clear of the vario
func _inav_throttle_gauge(thr: int) -> void:
	var ch := [I_THR_GAUGE_EMPTY, I_THR_GAUGE_EMPTY, I_THR_GAUGE_EMPTY, I_THR_GAUGE_EMPTY, I_THR_GAUGE_EMPTY]
	for i in 5:
		var full := 100 - 20 * i
		if thr >= full:
			ch[i] = I_THR_GAUGE_FULL
		elif thr >= full - 10:
			ch[i] = I_THR_GAUGE_HALF
	for i in 5:
		_iabs(6, 5 + i, ch[i], "throttle_gauge")


# ---- BrainFPV's graphical OSD ----
# Its drawing functions (brainfpv/osd_utils.c), pixel for pixel: lines take
# both end pixels; a filled rectangle is width + 1 pixels wide and height
# tall, as its 4-bit drawing code does it on the RADIX 2.

func _cross_y() -> int:
	return CY - roundi(float(cfg["crosshair_offset"]) / 100.0 * ROWS * GH)


func _gpx(x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x <= GR_RIGHT and y <= GR_BOTTOM:
		_img.set_pixel(x, y, c)


func _ghline(x0: int, x1: int, y: int, c: Color) -> void:
	if y < 0 or y > GR_BOTTOM:
		return
	var a := clampi(mini(x0, x1), 0, GR_RIGHT)
	var b := clampi(maxi(x0, x1), 0, GR_RIGHT)
	if a == b:
		return
	_img.fill_rect(Rect2i(a, y, b - a + 1, 1), c)


func _gvline(x: int, y0: int, y1: int, c: Color) -> void:
	if x < 0 or x > GR_RIGHT:
		return
	var a := clampi(mini(y0, y1), 0, GR_BOTTOM)
	var b := clampi(maxi(y0, y1), 0, GR_BOTTOM)
	if a == b:
		return
	_img.fill_rect(Rect2i(x, a, 1, b - a + 1), c)


func _grect(x: int, y: int, w: int, h: int, c: Color) -> void:
	# (BrainFPV leaves out a rectangle that runs off the picture; here it is
	# cut off at the edge, as sticks can be put anywhere)
	if w <= 0 or h <= 0:
		return
	var r := Rect2i(x, y, w + 1, h).intersection(Rect2i(0, 0, GR_RIGHT + 1, GR_BOTTOM + 1))
	if r.size.x > 0 and r.size.y > 0:
		_img.fill_rect(r, c)


# draw_hline_outlined with flat end caps (2) or none (0)
func _ghline_outlined(x0: int, x1: int, y: int, caps: int, lc: Color, oc: Color) -> void:
	var a := mini(x0, x1)
	var b := maxi(x0, x1)
	_ghline(a + 1, b - 1, y - 1, oc)
	_ghline(a + 1, b - 1, y + 1, oc)
	_ghline(a + 1, b - 1, y, lc)
	if caps == 2:
		for e in [a, b]:
			for dy in range(-1, 2):
				_gpx(e, y + dy, oc)


# draw_line_outlined / draw_line_outlined_dashed: Bresenham, the outline
# (the four neighbours of each pixel) first and then the line over it
func _gline_outlined(x0: int, y0: int, x1: int, y1: int, lc: Color, oc: Color, dots: int = 0) -> void:
	var steep := absi(y1 - y0) > absi(x1 - x0)
	if steep:
		var t := x0; x0 = y0; y0 = t
		t = x1; x1 = y1; y1 = t
	if x0 > x1:
		var t := x0; x0 = x1; x1 = t
		t = y0; y0 = y1; y1 = t
	var dx := x1 - x0
	var dy := absi(y1 - y0)
	var ystep := 1 if y0 < y1 else -1
	for p in 2:
		var err := dx / 2
		var y := y0
		var cnt := 0
		var drw := 1
		for x in range(x0, x1):
			if dots > 0:
				if cnt % dots == 0:
					drw += 1
				cnt += 1
			if drw % 2 == 1:
				var px := y if steep else x
				var py := x if steep else y
				if p == 0:
					_gpx(px - 1, py, oc)
					_gpx(px + 1, py, oc)
					_gpx(px, py - 1, oc)
					_gpx(px, py + 1, oc)
				else:
					_gpx(px, py, lc)
			err -= dy
			if err < 0:
				y += ystep
				err += dx


# draw_string, one line, with a font sheet of w x h characters; va / ha:
# 0 top / left, 1 middle / centre, 2 bottom / right
func _gtext(t: String, x: int, y: int, xs: int, va: int, ha: int, font: Image, w: int, h: int) -> void:
	if font == null:
		return
	var tw := t.length() * (w + xs)
	var yy := y if va == 0 else (y - h / 2 + 1 if va == 1 else y - h)
	var xx := x if ha == 0 else (x - tw / 2 if ha == 1 else x - tw)
	for i in t.length():
		var code := t.unicode_at(i) & 0xFF
		_img.blend_rect(font, Rect2i((code % 16) * w, (code / 16) * h, w, h), Vector2i(xx, yy))
		xx += w + xs


# draw_stick, one for each stick at the bottom corners, sized so a box is no
# bigger than the game's own stick overlay at sticks_size 1 (BrainFPV's own
# are 43 pixels across, about half as big again at 1080p).
func _bfpv_sticks() -> void:
	var sp = _player.get("stick_pos") if _player != null and is_instance_valid(_player) else null
	var st: Vector4 = sp if sp is Vector4 else Vector4(0, 0, -1, 0)
	var mode: Array = RADIO_MODES[clampi(int(cfg["sticks_mode"]), 1, 4) - 1]
	var target := float(cfg["sticks_size"]) * _game_stick_px * float(ROWS * GH) / _win_h
	var half := clampi(roundi((target - 3.0) / 2.0), 6, 40)
	var x := roundi(clampf(float(cfg["sticks_x"]), 0.0, 50.0) / 100.0 * COLS * GW)
	var y := GR_BOTTOM - roundi(clampf(float(cfg["sticks_y"]), 0.0, 100.0) / 100.0 * ROWS * GH)
	_bfpv_stick(x, y, half, st[mode[1]], st[mode[0]])
	_bfpv_stick(GR_RIGHT - x, y, half, st[mode[3]], st[mode[2]])


func _bfpv_stick(x: int, y: int, ln: int, horizontal: float, vertical: float) -> void:
	var w2 := BFPV_STICK_WIDTH / 2
	_grect(x - ln, y - w2, 2 * ln, BFPV_STICK_WIDTH, C_BLACK)
	_grect(x - w2, y - ln, BFPV_STICK_WIDTH, 2 * ln, C_BLACK)
	_ghline(x - ln - 1, x - w2 - 1, y - w2 - 1, C_WHITE)
	_ghline(x - ln - 1, x - w2 - 1, y + w2 + 1, C_WHITE)
	_ghline(x + w2 + 1, x + ln + 1, y - w2 - 1, C_WHITE)
	_ghline(x + w2 + 1, x + ln + 1, y + w2 + 1, C_WHITE)
	_ghline(x - w2 - 1, x + w2 + 1, y - ln - 1, C_WHITE)
	_ghline(x - w2 - 1, x + w2 + 1, y + ln + 1, C_WHITE)
	_gvline(x - w2 - 1, y - w2 - 1, y - ln - 1, C_WHITE)
	_gvline(x + w2 + 1, y - w2 - 1, y - ln - 1, C_WHITE)
	_gvline(x - w2 - 1, y + ln + 1, y + w2 + 1, C_WHITE)
	_gvline(x + w2 + 1, y + ln + 1, y + w2 + 1, C_WHITE)
	_gvline(x - ln - 1, y - w2 - 1, y + w2 + 1, C_WHITE)
	_gvline(x + ln + 1, y - w2 - 1, y + w2 + 1, C_WHITE)
	# the channels' 1000-2000 us as the flight controller has them
	var ext := ln - BFPV_STICK_BOX / 2 + 1
	var h := clampi(roundi(500.0 * clampf(horizontal, -1.0, 1.0)), -500, 500)
	var v := clampi(roundi(500.0 * clampf(vertical, -1.0, 1.0)), -500, 500)
	var sx := x + int(float(ext * h) / 500.0)
	var sy := y - int(float(ext * v) / 500.0)
	var b2 := BFPV_STICK_BOX / 2
	_grect(sx - b2 - 1, sy - b2 - 1, BFPV_STICK_BOX + 2, BFPV_STICK_BOX + 2, C_BLACK)
	_grect(sx - b2, sy - b2, BFPV_STICK_BOX, BFPV_STICK_BOX, C_WHITE)
	extras.append(["stick", ln, sx, sy])


# simple_artificial_horizon: a pitch ladder every 10 degrees, up to
# horizon_steps rungs each way, around the crosshair; rungs above the horizon
# solid, below it dashed, the horizon itself with a gap in the middle.
func _bfpv_horizon() -> void:
	var n_steps := clampi(int(cfg["horizon_steps"]), 0, 9)
	var width := int(GR_BOTTOM * 0.8) / 2
	var height := int(GR_RIGHT * 0.8) / 2
	if bool(cfg["horizon_uptilt"]):
		# on the real horizon: the rungs where 0, 10, 20... degrees up and down
		# are in the picture, tilted as the horizon is there
		var hzn := _true_horizon()
		if hzn.is_empty():
			return
		var u: Vector2 = hzn["dir"]
		var sr := -u.y
		var cr := u.x
		var d_x := 3 * int(cr * width / 2.0) / 4
		var d_y := 3 * int(sr * height / 2.0) / 4
		for k in range(-n_steps, n_steps + 1):
			var c = _true_elev(float(k * BFPV_PITCH_STEP))
			var c2 = _true_elev(float(k * BFPV_PITCH_STEP + BFPV_PITCH_STEP))
			if c == null or c2 == null:
				continue
			var up: Vector2 = c2 - c           # screen offset of the next 10 degrees up
			if absf(c.x - CX) > COLS * GW or absf(c.y - CY) > ROWS * GH:
				continue
			_bfpv_rung(k * BFPV_PITCH_STEP, roundi(c.x), roundi(c.y), d_x, d_y, 3 * d_x / 4, 3 * d_y / 4,
				int(-up.x / 6.0), int(-up.y / 6.0))
		return
	var att := _attitude()
	var roll := att.x
	var pitch := -att.y                  # BrainFPV passes nose-up positive
	var x := CX
	var y := _cross_y()
	var sr := sin(deg_to_rad(roll / 10.0))
	var cr := cos(deg_to_rad(roll / 10.0))
	var step_off := pitch / (BFPV_PITCH_STEP * 10)
	var mod_p := pitch / 10.0 - step_off * 10.0
	var pp_x := x + int(width * ((sr * mod_p) / float(BFPV_AH_MAX_PITCH)))
	var pp_y := y + int(height * ((cr * mod_p) / float(BFPV_AH_MAX_PITCH)))
	var d_x := int(cr * width / 2.0)
	var d_y := int(sr * height / 2.0)
	d_x = 3 * d_x / 4
	d_y = 3 * d_y / 4
	var d_x2 := 3 * d_x / 4
	var d_y2 := 3 * d_y / 4
	var d_x_10 := int(width * sr * BFPV_PITCH_STEP / float(BFPV_AH_MAX_PITCH))
	var d_y_10 := int(height * cr * BFPV_PITCH_STEP / float(BFPV_AH_MAX_PITCH))
	for i in range(-BFPV_AH_MAX_PITCH / 10 - 1, BFPV_AH_MAX_PITCH / 10 + 1):
		var angle := step_off + i
		if angle < -n_steps or angle > n_steps:
			continue
		angle *= BFPV_PITCH_STEP
		if angle > 90:
			angle = 180 - angle
		elif angle < -90:
			angle = -180 - angle
		_bfpv_rung(angle, pp_x - i * d_x_10, pp_y - i * d_y_10, d_x, d_y, d_x2, d_y2, d_x_10 / 6, d_y_10 / 6)


# One rung of simple_artificial_horizon: above the horizon solid with its
# ends turned down, below dashed with them turned up, both numbered; the
# horizon itself with a gap in the middle.
func _bfpv_rung(angle: int, px: int, py: int, d_x: int, d_y: int, d_x2: int, d_y2: int, d_x_2: int, d_y_2: int) -> void:
	if angle < 0:
		_gline_outlined(px - d_x2, py + d_y2, px + d_x2, py - d_y2, C_BLACK, C_WHITE, 5)
		_gline_outlined(px - d_x2, py + d_y2, px - d_x2 - d_x_2, py + d_y2 - d_y_2, C_BLACK, C_WHITE)
		_gline_outlined(px + d_x2, py - d_y2, px + d_x2 - d_x_2, py - d_y2 - d_y_2, C_BLACK, C_WHITE)
	elif angle > 0:
		_gline_outlined(px - d_x2, py + d_y2, px + d_x2, py - d_y2, C_BLACK, C_WHITE)
		_gline_outlined(px - d_x2, py + d_y2, px - d_x2 + d_x_2, py + d_y2 + d_y_2, C_BLACK, C_WHITE)
		_gline_outlined(px + d_x2, py - d_y2, px + d_x2 + d_x_2, py - d_y2 + d_y_2, C_BLACK, C_WHITE)
	else:
		_gline_outlined(px - d_x, py + d_y, px - d_x / 3, py + d_y / 3, C_BLACK, C_WHITE)
		_gline_outlined(px + d_x / 3, py - d_y / 3, px + d_x, py - d_y, C_BLACK, C_WHITE)
	if angle != 0:
		var label := str(angle)
		_gtext(label, px - d_x - 4, py + d_y, 0, 1, 1, _small8, 8, 8)
		_gtext(label, px + d_x + 4, py - d_y, 0, 1, 1, _small8, 8, 8)
	extras.append(["rung", angle, px, py])


# ---- the real horizon ----
# Where the horizon is in the picture: directions level with the camera,
# projected through the game's camera (so its uptilt and field of view, set
# per quad, count), then through the post-process's fisheye, onto this OSD.

func _camera() -> Camera3D:
	if _player == null or not is_instance_valid(_player) or not _player.is_inside_tree():
		return null
	return _player.get_viewport().get_camera_3d()


# The game's lens bend (ingame_main.gdshader fisheye()): screen UV -> the
# screen texture's UV
func _fisheye(p: Vector2) -> Vector2:
	var d := p - Vector2(0.5, 0.5)
	var r := d.length()
	if r > 0.0 and r < 1.0:
		d *= 1.0 + _fe_k * r * r
	return Vector2(0.5, 0.5) + d * (1.0 - _fe_crop)


# ... and back: where on the screen a point of the screen texture shows. The
# bend only scales the distance from the middle, so solve for that distance.
func _unfisheye(t: Vector2) -> Vector2:
	var d := t - Vector2(0.5, 0.5)
	var lq := d.length()
	if lq < 0.000001:
		return t
	var sc := 1.0 - _fe_crop
	var r := lq / sc
	for i in 12:
		var f := r * (1.0 + _fe_k * r * r) * sc - lq
		var df := (1.0 + 3.0 * _fe_k * r * r) * sc
		r = clampf(r - f / df, 0.0, 1.0)
	return Vector2(0.5, 0.5) + d / lq * r


# A world point to OSD pixels, or null behind the camera
func _to_osd(cam: Camera3D, vs: Vector2, w: Vector3):
	if cam.is_position_behind(w):
		return null
	var ur := cam.unproject_position(w) / vs
	var t := Vector2(_pic.x + ur.x * (_pic.z - _pic.x), _pic.y + ur.y * (_pic.w - _pic.y))
	var p := _unfisheye(t)
	var g := ((p - Vector2(_pic.x, _pic.y)) / Vector2(_pic.z - _pic.x, _pic.w - _pic.y) - Vector2(OSD_GRID.x, OSD_GRID.y)) \
		/ Vector2(OSD_GRID.z - OSD_GRID.x, OSD_GRID.w - OSD_GRID.y)
	return g * Vector2(COLS * GW, ROWS * GH)


# The level directions the camera looks along: straight ahead and to its right
func _level_axes(cam: Camera3D) -> Array:
	var f := -cam.global_transform.basis.z
	var fh := Vector3(f.x, 0.0, f.z)
	if fh.length() < 0.02:                   # looking straight up or down
		return []
	fh = fh.normalized()
	return [fh, Vector3(-fh.z, 0.0, fh.x)]


# The horizon: {"line": its points left to right along it, "dir": its
# direction on the screen where it is straight ahead}, or {} if not in view
func _true_horizon() -> Dictionary:
	var cam := _camera()
	if cam == null:
		return {}
	var ax := _level_axes(cam)
	if ax.is_empty():
		return {}
	var vs := Vector2(cam.get_viewport().get_visible_rect().size)
	var o := cam.global_position
	var line: Array = []
	for a in range(-80, 81, 4):
		var ar := deg_to_rad(float(a))
		var q = _to_osd(cam, vs, o + (ax[0] * cos(ar) + ax[1] * sin(ar)) * HORIZON_FAR)
		if q != null:
			line.append(q)
	var l = _to_osd(cam, vs, o + (ax[0] * cos(0.07) - ax[1] * sin(0.07)) * HORIZON_FAR)
	var r = _to_osd(cam, vs, o + (ax[0] * cos(0.07) + ax[1] * sin(0.07)) * HORIZON_FAR)
	if line.size() < 2 or l == null or r == null or (r - l).length() < 0.001:
		return {}
	return {"line": line, "dir": (r - l).normalized()}


# Where elev degrees above the horizon, straight ahead, is on the OSD
func _true_elev(elev: float):
	var cam := _camera()
	if cam == null:
		return null
	var ax := _level_axes(cam)
	if ax.is_empty() or absf(elev) >= 89.0:
		return null
	var e := deg_to_rad(elev)
	var vs := Vector2(cam.get_viewport().get_visible_rect().size)
	return _to_osd(cam, vs, cam.global_position + (ax[0] * cos(e) + Vector3.UP * sin(e)) * HORIZON_FAR)


# The line's height where it crosses x, or null
func _poly_y(line: Array, x: float):
	for i in line.size() - 1:
		var a: Vector2 = line[i]
		var b: Vector2 = line[i + 1]
		if (a.x <= x and x <= b.x) or (b.x <= x and x <= a.x):
			if absf(b.x - a.x) < 0.0001:
				return a.y
			return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
	return null


# osdUpdateLocal's altitude scale on the right (metres above where you armed)
# and speed scale on the left (km/h)
func _bfpv_scales() -> void:
	var p := _player if _player != null and is_instance_valid(_player) else null
	if bool(cfg["show_altitude_scale"]) and p is Node3D:
		_vscale(int((p as Node3D).global_position.y - _home.y), 100, 1, GR_RIGHT - 20, (GR_BOTTOM + 1) / 2, 120, 10, 20, 5, 8, 11)
	if bool(cfg["show_speed_scale"]) and p != null and p.has_method("get_speed_kph"):
		_vscale(int(float(p.call("get_speed_kph"))), 100, -1, 5, (GR_BOTTOM + 1) / 2, 120, 10, 20, 5, 8, 11)


# osd_draw_vertical_scale: a moving tape of ticks, numbered every major tick,
# with the value in a box pointing at the middle
func _vscale(v: int, rng: int, halign: int, x: int, y: int, height: int, mintick_step: int,
		majtick_step: int, mintick_len: int, majtick_len: int, boundtick_len: int) -> void:
	var maj_end := x + majtick_len * (-halign)
	var min_end := x + mintick_len * (-halign)
	var bound_end := x + boundtick_len * (-halign)
	var arrow_len := 10 / 2 + 1
	var text_x_spacing := 8 / 2
	var r2 := rng / 2
	for r in range(-r2, r2 + 1):
		var rr := r + r2 - v
		var rv := -rr + r2
		var style := 0
		if rr % majtick_step == 0:
			style = 1
		elif rr % mintick_step == 0:
			style = 2
		if style == 0:
			continue
		var ys := (r * height) / rng + y
		if style == 1:
			_ghline_outlined(x, maj_end, ys, 2, C_WHITE, C_BLACK)
			if halign == -1:
				_gtext(str(rv), maj_end + text_x_spacing + 1, ys, 1, 1, 0, _small8, 8, 8)
			else:
				_gtext(str(rv), maj_end - text_x_spacing + 1, ys, 1, 1, 2, _small8, 8, 8)
		else:
			_ghline_outlined(x, min_end, ys, 2, C_WHITE, C_BLACK)
	var t := "%02d" % v
	var xx := maj_end + text_x_spacing * (-halign)
	y += 1
	var width := t.length() * 9 + 4
	for i in arrow_len:
		if halign == -1:
			_gpx(xx - arrow_len + i, y - i - 1, C_WHITE)
			_gpx(xx - arrow_len + i, y + i - 1, C_WHITE)
			_ghline(xx + width - 1, xx - arrow_len + i + 1, y - i - 1, C_BLACK)
			_ghline(xx + width - 1, xx - arrow_len + i + 1, y + i - 1, C_BLACK)
		else:
			_gpx(xx + arrow_len - i, y - i - 1, C_WHITE)
			_gpx(xx + arrow_len - i, y + i - 1, C_WHITE)
			_ghline(xx - width - 1, xx + arrow_len - i - 1, y - i - 1, C_BLACK)
			_ghline(xx - width - 1, xx + arrow_len - i - 1, y + i - 1, C_BLACK)
	if halign == -1:
		_ghline(xx, xx + width - 1, y - arrow_len, C_WHITE)
		_ghline(xx, xx + width - 1, y + arrow_len - 2, C_WHITE)
		_gvline(xx + width - 1, y - arrow_len, y + arrow_len - 2, C_WHITE)
		_gtext(t, xx + width / 2, y - 1, 1, 1, 1, _font810, 8, 10)
	else:
		_ghline(xx, xx - width - 1, y - arrow_len, C_WHITE)
		_ghline(xx, xx - width - 1, y + arrow_len - 2, C_WHITE)
		_gvline(xx - width - 1, y - arrow_len, y + arrow_len - 2, C_WHITE)
		_gtext(t, xx - width / 2, y - 1, 1, 1, 1, _font810, 8, 10)
	y -= 1
	_ghline_outlined(x, bound_end, y + height / 2, 2, C_WHITE, C_BLACK)
	_ghline_outlined(x, bound_end, y - height / 2, 2, C_WHITE, C_BLACK)
	extras.append(["scale", v, x, y])


func _draw_cells(with_over: bool) -> void:
	_img.fill(Color(0, 0, 0, 0))
	lines.clear()
	for r in ROWS:
		var s := ""
		for c in COLS:
			var code := _cells[r * COLS + c]
			s += char(code) if code >= 0x20 and code < 0x60 else ("{%02X}" % code)
			if code == 0x20:
				continue
			_img.blit_rect(_font, Rect2i((code % 16) * GW, (code / 16) * GH, GW, GH), Vector2i(c * GW, r * GH))
		lines.append(s)
	extras.clear()
	if with_over:
		for o in _over:
			var code: int = o[0]
			var f: Image = o[4] if o.size() > 4 else _font
			_img.blend_rect(f, Rect2i((code % 16) * GW, (code / 16) * GH, GW, GH), Vector2i(o[1], o[2]))
			extras.append([o[3], code, o[1], o[2]])
		if _hz_style == "brainfpv" and bool(cfg["show_horizon"]):
			_bfpv_horizon()
		# the crosshair on top of the text, as Betaflight draws it
		if _xhair != null:
			var at := Vector2i(CX - _xhair.get_width() / 2, _cross_y() - _xhair.get_height() / 2)
			_img.blend_rect(_xhair, Rect2i(Vector2i.ZERO, _xhair.get_size()), at)
			extras.append(["crosshair", 0, at.x, at.y])
		for o in _over_late:
			var code: int = o[0]
			_img.blend_rect(o[4], Rect2i((code % 16) * GW, (code / 16) * GH, GW, GH), Vector2i(o[1], o[2]))
			extras.append([o[3], code, o[1], o[2]])
		# and BrainFPV's own drawings last, as in osdUpdateLocal
		_bfpv_scales()
		if bool(cfg["show_sticks"]) and _sticks_style == "brainfpv":
			_bfpv_sticks()
	_tex.update(_img)
	# for tests: the OSD as drawn, before the video effect
	var dump := OS.get_environment("FPV_OSD_DUMP")
	if dump != "":
		_img.save_png(dump)


func _exit_tree() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	if _game_box != null and is_instance_valid(_game_box):
		_game_box.modulate.a = 1.0
	if _game_sticks != null and is_instance_valid(_game_sticks):
		_game_sticks.modulate.a = 1.0
