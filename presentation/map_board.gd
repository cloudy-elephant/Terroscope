class_name LaboratoryMapBoard
extends Control

signal room_clicked(room_id: String)

const ROOM_SIZE := Vector2(108, 62)
const ROOM_POSITIONS := {
	"R1":Vector2(18, 22), "R2":Vector2(146, 22), "R3":Vector2(274, 22), "R4":Vector2(402, 22), "R5":Vector2(530, 22),
	"B1":Vector2(18, 190), "B2":Vector2(146, 190), "B3":Vector2(274, 190), "B4":Vector2(402, 190), "B5":Vector2(530, 190),
	"G1":Vector2(18, 358), "G2":Vector2(146, 358), "G3":Vector2(274, 358), "G4":Vector2(402, 358), "G5":Vector2(530, 358),
}
const REGION_COLORS := {
	"R":Color("5a2630"),
	"B":Color("243d5a"),
	"G":Color("294d3b"),
}

var map_data: Dictionary = {}
var edges_by_id: Dictionary = {}
var adjacency: Dictionary = {}
var view: Dictionary = {}
var highlighted_room_ids: Array = []
var preview_path: Array = []


func _ready() -> void:
	custom_minimum_size = Vector2(660, 454)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_load_map()
	queue_redraw()


func set_view(next_view: Dictionary) -> void:
	view = next_view.duplicate(true)
	queue_redraw()


func set_selection(highlighted: Array, path: Array = []) -> void:
	highlighted_room_ids = highlighted.duplicate()
	preview_path = path.duplicate()
	queue_redraw()


func clear_selection() -> void:
	highlighted_room_ids.clear()
	preview_path.clear()
	queue_redraw()


func neighbors(room_id: String) -> Array:
	return adjacency.get(room_id, []).duplicate()


func edge_id(a: String, b: String) -> String:
	var values := [a, b]
	values.sort()
	return "%s--%s" % values


func blockable_edges_touching(room_id: String) -> Array:
	var result: Array = []
	for id: String in edges_by_id:
		var edge: Dictionary = edges_by_id[id]
		if bool(edge.get("blockable", false)) and (edge.a == room_id or edge.b == room_id):
			result.append(id)
	result.sort()
	return result


func all_blockable_edges() -> Array:
	var result: Array = []
	for id: String in edges_by_id:
		if bool(edges_by_id[id].get("blockable", false)):
			result.append(id)
	result.sort()
	return result


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		for room_id: String in ROOM_POSITIONS:
			if Rect2(ROOM_POSITIONS[room_id], ROOM_SIZE).has_point(event.position):
				room_clicked.emit(room_id)
				accept_event()
				return


func _draw() -> void:
	if map_data.is_empty():
		return
	var blocked: Array = view.get("map", {}).get("blocked_edge_ids", [])
	for edge: Dictionary in map_data.get("edges", []):
		var from: Vector2 = ROOM_POSITIONS[edge.a] + ROOM_SIZE * 0.5
		var to: Vector2 = ROOM_POSITIONS[edge.b] + ROOM_SIZE * 0.5
		var edge_color := Color("e0a93a") if edge.id in blocked else Color("71808f")
		draw_line(from, to, edge_color, 5.0 if edge.id in blocked else 2.0, true)
	for room: Dictionary in map_data.get("rooms", []):
		var room_id: String = room.id
		var rect := Rect2(ROOM_POSITIONS[room_id], ROOM_SIZE)
		var fill: Color = REGION_COLORS.get(room.region, Color("333333"))
		if not highlighted_room_ids.is_empty() and room_id not in highlighted_room_ids:
			fill = fill.darkened(0.35)
		draw_rect(rect, fill, true)
		var border := Color("ffd166") if room_id in highlighted_room_ids else Color("b8c2cc")
		draw_rect(rect, border, false, 4.0 if room_id in highlighted_room_ids else 1.5)
		if room_id in preview_path:
			draw_rect(rect.grow(-5), Color("65d6ff"), false, 3.0)
		var font := ThemeDB.fallback_font
		draw_string(font, rect.position + Vector2(7, 20), "%s  %s" % [room_id, room.get("name_zh", "")], HORIZONTAL_ALIGNMENT_LEFT, ROOM_SIZE.x - 12, 14, Color.WHITE)
		_draw_room_markers(room_id, rect)


func _draw_room_markers(room_id: String, rect: Rect2) -> void:
	var marker_x := rect.position.x + 12.0
	var marker_y := rect.end.y - 13.0
	var noises: Array = view.get("revealed_noise_room_ids", [])
	if view.has("noises_this_round"):
		for noise: Dictionary in view.noises_this_round:
			if noise.room_id == room_id and room_id not in noises:
				noises.append(room_id)
	if room_id in noises:
		draw_circle(Vector2(marker_x, marker_y), 6, Color("ffd166"))
		marker_x += 17
	var killer: Dictionary = view.get("killer", {})
	if killer.get("room_id", "") == room_id:
		draw_circle(Vector2(marker_x, marker_y), 7, Color("e74c3c"))
		marker_x += 19
	for survivor: Dictionary in view.get("survivors", []):
		if survivor.get("room_id", "") == room_id:
			draw_circle(Vector2(marker_x, marker_y), 6, Color("65d6ff"))
			marker_x += 16


func _load_map() -> void:
	var file := FileAccess.open("res://content/maps/laboratory.json", FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return
	map_data = parsed
	for room: Dictionary in map_data.get("rooms", []):
		adjacency[room.id] = []
	for edge: Dictionary in map_data.get("edges", []):
		edges_by_id[edge.id] = edge
		adjacency[edge.a].append(edge.b)
		adjacency[edge.b].append(edge.a)
