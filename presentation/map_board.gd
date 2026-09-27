class_name LaboratoryMapBoard
extends Control

signal room_clicked(room_id: String)

const BOARD_SIZE := Vector2(780, 520)
const MAP_BACKGROUND_PATH := "res://assets/maps/laboratory_background.png"

# The layout follows the photographed board instead of presenting the rooms as a grid.
# Room rectangles are also the authoritative click targets for the presentation layer.
const ROOM_RECTS := {
	"R1":Rect2(18, 22, 130, 76),
	"R4":Rect2(158, 22, 132, 76),
	"R5":Rect2(300, 22, 180, 124),
	"G5":Rect2(622, 26, 140, 116),
	"G4":Rect2(558, 136, 110, 116),
	"G3":Rect2(622, 278, 140, 118),
	"G1":Rect2(622, 424, 140, 74),
	"B5":Rect2(472, 424, 140, 74),
	"B4":Rect2(316, 424, 146, 74),
	"R3":Rect2(158, 424, 148, 74),
	"R2":Rect2(18, 180, 150, 214),
	"B1":Rect2(210, 188, 146, 182),
	"B2":Rect2(370, 176, 156, 104),
	"B3":Rect2(370, 290, 106, 114),
	"G2":Rect2(486, 290, 106, 114),
}

const REGION_COLORS := {
	"R":Color("a93642"),
	"B":Color("315e89"),
	"G":Color("367153"),
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
var map_background: Texture2D


func _ready() -> void:
	custom_minimum_size = BOARD_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	if ResourceLoader.exists(MAP_BACKGROUND_PATH):
		map_background = load(MAP_BACKGROUND_PATH) as Texture2D
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


func room_name(room_id: String) -> String:
	return rooms_by_id.get(room_id, {}).get("name_zh", room_id)


func room_rect(room_id: String) -> Rect2:
	return ROOM_RECTS.get(room_id, Rect2())


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
		for room_id: String in ROOM_RECTS:
			if room_rect(room_id).has_point(event.position):
				room_clicked.emit(room_id)
				accept_event()
				return


func _draw() -> void:
	if map_data.is_empty():
		return
	if map_background != null:
		draw_texture_rect(map_background, Rect2(Vector2.ZERO, BOARD_SIZE), false, Color(0.62, 0.66, 0.70, 0.82))
	else:
		draw_rect(Rect2(Vector2.ZERO, BOARD_SIZE), Color("111820"), true)
	draw_rect(Rect2(Vector2.ZERO, BOARD_SIZE), Color(0.01, 0.018, 0.025, 0.28), true)
	_draw_connections()
	for room: Dictionary in map_data.get("rooms", []):
		_draw_room(room)


func _draw_connections() -> void:
	var blocked: Array = view.get("map", {}).get("blocked_edge_ids", [])
	for edge: Dictionary in map_data.get("edges", []):
		var from := room_rect(edge.a).get_center()
		var to := room_rect(edge.b).get_center()
		var is_blocked: bool = edge.id in blocked
		draw_line(from, to, Color(0.015, 0.02, 0.025, 0.94), 14.0 if is_blocked else 10.0, true)
		draw_line(from, to, Color("e5a93c") if is_blocked else Color("8293a1"), 7.0 if is_blocked else 3.0, true)
		if is_blocked:
			var midpoint := from.lerp(to, 0.5)
			draw_circle(midpoint, 9.0, Color("20150a"))
			draw_line(midpoint + Vector2(-6, -6), midpoint + Vector2(6, 6), Color("ffd166"), 3.0, true)
			draw_line(midpoint + Vector2(-6, 6), midpoint + Vector2(6, -6), Color("ffd166"), 3.0, true)


func _draw_room(room: Dictionary) -> void:
	var room_id: String = room.id
	var rect := room_rect(room_id)
	var fill: Color = REGION_COLORS.get(room.region, Color("3c4650"))
	fill.a = 0.66
	if not highlighted_room_ids.is_empty() and room_id not in highlighted_room_ids:
		fill = fill.darkened(0.55)
		fill.a = 0.62
	draw_rect(rect, Color(0.01, 0.015, 0.02, 0.82), true)
	draw_rect(rect.grow(-3), fill, true)
	var border := Color("ffd166") if room_id in highlighted_room_ids else Color(0.72, 0.78, 0.82, 0.92)
	draw_rect(rect, border, false, 4.0 if room_id in highlighted_room_ids else 2.0)
	if room_id in preview_path:
		draw_rect(rect.grow(-7), Color("65d6ff"), false, 3.0)
	_draw_room_label(room, rect)
	_draw_feature_badges(room, rect)
	_draw_room_markers(room_id, rect)


func _draw_room_label(room: Dictionary, rect: Rect2) -> void:
	var font := ThemeDB.fallback_font
	var label_rect := Rect2(rect.position + Vector2(4, 4), Vector2(rect.size.x - 8, 25))
	draw_rect(label_rect, Color(0.015, 0.02, 0.025, 0.86), true)
	draw_string(font, label_rect.position + Vector2(7, 18), str(room.id), HORIZONTAL_ALIGNMENT_LEFT, 28, 14, Color("ffd166"))
	draw_string(font, label_rect.position + Vector2(37, 18), str(room.get("name_zh", "")), HORIZONTAL_ALIGNMENT_LEFT, label_rect.size.x - 42, 14, Color.WHITE)


func _draw_feature_badges(room: Dictionary, rect: Rect2) -> void:
	var badges: Array[String] = []
	for feature_value: Variant in room.get("features", []):
		var feature := str(feature_value)
		if FEATURE_LABELS.has(feature):
			badges.append(FEATURE_LABELS[feature])
	if badges.is_empty():
		return
	var font := ThemeDB.fallback_font
	var text := " · ".join(badges)
	draw_string(font, rect.position + Vector2(8, 45), text, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("dce6ee"))


func _draw_room_markers(room_id: String, rect: Rect2) -> void:
	var marker_x := rect.position.x + 15.0
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
