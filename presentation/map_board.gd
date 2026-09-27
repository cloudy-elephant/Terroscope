class_name LaboratoryMapBoard
extends Control

signal room_clicked(room_id: String)

const BOARD_SIZE := Vector2(780, 520)
const MAP_BACKGROUND_PATH := "res://assets/maps/laboratory_background.png"

# Interactive regions mapped onto the generated laboratory illustration. Their relative
# placement follows the numbered physical board supplied as the reference.
const ROOM_POLYGONS := {
	"R1":[Vector2(45,22), Vector2(197,22), Vector2(197,105), Vector2(45,105)],
	"R4":[Vector2(205,25), Vector2(400,25), Vector2(400,105), Vector2(205,105)],
	"R5":[Vector2(405,20), Vector2(528,20), Vector2(528,45), Vector2(578,45), Vector2(578,150), Vector2(480,150), Vector2(480,125), Vector2(405,125)],
	"G5":[Vector2(575,35), Vector2(676,35), Vector2(742,80), Vector2(720,162), Vector2(660,180), Vector2(585,140)],
	"G4":[Vector2(598,145), Vector2(681,170), Vector2(675,270), Vector2(620,270), Vector2(598,215)],
	"G3":[Vector2(675,244), Vector2(758,244), Vector2(758,382), Vector2(678,382)],
	"G1":[Vector2(586,383), Vector2(758,383), Vector2(758,478), Vector2(587,478)],
	"B5":[Vector2(455,354), Vector2(586,354), Vector2(586,478), Vector2(455,478)],
	"B4":[Vector2(185,349), Vector2(455,349), Vector2(455,458), Vector2(185,458)],
	"R3":[Vector2(40,260), Vector2(182,260), Vector2(182,423), Vector2(42,423)],
	"R2":[Vector2(43,105), Vector2(201,105), Vector2(201,255), Vector2(178,255), Vector2(178,260), Vector2(43,260)],
	"B1":[Vector2(235,150), Vector2(367,150), Vector2(367,349), Vector2(235,349)],
	"B2":[Vector2(368,150), Vector2(535,150), Vector2(535,233), Vector2(368,233)],
	"B3":[Vector2(368,234), Vector2(484,234), Vector2(484,349), Vector2(368,349)],
	"G2":[Vector2(485,230), Vector2(602,230), Vector2(602,350), Vector2(485,350)],
}

const FEATURE_LABELS := {
	"search":"搜索",
	"hidden_exit":"隐藏出口",
	"main_exit":"主出口",
	"radio":"无线电",
	"first_aid_cabinet":"急救",
	"killer_start":"屠夫起点",
	"survivor_start":"幸存者起点",
}

const SURVIVOR_MARKERS := {
	"marco_carven":"M",
	"william_hooper":"W",
	"anna_kubrick":"A",
}

var map_data: Dictionary = {}
var rooms_by_id: Dictionary = {}
var edges_by_id: Dictionary = {}
var adjacency: Dictionary = {}
var view: Dictionary = {}
var highlighted_room_ids: Array = []
var preview_path: Array = []
var pending_destination_room_id := ""
var destination_flash_phase := 0.0
var map_background: Texture2D


func _ready() -> void:
	custom_minimum_size = BOARD_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)
	if ResourceLoader.exists(MAP_BACKGROUND_PATH):
		map_background = load(MAP_BACKGROUND_PATH) as Texture2D
	_load_map()
	queue_redraw()


func _process(delta: float) -> void:
	if pending_destination_room_id.is_empty():
		set_process(false)
		return
	destination_flash_phase = fmod(destination_flash_phase + delta * 1.8, 1.0)
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


func set_pending_destination(room_id: String) -> void:
	pending_destination_room_id = room_id if ROOM_POLYGONS.has(room_id) else ""
	destination_flash_phase = 0.0
	set_process(not pending_destination_room_id.is_empty())
	queue_redraw()


func clear_pending_destination() -> void:
	pending_destination_room_id = ""
	destination_flash_phase = 0.0
	set_process(false)
	queue_redraw()


func destination_flash_strength() -> float:
	return 0.5 + 0.5 * sin(destination_flash_phase * TAU)


func neighbors(room_id: String) -> Array:
	return adjacency.get(room_id, []).duplicate()


func room_name(room_id: String) -> String:
	return rooms_by_id.get(room_id, {}).get("name_zh", room_id)


func room_polygon(room_id: String) -> PackedVector2Array:
	return PackedVector2Array(ROOM_POLYGONS.get(room_id, []))


func room_rect(room_id: String) -> Rect2:
	var polygon := room_polygon(room_id)
	if polygon.is_empty():
		return Rect2()
	var rect := Rect2(polygon[0], Vector2.ZERO)
	for point: Vector2 in polygon:
		rect = rect.expand(point)
	return rect


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
		for room_id: String in ROOM_POLYGONS:
			if Geometry2D.is_point_in_polygon(event.position, room_polygon(room_id)):
				room_clicked.emit(room_id)
				accept_event()
				return


func _draw() -> void:
	if map_data.is_empty():
		return
	if map_background != null:
		draw_texture_rect(map_background, Rect2(Vector2.ZERO, BOARD_SIZE), false)
	else:
		draw_rect(Rect2(Vector2.ZERO, BOARD_SIZE), Color("111820"), true)
	draw_rect(Rect2(Vector2.ZERO, BOARD_SIZE), Color(0.01, 0.015, 0.02, 0.10), true)
	_draw_blocked_edges()
	for room: Dictionary in map_data.get("rooms", []):
		_draw_room_overlay(room)


