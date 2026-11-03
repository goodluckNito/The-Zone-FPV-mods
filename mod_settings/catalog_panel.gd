extends "res://mod_settings/panel.gd"
## Catalog around the upstream settings forms; controls remain upstream-owned.
var _search: LineEdit
var _filter: OptionButton
var _entries={}

func build(h,is_compact: bool,title_hint: String) -> void:
 super.build(h,is_compact,title_hint)
 var sc=_list.get_parent() as ScrollContainer
 sc.custom_minimum_size.x=350
 var split=sc.get_parent()
 var side=VBoxContainer.new()
 side.custom_minimum_size.x=350
 split.remove_child(sc)
 split.add_child(side)
 split.move_child(side,0)
 _search=LineEdit.new()
 _search.placeholder_text="Поиск модов"
 _search.text_changed.connect(func(_text): _render_catalog())
 side.add_child(_search)
 _filter=OptionButton.new()
 for title in ["Все моды","Картинка и звук","Физика","Служебные","Включённые"]:
  _filter.add_item(title)
 _filter.item_selected.connect(func(_i): _render_catalog())
 side.add_child(_filter)
 side.add_child(sc)
 sc.size_flags_vertical=Control.SIZE_EXPAND_FILL
 get_node("Bar").get_child(1).text="Моды  ·  F6"

func refresh(fresh:=false) -> void:
 # The upstream implementation dispatches _select only on user action.
 super.refresh(fresh)
 _render_catalog()

func _render_catalog() -> void:
 if _list==null or _search==null: return
 var scroll=_list.get_parent() as ScrollContainer
 var at=scroll.scroll_vertical
 for child in _list.get_children():
  _list.remove_child(child)
  child.queue_free()
 _entries.clear()
 var count=0
 for id in _pages:
  var data: Dictionary=host.catalog_info(id)
  var query=_search.text.strip_edges().to_lower()
  if query!="" and not (str(data.name)+" "+str(data.description)+" "+id).to_lower().contains(query): continue
  var enabled=host.catalog_enabled(id)
  var group=int(data.group)
  if _filter.selected in [1,2,3] and group!=_filter.selected: continue
  if _filter.selected==4 and not enabled: continue
  var box=VBoxContainer.new()
  box.add_theme_constant_override("separation",3)
  _list.add_child(box)
  var row=HBoxContainer.new()
  box.add_child(row)
  var pick=Button.new()
  pick.text=data.name
  pick.toggle_mode=true
  pick.button_pressed=id==_sel
  pick.alignment=HORIZONTAL_ALIGNMENT_LEFT
  pick.size_flags_horizontal=Control.SIZE_EXPAND_FILL
  pick.clip_text=true
  pick.pressed.connect(_select.bind(id))
  row.add_child(pick)
  _entries[id]=pick
  if id!=FEEL_ID:
   var toggle=CheckButton.new()
   toggle.button_pressed=enabled
   toggle.disabled=id=="mod_settings"
   toggle.tooltip_text=host.toggle_tip(id) if not toggle.disabled else "Служба управления модами"
   toggle.toggled.connect(func(on):
    host.set_value(id,"mod","enabled","true" if on else "false")
    host.save_now()
    refresh.call_deferred())
   row.add_child(toggle)
  var note=_desc(str(data.description))
  note.custom_minimum_size.x=320
  box.add_child(note)
  var status="Общие настройки полёта" if id==FEEL_ID else ("Включён" if enabled else "Выключен")
  if id!=FEEL_ID and enabled!=host.mod_loaded(id): status+=" · после перезапуска"
  var state=_desc(status)
  state.modulate=GOOD if enabled else DIM
  box.add_child(state)
  box.add_child(HSeparator.new())
  count+=1
 if count==0: _list.add_child(_desc("Ничего не найдено"))
 scroll.set_deferred("scroll_vertical",at)

func _select(id: String) -> void:
 _sel=id
 for key in _entries: _entries[key].button_pressed=key==id
 _show(id)
 _scroll.scroll_vertical=0
