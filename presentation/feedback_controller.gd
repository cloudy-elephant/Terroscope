class_name FeedbackController
extends Node

var audio_player: AudioStreamPlayer


func _ready() -> void:
	audio_player = AudioStreamPlayer.new()
	audio_player.volume_db = -16.0
	add_child(audio_player)


func present(events: Array, visual_target: CanvasItem) -> void:
	var frequency := 0.0
	var emphasis := Color.WHITE
	for event: Dictionary in events:
		match event.get("type", ""):
			"ActorMoved":
				frequency = maxf(frequency, 330.0)
				emphasis = Color("b7e4c7")
			"ItemAcquired", "ItemDiscarded", "ItemsExchanged":
				frequency = maxf(frequency, 440.0)
				emphasis = Color("bde0fe")
			"DefenseRolled", "HealthChanged":
				frequency = maxf(frequency, 180.0)
				emphasis = Color("ff8fa3")
			"MatchEnded":
				frequency = 660.0
				emphasis = Color("ffd166")
	if frequency <= 0.0:
		return
	_pulse(visual_target, emphasis)
	_play_tone(frequency)


func _pulse(target: CanvasItem, color: Color) -> void:
	if target == null:
		return
	target.modulate = color
	var tween := create_tween()
	tween.tween_property(target, "modulate", Color.WHITE, 0.22)


func _play_tone(frequency: float) -> void:
	if OS.has_feature("headless") or audio_player == null:
		return
	var mix_rate := 22050
	var sample_count := int(mix_rate * 0.07)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for index in range(sample_count):
		var fade := 1.0 - float(index) / float(sample_count)
		var sample := int(sin(TAU * frequency * float(index) / float(mix_rate)) * 9000.0 * fade)
		bytes.encode_s16(index * 2, sample)
	var sound := AudioStreamWAV.new()
	sound.format = AudioStreamWAV.FORMAT_16_BITS
	sound.mix_rate = mix_rate
	sound.stereo = false
	sound.data = bytes
	audio_player.stream = sound
	audio_player.play()