func _draw_blocked_edges() -> void:
	var blocked: Array = view.get("map", {}).get("blocked_edge_ids", [])
	for edge_id_value: Variant in blocked:
		var id := str(edge_id_value)
		if not edges_by_id.has(id):
			continue
		var edge: Dictionary = edges_by_id[id]
		var midpoint := room_rect(edge.a).get_center().lerp(room_rect(edge.b).get_center(), 0.5)
		draw_circle(midpoint, 11.0, Color(0.03, 0.02, 0.01, 0.94))
		draw_line(midpoint + Vector2(-7, -7), midpoint + Vector2(7, 7), Color("ffd166"), 4.0, true)
		draw_line(midpoint + Vector2(-7, 7), midpoint + Vector2(7, -7), Color("ffd166"), 4.0, true)


func _draw_room_overlay(room: Dictionary) -> void:
	var room_id: String = room.id
	var polygon := room_polygon(room_id)
	var outline := Color(0.82, 0.88, 0.92, 0.34)
	var width := 1.4
	if room_id in highlighted_room_ids:
		draw_colored_polygon(polygon, Color(1.0, 0.78, 0.28, 0.12))
		outline = Color("ffd166")
		width = 4.0
	if room_id in preview_path:
		draw_colored_polygon(polygon, Color(0.20, 0.75, 1.0, 0.10))
		_draw_polygon_outline(polygon, Color("65d6ff"), 3.0)
	_draw_polygon_outline(polygon, outline, width)
	if room_id == pending_destination_room_id:
		var strength := destination_flash_strength()
		draw_colored_polygon(polygon, Color(1.0, 0.76, 0.20, 0.08 + strength * 0.14))
		_draw_polygon_outline(polygon, Color(1.0, 0.72 + strength * 0.20, 0.18, 0.45 + strength * 0.55), 4.0 + strength * 3.0)
	_draw_room_label(room, room_rect(room_id))
	_draw_room_markers(room_id, room_rect(room_id))


func _draw_polygon_outline(polygon: PackedVector2Array, color: Color, width: float) -> void:
	var closed := polygon.duplicate()
	closed.append(polygon[0])
	draw_polyline(closed, color, width, true)


func _draw_room_label(room: Dictionary, rect: Rect2) -> void:
	var font := ThemeDB.fallback_font
	var label_width := minf(maxf(88.0, rect.size.x - 10.0), 170.0)
	var label_rect := Rect2(rect.position + Vector2(5, 5), Vector2(label_width, 24))
	draw_rect(label_rect, Color(0.015, 0.02, 0.025, 0.82), true)
	draw_rect(label_rect, Color(0.82, 0.88, 0.92, 0.45), false, 1.0)
	draw_string(font, label_rect.position + Vector2(6, 17), str(room.id), HORIZONTAL_ALIGNMENT_LEFT, 25, 13, Color("ffd166"))
	draw_string(font, label_rect.position + Vector2(31, 17), str(room.get("name_zh", "")), HORIZONTAL_ALIGNMENT_LEFT, label_rect.size.x - 35, 13, Color.WHITE)
	var badges: Array[String] = []
	for feature_value: Variant in room.get("features", []):
		var feature := str(feature_value)
		if FEATURE_LABELS.has(feature):
			badges.append(FEATURE_LABELS[feature])
	if not badges.is_empty() and rect.size.y >= 70.0:
		draw_string(font, rect.position + Vector2(7, 44), " · ".join(badges), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 12, 10, Color(0.9, 0.93, 0.95, 0.90))


func _draw_room_markers(room_id: String, rect: Rect2) -> void:
	var marker_x := rect.position.x + 16.0
	var marker_y := rect.end.y - 15.0
	var noises: Array = view.get("revealed_noise_room_ids", []).duplicate()
	if view.has("noises_this_round"):
		for noise: Dictionary in view.noises_this_round:
			if noise.room_id == room_id and room_id not in noises:
				noises.append(room_id)
	if room_id in noises:
		_draw_marker(Vector2(marker_x, marker_y), Color("ffd166"), "!")
		marker_x += 22
	var killer: Dictionary = view.get("killer", {})
	if killer.get("room_id", "") == room_id:
		_draw_marker(Vector2(marker_x, marker_y), Color("e74c3c"), "K")
		marker_x += 24
	for survivor: Dictionary in view.get("survivors", []):
		if survivor.get("room_id", "") == room_id:
			_draw_marker(Vector2(marker_x, marker_y), Color("65d6ff"), SURVIVOR_MARKERS.get(survivor.get("id", ""), "S"))
			marker_x += 22


func _draw_marker(position: Vector2, color: Color, text: String) -> void:
	draw_circle(position, 9.0, Color(0.01, 0.015, 0.02, 0.96))
	draw_circle(position, 7.0, color)
	var font := ThemeDB.fallback_font
	draw_string(font, position + Vector2(-5, 4), text, HORIZONTAL_ALIGNMENT_CENTER, 10, 10, Color("101820"))


func _load_map() -> void:
	var file := FileAccess.open("res://content/maps/laboratory.json", FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return
	map_data = parsed
	for room: Dictionary in map_data.get("rooms", []):
		rooms_by_id[room.id] = room
		adjacency[room.id] = []
	for edge: Dictionary in map_data.get("edges", []):
		edges_by_id[edge.id] = edge
		adjacency[edge.a].append(edge.b)
		adjacency[edge.b].append(edge.a)
	for room_id: String in adjacency:
		adjacency[room_id].sort()
