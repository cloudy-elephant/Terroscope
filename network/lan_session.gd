class_name LanSession
extends Node

const GameCommandScript = preload("res://core/command.gd")
const GameStateScript = preload("res://core/game_state.gd")
const MatchHostScript = preload("res://network/match_host.gd")
const LobbyStateScript = preload("res://network/lobby_state.gd")
const LanTransportScript = preload("res://network/lan_transport.gd")

const DEFAULT_PORT := 28735
const PROTOCOL_VERSION := "1"

signal lobby_changed(snapshot: Dictionary)
signal match_started(view: Dictionary, events: Array)
signal view_changed(view: Dictionary, events: Array)
signal command_completed(result: Dictionary)
signal session_status_changed(message: String)
signal connection_lost(message: String)

var transport = LanTransportScript.new()
var lobby = LobbyStateScript.new()
var match_host
var mode := "idle"
var local_side := ""
var remote_side := ""
var current_view: Dictionary = {}
var current_events: Array = []
var lobby_snapshot: Dictionary = {}
var match_active := false
var paused := false
var command_counter := 0


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	poll_network()


func protocol_versions() -> Dictionary:
	var map_version := ""
	var file := FileAccess.open("res://content/maps/laboratory.json", FileAccess.READ)
	if file != null:
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		if parsed is Dictionary:
			map_version = str(parsed.get("version", ""))
	return {
		"protocol_version":PROTOCOL_VERSION,
		"rules_version":GameStateScript.RULES_VERSION,
		"content_version":GameStateScript.CONTENT_VERSION,
		"map_version":map_version,
		"schema_version":GameStateScript.SCHEMA_VERSION,
	}


func create_room(host_side: String, port: int = DEFAULT_PORT) -> Dictionary:
	shutdown()
	var lobby_result: Dictionary = lobby.create(host_side, port, protocol_versions())
	if not lobby_result.ok:
		return lobby_result
	var transport_result: Dictionary = transport.host(port)
	if not transport_result.ok:
		return transport_result
	mode = "host"
	local_side = host_side
	remote_side = LobbyStateScript._opposite_side(host_side)
	lobby_snapshot = lobby.snapshot()
	lobby_changed.emit(lobby_snapshot)
	session_status_changed.emit("Room listening on port %d" % port)
	return {"ok":true,"port":port,"side":local_side}


func join_room(address: String, port: int = DEFAULT_PORT) -> Dictionary:
	shutdown()
	var result: Dictionary = transport.join(address, port)
	if not result.ok:
		return result
	mode = "client"
	session_status_changed.emit("Connecting to %s:%d" % [address, port])
	return {"ok":true}


func start_offline(seed_value: int, side: String = "survivors") -> Dictionary:
	shutdown()
	if side not in ["survivors", "killer"]:
		return {"ok":false,"message":"Unknown side"}
	mode = "offline"
	local_side = side
	remote_side = LobbyStateScript._opposite_side(side)
	return _start_authoritative_match(seed_value, false)


func set_debug_side(side: String) -> Dictionary:
	if mode != "offline" or not match_active or side not in ["survivors", "killer"]:
		return {"ok":false,"message":"Debug side switch is unavailable"}
	local_side = side
	remote_side = LobbyStateScript._opposite_side(side)
	current_view = match_host.view_for_side(local_side)
	view_changed.emit(current_view, [])
	return {"ok":true}


func set_ready(ready: bool) -> Dictionary:
	if mode == "host":
		var result: Dictionary = lobby.set_ready("host", ready)
		if result.ok:
			_broadcast_lobby()
		return result
	if mode == "client":
		return transport.send({"kind":"set_ready","ready":ready})
	return {"ok":false,"message":"No network lobby is active"}


func can_start_network_match() -> bool:
	return mode == "host" and lobby.can_start()


func start_network_match(seed_value: int) -> Dictionary:
	if mode != "host":
		return {"ok":false,"message":"Only the host can start the match"}
	var marked: Dictionary = lobby.mark_started()
	if not marked.ok:
		return marked
	_broadcast_lobby()
	return _start_authoritative_match(seed_value, true)


