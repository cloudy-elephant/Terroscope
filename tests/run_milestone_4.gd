extends SceneTree

const LobbyStateScript = preload("res://network/lobby_state.gd")
const LanTransportScript = preload("res://network/lan_transport.gd")
const LanSessionScript = preload("res://network/lan_session.gd")

var failures: Array[String] = []
var assertions := 0


func _initialize() -> void:
	_test_lobby_contract()
	_test_reliable_loopback_transport()
	_test_authoritative_network_session()
	_test_offline_dual_view()
	await _test_main_scene_and_cancel_boundary()
	if failures.is_empty():
		print("Milestone 4 PASS (%d assertions)" % assertions)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("Milestone 4 FAIL (%d failures, %d assertions)" % [failures.size(), assertions])
		quit(1)


func _test_lobby_contract() -> void:
	var session = LanSessionScript.new()
	var versions: Dictionary = session.protocol_versions()
	var lobby = LobbyStateScript.new()
	var created: Dictionary = lobby.create("killer", 28735, versions)
	_expect(created.ok, "lobby accepts one valid host side")
	_expect_eq(lobby.data.host_side, "killer", "host keeps its chosen side")
	_expect_eq(lobby.data.client_side, "survivors", "joining player receives the opposite side")
	_expect(not lobby.can_start(), "lobby cannot start without a compatible client")
	var mismatch := versions.duplicate(true)
	mismatch.rules_version = "different"
	var mismatch_result: Dictionary = lobby.accept_client_versions(mismatch)
	_expect(not mismatch_result.ok, "version mismatch rejects the client")
	_expect("rules_version" in mismatch_result.message, "version rejection identifies the mismatched field")
	var accepted: Dictionary = lobby.accept_client_versions(versions)
	_expect(accepted.ok, "matching version handshake is accepted")
	_expect_eq(accepted.side, "survivors", "handshake reports assigned side")
	_expect(lobby.set_ready("host", true).ok, "host can become ready")
	_expect(lobby.set_ready("client", true).ok, "compatible client can become ready")
	_expect(lobby.can_start(), "both ready compatible players unlock match start")
	_expect(lobby.mark_started().ok, "ready lobby enters playing state")
	lobby.mark_client_disconnected()
	_expect_eq(lobby.data.status, "paused", "client disconnect pauses an active lobby")
	_expect(not lobby.can_start(), "disconnected lobby no longer satisfies start conditions")
	session.free()


func _test_reliable_loopback_transport() -> void:
	var server = LanTransportScript.new()
	var client = LanTransportScript.new()
	var port := _listen_on_available_port(server, 29300)
	_expect(port > 0, "TCP server finds a local test port")
	if port <= 0:
		return
	_expect(client.join("127.0.0.1", port).ok, "TCP client starts a loopback connection")
	_expect(_wait_for_connection(server, client), "loopback peers establish a reliable stream")
	_expect(client.send({"kind":"first","value":1}).ok, "client sends first framed JSON message")
	_expect(client.send({"kind":"second","value":2}).ok, "client sends second framed JSON message")
	var received := _wait_for_messages(server, client, server, 2)
	_expect_eq(received.size(), 2, "server receives both complete frames")
	if received.size() == 2:
		_expect_eq(received[0].kind, "first", "reliable stream preserves first message order")
		_expect_eq(received[1].kind, "second", "reliable stream preserves second message order")
	_expect(server.send({"kind":"reply","nested":{"ok":true}}).ok, "server sends a structured reply")
	var replies := _wait_for_messages(server, client, client, 1)
	_expect_eq(replies.size(), 1, "client receives host reply")
	if not replies.is_empty():
		_expect_eq(replies[0].nested.ok, true, "transport preserves nested JSON data")
	client.close()
	var disconnected := false
	for attempt in range(200):
		server.poll()
		for event: Dictionary in server.take_events():
			if event.type == "disconnected":
				disconnected = true
		if disconnected:
			break
		OS.delay_msec(2)
	_expect(disconnected, "server detects peer disconnect")
	server.close()


func _test_authoritative_network_session() -> void:
	var host_session = LanSessionScript.new()
	var client_session = LanSessionScript.new()
	root.add_child(host_session)
	root.add_child(client_session)
	var host_result: Dictionary = {}
	var port := 0
	for candidate in range(29400, 29420):
		host_result = host_session.create_room("killer", candidate)
		if host_result.ok:
			port = candidate
			break
	_expect(port > 0, "network session opens a host room")
	if port <= 0:
		host_session.queue_free()
		client_session.queue_free()
		return
	_expect(client_session.join_room("127.0.0.1", port).ok, "second session joins host address")
	_expect(_wait_for_session_handshake(host_session, client_session), "sessions complete version handshake")
	_expect_eq(host_session.remote_side, "survivors", "host records the remote side")
	_expect_eq(client_session.local_side, "survivors", "client receives survivor authority")
	_expect(host_session.set_ready(true).ok, "network host readies")
	_expect(client_session.set_ready(true).ok, "network client sends ready message")
	for attempt in range(300):
		host_session.poll_network()
		client_session.poll_network()
		if host_session.can_start_network_match():
			break
		OS.delay_msec(2)
	_expect(host_session.can_start_network_match(), "ready state reaches the host over TCP")
	var started: Dictionary = host_session.start_network_match(40404)
	_expect(started.ok, "host creates the authoritative match")
	_expect(_wait_for_client_match(host_session, client_session), "client receives its initial projected snapshot")
	_expect(not client_session.current_view.killer.has("hand"), "survivor network snapshot omits killer hand")
	_expect(not host_session.current_view.survivors[0].has("room_id"), "killer network snapshot omits survivor positions")
	_expect(not host_session.current_view.survivors[0].has("fear"), "killer network snapshot omits survivor fear")
	_expect(not host_session.current_view.has("rng_state"), "network views never expose authoritative RNG")

	var queued: Dictionary = client_session.submit_command("BeginSurvivorActivation", {"survivor_id":"marco_carven"})
	_expect(queued.queued, "client queues intent instead of mutating local state")
	_expect_eq(client_session.current_view.command_sequence, 0, "client waits for host acceptance")
	_expect(_wait_for_command_sequence(host_session, client_session, 1), "host accepts client command and returns both projections")
	_expect_eq(client_session.current_view.active_actor_id, "marco_carven", "client receives accepted survivor activation")
	_expect_eq(host_session.match_host.state.data.active_actor_id, "marco_carven", "host owns the authoritative state mutation")
	_expect(not host_session.current_view.survivors[0].has("room_id"), "updated killer projection still hides positions")

	client_session.shutdown()
	for attempt in range(200):
		host_session.poll_network()
		if host_session.paused:
			break
		OS.delay_msec(2)
	_expect(host_session.paused, "client disconnect pauses the authoritative session")
	var paused_result: Dictionary = host_session.submit_command("EndKillerFast", {})
	_expect_eq(paused_result.code, "PREREQUISITE_MISSING", "paused host rejects further gameplay commands")
	host_session.shutdown()
	host_session.queue_free()
	client_session.queue_free()


