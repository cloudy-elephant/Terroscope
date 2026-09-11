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
		"Calm":
			return _calm(draft, command.player_id, payload, events)
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
	return _invalid("WRONG_PHASE", "Command is not implemented in Milestone 0")


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


func _calm(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _active_survivor(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var survivor: Dictionary = check.survivor
	var old_fear: int = survivor.fear
	survivor.fear = 0
	survivor.main_action_completed = true
	if old_fear != 0:
		events.append(DomainEventScript.make("FearChanged", {"survivor_id":survivor.id,"from":old_fear,"to":0}, "survivors"))
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
		_transition(draft, "SURVIVOR_DISCOVER_SELECT", events)
	else:
		_transition(draft, "SURVIVOR_CHOOSE_ACTOR", events)
	return _valid()


func _choose_discoverer(draft: Dictionary, player_id: String, payload: Dictionary, rng, events: Array) -> Dictionary:
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
	var definition_id: String = draft.items.item_instances[kept_id]
	if definition_id == "key":
		draft.items.team_key_instance_ids.append(kept_id)
		events.append(DomainEventScript.make("KeyAdded", {"card_instance_id":kept_id,"total":draft.items.team_key_instance_ids.size()}))
	else:
		survivor.inventory_instance_ids.append(kept_id)
		events.append(DomainEventScript.make("ItemAcquired", {"survivor_id":survivor.id,"card_instance_id":kept_id}, "survivors"))
	for card_id: String in drawn:
		if card_id != kept_id:
			draft.items.discard.append(card_id)
			events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":card_id}, "survivors"))
	draft.items.pending_private_draw = {}
	_transition(draft, "SURVIVOR_REVEAL_NOISE", events)
	draft.noises_last_round = draft.noises_this_round.duplicate(true)
	draft.noises_this_round.clear()
	_transition(draft, "KILLER_REAPPEAR", events)
	_transition(draft, "KILLER_FAST", events)
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
	draft.round_index += 1
	draft.acted_survivor_ids.clear()
	for survivor: Dictionary in draft.survivors:
		survivor.main_action_completed = false
	draft.objectives.repair_increased_this_round = false
	draft.firecracker_active = false
	_transition(draft, "SURVIVOR_START", events)
	_transition(draft, "SURVIVOR_CHOOSE_ACTOR", events)
	return _valid()


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