func restart_match(seed_value: int) -> Dictionary:
	if mode not in ["offline", "host"]:
		return {"ok":false,"message":"Only an authoritative session can restart"}
	return _start_authoritative_match(seed_value, mode == "host")


func submit_command(command_type: String, payload: Dictionary = {}) -> Dictionary:
	if not match_active:
		return _local_rejection("PREREQUISITE_MISSING", "No match is active")
	if paused:
		return _local_rejection("PREREQUISITE_MISSING", "Match is paused after a disconnect")
	command_counter += 1
	var command: Dictionary = GameCommandScript.make(
		command_type,
		"%s-%d-%d" % [mode, Time.get_ticks_usec(), command_counter],
		int(current_view.get("command_sequence", -1)),
		_player_id_for_side(local_side),
		payload
	)
	if mode == "client":
		var sent: Dictionary = transport.send({"kind":"command","command":command})
		return {"accepted":false,"queued":bool(sent.ok),"message":sent.get("message", "")}
	return _apply_authoritative_command(command, local_side, false)


func poll_network() -> void:
	if mode not in ["host", "client"]:
		return
	transport.poll()
	for event: Dictionary in transport.take_events():
		_handle_transport_event(event)
	for message: Dictionary in transport.take_messages():
		_handle_message(message)


func get_local_addresses() -> Array:
	var result: Array = []
	for address: String in IP.get_local_addresses():
		if ":" not in address and not address.begins_with("127.") and address not in result:
			result.append(address)
	result.sort()
	return result


func shutdown() -> void:
	transport.close()
	match_host = null
	mode = "idle"
	local_side = ""
	remote_side = ""
	current_view = {}
	current_events = []
	lobby_snapshot = {}
	match_active = false
	paused = false
	command_counter = 0


func _start_authoritative_match(seed_value: int, notify_remote: bool) -> Dictionary:
	match_host = MatchHostScript.new()
	var started: Dictionary = match_host.start_match(seed_value)
	if not started.ok:
		return started
	match_active = true
	paused = false
	current_events = match_host.events_for_side(started.events, local_side)
	current_view = match_host.view_for_side(local_side)
	match_started.emit(current_view, current_events)
	if notify_remote:
		transport.send({
			"kind":"match_started",
			"side":remote_side,
			"view":match_host.view_for_side(remote_side),
			"events":match_host.events_for_side(started.events, remote_side),
		})
	return {"ok":true,"view":current_view,"events":current_events}


func _apply_authoritative_command(command: Dictionary, requesting_side: String, from_remote: bool) -> Dictionary:
	if _player_id_for_side(requesting_side) != str(command.get("player_id", "")):
		var forbidden: Dictionary = _local_rejection("NOT_CONTROLLER", "Network sender cannot control the other side")
		if from_remote:
			transport.send({"kind":"command_result","result":forbidden,"view":match_host.view_for_side(requesting_side)})
		return forbidden
	var result: Dictionary = match_host.submit(command)
	var projected_result: Dictionary = _project_result(result, requesting_side)
	if from_remote:
		transport.send({"kind":"command_result","result":projected_result,"view":match_host.view_for_side(requesting_side)})
	else:
		command_completed.emit(projected_result)
	current_view = match_host.view_for_side(local_side)
	current_events = match_host.events_for_side(result.get("events", []), local_side)
	view_changed.emit(current_view, current_events)
	if mode == "host" and not from_remote:
		transport.send({
			"kind":"remote_update",
			"view":match_host.view_for_side(remote_side),
			"events":match_host.events_for_side(result.get("events", []), remote_side),
		})
	return projected_result


func _project_result(result: Dictionary, side: String) -> Dictionary:
	var projected: Dictionary = result.duplicate(true)
	if match_host != null:
		projected.events = match_host.events_for_side(result.get("events", []), side)
	return projected


