class_name RuleEngine
extends RefCounted

const SeededRngScript = preload("res://core/seeded_rng.gd")
const DomainEventScript = preload("res://core/domain_event.gd")
const PhaseMachineScript = preload("res://core/phase_machine.gd")
const MapGraphScript = preload("res://core/map_graph.gd")

const REJECTION_CODES := [
	"STALE_STATE", "WRONG_PHASE", "NOT_CONTROLLER", "NOT_ACTIVE_ACTOR",
	"RESOURCE_MISSING", "TARGET_REQUIRED", "TARGET_ILLEGAL", "PATH_ILLEGAL",
	"CAPACITY_RESULT_INVALID", "PREREQUISITE_MISSING", "MATCH_ENDED",
]

var map_graph
var phase_machine = PhaseMachineScript.new()


func _init(graph) -> void:
	map_graph = graph


func bootstrap(state) -> Array:
	var events: Array = [DomainEventScript.make("MatchCreated", {"match_id":state.data.match_id,"seed":state.data.seed})]
	_transition(state.data, "SURVIVOR_START", events)
	_transition(state.data, "SURVIVOR_CHOOSE_ACTOR", events)
	return _stamp_events(state.data, events)


func submit(state, command: Dictionary) -> Dictionary:
	var command_id: String = command.get("command_id", "")
	if command_id.is_empty():
		return _rejected("TARGET_REQUIRED", "command_id is required")
	if state.data.processed_commands.has(command_id):
		return state.data.processed_commands[command_id].duplicate(true)
	if state.data.phase == "GAME_OVER":
		return _rejected("MATCH_ENDED", "The match has ended")
	if int(command.get("expected_command_sequence", -1)) != int(state.data.command_sequence):
		return _rejected("STALE_STATE", "Expected command sequence does not match host state")
	var command_type: String = command.get("type", "")
	if not phase_machine.allows(state.data.phase, command_type):
		return _rejected("WRONG_PHASE", "%s is not allowed during %s" % [command_type, state.data.phase])

	var draft: Dictionary = state.snapshot()
	var rng = SeededRngScript.new(1)
	rng.restore(int(draft.rng_state))
	var events: Array = []
	var validation := _apply_command(draft, command, rng, events)
	if not validation.ok:
		return _rejected(validation.code, validation.message)

	draft.rng_state = rng.snapshot()
	draft.command_sequence += 1
	events.push_front(DomainEventScript.make("CommandAccepted", {"command_id":command_id,"command_sequence":draft.command_sequence}))
	var stamped_events := _stamp_events(draft, events)
	var result := {
		"accepted": true,
		"command_id": command_id,
		"command_sequence": draft.command_sequence,
		"events": stamped_events,
	}
	draft.processed_commands[command_id] = result.duplicate(true)
	state.data = draft
	return result


func _apply_command(draft: Dictionary, command: Dictionary, rng, events: Array) -> Dictionary:
	var type: String = command.type
	var payload: Dictionary = command.get("payload", {})
	match type:
		"BeginSurvivorActivation":
			return _begin_survivor_activation(draft, command.player_id, payload, events)
		"MoveSurvivor":
			return _move_survivor(draft, command.player_id, payload, events)
		"Calm":
			return _calm(draft, command.player_id, payload, events)
		"RemoveBlock":
			return _remove_block(draft, command.player_id, payload, events)
		"RepairRadio":
			return _repair_radio(draft, command.player_id, payload, events)
		"BeginSearch":
			return _begin_search(draft, command.player_id, payload, events)
		"ResolveSearchItem":
			return _resolve_search_item(draft, command.player_id, payload, events)
		"UseSpecialAction":
			return _use_special_action(draft, command.player_id, payload, events)
		"EndActivation":
			return _end_activation(draft, command.player_id, payload, events)
		"ChooseDiscoverer":
			return _choose_discoverer(draft, command.player_id, payload, rng, events)
		"ResolveDiscover":
			return _resolve_discover(draft, command.player_id, payload, events)
		"EndKillerFast":
			return _end_killer_fast(draft, command.player_id, events)
		"KillerMove":
			return _killer_move(draft, command.player_id, payload, events)
		"EndKillerSlow":
			return _end_killer_slow(draft, command.player_id, events)
	return _invalid("WRONG_PHASE", "Command is not implemented")


