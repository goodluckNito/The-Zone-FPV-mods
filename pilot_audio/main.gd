extends Node
## pilot_audio 1.0
##
## Hear the quad from where the pilot stands: loudness, tone, delay, doppler
## and stereo by distance and direction from the spawn point, and optionally
## other players' quads too. Loaded by zonemods (override.cfg in the game
## folder). Settings are in pilot_audio/settings.cfg; audio.gd does the work.
##
## Uninstall: delete the pilot_audio folder.

const VERSION := "1.0"
const DIR := "res://pilot_audio/"

var _audio: Node = null
var _log := PackedStringArray()


func zm_init(_core: Node, _dir: String) -> void:
	_say("pilot_audio %s" % VERSION)
	var script = load(DIR + "audio.gd")
	if script is Script and script.can_instantiate():
		_audio = script.new()
		_audio.name = "Audio"
		_say(_audio.setup(DIR))
		add_child(_audio)
	else:
		_say("could not load audio.gd")
	_write_status()


## The sounds the pilot hears and what each is doing: distance, gain_db,
## cutoff_hz, pan, pitch, doppler, delay, walls, playing, remote.
func zm_audio() -> Array:
	return _audio.report() if _audio != null and is_instance_valid(_audio) and _audio.has_method("report") else []


func _say(s: String) -> void:
	_log.append(s)
	print("[pilot_audio] " + s)


func _write_status() -> void:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("pilot_audio/status.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_log) + "\n")