func _handle_transport_event(event: Dictionary) -> void:
	match event.get("type", ""):
		"connected":
			if mode == "client":
				transport.send({"kind":"hello","versions":protocol_versions()})
			session_status_changed.emit("Peer connected")
		"disconnected":
			if mode == "host":
				lobby.mark_client_disconnected()
				lobby_snapshot = lobby.snapshot()
				paused = match_active
				lobby_changed.emit(lobby_snapshot)
			else:
				match_active = false
				paused = false
				current_view = {}
			connection_lost.emit("Connection closed; the host is waiting" if mode == "host" else "Connection closed; returned to lobby")
		"protocol_error":
			connection_lost.emit(event.get("message", "Protocol error"))


func _handle_message(message: Dictionary) -> void:
	if mode == "host":
		_handle_host_message(message)
	elif mode == "client":
		_handle_client_message(message)


func _handle_host_message(message: Dictionary) -> void:
	match message.get("kind", ""):
		"hello":
			var versions: Dictionary = message.get("versions", {})
			if str(versions.get("protocol_version", "")) != PROTOCOL_VERSION:
				transport.send({"kind":"hello_result","ok":false,"message":"Protocol version mismatch"})
				return
			var result: Dictionary = lobby.accept_client_versions(versions)
			transport.send({"kind":"hello_result","ok":result.ok,"message":result.get("message", ""),"side":remote_side,"lobby":lobby.snapshot()})
			if result.ok:
				_broadcast_lobby()
		"set_ready":
			lobby.set_ready("client", bool(message.get("ready", false)))
			_broadcast_lobby()
		"command":
			if match_active and not paused:
				_apply_authoritative_command(message.get("command", {}), remote_side, true)
			else:
				transport.send({"kind":"command_result","result":_local_rejection("PREREQUISITE_MISSING", "Match is unavailable"),"view":match_host.view_for_side(remote_side) if match_host != null else {}})
		"snapshot_request":
			if match_host != null:
				transport.send({"kind":"snapshot","view":match_host.view_for_side(remote_side)})


func _handle_client_message(message: Dictionary) -> void:
	match message.get("kind", ""):
		"hello_result":
			if not bool(message.get("ok", false)):
				connection_lost.emit(message.get("message", "Version handshake failed"))
				return
			local_side = message.get("side", "")
			remote_side = LobbyStateScript._opposite_side(local_side)
			lobby_snapshot = message.get("lobby", {}).duplicate(true)
			lobby_changed.emit(lobby_snapshot)
			session_status_changed.emit("Connected as %s" % local_side)
		"lobby":
			lobby_snapshot = message.get("lobby", {}).duplicate(true)
			lobby_changed.emit(lobby_snapshot)
		"match_started":
			local_side = message.get("side", local_side)
			remote_side = LobbyStateScript._opposite_side(local_side)
			match_active = true
			paused = false
			current_view = message.get("view", {}).duplicate(true)
			current_events = message.get("events", []).duplicate(true)
			match_started.emit(current_view, current_events)
		"command_result":
			command_completed.emit(message.get("result", {}).duplicate(true))
			_accept_remote_view(message.get("view", {}), message.get("result", {}).get("events", []))
		"remote_update":
			_accept_remote_view(message.get("view", {}), message.get("events", []))
		"snapshot":
			current_view = message.get("view", {}).duplicate(true)
			view_changed.emit(current_view, [])


func _accept_remote_view(view: Dictionary, events: Array) -> void:
	if view.is_empty():
		return
	var current_sequence: int = int(current_view.get("command_sequence", -1))
	var incoming_sequence: int = int(view.get("command_sequence", -1))
	if current_sequence >= 0 and incoming_sequence > current_sequence + 1:
		transport.send({"kind":"snapshot_request","after_command_sequence":current_sequence})
		return
	if incoming_sequence < current_sequence:
		return
	current_view = view.duplicate(true)
	current_events = events.duplicate(true)
	view_changed.emit(current_view, current_events)


func _broadcast_lobby() -> void:
	lobby_snapshot = lobby.snapshot()
	lobby_changed.emit(lobby_snapshot)
	transport.send({"kind":"lobby","lobby":lobby_snapshot})


func _player_id_for_side(side: String) -> String:
	return "player_killer" if side == "killer" else "player_survivors"


func _local_rejection(code: String, message: String) -> Dictionary:
	return {"accepted":false,"code":code,"message":message,"events":[]}
