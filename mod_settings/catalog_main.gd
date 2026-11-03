extends "res://mod_settings/main.gd"
const Catalog=preload("res://mod_settings/catalog_panel.gd")
const CATALOG={
 "zone_fixes":["Исправления игры","Прогресс обучения и навигация через Esc. Каждый фикс отключается отдельно.",3],
 "*feel":["Flight feel","Общая страница воздуха, батареи и контроллера.",2],
 "video_profiles":["Аналоговое видео","6 стилей: Nito DVR, мягкий, чёткий, моно и оригинал.",1],
 "fpv_osd":["FPV OSD","Пиксельный OSD, стики, горизонт, батарея и статистика.",1],
 "pilot_audio":["Звук пилота","Звук со стороны пилота: расстояние, стены и Доплер.",1],
 "dirty_air":["Воздух и propwash","Вихри, ветер, турбулентность и эффект земли.",2],
 "rotor_drag":["Сопротивление роторов","Дополнительное аэродинамическое сопротивление.",2],
 "battery_sag":["Просадка батареи","Напряжение и доступная тяга меняются под нагрузкой.",2],
 "prop_damage":["Повреждения пропеллеров","Последствия ударов: вибрации и потеря эффективности.",2],
 "flight_controller":["Полётный контроллер","Betaflight-style PID и airmode, расширенная физика.",2],
 "drones":["Параметры дронов","Моторы, пропеллеры, рамы и собственные сборки.",2],
 "mod_settings":["Mod settings","Готовые формы настроек и компактный оверлей F9.",3],
}
var _catalog_layer: CanvasLayer
var _catalog_box: PanelContainer
var _catalog_panel: Control
var _catalog_resume=false
var _hidden_pause: CanvasItem
var _pause_visible=false

func _ready() -> void:
 super._ready()
 _catalog_layer=CanvasLayer.new()
 _catalog_layer.layer=95
 _catalog_layer.visible=false
 add_child(_catalog_layer)
 _catalog_box=PanelContainer.new()
 _catalog_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 _catalog_box.offset_left=32
 _catalog_box.offset_right=-32
 _catalog_box.offset_top=24
 _catalog_box.offset_bottom=-24
 _catalog_box.add_theme_stylebox_override("panel",_box_style(0.97))
 _catalog_layer.add_child(_catalog_box)
 _catalog_panel=Catalog.new()
 _catalog_box.add_child(_catalog_panel)
 _catalog_panel.build(self,false,"")
 _catalog_panel.back.connect(close_catalog)
 print("ZONE_CATALOG_READY mods=",mod_ids().size())

func mod_ids() -> Array:
 var ids=super.mod_ids()
 var priority=["video_profiles","fpv_osd","pilot_audio","dirty_air","rotor_drag","battery_sag","prop_damage","flight_controller","drones","mod_settings"]
 ids.sort_custom(func(a,b): return priority.find(a)<priority.find(b))
 return ids

func _open_page() -> void:
 open_catalog()

func catalog_info(id: String) -> Dictionary:
 var entry=CATALOG.get(id,[id,"Настройки установленного мода.",3])
 return {"name":entry[0],"description":entry[1],"group":entry[2]}

func catalog_enabled(id: String) -> bool:
 return id=="*feel" or str(values(id).get("mod/enabled","true")).to_lower()!="false"

func open_catalog() -> void:
 var desk=get_node_or_null("/root/ZoneDesk")
 if desk!=null and desk.get("_shell").visible:
  if desk.call("_has_changes"):
   desk.get("_status").text="Примени или отмени изменения перед открытием модов."
   return
  desk.call("discard_close")
 show_overlay(false)
 var gs=get_node_or_null("/root/ZGamestate")
 _catalog_resume=gs!=null and not gs.get("is_paused") and get_node_or_null("/root/IngameMain")!=null
 if _catalog_resume: gs.call("set_paused",true)
 _hidden_pause=get_node_or_null("/root/IngameMain/PauseLayer")
 if _hidden_pause!=null:
  _pause_visible=_hidden_pause.visible
  _hidden_pause.visible=false
 _catalog_panel.refresh(true)
 if _catalog_panel._sel=="*feel" and mod_ids().has("video_profiles"): _catalog_panel._select("video_profiles")
 _catalog_layer.visible=true
 Input.mouse_mode=Input.MOUSE_MODE_VISIBLE