func _test_offline_dual_view() -> void:
	var session = LanSessionScript.new()
	root.add_child(session)
	var started: Dictionary = session.start_offline(40505, "survivors")
	_expect(started.ok, "offline debug mode starts without a socket")
	_expect(session.current_view.survivors[0].has("room_id"), "survivor debug view includes survivor room")
	_expect(not session.current_view.killer.has("hand"), "survivor debug view hides killer hand")
	_expect(session.set_debug_side("killer").ok, "offline mode can switch to killer projection")
	_expect(session.current_view.killer.has("hand"), "killer debug view includes private hand")
	_expect(not session.current_view.survivors[0].has("room_id"), "killer debug view strips survivor room")
	_expect(session.set_debug_side("survivors").ok, "offline mode switches back to survivors")
	var result: Dictionary = session.submit_command("BeginSurvivorActivation", {"survivor_id":"anna_kubrick"})
	_expect(result.accepted, "offline UI submits through the same host command path")
	_expect_eq(session.current_view.command_sequence, 1, "offline accepted command advances projected sequence")
	session.shutdown()
	session.queue_free()


func _test_main_scene_and_cancel_boundary() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var app = scene.instantiate()
	root.add_child(app)
	await process_frame
	_expect(app.lobby_panel.visible, "main scene opens on the playable lobby")
	_expect(not app.game_panel.visible, "game board stays hidden before a match")
	_expect_eq(app.map_board.map_data.rooms.size(), 15, "visual board loads all laboratory rooms")
	var started: Dictionary = app.session.start_offline(40606, "survivors")
	_expect(started.ok, "main scene enters local dual-view match")
	_expect(app.game_panel.visible, "game board appears when match starts")
	_expect(app.action_list.get_child_count() >= 3, "first phase renders one action per survivor")
	var sequence_before: int = app.session.current_view.command_sequence
	var first_button: Button = app.action_list.get_child(0)
	first_button.pressed.emit()
	_expect(not app.pending_command.is_empty(), "clicking an action creates a local preview")
	_expect_eq(app.session.current_view.command_sequence, sequence_before, "preview does not mutate authoritative state")
	_expect(app.confirmation_panel.visible, "preview exposes explicit confirm and cancel controls")
	app._cancel_pending_command()
	_expect(app.pending_command.is_empty(), "cancel removes the pending selection")
	_expect_eq(app.session.current_view.command_sequence, sequence_before, "cancel leaves host command sequence unchanged")
	app.queue_free()


func _listen_on_available_port(server, first_port: int) -> int:
	for port in range(first_port, first_port + 20):
		if server.host(port).ok:
			return port
	return 0


func _wait_for_connection(server, client) -> bool:
	for attempt in range(400):
		server.poll()
		client.poll()
		if server.is_peer_connected() and client.is_peer_connected():
			server.take_events()
			client.take_events()
			return true
		OS.delay_msec(2)
	return false


func _wait_for_messages(server, client, receiver, count: int) -> Array:
	var result: Array = []
	for attempt in range(400):
		server.poll()
		client.poll()
		result.append_array(receiver.take_messages())
		if result.size() >= count:
			return result
		OS.delay_msec(2)
	return result


func _wait_for_session_handshake(host_session, client_session) -> bool:
	for attempt in range(500):
		host_session.poll_network()
		client_session.poll_network()
		if client_session.local_side == "survivors" and not client_session.lobby_snapshot.is_empty():
			return true
		OS.delay_msec(2)
	return false


func _wait_for_client_match(host_session, client_session) -> bool:
	for attempt in range(500):
		host_session.poll_network()
		client_session.poll_network()
		if client_session.match_active:
			return true
		OS.delay_msec(2)
	return false


func _wait_for_command_sequence(host_session, client_session, sequence: int) -> bool:
	for attempt in range(500):
		host_session.poll_network()
		client_session.poll_network()
		if int(host_session.current_view.get("command_sequence", -1)) == sequence and int(client_session.current_view.get("command_sequence", -1)) == sequence:
			return true
		OS.delay_msec(2)
	return false


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)


func _expect_eq(actual: Variant, expected: Variant, message: String) -> void:
	assertions += 1
	if actual != expected:
		failures.append("%s; expected=%s actual=%s" % [message, str(expected), str(actual)])
