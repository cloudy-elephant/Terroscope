class_name LobbyState
extends RefCounted

const VALID_SIDES := ["survivors", "killer"]

var data: Dictionary = {}


func create(host_side: String, port: int, versions: Dictionary) -> Dictionary:
	if host_side not in VALID_SIDES:
		return {"ok":false,"message":"Host side must be survivors or killer"}
	data = {
		"status":"waiting",
		"port":port,
		"host_side":host_side,
		"client_side":_opposite_side(host_side),
		"versions":versions.duplicate(true),
		"version_compatible":false,
		"players":{
			"host":{"connected":true,"ready":false,"side":host_side},
			"client":{"connected":false,"ready":false,"side":_opposite_side(host_side)},
		},
	}
	return {"ok":true}


func accept_client_versions(client_versions: Dictionary) -> Dictionary:
	if data.is_empty():
		return {"ok":false,"message":"Lobby is not initialized"}
	for key: String in ["rules_version", "content_version", "map_version", "schema_version"]:
		if str(client_versions.get(key, "")) != str(data.versions.get(key, "")):
			data.version_compatible = false
			data.players.client.connected = false
			return {"ok":false,"message":"Version mismatch: %s" % key}
	data.version_compatible = true
	data.players.client.connected = true
	return {"ok":true,"side":data.client_side}


func set_ready(slot: String, ready: bool) -> Dictionary:
	if slot not in ["host", "client"]:
		return {"ok":false,"message":"Unknown lobby slot"}
	if data.is_empty() or not bool(data.players[slot].connected):
		return {"ok":false,"message":"Player is not connected"}
	if slot == "client" and not bool(data.version_compatible):
		return {"ok":false,"message":"Client version is not compatible"}
	data.players[slot].ready = ready
	return {"ok":true}


func can_start() -> bool:
	return (
		not data.is_empty()
		and bool(data.version_compatible)
		and bool(data.players.host.connected)
		and bool(data.players.client.connected)
		and bool(data.players.host.ready)
		and bool(data.players.client.ready)
	)


func mark_started() -> Dictionary:
	if not can_start():
		return {"ok":false,"message":"Both compatible players must be ready"}
	data.status = "playing"
	return {"ok":true}


func mark_client_disconnected() -> void:
	if data.is_empty():
		return
	data.players.client.connected = false
	data.players.client.ready = false
	if data.status == "playing":
		data.status = "paused"
	else:
		data.status = "waiting"


func snapshot() -> Dictionary:
	return data.duplicate(true)


static func _opposite_side(side: String) -> String:
	return "killer" if side == "survivors" else "survivors"
