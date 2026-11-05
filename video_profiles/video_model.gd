extends RefCounted
## Visual profiles, not simulations of particular physical transmitters.
const PROFILES = [
 {"id":"clean","name":"Без эффектов","note":"Чистое изображение для сравнения.","mode":"disabled","nito":false},
 {"id":"stock","name":"Штатный аналог","note":"Встроенный аналог установленной версии игры.","mode":"analog_2500","nito":false},
 {"id":"nito","name":"Whoop / DVR · Nito","note":"Шейдер analog400mw со скрина: мягкая камера и аналоговые помехи.","mode":"analog_2500","nito":true,"lines":480,"noise":1.0,"sharpness":1.0,"color":0.7,"scanlines":0.14},
 {"id":"soft","name":"Мягкий аналог","note":"Спокойнее помехи, мягче детали и цвет. Визуальный профиль.","mode":"analog_2500","nito":true,"lines":360,"noise":0.25,"sharpness":0.65,"color":0.55,"scanlines":0.08},
 {"id":"crisp","name":"Чёткий аналог","note":"Больше деталей, слабее цветовые искажения. Визуальный профиль.","mode":"analog_2500","nito":true,"lines":720,"noise":0.4,"sharpness":1.4,"color":0.9,"scanlines":0.05},
 {"id":"mono","name":"Чёрно-белый DVR","note":"Аналоговая картинка без цветовой составляющей.","mode":"analog_2500","nito":true,"lines":480,"noise":0.8,"sharpness":0.9,"color":0.0,"scanlines":0.2},
]
const DEFAULTS = {"profile":"nito","lines":480,"noise":1.0,"sharpness":1.0,"color":0.7,"scanlines":0.14,"glare":0.6,"softness":0.5,"auto_signal":true,"quality":85.0,"minimum":25.0,"range":400.0,"osd":true,"osd_style":"betaflight","font":"betaflight_default.mcm","show_sticks":true,"show_horizon":false,"show_battery":true,"show_timer":true,"show_speed":true,"show_lq":true,"show_mah":true,"show_current":false,"stats":true,"crosshair":"off"}
const RANGES = {"lines":Vector2(0,1080),"noise":Vector2(0,2),"sharpness":Vector2(0.2,2),"color":Vector2(0,1.5),"scanlines":Vector2(0,0.5),"glare":Vector2(0,2),"softness":Vector2(0,1.5),"quality":Vector2(0,100),"minimum":Vector2(0,100),"range":Vector2(0,2000)}
const OSD_KEYS = ["font","show_sticks","show_horizon","show_battery","show_timer","show_speed","show_lq","show_mah","show_current","stats","crosshair"]

static func profile(id: String) -> Dictionary:
 for item in PROFILES:
  if item.id==id: return item.duplicate(true)
 return PROFILES[2].duplicate(true)

static func normalize(value: Dictionary) -> Dictionary:
 var out=DEFAULTS.duplicate(true)
 for key in DEFAULTS:
  if not value.has(key): continue
  if RANGES.has(key):
   if (value[key] is float or value[key] is int) and is_finite(float(value[key])):
    out[key]=clampf(float(value[key]),RANGES[key].x,RANGES[key].y)
  elif DEFAULTS[key] is bool:
   if value[key] is bool: out[key]=value[key]
  elif value[key] is String: out[key]=value[key]
 out.profile=profile(out.profile).id
 if not out.osd_style in ["betaflight","brainfpv","inav"]: out.osd_style="betaflight"
 if not out.font in ["betaflight_default.mcm","betaflight_large.mcm","betaflight_bold.mcm"]: out.font=DEFAULTS.font
 if not out.crosshair in ["off","betaflight","brainfpv","inav","dot"]: out.crosshair="off"
 return out

static func choose(current: Dictionary,id: String) -> Dictionary:
 var out=normalize(current)
 var selected=profile(id)
 out.profile=selected.id
 for key in ["lines","noise","sharpness","color","scanlines"]:
  if selected.has(key): out[key]=selected[key]
 return out

static func signal_quality(cfg: Dictionary,native_quality: float,distance: float) -> float:
 if not cfg.auto_signal: return clampf(float(cfg.quality),0,100)
 var loss=maxf(0,100-native_quality)
 if float(cfg.range)>0: loss+=maxf(distance,0)/float(cfg.range)*55.0
 return clampf(100-loss,float(cfg.minimum),100)

static func osd_values(cfg: Dictionary,mode: String) -> Dictionary:
 var out={}
 for key in OSD_KEYS: out[key]=cfg[key]
 out.style="brainfpv" if cfg.osd_style=="brainfpv" else "betaflight"
 out.horizon_style=cfg.osd_style
 out.sticks_style="brainfpv"
 out.sticks_mode=1 if mode=="mode_1" else 2
 return out
