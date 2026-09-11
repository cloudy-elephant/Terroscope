class_name LanTransport
extends RefCounted

const MAX_PACKET_BYTES := 4 * 1024 * 1024

var server: TCPServer
var peer: StreamPeerTCP
var mode := "idle"
var receive_buffer := PackedByteArray()
var messages: Array = []
var events: Array = []
var last_error := ""
var connection_announced := false


func host(port: int) -> Dictionary:
	close()
	server = TCPServer.new()
	var error := server.listen(port)
	if error != OK:
		last_error = "Unable to listen on port %d: %s" % [port, error_string(error)]
		server = null
		return {"ok":false,"message":last_error}
	mode = "host"
	return {"ok":true,"port":port}


func join(address: String, port: int) -> Dictionary:
	close()
	peer = StreamPeerTCP.new()
	var error := peer.connect_to_host(address, port)
	if error != OK:
		last_error = "Unable to connect to %s:%d: %s" % [address, port, error_string(error)]
		peer = null
		return {"ok":false,"message":last_error}
	mode = "client"
	return {"ok":true}


func poll() -> void:
	if mode == "host" and server != null and peer == null and server.is_connection_available():
		peer = server.take_connection()
		if peer != null:
			peer.set_no_delay(true)
			events.append({"type":"connected"})
			connection_announced = true
	if peer == null:
		return
	peer.poll()
	var status := peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not connection_announced:
			events.append({"type":"connected"})
			connection_announced = true
		_read_available()
	elif status in [StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE]:
		_disconnect_peer("connection_closed")


func send(message: Dictionary) -> Dictionary:
	if not is_peer_connected():
		return {"ok":false,"message":"No connected peer"}
	var body := JSON.stringify(message).to_utf8_buffer()
	if body.size() > MAX_PACKET_BYTES:
		return {"ok":false,"message":"Message exceeds the packet limit"}
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, body.size())
	frame.append_array(body)
	var error := peer.put_data(frame)
	if error != OK:
		last_error = "Unable to send packet: %s" % error_string(error)
		return {"ok":false,"message":last_error}
	return {"ok":true}


func take_messages() -> Array:
	var result: Array = messages.duplicate(true)
	messages.clear()
	return result


func take_events() -> Array:
	var result: Array = events.duplicate(true)
	events.clear()
	connection_announced = false
	return result


func is_peer_connected() -> bool:
	if peer == null:
		return false
	peer.poll()
	return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func close() -> void:
	if peer != null:
		peer.disconnect_from_host()
	peer = null
	if server != null:
		server.stop()
	server = null
	mode = "idle"
	receive_buffer.clear()
	messages.clear()
	events.clear()


func _read_available() -> void:
	var available := peer.get_available_bytes()
	if available > 0:
		var received: Array = peer.get_data(available)
		if int(received[0]) != OK:
			_disconnect_peer("read_error")
			return
		receive_buffer.append_array(received[1])
	_parse_frames()


func _parse_frames() -> void:
	while receive_buffer.size() >= 4:
		var body_size := receive_buffer.decode_u32(0)
		if body_size > MAX_PACKET_BYTES:
			_disconnect_peer("packet_too_large")
			return
		if receive_buffer.size() < body_size + 4:
			return
		var body := receive_buffer.slice(4, body_size + 4)
		receive_buffer = receive_buffer.slice(body_size + 4)
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary:
			messages.append(parsed)
		else:
			events.append({"type":"protocol_error","message":"Packet is not a JSON object"})


func _disconnect_peer(reason: String) -> void:
	if peer != null:
		peer.disconnect_from_host()
	peer = null
	receive_buffer.clear()
	connection_announced = false
	events.append({"type":"disconnected","reason":reason})
