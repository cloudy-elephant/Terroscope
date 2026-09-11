class_name MatchHost
extends RefCounted

const MapGraphScript = preload("res://core/map_graph.gd")
const GameStateScript = preload("res://core/game_state.gd")
const RuleEngineScript = preload("res://core/rule_engine.gd")

const MAP_PATH := "res://content/maps/laboratory.json"
const ITEM_PATH := "res://content/items/mvp_items.json"
const KILLER_PATH := "res://content/killers/butcher.json"

var map_graph
var state
var rule_engine
var event_log: Array = []
var phase_snapshots: Array = []


func start_match(seed_value: int) -> Dictionary:
	map_graph = MapGraphScript.new()
	if not map_graph.load_from_file(MAP_PATH):
		return {"ok":false,"message":map_graph.load_error}
	var item_content := _read_json(ITEM_PATH)
	var killer_content := _read_json(KILLER_PATH)
	if item_content.is_empty() or killer_content.is_empty():
		return {"ok":false,"message":"Unable to load content data"}
	state = GameStateScript.new()
	state.initialize(seed_value, map_graph, item_content, killer_content)
	rule_engine = RuleEngineScript.new(map_graph)
	var initial_events = rule_engine.bootstrap(state)
	event_log.append_array(initial_events)
	_capture_phase_snapshots(initial_events)
	return {"ok":true,"events":initial_events}


func submit(command: Dictionary) -> Dictionary:
	var result = rule_engine.submit(state, command)
	if result.accepted:
		event_log.append_array(result.events)
		_capture_phase_snapshots(result.events)
	return result


func _capture_phase_snapshots(events: Array) -> void:
	var last_phase_event: Dictionary = {}
	for event: Dictionary in events:
		if event.type == "PhaseChanged":
			last_phase_event = event
	if not last_phase_event.is_empty():
		phase_snapshots.append({
			"event_sequence": last_phase_event.event_sequence,
			"phase": state.data.phase,
			"state": state.snapshot(),
		})


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}