func _begin_survivor_activation(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var survivor := _survivor_by_id(draft, payload.get("survivor_id", ""))
	if survivor.is_empty():
		return _invalid("TARGET_ILLEGAL", "Unknown survivor")
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control this survivor")
	if survivor.id in draft.acted_survivor_ids:
		return _invalid("TARGET_ILLEGAL", "Survivor has already acted this round")
	draft.active_actor_id = survivor.id
	_transition(draft, "SURVIVOR_ACTIVATION", events)
	return _valid()


func _move_survivor(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var path_value: Variant = payload.get("path_room_ids", payload.get("path", []))
	if not path_value is Array:
		return _invalid("PATH_ILLEGAL", "Movement path must be an array")
	var path: Array = path_value
	if path.size() < 1 or path.size() > 2:
		return _invalid("PATH_ILLEGAL", "Normal survivor movement requires one or two steps")
	var survivor: Dictionary = check.survivor
	var path_check: Dictionary = map_graph.validate_path(survivor.room_id, path, draft.map.blocked_edge_ids)
	if not path_check.ok:
		return _invalid("PATH_ILLEGAL", path_check.reason)
	for next_value: Variant in path:
		var source_room_id: String = survivor.room_id
		var target_room_id := str(next_value)
		survivor.room_id = target_room_id
		events.append(DomainEventScript.make("ActorMoved", {"actor_id":survivor.id,"from":source_room_id,"to":target_room_id}, "survivors"))
		if target_room_id == "R4":
			_record_noise(draft, target_room_id, "sterile_room_entry", false, events)
	survivor.main_action_completed = true
	return _valid()


func _calm(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var survivor: Dictionary = check.survivor
	var old_fear: int = survivor.fear
	survivor.fear = 0
	survivor.main_action_completed = true
	if old_fear != 0:
		events.append(DomainEventScript.make("FearChanged", {"survivor_id":survivor.id,"from":old_fear,"to":0}, "survivors"))
	return _valid()


func _remove_block(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", draft.active_actor_id))
	if not check.ok:
		return check
	var edge_id: String = payload.get("edge_id", "")
	if not map_graph.edges_by_id.has(edge_id):
		return _invalid("TARGET_ILLEGAL", "Unknown map edge")
	var survivor: Dictionary = check.survivor
	var edge: Dictionary = map_graph.edges_by_id[edge_id]
	if survivor.room_id != edge.a and survivor.room_id != edge.b:
		return _invalid("TARGET_ILLEGAL", "Block must be adjacent to the active survivor")
	if edge_id not in draft.map.blocked_edge_ids:
		return _invalid("RESOURCE_MISSING", "Selected edge is not blocked")
	draft.map.blocked_edge_ids.erase(edge_id)
	draft.map.block_supply_remaining += 1
	survivor.main_action_completed = true
	events.append(DomainEventScript.make("BlockRemoved", {"edge_id":edge_id,"actor_id":survivor.id}))
	return _valid()


func _repair_radio(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var survivor: Dictionary = check.survivor
	if survivor.room_id != "B4":
		return _invalid("TARGET_ILLEGAL", "Radio repairs are only available in B4")
	if draft.killer.room_id == survivor.room_id:
		return _invalid("PREREQUISITE_MISSING", "Cannot repair while sharing a room with the killer")
	if draft.objectives.repair_increased_this_round:
		return _invalid("PREREQUISITE_MISSING", "Radio progress may increase only once per round")
	if draft.objectives.radio_progress >= 5:
		return _invalid("PREREQUISITE_MISSING", "The rescue signal is already complete")
	var previous_progress: int = draft.objectives.radio_progress
	draft.objectives.radio_progress += 1
	draft.objectives.repair_increased_this_round = true
	survivor.main_action_completed = true
	events.append(DomainEventScript.make("RepairAdded", {"survivor_id":survivor.id,"from":previous_progress,"to":draft.objectives.radio_progress}, "survivors"))
	_record_noise(draft, "B4", "radio_repair", false, events)
	if draft.objectives.radio_progress >= 5:
		draft.objectives.rescue_countdown = 5
		events.append(DomainEventScript.make("RescueAdvanced", {"from":-1,"to":5,"started":true}))
	return _valid()


func _begin_search(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var survivor: Dictionary = check.survivor
	if not _room_has_feature(survivor.room_id, "search"):
		return _invalid("TARGET_ILLEGAL", "Current room is not a search location")
	if draft.killer.room_id == survivor.room_id:
		return _invalid("PREREQUISITE_MISSING", "Cannot search while sharing a room with the killer")
	if draft.items.search_deck.is_empty():
		return _invalid("RESOURCE_MISSING", "Search deck is empty")
	var card_instance_id: String = draft.items.search_deck.pop_front()
	draft.items.pending_private_draw = {"source":"search","survivor_id":survivor.id,"card_instance_ids":[card_instance_id]}
	survivor.main_action_completed = true
	if survivor.id != "anna_kubrick":
		_record_noise(draft, survivor.room_id, "search_action", false, events)
	_record_draw_noise(draft, survivor, [card_instance_id], events)
	events.append(DomainEventScript.make("ItemDrawn", {"source":"search","survivor_id":survivor.id,"card_instance_ids":[card_instance_id]}, "survivors"))
	_transition(draft, "SURVIVOR_SEARCH_RESOLVE", events)
	return _valid()


func _resolve_search_item(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var pending: Dictionary = draft.items.pending_private_draw
	if pending.is_empty() or pending.get("source", "") != "search":
		return _invalid("PREREQUISITE_MISSING", "No search draw is waiting for resolution")
	var survivor := _survivor_by_id(draft, pending.survivor_id)
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the searching survivor")
	var card_instance_id: String = pending.card_instance_ids[0]
	var take_card: bool = bool(payload.get("take", false))
	if take_card:
		var acquisition := _plan_acquisition(draft, survivor, card_instance_id, payload)
		if not acquisition.ok:
			return acquisition
		_apply_acquisition(draft, survivor, card_instance_id, acquisition, events)
	else:
		draft.items.discard.append(card_instance_id)
		events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":card_instance_id,"reason":"search_choice"}, "survivors"))
	draft.items.pending_private_draw = {}
	_transition(draft, "SURVIVOR_ACTIVATION", events)
	return _valid()


func _use_special_action(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	if payload.get("source_id", "") != "g3_first_aid_cabinet":
		return _invalid("TARGET_ILLEGAL", "Unknown Milestone 1 special action")
	var actor: Dictionary = check.survivor
	if actor.room_id != "G3" or not draft.map.first_aid_cabinet_available:
		return _invalid("PREREQUISITE_MISSING", "The G3 first aid cabinet is not available here")
	var target := _survivor_by_id(draft, payload.get("target_survivor_id", ""))
	if target.is_empty() or target.room_id != "G3" or target.health != "injured":
		return _invalid("TARGET_ILLEGAL", "First aid target must be an injured survivor in G3")
	var old_fear: int = target.fear
	target.health = "healthy"
	target.fear = 0
	draft.map.first_aid_cabinet_available = false
	actor.main_action_completed = true
	events.append(DomainEventScript.make("HealthChanged", {"survivor_id":target.id,"from":"injured","to":"healthy"}))
	if old_fear > 0:
		events.append(DomainEventScript.make("FearChanged", {"survivor_id":target.id,"from":old_fear,"to":0}, "survivors"))
	return _valid()


func _end_activation(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _active_survivor(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var survivor: Dictionary = check.survivor
	if not survivor.main_action_completed:
		return _invalid("PREREQUISITE_MISSING", "A survivor must complete one main action")
	draft.acted_survivor_ids.append(survivor.id)
	draft.active_actor_id = ""
	if draft.acted_survivor_ids.size() == draft.survivors.size():
		_enter_discover_or_finish(draft, events)
	else:
		_transition(draft, "SURVIVOR_CHOOSE_ACTOR", events)
	return _valid()


func _choose_discoverer(draft: Dictionary, player_id: String, payload: Dictionary, _rng, events: Array) -> Dictionary:
	var survivor := _survivor_by_id(draft, payload.get("survivor_id", ""))
	if survivor.is_empty():
		return _invalid("TARGET_ILLEGAL", "Unknown discoverer")
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control this survivor")
	var deck: Array = draft.items.discover_deck
	if deck.is_empty():
		return _invalid("RESOURCE_MISSING", "Discover deck is empty")
	var draw_count: int = mini(2, deck.size())
	var drawn: Array = []
	for draw_index in range(draw_count):
		drawn.append(deck.pop_front())
	draft.items.pending_private_draw = {"source":"discover","survivor_id":survivor.id,"card_instance_ids":drawn}
	_record_draw_noise(draft, survivor, drawn, events)
	events.append(DomainEventScript.make("ItemDrawn", {"source":"discover","survivor_id":survivor.id,"card_instance_ids":drawn}, "survivors"))
	_transition(draft, "SURVIVOR_DISCOVER_RESOLVE", events)
	return _valid()


func _resolve_discover(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var pending: Dictionary = draft.items.pending_private_draw
	if pending.is_empty() or pending.get("source", "") != "discover":
		return _invalid("PREREQUISITE_MISSING", "No discover draw is waiting for resolution")
	var survivor := _survivor_by_id(draft, pending.survivor_id)
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the discoverer")
	var drawn: Array = pending.card_instance_ids
	var kept_id: String = payload.get("keep_card_instance_id", "")
	if drawn.size() == 1:
		kept_id = drawn[0]
	if kept_id not in drawn:
		return _invalid("TARGET_ILLEGAL", "Kept card must be one of the drawn cards")
	var acquisition := _plan_acquisition(draft, survivor, kept_id, payload)
	if not acquisition.ok:
		return acquisition
	for card_id: String in drawn:
		if card_id != kept_id:
			draft.items.discard.append(card_id)
			events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":card_id,"reason":"discover_choice"}, "survivors"))
	_apply_acquisition(draft, survivor, kept_id, acquisition, events)
	draft.items.pending_private_draw = {}
	_finish_survivor_turn(draft, events)
	return _valid()


func _end_killer_fast(draft: Dictionary, player_id: String, events: Array) -> Dictionary:
	if draft.killer.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the killer")
	draft.killer.main_actions_remaining = 2
	_transition(draft, "KILLER_MAIN", events)
	return _valid()


func _killer_move(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	if draft.killer.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the killer")
	var target_room_id: String = payload.get("target_room_id", "")
	var source_room_id: String = draft.killer.room_id
	if not map_graph.is_adjacent(source_room_id, target_room_id):
		return _invalid("PATH_ILLEGAL", "Killer move target must be adjacent")
	var edge_id := MapGraphScript.edge_id_for(source_room_id, target_room_id)
	if edge_id in draft.map.blocked_edge_ids:
		draft.map.blocked_edge_ids.erase(edge_id)
		draft.map.block_supply_remaining += 1
		events.append(DomainEventScript.make("BlockRemoved", {"edge_id":edge_id}))
	draft.killer.room_id = target_room_id
	draft.killer.main_actions_remaining -= 1
	events.append(DomainEventScript.make("ActorMoved", {"actor_id":draft.killer.id,"from":source_room_id,"to":target_room_id}))
	if draft.killer.main_actions_remaining <= 0:
		_transition(draft, "KILLER_SLOW", events)
	return _valid()


func _end_killer_slow(draft: Dictionary, player_id: String, events: Array) -> Dictionary:
	if draft.killer.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the killer")
	_transition(draft, "KILLER_DRAW", events)
	var draw_count: int = int(draft.killer.draw_per_turn)
	for draw_index in range(draw_count):
		if draft.killer.deck.is_empty():
			break
		var card_id: String = draft.killer.deck.pop_front()
		if draft.killer.hand.size() < 5:
			draft.killer.hand.append(card_id)
		else:
			draft.killer.discard.append(card_id)
	_begin_next_survivor_round(draft, events)
	return _valid()


func _main_action_check(draft: Dictionary, player_id: String, actor_id: String) -> Dictionary:
	var check := _active_survivor(draft, player_id, actor_id)
	if not check.ok:
		return check
	if check.survivor.main_action_completed:
		return _invalid("PREREQUISITE_MISSING", "The active survivor already completed a main action")
	return check


func _room_has_feature(room_id: String, feature: String) -> bool:
	if not map_graph.rooms_by_id.has(room_id):
		return false
	return feature in map_graph.rooms_by_id[room_id].get("features", [])


func _plan_acquisition(draft: Dictionary, survivor: Dictionary, card_instance_id: String, payload: Dictionary) -> Dictionary:
	if not draft.items.item_instances.has(card_instance_id):
		return _invalid("TARGET_ILLEGAL", "Unknown item instance")
	var definition_id: String = draft.items.item_instances[card_instance_id]
	if definition_id == "key":
		return {"ok":true,"kind":"key","kept_ids":[],"discarded_ids":[]}
	var candidates: Array = survivor.inventory_instance_ids.duplicate()
	candidates.append(card_instance_id)
	var inventory_limit: int = int(draft.items.inventory_limit)
	var keep_value: Variant = payload.get("keep_inventory_instance_ids", null)
	var kept_ids: Array = []
	if keep_value == null and candidates.size() <= inventory_limit:
		kept_ids = candidates.duplicate()
	elif keep_value is Array:
		kept_ids = keep_value.duplicate()
	else:
		return _invalid("CAPACITY_RESULT_INVALID", "Final inventory selection is required")
	if kept_ids.size() != mini(inventory_limit, candidates.size()):
		return _invalid("CAPACITY_RESULT_INVALID", "Final inventory must retain exactly the allowed number of items")
	var seen: Dictionary = {}
	for item_value: Variant in kept_ids:
		var item_id := str(item_value)
		if item_id not in candidates or seen.has(item_id):
			return _invalid("CAPACITY_RESULT_INVALID", "Final inventory contains an invalid or duplicate item")
		seen[item_id] = true
	var discarded_ids: Array = []
	for candidate_id: String in candidates:
		if candidate_id not in kept_ids:
			discarded_ids.append(candidate_id)
	return {"ok":true,"kind":"inventory","kept_ids":kept_ids,"discarded_ids":discarded_ids}


func _apply_acquisition(draft: Dictionary, survivor: Dictionary, card_instance_id: String, acquisition: Dictionary, events: Array) -> void:
	if acquisition.kind == "key":
		draft.items.team_key_instance_ids.append(card_instance_id)
		events.append(DomainEventScript.make("KeyAdded", {"card_instance_id":card_instance_id,"total":draft.items.team_key_instance_ids.size()}))
		return
	survivor.inventory_instance_ids = acquisition.kept_ids.duplicate()
	if card_instance_id in survivor.inventory_instance_ids:
		events.append(DomainEventScript.make("ItemAcquired", {"survivor_id":survivor.id,"card_instance_id":card_instance_id}, "survivors"))
	for discarded_id: String in acquisition.discarded_ids:
		draft.items.discard.append(discarded_id)
		events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":discarded_id,"reason":"inventory_capacity"}, "survivors"))


func _record_draw_noise(draft: Dictionary, survivor: Dictionary, card_instance_ids: Array, events: Array) -> void:
	for card_instance_id: String in card_instance_ids:
		var definition_id: String = draft.items.item_instances.get(card_instance_id, "")
		var definition: Dictionary = draft.items.definitions.get(definition_id, {})
		if definition.get("draw_noise", false):
			_record_noise(draft, survivor.room_id, "item_draw:%s" % definition_id, false, events)


func _record_noise(draft: Dictionary, room_id: String, source: String, immediate: bool, events: Array) -> void:
	var record := {"room_id":room_id,"source":source,"immediate":immediate}
	draft.noises_this_round.append(record)
	events.append(DomainEventScript.make("NoiseRecorded", record, "survivors"))
	if immediate:
		events.append(DomainEventScript.make("NoiseRevealed", {"room_ids":[room_id],"immediate":true}))


func _enter_discover_or_finish(draft: Dictionary, events: Array) -> void:
	if not draft.items.discover_deck.is_empty():
		_transition(draft, "SURVIVOR_DISCOVER_SELECT", events)
		return
	if draft.objectives.rescue_countdown < 0:
		_end_match(draft, "killer", "discover_deck_empty", events)
		return
	_finish_survivor_turn(draft, events)


func _finish_survivor_turn(draft: Dictionary, events: Array) -> void:
	_transition(draft, "SURVIVOR_REVEAL_NOISE", events)
	var room_ids: Array = []
	for record: Dictionary in draft.noises_this_round:
		if record.room_id not in room_ids:
			room_ids.append(record.room_id)
	room_ids.sort()
	draft.revealed_noise_room_ids = room_ids.duplicate()
	if draft.firecracker_active:
		events.append(DomainEventScript.make("NoiseRevealed", {"firecracker_active":true,"immediate":false}))
	else:
		events.append(DomainEventScript.make("NoiseRevealed", {"room_ids":room_ids,"immediate":false}))
	draft.noises_this_round.clear()
	_transition(draft, "KILLER_REAPPEAR", events)
	_transition(draft, "KILLER_FAST", events)


func _begin_next_survivor_round(draft: Dictionary, events: Array) -> void:
	draft.round_index += 1
	_transition(draft, "SURVIVOR_START", events)
	draft.noises_last_round = draft.revealed_noise_room_ids.duplicate()
	draft.revealed_noise_room_ids.clear()
	draft.noises_this_round.clear()
	if draft.objectives.rescue_countdown >= 0:
		var previous_countdown: int = draft.objectives.rescue_countdown
		draft.objectives.rescue_countdown -= 1
		events.append(DomainEventScript.make("RescueAdvanced", {"from":previous_countdown,"to":draft.objectives.rescue_countdown}))
		if draft.objectives.rescue_countdown <= 0:
			_end_match(draft, "survivors", "rescue_arrived", events)
			return
	if draft.items.team_key_instance_ids.size() >= 5 and _all_survivors_in_room(draft, "G1"):
		_end_match(draft, "survivors", "main_exit_unlocked", events)
		return
	draft.acted_survivor_ids.clear()
	draft.active_actor_id = ""
	for survivor: Dictionary in draft.survivors:
		survivor.main_action_completed = false
	draft.objectives.repair_increased_this_round = false
	draft.firecracker_active = false
	_transition(draft, "SURVIVOR_CHOOSE_ACTOR", events)


func _all_survivors_in_room(draft: Dictionary, room_id: String) -> bool:
	for survivor: Dictionary in draft.survivors:
		if survivor.room_id != room_id or survivor.health == "eliminated":
			return false
	return true


func _end_match(draft: Dictionary, winner: String, reason: String, events: Array) -> void:
	draft.winner = winner
	draft.end_reason = reason
	_transition(draft, "GAME_OVER", events)
	events.append(DomainEventScript.make("MatchEnded", {"winner":winner,"reason":reason}))


func _active_survivor(draft: Dictionary, player_id: String, actor_id: String) -> Dictionary:
	if actor_id != draft.active_actor_id:
		return _invalid("NOT_ACTIVE_ACTOR", "Command actor is not the active survivor")
	var survivor := _survivor_by_id(draft, actor_id)
	if survivor.is_empty() or survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the active survivor")
	return {"ok":true,"survivor":survivor}


func _survivor_by_id(draft: Dictionary, survivor_id: String) -> Dictionary:
	for survivor: Dictionary in draft.survivors:
		if survivor.id == survivor_id:
			return survivor
	return {}


func _transition(draft: Dictionary, next_phase: String, events: Array) -> void:
	var previous_phase: String = draft.phase
	draft.phase = next_phase
	events.append(DomainEventScript.make("PhaseChanged", {"from":previous_phase,"to":next_phase}))


func _stamp_events(draft: Dictionary, events: Array) -> Array:
	var result: Array = []
	for event: Dictionary in events:
		draft.event_sequence += 1
		var stamped := event.duplicate(true)
		stamped.event_sequence = draft.event_sequence
		result.append(stamped)
	return result


func _valid() -> Dictionary:
	return {"ok":true}


func _invalid(code: String, message: String) -> Dictionary:
	assert(code in REJECTION_CODES)
	return {"ok":false,"code":code,"message":message}


func _rejected(code: String, message: String) -> Dictionary:
	return {"accepted":false,"code":code,"message":message,"events":[DomainEventScript.make("CommandRejected", {"code":code,"message":message})]}
