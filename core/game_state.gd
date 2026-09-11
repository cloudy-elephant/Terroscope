class_name GameState
extends RefCounted

const SeededRngScript = preload("res://core/seeded_rng.gd")

const RULES_VERSION := "0.1.0"
const CONTENT_VERSION := "0.3.0"
const SCHEMA_VERSION := "0.3.0"

var data: Dictionary


func _init(initial_data: Dictionary = {}) -> void:
	data = initial_data.duplicate(true)


func initialize(
		seed_value: int,
		map_graph,
		item_content: Dictionary,
		killer_content: Dictionary
) -> void:
	var rng := SeededRngScript.new(seed_value)
	var item_definitions: Dictionary = {}
	for definition: Dictionary in item_content.get("definitions", []):
		item_definitions[definition.get("id", "")] = definition.duplicate(true)
	var item_instances: Dictionary = {}
	var discover_deck := _build_instances("discover", item_content.get("discover", []), item_instances)
	discover_deck = rng.shuffled(discover_deck)

	var search_all := _build_instances("search", item_content.get("search", []), item_instances)
	var fixed_search_bottom := ""
	for instance_id: String in search_all:
		if item_instances[instance_id] == "key":
			fixed_search_bottom = instance_id
			break
	search_all.erase(fixed_search_bottom)
	var search_deck: Array = rng.shuffled(search_all)
	search_deck.append(fixed_search_bottom)

	var starting_items := _build_instances("starting", item_content.get("starting", []), item_instances)
	var killer_instances: Dictionary = {}
	var killer_definitions: Dictionary = {}
	for definition: Dictionary in killer_content.get("definitions", []):
		killer_definitions[definition.get("id", "")] = definition.duplicate(true)
	var killer_deck := _build_instances("killer", killer_content.get("deck", []), killer_instances)
	killer_deck = rng.shuffled(killer_deck)
	var killer_hand: Array = []
	for draw_index in range(int(killer_content.get("starting_hand_size", 2))):
		killer_hand.append(killer_deck.pop_front())
	var locked_cards := _build_instances("killer_locked", killer_content.get("locked", []), killer_instances)
	var unlocked_skill_ids: Array = []
	for instance_id: String in killer_deck + killer_hand:
		var definition_id: String = killer_instances[instance_id]
		if definition_id not in unlocked_skill_ids:
			unlocked_skill_ids.append(definition_id)
	unlocked_skill_ids.sort()

	var blocked_edges: Array = map_graph.data.get("initial_blocked_edges", []).duplicate()
	var survivor_start: String = map_graph.data.get("survivor_start_room_id", "G1")
	var killer_start: String = map_graph.data.get("killer_start_room_id", "R1")
	var initial := {
		"match_id": "local-%s" % seed_value,
		"seed": seed_value,
		"rng_state": rng.snapshot(),
		"rules_version": RULES_VERSION,
		"content_version": CONTENT_VERSION,
		"map_version": map_graph.data.get("version", ""),
		"schema_version": SCHEMA_VERSION,
		"command_sequence": 0,
		"event_sequence": 0,
		"round_index": 1,
		"phase": "SETUP",
		"return_phase": "",
		"active_actor_id": "",
		"acted_survivor_ids": [],
		"players": [
			{"player_id":"player_survivors","side":"survivors","connection_state":"connected"},
			{"player_id":"player_killer","side":"killer","connection_state":"connected"},
		],
		"map": {
			"map_id": map_graph.data.get("id", "laboratory"),
			"room_ids": map_graph.rooms_by_id.keys(),
			"edge_ids": map_graph.edges_by_id.keys(),
			"blocked_edge_ids": blocked_edges,
			"block_supply_remaining": int(map_graph.data.get("block_supply_total", 7)) - blocked_edges.size(),
			"trap_room_id": "",
			"first_aid_cabinet_available": true,
		},
		"survivors": [
			{"id":"marco_carven","controller_player_id":"player_survivors","room_id":survivor_start,"health":"healthy","fear":0,"inventory_instance_ids":[starting_items[0]],"ability_state":{},"main_action_completed":false},
			{"id":"william_hooper","controller_player_id":"player_survivors","room_id":survivor_start,"health":"healthy","fear":0,"inventory_instance_ids":[],"ability_state":{},"main_action_completed":false},
			{"id":"anna_kubrick","controller_player_id":"player_survivors","room_id":survivor_start,"health":"healthy","fear":0,"inventory_instance_ids":[],"ability_state":{},"main_action_completed":false},
		],
		"killer": {
			"id": killer_content.get("id", "butcher"),
			"controller_player_id": "player_killer",
			"room_id": killer_start,
			"is_stealthed": false,
			"level": int(killer_content.get("start_level", 1)),
			"base_strength": int(killer_content.get("start_strength", 5)),
			"effective_strength": int(killer_content.get("start_strength", 5)),
			"temporary_modifiers": [],
			"hand": killer_hand,
			"deck": killer_deck,
			"discard": [],
			"locked_cards": locked_cards,
			"unlocked_skill_ids": unlocked_skill_ids,
			"definitions": killer_definitions,
			"main_actions_remaining": 0,
			"main_action_mode": "",
			"encounter_started_this_turn": false,
			"draw_per_turn": int(killer_content.get("draw_per_turn", 3)),
			"hand_limit": int(killer_content.get("hand_limit", 5)),
			"max_level": int(killer_content.get("max_level", 5)),
			"pending_draw_count": 0,
			"pending_unlock_discard": {},
			"skill_instances": killer_instances,
		},
		"items": {
			"inventory_limit": int(item_content.get("inventory_limit", 3)),
			"definitions": item_definitions,
			"item_instances": item_instances,
			"discover_deck": discover_deck,
			"search_deck": search_deck,
			"discard": [],
			"team_key_instance_ids": [],
			"pending_private_draw": {},
		},
		"objectives": {"radio_progress":0,"repair_increased_this_round":false,"rescue_countdown":-1},
		"noises_this_round": [],
		"noises_last_round": [],
		"revealed_noise_room_ids": [],
		"firecracker_active": false,
		"encounter": {},
		"processed_commands": {},
		"winner": "",
		"end_reason": "",
	}
	data = initial


static func _build_instances(prefix: String, definitions: Array, index: Dictionary) -> Array:
	var result: Array = []
	for definition: Dictionary in definitions:
		var definition_id: String = definition.get("id", "")
		var count: int = int(definition.get("count", 0))
		for copy_index in range(1, count + 1):
			var instance_id := "%s.%s.%02d" % [prefix, definition_id, copy_index]
			result.append(instance_id)
			index[instance_id] = definition_id
	return result


func snapshot() -> Dictionary:
	return data.duplicate(true)


func canonical_json() -> String:
	return JSON.stringify(data, "", true, true)
