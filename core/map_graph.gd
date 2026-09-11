class_name MapGraph
extends RefCounted

var data: Dictionary = {}
var rooms_by_id: Dictionary = {}
var edges_by_id: Dictionary = {}
var adjacency: Dictionary = {}
var load_error: String = ""


func load_from_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		load_error = "Cannot open map file: %s" % path
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		load_error = "Map file is not a JSON object: %s" % path
		return false
	data = parsed
	return _build_indexes()


func _build_indexes() -> bool:
	rooms_by_id.clear()
	edges_by_id.clear()
	adjacency.clear()
	for room: Dictionary in data.get("rooms", []):
		var room_id: String = room.get("id", "")
		if room_id.is_empty() or rooms_by_id.has(room_id):
			load_error = "Invalid or duplicate room id: %s" % room_id
			return false
		rooms_by_id[room_id] = room
		adjacency[room_id] = []
	for edge: Dictionary in data.get("edges", []):
		var edge_id: String = edge.get("id", "")
		var a: String = edge.get("a", "")
		var b: String = edge.get("b", "")
		if edge_id != edge_id_for(a, b) or edges_by_id.has(edge_id):
			load_error = "Invalid or duplicate edge id: %s" % edge_id
			return false
		if not rooms_by_id.has(a) or not rooms_by_id.has(b):
			load_error = "Edge %s refers to an unknown room" % edge_id
			return false
		edges_by_id[edge_id] = edge
		adjacency[a].append(b)
		adjacency[b].append(a)
	for room_id: String in adjacency:
		adjacency[room_id].sort()
	return true


func room_count() -> int:
	return rooms_by_id.size()


func edge_count() -> int:
	return edges_by_id.size()


func has_room(room_id: String) -> bool:
	return rooms_by_id.has(room_id)


func neighbors(room_id: String) -> Array:
	return adjacency.get(room_id, []).duplicate()


func is_adjacent(a: String, b: String) -> bool:
	return edges_by_id.has(edge_id_for(a, b))


func is_blockable(edge_id: String) -> bool:
	return edges_by_id.has(edge_id) and edges_by_id[edge_id].get("blockable", false)


func validate_path(start_room_id: String, path: Array, blocked_edge_ids: Array, ignore_blocks: bool = false) -> Dictionary:
	var current_room_id := start_room_id
	for next_value: Variant in path:
		var next_room_id := str(next_value)
		var edge_id := edge_id_for(current_room_id, next_room_id)
		if not edges_by_id.has(edge_id):
			return {"ok": false, "reason": "Rooms are not adjacent: %s -> %s" % [current_room_id, next_room_id]}
		if not ignore_blocks and edge_id in blocked_edge_ids:
			return {"ok": false, "reason": "Edge is blocked: %s" % edge_id}
		current_room_id = next_room_id
	return {"ok": true, "end_room_id": current_room_id}


static func edge_id_for(a: String, b: String) -> String:
	var endpoints := [a, b]
	endpoints.sort()
	return "%s--%s" % endpoints
