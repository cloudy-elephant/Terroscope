class_name GameCommand
extends RefCounted


static func make(
		type: String,
		command_id: String,
		expected_command_sequence: int,
		player_id: String,
		payload: Dictionary = {}
) -> Dictionary:
	return {
		"type": type,
		"command_id": command_id,
		"expected_command_sequence": expected_command_sequence,
		"player_id": player_id,
		"payload": payload.duplicate(true),
	}