func close_catalog() -> void:
 save_now()
 _stop_typing(_catalog_box)
 _catalog_layer.visible=false
 if is_instance_valid(_hidden_pause): _hidden_pause.visible=_pause_visible
 if _catalog_resume:
  var gs=get_node_or_null("/root/ZGamestate")
  if gs!=null: gs.call("set_paused",false)
 _catalog_resume=false

func guard_key(event: InputEvent) -> void:
 var router=get_node_or_null("/root/ZoneMods/zone_fixes/esc_navigation")
 if router!=null and router.handle_key(event):
  get_viewport().set_input_as_handled()
  return
 if event is InputEventKey and event.pressed and not event.echo:
  if event.keycode==KEY_F6 or (_catalog_layer!=null and _catalog_layer.visible and event.keycode==KEY_ESCAPE):
   if _catalog_layer.visible: close_catalog()
   else: open_catalog()
   get_viewport().set_input_as_handled()
   return
 super.guard_key(event)
 if _catalog_layer!=null and _catalog_layer.visible and event is InputEventKey and _typing_into()==null:
  # Keep flight/reset/chat hotkeys out of the full-screen catalog.
  if event.keycode in [KEY_R,KEY_T,KEY_S,KEY_X,KEY_ENTER,KEY_F9]: get_viewport().set_input_as_handled()

func _typing_into() -> LineEdit:
 var focus=get_viewport().gui_get_focus_owner()
 if _catalog_layer!=null and _catalog_layer.visible and focus is LineEdit and _catalog_box.is_ancestor_of(focus) and focus.editable:
  return focus
 return super._typing_into()

func model(id: String) -> Array:
 var rows=super.model(id).duplicate(true)
 if id=="mod_settings":
  rows=rows.filter(func(item): return not (item.kind=="value" and item.section=="mod" and item.key=="enabled"))
 if id=="video_profiles":
  var labels={"profile":"Видеопрофиль","noise_factor":"Помехи","sharpness_factor":"Резкость","colour_factor":"Насыщенность","glare":"Свечение","softness":"Мягкость","auto_signal":"Автоматический сигнал","quality":"Качество вручную","minimum":"Нижний предел","range":"Дальность, м"}
  for item in rows:
   if item.kind!="value": continue
   item.label=labels.get(item.key,item.key)
   if item.key=="profile":
    item.options=[]
    item.option_names={}
    for profile in [["clean","Чистый"],["stock","Штатный аналог"],["nito","Nito DVR"],["soft","Мягкий"],["crisp","Чёткий"],["mono","Монохром"]]:
     item.options.append(profile[0])
     item.option_names[profile[0]]=profile[1]
 return rows

func set_value(id: String,sec: String,key: String,raw: String,file: String="") -> void:
 if id=="mod_settings" and sec=="mod" and key=="enabled": return
 super.set_value(id,sec,key,raw,file)
 if sec=="mod" and key=="enabled" and _restart.has(id) and (raw.to_lower()!="false")==mod_loaded(id):
  _restart[id].erase("mod/enabled")
 _update_panels()
 if sec=="mod" and key=="enabled" and is_instance_valid(_catalog_panel):
  _catalog_panel._render_catalog.call_deferred()

func mod_title(id: String) -> String:
 return str(catalog_info(id).name)+" · "+super.mod_title(id)

func _update_panels() -> void:
 super._update_panels()
 if is_instance_valid(_catalog_panel): _catalog_panel.update_state()

func toggle_tip(id: String) -> String:
 return "Включение и отключение сразу, без перезапуска." if _core.has_method("can_toggle") and _core.can_toggle(id) else "Включение и отключение применяется после перезапуска игры."
