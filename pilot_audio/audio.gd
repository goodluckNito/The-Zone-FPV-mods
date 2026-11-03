extends "res://pilot_audio/audio_original.gd"
func _exit_tree() -> void:
 if is_instance_valid(_qa):
  _qa.pitch_scale=_game_pitch
  _qa.volume_db=_game_vol
 super._exit_tree()
