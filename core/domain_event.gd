class_name DomainEvent
extends RefCounted


static func make(type: String, payload: Dictionary = {}, audience: String = "all") -> Dictionary:
	return {
		"type": type,
		"audience": audience,
		"payload": payload.duplicate(true),
	}
