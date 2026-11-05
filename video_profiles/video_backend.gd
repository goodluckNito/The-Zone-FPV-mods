extends Node
const Model=preload("video_model.gd")
const ASSETS="res://video_profiles/assets/"
var desk: Node
var cfg=Model.DEFAULTS.duplicate(true)
var quality_now=100.0
var available=false
var active=false
var error_text=""
var _scene: Node
var _pp: ColorRect
var _original: ShaderMaterial
var _analog: ShaderMaterial
var _camera: Node
var _last_cfg={}
var _prior_mode="disabled"
func setup(owner_desk: Node) -> void:
 desk=owner_desk
 _analog=ShaderMaterial.new()
 if ResourceLoader.exists(ASSETS+"nito.gdshader"):
  _analog.shader=load(ASSETS+"nito.gdshader")
 else: error_text="Не найден совместимый шейдер Nito в video_profiles/assets."
 var camera_script=load(ASSETS+"camera.gd") if ResourceLoader.exists(ASSETS+"camera.gd") else null
 if camera_script!=null:
  _camera=camera_script.new()
  _camera.call("setup",ASSETS)
  add_child(_camera)
  _camera.set_process(false)
 process_priority=100

func set_active(enabled: bool) -> void:
 if active==enabled: return
 if enabled:
  _prior_mode=str(desk.settings.get("SIGNAL_SIMULATION"))
  active=true
  if is_instance_valid(_camera): _camera.set_process(available)
  _apply()
 else:
  active=false
  _detach()
  desk.settings.set("SIGNAL_SIMULATION",_prior_mode)

func update(values: Dictionary) -> void:
 cfg=Model.normalize(values)
 _apply()

func _process(_delta: float) -> void:
 var scene=desk.ingame() if desk!=null else null
 if scene!=_scene:
  _detach()
  _scene=scene
  _attach()
 elif _pp==null and _scene!=null:
  _attach()
 if not active: return
 if _pp==null or not is_instance_valid(_pp): return
 var selected=Model.profile(cfg.profile)
 if selected.nito:
  if _pp.material!=_analog: _pp.material=_analog
  var native_value=_scene.get("_current_signal_quality")
  var native_q=float(native_value) if native_value!=null else 100.0
  var distance=0.0
  var commands=get_node_or_null("/root/ZCommands")
  var state=get_node_or_null("/root/ZGamestate")
  var player=commands.get("player") if commands!=null else null
  if player is Node3D and state!=null:
   distance=player.global_position.distance_to(state.get("respawn_transform").origin)
  quality_now=Model.signal_quality(cfg,native_q,distance)
  _analog.set_shader_parameter("signal_quality",quality_now)
 else:
  quality_now=100.0 if selected.mode=="disabled" else float(_scene.get("_current_signal_quality"))
func _attach() -> void:
 if _scene==null: return
 var loading=_scene.get_node_or_null("LoadingScreen")
 if loading!=null and loading.visible: return
 _pp=_scene.get_node_or_null("%PostProcessingShader") as ColorRect
 if _pp==null or not _pp.material is ShaderMaterial:
  available=false
  error_text="В этой сцене нет видеопотока. Открой карту для предпросмотра."
  return
 _original=_pp.material
 if _camera!=null: _camera.set_process(active)
 available=true
 error_text=""
 _last_cfg={}
 _apply()

func _detach() -> void:
 if is_instance_valid(_camera):
  _camera.call("_restore")
  _camera.set_process(false)
 _restore_material()
 _pp=null
 _original=null
 _last_cfg={}
 available=false

func _apply() -> void:
 if desk==null or not active: return
 var selected=Model.profile(cfg.profile)
 desk.settings.set("SIGNAL_SIMULATION",selected.mode)
 if _pp==null or not is_instance_valid(_pp): return
 if selected.nito and _analog.shader!=null:
  if _pp.material!=_analog:
   for key in ["fisheye_strength","fisheye_crop"]:
    var value=_pp.material.get_shader_parameter(key)
    if value!=null: _analog.set_shader_parameter(key,value)
  _pp.material=_analog
  var params={"is_analog":true,"video_lines":float(cfg.lines),"signal_res":Vector2(maxf(float(cfg.lines),480)*4.0/3.0,maxf(float(cfg.lines),480)),"sharpness":cfg.sharpness,"chroma_gain":cfg.color,"scanlines":cfg.scanlines,"hit_rate":cfg.noise,"hit_strength":cfg.noise,"band_rate":cfg.noise,"warble":cfg.noise,"warble_rate":cfg.noise,"composite_noise":0.1*cfg.noise,"chroma_noise":0.22*cfg.noise,"sparkly_amount":0.8*cfg.noise,"confetti":cfg.noise,"haze":cfg.glare,"glare_tint":cfg.glare}
  for key in params: _analog.set_shader_parameter(key,params[key])
 else:
  _restore_material()
 if _camera!=null and cfg!=_last_cfg:
  _camera.call("_restore")
  var camera_cfg=_camera.get("cfg")
  camera_cfg.lines=int(cfg.lines) if selected.nito else 0
  camera_cfg.antialias=false
  camera_cfg.texture_softness=float(cfg.softness) if selected.nito else 0.0
  camera_cfg.glare=float(cfg.glare) if selected.nito else 0.0
  camera_cfg.haze=float(cfg.glare)
  camera_cfg.glare_tint=float(cfg.glare)
  _camera.set("cfg",camera_cfg)
  _camera.set("_res_on",selected.nito and float(cfg.lines)>0)
  _camera.set("_glow_on",selected.nito and float(cfg.glare)>0)
 _last_cfg=cfg.duplicate(true)
func _restore_material() -> void:
 if not is_instance_valid(_pp) or _original==null: return
 if _pp.material!=_original and _pp.material is ShaderMaterial:
  for key in ["fisheye_strength","fisheye_crop"]:
   var value=_pp.material.get_shader_parameter(key)
   if value!=null: _original.set_shader_parameter(key,value)
 _pp.material=_original

func _exit_tree() -> void:
 _detach()
