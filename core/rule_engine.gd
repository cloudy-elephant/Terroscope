class_name RuleEngine
extends RefCounted

const SeededRngScript = preload("res://core/seeded_rng.gd")
const DomainEventScript = preload("res://core/domain_event.gd")
const PhaseMachineScript = preload("res://core/phase_machine.gd")
const MapGraphScript = preload("res://core/map_graph.gd")
const DEFENSE_DIE_FACES := [0, 0, 1, 1, 1, 3]

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
	draft.stats.commands_accepted = int(draft.stats.get("commands_accepted", 0)) + 1
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
		"UseItem":
			return _use_item(draft, command.player_id, payload, events)
		"ExchangeItems":
			return _exchange_items(draft, command.player_id, payload, events)
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
		"UseKillerSkill":
			return _use_killer_skill(draft, command.player_id, payload, rng, events)
		"KillerMove":
			return _killer_move(draft, command.player_id, payload, events)
		"KillerSearch":
			return _killer_search(draft, command.player_id, events)
		"EndKillerSlow":
			return _end_killer_slow(draft, command.player_id, rng, events)
		"ResolveKillerUnlockOverflow":
			return _resolve_killer_unlock_overflow(draft, command.player_id, payload, rng, events)
		"SelectAttackSkill":
			return _select_attack_skill(draft, command.player_id, payload, events)
		"PassAttackSkill":
			return _pass_attack_skill(draft, command.player_id, events)
		"SelectDefender":
			return _select_defender(draft, command.player_id, payload, events)
		"SelectDefenseItem":
			return _select_defense_items(draft, command.player_id, payload, rng, events)
		"PassDefenseItem":
			return _select_defense_items(draft, command.player_id, {"card_instance_ids":[]}, rng, events)
		"ConfirmFlee":
			return _confirm_flee(draft, command.player_id, payload, rng, events)
		"ResolveDamageResponse":
			return _resolve_damage_response(draft, command.player_id, payload, events)
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
	events.append(DomainEventScript.make("BlockRemoved", {"edge_id":edge_id}))
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
	draft.stats.searches_completed = int(draft.stats.get("searches_completed", 0)) + 1
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


func _use_item(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _active_survivor(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var actor: Dictionary = check.survivor
	var card_instance_id: String = payload.get("card_instance_id", "")
	if card_instance_id not in actor.inventory_instance_ids:
		return _invalid("RESOURCE_MISSING", "Selected item is not in the active survivor inventory")
	var definition_id: String = draft.items.item_instances.get(card_instance_id, "")
	match definition_id:
		"sedatives":
			if int(actor.fear) <= 0:
				return _invalid("PREREQUISITE_MISSING", "Sedatives require at least one fear")
			var old_fear: int = actor.fear
			_consume_item(draft, actor, card_instance_id, "sedatives", events)
			actor.fear = 0
			events.append(DomainEventScript.make("FearChanged", {"survivor_id":actor.id,"from":old_fear,"to":0}, "survivors"))
		"firecracker":
			if draft.firecracker_active:
				return _invalid("PREREQUISITE_MISSING", "A firecracker is already active this round")
			_consume_item(draft, actor, card_instance_id, "firecracker", events)
			draft.firecracker_active = true
			events.append(DomainEventScript.make("FirecrackerActivated", {"active":true}))
		"hatchet":
			var edge_id: String = payload.get("edge_id", "")
			if edge_id not in draft.map.blocked_edge_ids or not _edge_touches_room(edge_id, actor.room_id):
				return _invalid("TARGET_ILLEGAL", "Hatchet target must be an adjacent blocked door")
			_consume_item(draft, actor, card_instance_id, "hatchet_remove_block", events)
			draft.map.blocked_edge_ids.erase(edge_id)
			draft.map.block_supply_remaining += 1
			events.append(DomainEventScript.make("BlockRemoved", {"edge_id":edge_id,"source":"hatchet"}))
		"whiskey_bottle":
			var target_room_id: String = payload.get("target_room_id", "")
			if not map_graph.is_adjacent(actor.room_id, target_room_id):
				return _invalid("TARGET_ILLEGAL", "Whiskey target must be an adjacent room")
			_consume_item(draft, actor, card_instance_id, "whiskey_bottle", events)
			_record_noise(draft, target_room_id, "whiskey_bottle", false, events)
		"adrenaline":
			var path_value: Variant = payload.get("path_room_ids", [])
			if not path_value is Array:
				return _invalid("PATH_ILLEGAL", "Adrenaline path must be an array")
			var path: Array = path_value
			if path.size() < 1 or path.size() > 4:
				return _invalid("PATH_ILLEGAL", "Adrenaline movement requires one to four steps")
			var path_check: Dictionary = map_graph.validate_path(actor.room_id, path, draft.map.blocked_edge_ids)
			if not path_check.ok:
				return _invalid("PATH_ILLEGAL", path_check.reason)
			_consume_item(draft, actor, card_instance_id, "adrenaline", events)
			for next_value: Variant in path:
				var source_room_id: String = actor.room_id
				var next_room_id := str(next_value)
				actor.room_id = next_room_id
				events.append(DomainEventScript.make("ActorMoved", {"actor_id":actor.id,"from":source_room_id,"to":next_room_id,"source":"adrenaline"}, "survivors"))
				if next_room_id == "R4":
					_record_noise(draft, next_room_id, "sterile_room_entry", false, events)
		_:
			return _invalid("TARGET_ILLEGAL", "Selected item has no extra-action effect")
	draft.stats.items_used = int(draft.stats.get("items_used", 0)) + 1
	return _valid()


func _exchange_items(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _active_survivor(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var actor: Dictionary = check.survivor
	var target := _survivor_by_id(draft, payload.get("target_survivor_id", ""))
	if target.is_empty() or target.id == actor.id or target.health == "eliminated":
		return _invalid("TARGET_ILLEGAL", "Exchange target must be another living survivor")
	if target.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the exchange target")
	if target.room_id != actor.room_id:
		return _invalid("TARGET_ILLEGAL", "Survivors must share a room to exchange items")
	var actor_value: Variant = payload.get("actor_inventory_instance_ids", null)
	var target_value: Variant = payload.get("target_inventory_instance_ids", null)
	if not actor_value is Array or not target_value is Array:
		return _invalid("TARGET_REQUIRED", "Exchange requires both complete final inventories")
	var actor_final: Array = actor_value.duplicate()
	var target_final: Array = target_value.duplicate()
	var limit: int = int(draft.items.inventory_limit)
	if actor_final.size() > limit or target_final.size() > limit:
		return _invalid("CAPACITY_RESULT_INVALID", "Exchange exceeds an inventory limit")
	var available: Array = actor.inventory_instance_ids.duplicate()
	available.append_array(target.inventory_instance_ids)
	var proposed: Array = actor_final.duplicate()
	proposed.append_array(target_final)
	if proposed.size() != available.size():
		return _invalid("CAPACITY_RESULT_INVALID", "Exchange must assign every existing item exactly once")
	var seen: Dictionary = {}
	for value: Variant in proposed:
		var instance_id := str(value)
		if instance_id not in available or seen.has(instance_id):
			return _invalid("CAPACITY_RESULT_INVALID", "Exchange contains an unavailable or duplicate item")
		seen[instance_id] = true
	actor.inventory_instance_ids = actor_final
	target.inventory_instance_ids = target_final
	draft.stats.exchanges_completed = int(draft.stats.get("exchanges_completed", 0)) + 1
	events.append(DomainEventScript.make("ItemsExchanged", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final}, "survivors"))
	return _valid()


func _use_special_action(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var check := _main_action_check(draft, player_id, payload.get("actor_id", ""))
	if not check.ok:
		return check
	var actor: Dictionary = check.survivor
	var source_id: String = payload.get("source_id", "")
	if source_id == "marco_equipped":
		if actor.id != "marco_carven":
			return _invalid("TARGET_ILLEGAL", "Only Marco can use Equipped")
		var card_instance_id: String = payload.get("card_instance_id", "")
		if card_instance_id not in draft.items.discard:
			return _invalid("RESOURCE_MISSING", "Selected item is not in the item discard")
		if draft.items.item_instances.get(card_instance_id, "") not in ["adrenaline", "sedatives"]:
			return _invalid("TARGET_ILLEGAL", "Equipped can recover only adrenaline or sedatives")
		var acquisition := _plan_acquisition(draft, actor, card_instance_id, payload)
		if not acquisition.ok:
			return acquisition
		draft.items.discard.erase(card_instance_id)
		_apply_acquisition(draft, actor, card_instance_id, acquisition, events)
		actor.main_action_completed = true
		events.append(DomainEventScript.make("CharacterAbilityUsed", {"survivor_id":actor.id,"ability_id":"marco_equipped","card_instance_id":card_instance_id}, "survivors"))
		return _valid()
	if source_id == "william_sprint":
		if actor.id != "william_hooper":
			return _invalid("TARGET_ILLEGAL", "Only William can use Sprint")
		var path_value: Variant = payload.get("path_room_ids", [])
		if not path_value is Array:
			return _invalid("PATH_ILLEGAL", "Sprint path must be an array")
		var path: Array = path_value
		if path.size() < 1 or path.size() > 3:
			return _invalid("PATH_ILLEGAL", "Sprint requires one to three steps")
		var path_check: Dictionary = map_graph.validate_path(actor.room_id, path, draft.map.blocked_edge_ids)
		if not path_check.ok:
			return _invalid("PATH_ILLEGAL", path_check.reason)
		for next_value: Variant in path:
			var source_room_id: String = actor.room_id
			var next_room_id := str(next_value)
			actor.room_id = next_room_id
			events.append(DomainEventScript.make("ActorMoved", {"actor_id":actor.id,"from":source_room_id,"to":next_room_id,"source":"william_sprint"}, "survivors"))
			if next_room_id == "R4":
				_record_noise(draft, next_room_id, "sterile_room_entry", false, events)
		_record_noise(draft, actor.room_id, "william_sprint", false, events)
		actor.main_action_completed = true
		events.append(DomainEventScript.make("CharacterAbilityUsed", {"survivor_id":actor.id,"ability_id":"william_sprint"}, "survivors"))
		return _valid()
	if source_id == "toolbox":
		if actor.room_id != "B4" or draft.killer.room_id == actor.room_id:
			return _invalid("PREREQUISITE_MISSING", "Toolbox requires a safe survivor at B4")
		if draft.objectives.repair_increased_this_round or draft.objectives.radio_progress >= 5:
			return _invalid("PREREQUISITE_MISSING", "Radio progress cannot increase now")
		var toolbox_id := _inventory_instance_with_definition(draft, actor, "toolbox")
		if toolbox_id.is_empty():
			return _invalid("RESOURCE_MISSING", "Survivor does not have a toolbox")
		var previous_progress: int = draft.objectives.radio_progress
		_consume_item(draft, actor, toolbox_id, "toolbox", events)
		draft.objectives.radio_progress = mini(5, previous_progress + 2)
		draft.objectives.repair_increased_this_round = true
		actor.main_action_completed = true
		draft.stats.items_used = int(draft.stats.get("items_used", 0)) + 1
		events.append(DomainEventScript.make("RepairAdded", {"survivor_id":actor.id,"from":previous_progress,"to":draft.objectives.radio_progress,"source":"toolbox"}, "survivors"))
		_record_noise(draft, "B4", "toolbox", false, events)
		if draft.objectives.radio_progress >= 5:
			draft.objectives.rescue_countdown = 5
			events.append(DomainEventScript.make("RescueAdvanced", {"from":-1,"to":5,"started":true}))
		return _valid()
	if source_id == "marco_medical_kit":
		if actor.id != "marco_carven":
			return _invalid("TARGET_ILLEGAL", "Only Marco can use his medical kit")
		var medical_kit_id := _inventory_instance_with_definition(draft, actor, "marco_medical_kit")
		if medical_kit_id.is_empty():
			return _invalid("RESOURCE_MISSING", "Marco no longer has his medical kit")
		var medical_target := _survivor_by_id(draft, payload.get("target_survivor_id", ""))
		if medical_target.is_empty() or medical_target.health != "injured":
			return _invalid("TARGET_ILLEGAL", "Medical kit target must be an injured survivor")
		_heal_survivor(draft, medical_target, "marco_medical_kit", events)
		actor.inventory_instance_ids.erase(medical_kit_id)
		draft.items.discard.append(medical_kit_id)
		actor.main_action_completed = true
		draft.stats.items_used = int(draft.stats.get("items_used", 0)) + 1
		events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":medical_kit_id,"reason":"marco_medical_kit"}, "survivors"))
		return _valid()
	if source_id == "trap_parts":
		var trap_parts_id := _inventory_instance_with_definition(draft, actor, "trap_parts")
		if trap_parts_id.is_empty():
			return _invalid("RESOURCE_MISSING", "Survivor does not have trap parts")
		if not draft.map.trap_room_id.is_empty():
			return _invalid("PREREQUISITE_MISSING", "A survivor trap is already on the map")
		actor.inventory_instance_ids.erase(trap_parts_id)
		draft.items.discard.append(trap_parts_id)
		draft.map.trap_room_id = actor.room_id
		actor.main_action_completed = true
		draft.stats.items_used = int(draft.stats.get("items_used", 0)) + 1
		events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":trap_parts_id,"reason":"trap_parts"}, "survivors"))
		events.append(DomainEventScript.make("TrapPlaced", {"room_id":actor.room_id}, "survivors"))
		return _valid()
	if source_id != "g3_first_aid_cabinet":
		return _invalid("TARGET_ILLEGAL", "Unknown special action")
	if actor.room_id != "G3" or not draft.map.first_aid_cabinet_available:
		return _invalid("PREREQUISITE_MISSING", "The G3 first aid cabinet is not available here")
	var target := _survivor_by_id(draft, payload.get("target_survivor_id", ""))
	if target.is_empty() or target.room_id != "G3" or target.health != "injured":
		return _invalid("TARGET_ILLEGAL", "First aid target must be an injured survivor in G3")
	_heal_survivor(draft, target, "g3_first_aid_cabinet", events)
	draft.map.first_aid_cabinet_available = false
	actor.main_action_completed = true
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
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	draft.killer.main_actions_remaining = 2
	draft.killer.main_action_mode = ""
	_transition(draft, "KILLER_MAIN", events)
	return _valid()


func _killer_move(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	if draft.killer.main_action_mode == "skill":
		return _invalid("PREREQUISITE_MISSING", "A main skill already replaced the standard actions")
	var target_room_id: String = payload.get("target_room_id", "")
	var source_room_id: String = draft.killer.room_id
	if not map_graph.is_adjacent(source_room_id, target_room_id):
		return _invalid("PATH_ILLEGAL", "Killer move target must be adjacent")
	draft.killer.main_action_mode = "standard"
	var moved := _move_killer_path(draft, [target_room_id], events)
	if not moved.ok:
		return moved
	draft.killer.main_actions_remaining -= 1
	if draft.killer.main_actions_remaining <= 0:
		_transition(draft, "KILLER_SLOW", events)
	return _valid()


func _killer_search(draft: Dictionary, player_id: String, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	if draft.killer.main_action_mode == "skill":
		return _invalid("PREREQUISITE_MISSING", "A main skill already replaced the standard actions")
	draft.killer.main_action_mode = "standard"
	draft.killer.main_actions_remaining -= 1
	if _perform_killer_search(draft, events):
		draft.killer.main_actions_remaining = 0
		return _valid()
	if draft.killer.main_actions_remaining <= 0:
		_transition(draft, "KILLER_SLOW", events)
	return _valid()


func _use_killer_skill(draft: Dictionary, player_id: String, payload: Dictionary, rng, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	var card_instance_id: String = payload.get("card_instance_id", "")
	if card_instance_id not in draft.killer.hand:
		return _invalid("RESOURCE_MISSING", "Selected skill is not in the killer hand")
	var definition_id: String = draft.killer.skill_instances.get(card_instance_id, "")
	var definition: Dictionary = draft.killer.definitions.get(definition_id, {})
	if definition.is_empty():
		return _invalid("TARGET_ILLEGAL", "Selected skill has no definition")
	var timing: String = _effective_skill_timing(draft, definition_id)
	var phase_for_timing: String = {"fast":"KILLER_FAST","main":"KILLER_MAIN","slow":"KILLER_SLOW"}.get(timing, "")
	if draft.phase != phase_for_timing:
		return _invalid("WRONG_PHASE", "Skill timing is %s" % timing)
	if timing == "main" and draft.killer.main_action_mode != "":
		return _invalid("PREREQUISITE_MISSING", "Main actions have already started")

	var cost_value: Variant = payload.get("cost_card_instance_ids", [])
	if not cost_value is Array:
		return _invalid("TARGET_ILLEGAL", "Skill costs must be an array")
	var cost_ids: Array = cost_value
	var required_cost: int = int(definition.get("extra_hand_cost", 0))
	if cost_ids.size() != required_cost:
		return _invalid("RESOURCE_MISSING", "Skill requires %d other hand cards" % required_cost)
	var cost_seen: Dictionary = {}
	for cost_value_id: Variant in cost_ids:
		var cost_id := str(cost_value_id)
		if cost_id == card_instance_id or cost_id not in draft.killer.hand or cost_seen.has(cost_id):
			return _invalid("TARGET_ILLEGAL", "Skill cost contains an invalid card")
		cost_seen[cost_id] = true

	for cost_id: String in cost_ids:
		draft.killer.hand.erase(cost_id)
		draft.killer.discard.append(cost_id)
		events.append(DomainEventScript.make("SkillCostPaid", {"card_instance_id":cost_id}, "killer"))
	draft.killer.hand.erase(card_instance_id)
	events.append(DomainEventScript.make("SkillPlayed", {"definition_id":definition_id}))
	var effect_result := _apply_killer_skill_effect(draft, definition_id, card_instance_id, payload, events)
	if not effect_result.ok:
		return effect_result
	draft.killer.discard.append(card_instance_id)
	draft.stats.killer_skills_played = int(draft.stats.get("killer_skills_played", 0)) + 1
	events.append(DomainEventScript.make("SkillDiscarded", {"card_instance_id":card_instance_id,"reason":"played"}, "killer"))

	if draft.phase == "GAME_OVER" or draft.phase.begins_with("ENCOUNTER"):
		return _valid()
	if draft.phase == "DAMAGE_RESPONSE":
		if timing == "main":
			draft.killer.main_action_mode = "skill"
			draft.killer.main_actions_remaining = 0
		return _valid()
	if timing == "main":
		draft.killer.main_action_mode = "skill"
		draft.killer.main_actions_remaining = 0
		_transition(draft, "KILLER_SLOW", events)
	elif timing == "slow":
		_begin_killer_draw(draft, rng, events)
	return _valid()


func _apply_killer_skill_effect(draft: Dictionary, definition_id: String, card_instance_id: String, payload: Dictionary, events: Array) -> Dictionary:
	match definition_id:
		"pursue":
			var pursue_path := _skill_path(payload, 1, 1)
			if not pursue_path.ok:
				return pursue_path
			return _move_killer_path(draft, pursue_path.path, events)
		"sense":
			var region: String = payload.get("region", "")
			if region not in ["R", "B", "G"]:
				return _invalid("TARGET_ILLEGAL", "Sense requires one map region")
			var sensed_survivor_ids: Array = []
			for survivor: Dictionary in draft.survivors:
				if survivor.health != "eliminated" and survivor.id != "anna_kubrick" and map_graph.rooms_by_id[survivor.room_id].region == region:
					sensed_survivor_ids.append(survivor.id)
			sensed_survivor_ids.sort()
			events.append(DomainEventScript.make("SenseResolved", {"region":region,"survivor_ids":sensed_survivor_ids}))
			return _valid()
		"madness":
			var madness_blocks := _place_blocks(draft, [payload.get("edge_id", "")], _relocation_ids(payload), events)
			if not madness_blocks.ok:
				return madness_blocks
			draft.killer.temporary_modifiers.append({"source_instance_id":card_instance_id,"definition_id":"madness","amount":2})
			_update_killer_strength(draft, events)
			return _valid()
		"barricade":
			var barricade_edge: String = payload.get("edge_id", "")
			if not _edge_touches_room(barricade_edge, draft.killer.room_id):
				return _invalid("TARGET_ILLEGAL", "Barricade must target a door in the killer room")
			return _place_blocks(draft, [barricade_edge], _relocation_ids(payload), events)
		"stayyyy":
			var room_edges: Array = []
			for edge_id: String in map_graph.edges_by_id:
				if _edge_touches_room(edge_id, draft.killer.room_id) and map_graph.is_blockable(edge_id):
					room_edges.append(edge_id)
			room_edges.sort()
			return _place_blocks(draft, room_edges, _relocation_ids(payload), events)
		"revving_chainsaw":
			return _apply_revving_chainsaw(draft, payload, events)
		"brutal_rage":
			return _apply_brutal_rage(draft, payload, events)
	return _invalid("TARGET_ILLEGAL", "Unknown killer skill")


func _apply_revving_chainsaw(draft: Dictionary, payload: Dictionary, events: Array) -> Dictionary:
	var affected_rooms := _rooms_within_distance(draft.killer.room_id, 1)
	for survivor: Dictionary in draft.survivors:
		if survivor.health != "eliminated" and survivor.room_id in affected_rooms:
			_add_fear(draft, survivor, "revving_chainsaw", events)
	var path_value: Variant = payload.get("path_room_ids", [])
	if not path_value is Array:
		return _invalid("PATH_ILLEGAL", "Chainsaw movement path must be an array")
	var path: Array = path_value
	if path.size() > 1:
		return _invalid("PATH_ILLEGAL", "Chainsaw movement is zero or one step")
	if not path.is_empty():
		var moved := _move_killer_path(draft, path, events)
		if not moved.ok:
			return moved
	var target_ids: Array = []
	for survivor: Dictionary in draft.survivors:
		if survivor.health != "eliminated" and survivor.room_id == draft.killer.room_id:
			target_ids.append(survivor.id)
	var return_phase := "KILLER_SLOW" if draft.phase == "KILLER_MAIN" else "KILLER_FAST"
	_begin_non_encounter_damage(draft, target_ids, "revving_chainsaw", return_phase, events)
	return _valid()


func _apply_brutal_rage(draft: Dictionary, payload: Dictionary, events: Array) -> Dictionary:
	var segments_value: Variant = payload.get("path_segments", [])
	if not segments_value is Array:
		return _invalid("PATH_ILLEGAL", "Brutal Rage paths must be an array")
	var segments: Array = segments_value
	if segments.is_empty() or segments.size() > 8:
		return _invalid("PATH_ILLEGAL", "Brutal Rage requires one to eight movement segments")
	for index in range(segments.size()):
		if not segments[index] is Array:
			return _invalid("PATH_ILLEGAL", "Each Brutal Rage segment must be a path")
		var path: Array = segments[index]
		if path.size() < 1 or path.size() > 2:
			return _invalid("PATH_ILLEGAL", "Each Brutal Rage move is one or two steps")
		var moved := _move_killer_path(draft, path, events)
		if not moved.ok:
			return moved
		if _perform_killer_search(draft, events):
			break
		if not moved.removed_block:
			if index < segments.size() - 1:
				return _invalid("PREREQUISITE_MISSING", "Brutal Rage cannot repeat without removing a block")
			break
	return _valid()


func _end_killer_slow(draft: Dictionary, player_id: String, rng, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	_begin_killer_draw(draft, rng, events)
	return _valid()


func _begin_killer_draw(draft: Dictionary, rng, events: Array) -> void:
	_begin_killer_draw_operation(draft, int(draft.killer.draw_per_turn), "turn_end", rng, events)


func _begin_killer_draw_operation(draft: Dictionary, count: int, context: String, rng, events: Array) -> void:
	_transition(draft, "KILLER_DRAW", events)
	draft.killer.pending_draw_count = count
	draft.killer.pending_draw_context = context
	_continue_killer_draw(draft, rng, events)


func _continue_killer_draw(draft: Dictionary, rng, events: Array) -> void:
	while draft.killer.pending_draw_count > 0:
		if draft.killer.deck.is_empty():
			_level_up_and_recycle(draft, rng, events)
			if not draft.killer.pending_unlock_discard.is_empty():
				_transition(draft, "KILLER_UNLOCK_DISCARD", events)
				return
			if draft.killer.deck.is_empty():
				draft.killer.pending_draw_count = 0
				break
		var card_instance_id: String = draft.killer.deck.pop_front()
		draft.killer.pending_draw_count -= 1
		if draft.killer.hand.size() < int(draft.killer.hand_limit):
			draft.killer.hand.append(card_instance_id)
			events.append(DomainEventScript.make("SkillDrawn", {"card_instance_id":card_instance_id}, "killer"))
		else:
			draft.killer.discard.append(card_instance_id)
			events.append(DomainEventScript.make("SkillDiscarded", {"card_instance_id":card_instance_id,"reason":"hand_limit"}, "killer"))
	if draft.killer.pending_draw_count <= 0:
		var context: String = draft.killer.pending_draw_context
		draft.killer.pending_draw_context = ""
		if context == "turn_end":
			_finish_killer_turn(draft, events)
		elif context == "encounter_roll":
			_resolve_defense_roll(draft, rng, events)


func _level_up_and_recycle(draft: Dictionary, rng, events: Array) -> void:
	var old_level: int = draft.killer.level
	if old_level < int(draft.killer.max_level):
		draft.killer.level = old_level + 1
		if draft.killer.level == 2:
			draft.killer.base_strength += 1
			_update_killer_strength(draft, events)
		elif draft.killer.level == 3:
			var original_hand: Array = draft.killer.hand.duplicate()
			for locked_instance_id: String in draft.killer.locked_cards.duplicate():
				if draft.killer.skill_instances.get(locked_instance_id, "") == "brutal_rage":
					draft.killer.locked_cards.erase(locked_instance_id)
					draft.killer.hand.append(locked_instance_id)
					if "brutal_rage" not in draft.killer.unlocked_skill_ids:
						draft.killer.unlocked_skill_ids.append("brutal_rage")
					events.append(DomainEventScript.make("SkillUnlocked", {"definition_id":"brutal_rage"}))
					if draft.killer.hand.size() > int(draft.killer.hand_limit):
						draft.killer.pending_unlock_discard = {"unlocked_card_instance_id":locked_instance_id,"eligible_discard_instance_ids":original_hand}
					break
		events.append(DomainEventScript.make("KillerLeveled", {"from":old_level,"to":draft.killer.level,"strength":draft.killer.effective_strength}))
	var recycled: Array = draft.killer.discard.duplicate()
	draft.killer.discard.clear()
	draft.killer.deck = rng.shuffled(recycled)
	events.append(DomainEventScript.make("SkillDeckRebuilt", {"card_count":draft.killer.deck.size()}, "killer"))


func _resolve_killer_unlock_overflow(draft: Dictionary, player_id: String, payload: Dictionary, rng, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	var pending: Dictionary = draft.killer.pending_unlock_discard
	if pending.is_empty():
		return _invalid("PREREQUISITE_MISSING", "No unlocked skill overflow is pending")
	var discard_instance_id: String = payload.get("discard_card_instance_id", "")
	if discard_instance_id not in pending.eligible_discard_instance_ids or discard_instance_id not in draft.killer.hand:
		return _invalid("TARGET_ILLEGAL", "Discard must be one of the previous hand cards")
	draft.killer.hand.erase(discard_instance_id)
	draft.killer.discard.append(discard_instance_id)
	draft.killer.pending_unlock_discard = {}
	events.append(DomainEventScript.make("SkillDiscarded", {"card_instance_id":discard_instance_id,"reason":"unlock_overflow"}, "killer"))
	if not draft.killer.pending_draw_context.is_empty():
		_continue_killer_draw(draft, rng, events)
	elif not draft.killer.pending_deck_discard_context.is_empty():
		_continue_killer_deck_discard(draft, rng, events)
	else:
		return _invalid("PREREQUISITE_MISSING", "No paused killer operation is waiting")
	return _valid()


func _finish_killer_turn(draft: Dictionary, events: Array) -> void:
	if not draft.killer.temporary_modifiers.is_empty():
		draft.killer.temporary_modifiers.clear()
		_update_killer_strength(draft, events)
	draft.killer.pending_draw_count = 0
	draft.killer.pending_draw_context = ""
	draft.killer.pending_deck_discard_count = 0
	draft.killer.pending_deck_discard_context = ""
	draft.killer.pending_deck_discarded_instance_ids.clear()
	draft.killer.main_actions_remaining = 0
	draft.killer.main_action_mode = ""
	draft.killer.encounter_started_this_turn = false
	_begin_next_survivor_round(draft, events)


func _killer_control_check(draft: Dictionary, player_id: String) -> Dictionary:
	if draft.killer.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the killer")
	return _valid()


func _effective_skill_timing(draft: Dictionary, definition_id: String) -> String:
	var definition: Dictionary = draft.killer.definitions.get(definition_id, {})
	if definition_id == "revving_chainsaw" and draft.killer.level >= int(definition.get("fast_from_level", 99)):
		return "fast"
	return definition.get("timing", "")


func _skill_path(payload: Dictionary, minimum: int, maximum: int) -> Dictionary:
	var path_value: Variant = payload.get("path_room_ids", [])
	if not path_value is Array:
		return _invalid("PATH_ILLEGAL", "Skill movement path must be an array")
	var path: Array = path_value
	if path.size() < minimum or path.size() > maximum:
		return _invalid("PATH_ILLEGAL", "Skill movement path has an invalid length")
	return {"ok":true,"path":path}


func _move_killer_path(draft: Dictionary, path: Array, events: Array) -> Dictionary:
	var path_check: Dictionary = map_graph.validate_path(draft.killer.room_id, path, draft.map.blocked_edge_ids, true)
	if not path_check.ok:
		return _invalid("PATH_ILLEGAL", path_check.reason)
	var removed_block := false
	for next_value: Variant in path:
		var source_room_id: String = draft.killer.room_id
		var target_room_id := str(next_value)
		var edge_id := MapGraphScript.edge_id_for(source_room_id, target_room_id)
		if edge_id in draft.map.blocked_edge_ids:
			draft.map.blocked_edge_ids.erase(edge_id)
			draft.map.block_supply_remaining += 1
			removed_block = true
			events.append(DomainEventScript.make("BlockRemoved", {"edge_id":edge_id}))
		draft.killer.room_id = target_room_id
		events.append(DomainEventScript.make("ActorMoved", {"actor_id":draft.killer.id,"from":source_room_id,"to":target_room_id}))
	return {"ok":true,"removed_block":removed_block}


func _perform_killer_search(draft: Dictionary, events: Array) -> bool:
	var found_ids: Array = []
	for survivor: Dictionary in draft.survivors:
		if survivor.health != "eliminated" and survivor.room_id == draft.killer.room_id:
			found_ids.append(survivor.id)
	found_ids.sort()
	events.append(DomainEventScript.make("KillerSearched", {"room_id":draft.killer.room_id,"found":not found_ids.is_empty(),"survivor_ids":found_ids}))
	if found_ids.is_empty():
		return false
	_start_encounter(draft, found_ids, "search", events)
	return true


func _start_encounter(draft: Dictionary, survivor_ids: Array, source: String, events: Array) -> void:
	draft.killer.encounter_started_this_turn = true
	draft.killer.main_actions_remaining = 0
	draft.stats.encounters_started = int(draft.stats.get("encounters_started", 0)) + 1
	draft.encounter = {
		"id":"encounter-%d-%d" % [draft.round_index, draft.command_sequence + 1],
		"room_id":draft.killer.room_id,
		"survivor_ids":survivor_ids.duplicate(),
		"attacked_survivor_ids":[],
		"active_defender_id":"",
		"attack_index":0,
		"attack_skill_definition_id":"",
		"selected_item_instance_ids":[],
		"selected_item_definition_ids":[],
		"item_bonus":0,
		"used_weapon":false,
		"flee_pending_ids":[],
		"end_reason":"",
		"source":source,
	}
	draft.return_phase = "KILLER_DRAW"
	_transition(draft, "ENCOUNTER_START", events)
	events.append(DomainEventScript.make("EncounterStarted", {"encounter_id":draft.encounter.id,"room_id":draft.killer.room_id,"survivor_ids":survivor_ids}))
	if int(draft.killer.level) >= 5:
		for survivor_id: String in survivor_ids:
			var survivor := _survivor_by_id(draft, survivor_id)
			if not survivor.is_empty() and survivor.health != "eliminated":
				_damage_survivor(draft, survivor, "butcher_level_5_encounter", events)
				if draft.phase == "GAME_OVER":
					return
	_transition(draft, "ENCOUNTER_ATTACK_SKILL", events)


func _select_attack_skill(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	var card_instance_id: String = payload.get("card_instance_id", "")
	if card_instance_id not in draft.killer.hand:
		return _invalid("RESOURCE_MISSING", "Selected attack skill is not in the killer hand")
	var definition_id: String = draft.killer.skill_instances.get(card_instance_id, "")
	var definition: Dictionary = draft.killer.definitions.get(definition_id, {})
	if definition.get("timing", "") != "attack":
		return _invalid("TARGET_ILLEGAL", "Selected card is not an attack skill")
	_clear_encounter_attack_modifier(draft, events)
	draft.killer.hand.erase(card_instance_id)
	draft.killer.discard.append(card_instance_id)
	draft.encounter.attack_skill_definition_id = definition_id
	var strength_bonus: int = int(definition.get("attack_strength_bonus", 0))
	if strength_bonus != 0:
		draft.killer.temporary_modifiers.append({"source_instance_id":card_instance_id,"definition_id":definition_id,"amount":strength_bonus,"encounter_attack":true})
		_update_killer_strength(draft, events)
	events.append(DomainEventScript.make("AttackSkillCommitted", {"definition_id":definition_id}))
	_transition(draft, "ENCOUNTER_DEFENDER", events)
	return _valid()


func _pass_attack_skill(draft: Dictionary, player_id: String, events: Array) -> Dictionary:
	var control := _killer_control_check(draft, player_id)
	if not control.ok:
		return control
	_clear_encounter_attack_modifier(draft, events)
	draft.encounter.attack_skill_definition_id = ""
	events.append(DomainEventScript.make("AttackSkillPassed"))
	_transition(draft, "ENCOUNTER_DEFENDER", events)
	return _valid()


func _select_defender(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	var survivor := _survivor_by_id(draft, payload.get("survivor_id", ""))
	if survivor.is_empty() or survivor.id not in draft.encounter.survivor_ids or survivor.health == "eliminated":
		return _invalid("TARGET_ILLEGAL", "Defender must be a living encounter participant")
	if survivor.id in draft.encounter.attacked_survivor_ids:
		return _invalid("TARGET_ILLEGAL", "This survivor has already defended in the encounter")
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control this defender")
	draft.encounter.active_defender_id = survivor.id
	draft.encounter.selected_item_instance_ids = []
	draft.encounter.selected_item_definition_ids = []
	draft.encounter.item_bonus = 0
	draft.encounter.used_weapon = false
	events.append(DomainEventScript.make("DefenderSelected", {"survivor_id":survivor.id}))
	_transition(draft, "ENCOUNTER_ITEM", events)
	return _valid()


func _select_defense_items(draft: Dictionary, player_id: String, payload: Dictionary, rng, events: Array) -> Dictionary:
	var defender := _survivor_by_id(draft, draft.encounter.get("active_defender_id", ""))
	if defender.is_empty():
		return _invalid("PREREQUISITE_MISSING", "No defender is awaiting an item choice")
	if defender.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control this defender")
	var cards_value: Variant = payload.get("card_instance_ids", [])
	if not cards_value is Array:
		return _invalid("TARGET_ILLEGAL", "Defense item selection must be an array")
	var selected_ids: Array = []
	var selected_definition_ids: Array = []
	var seen: Dictionary = {}
	for value: Variant in cards_value:
		var instance_id := str(value)
		if seen.has(instance_id) or instance_id not in defender.inventory_instance_ids:
			return _invalid("RESOURCE_MISSING", "Defense selection contains an unavailable item")
		seen[instance_id] = true
		selected_ids.append(instance_id)
		selected_definition_ids.append(str(draft.items.item_instances.get(instance_id, "")))
	if selected_ids.size() > 2:
		return _invalid("TARGET_ILLEGAL", "At most one defense item may be used")
	var legal_definitions := ["longsword", "shortsword", "limestone_powder", "hatchet", "revolver"]
	if selected_ids.size() == 1 and selected_definition_ids[0] not in legal_definitions:
		return _invalid("TARGET_ILLEGAL", "Selected card cannot defend by itself")
	if selected_ids.size() == 2:
		var pair: Array = selected_definition_ids.duplicate()
		pair.sort()
		if pair != ["ammo_pack", "revolver"]:
			return _invalid("TARGET_ILLEGAL", "Only a revolver and one ammunition pack may be combined")
	var item_bonus := 0
	var used_weapon := false
	var killer_draw_count := 0
	for definition_id: String in selected_definition_ids:
		var definition: Dictionary = draft.items.definitions.get(definition_id, {})
		item_bonus += int(definition.get("defense_bonus", 0))
		killer_draw_count += int(definition.get("killer_draw_on_defend", 0))
		var tags: Array = definition.get("tags", [])
		if "weapon" in tags or "weapon_ammo" in tags:
			used_weapon = true
	for instance_id: String in selected_ids:
		var definition_id: String = draft.items.item_instances.get(instance_id, "")
		var definition: Dictionary = draft.items.definitions.get(definition_id, {})
		if "infinite" not in definition.get("tags", []):
			defender.inventory_instance_ids.erase(instance_id)
			draft.items.discard.append(instance_id)
			events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":instance_id,"reason":"encounter_defense"}, "survivors"))
	draft.stats.items_used = int(draft.stats.get("items_used", 0)) + selected_ids.size()
	draft.encounter.selected_item_instance_ids = selected_ids
	draft.encounter.selected_item_definition_ids = selected_definition_ids
	draft.encounter.item_bonus = item_bonus
	draft.encounter.used_weapon = used_weapon
	events.append(DomainEventScript.make("EncounterItemCommitted", {"survivor_id":defender.id,"definition_ids":selected_definition_ids,"item_bonus":item_bonus}))
	if killer_draw_count > 0:
		_begin_killer_draw_operation(draft, killer_draw_count, "encounter_roll", rng, events)
	else:
		_resolve_defense_roll(draft, rng, events)
	return _valid()


func _resolve_defense_roll(draft: Dictionary, rng, events: Array) -> void:
	if draft.encounter.is_empty():
		return
	_transition(draft, "ENCOUNTER_ROLL", events)
	var defender := _survivor_by_id(draft, draft.encounter.active_defender_id)
	if defender.is_empty() or defender.health == "eliminated":
		return
	var dice_count: int = maxi(0, 4 - int(defender.fear))
	var dice_results: Array = []
	var dice_total := 0
	for die_index in range(dice_count):
		var result: int = DEFENSE_DIE_FACES[rng.next_index(DEFENSE_DIE_FACES.size())]
		dice_results.append(result)
		dice_total += result
	events.append(DomainEventScript.make("DefenseDiceRolled", {"survivor_id":defender.id,"dice_count":dice_count,"dice_results":dice_results,"dice_total":dice_total}))
	var trap_bonus := 0
	if int(draft.encounter.attack_index) == 0 and draft.map.trap_room_id == draft.encounter.room_id:
		trap_bonus = 2
		draft.map.trap_room_id = ""
		events.append(DomainEventScript.make("TrapTriggered", {"room_id":draft.encounter.room_id,"defense_bonus":trap_bonus}))
	var character_bonus := 0
	if defender.id == "william_hooper" and not bool(draft.encounter.used_weapon):
		character_bonus = 1
	var total: int = dice_total + int(draft.encounter.item_bonus) + trap_bonus + character_bonus
	var killer_strength: int = int(draft.killer.effective_strength)
	var success := total >= killer_strength
	if success:
		draft.stats.defenses_succeeded = int(draft.stats.get("defenses_succeeded", 0)) + 1
	else:
		draft.stats.defenses_failed = int(draft.stats.get("defenses_failed", 0)) + 1
	events.append(DomainEventScript.make("DefenseRolled", {
		"survivor_id":defender.id,
		"dice_count":dice_count,
		"dice_results":dice_results,
		"dice_total":dice_total,
		"item_bonus":draft.encounter.item_bonus,
		"trap_bonus":trap_bonus,
		"character_bonus":character_bonus,
		"total":total,
		"killer_strength":killer_strength,
		"success":success,
	}))
	if defender.id not in draft.encounter.attacked_survivor_ids:
		draft.encounter.attacked_survivor_ids.append(defender.id)
	draft.encounter.attack_index = int(draft.encounter.attack_index) + 1
	draft.encounter.active_defender_id = ""
	if success:
		_begin_killer_deck_discard(draft, 2, "encounter_success", rng, events)
		return
	_damage_survivor(draft, defender, "encounter_failure", events)
	if draft.phase == "GAME_OVER":
		return
	if not _remaining_encounter_defenders(draft).is_empty():
		_clear_encounter_attack_modifier(draft, events)
		_transition(draft, "ENCOUNTER_ATTACK_SKILL", events)
	else:
		_begin_encounter_flee(draft, "all_participants_attacked", events)


func _begin_killer_deck_discard(draft: Dictionary, count: int, context: String, rng, events: Array) -> void:
	_transition(draft, "KILLER_DECK_DISCARD", events)
	draft.killer.pending_deck_discard_count = count
	draft.killer.pending_deck_discard_context = context
	draft.killer.pending_deck_discarded_instance_ids = []
	_continue_killer_deck_discard(draft, rng, events)


func _continue_killer_deck_discard(draft: Dictionary, rng, events: Array) -> void:
	while int(draft.killer.pending_deck_discard_count) > 0:
		if draft.killer.deck.is_empty():
			_level_up_and_recycle(draft, rng, events)
			if not draft.killer.pending_unlock_discard.is_empty():
				_transition(draft, "KILLER_UNLOCK_DISCARD", events)
				return
			if draft.killer.deck.is_empty():
				draft.killer.pending_deck_discard_count = 0
				break
		var card_instance_id: String = draft.killer.deck.pop_front()
		draft.killer.discard.append(card_instance_id)
		draft.killer.pending_deck_discarded_instance_ids.append(card_instance_id)
		draft.killer.pending_deck_discard_count -= 1
		events.append(DomainEventScript.make("KillerDeckCardDiscarded", {"definition_id":draft.killer.skill_instances.get(card_instance_id, "")}))
	if int(draft.killer.pending_deck_discard_count) <= 0:
		var context: String = draft.killer.pending_deck_discard_context
		var discarded_ids: Array = draft.killer.pending_deck_discarded_instance_ids.duplicate()
		draft.killer.pending_deck_discard_context = ""
		draft.killer.pending_deck_discarded_instance_ids = []
		if context == "encounter_success":
			var definition_ids: Array = []
			for instance_id: String in discarded_ids:
				definition_ids.append(draft.killer.skill_instances.get(instance_id, ""))
			events.append(DomainEventScript.make("KillerRepelled", {"discarded_definition_ids":definition_ids}))
			_begin_encounter_flee(draft, "defense_succeeded", events)


func _begin_encounter_flee(draft: Dictionary, reason: String, events: Array) -> void:
	_clear_encounter_attack_modifier(draft, events)
	var pending_ids: Array = []
	for survivor_id: String in draft.encounter.survivor_ids:
		var survivor := _survivor_by_id(draft, survivor_id)
		if not survivor.is_empty() and survivor.health != "eliminated":
			pending_ids.append(survivor_id)
	draft.encounter.flee_pending_ids = pending_ids
	draft.encounter.end_reason = reason
	_transition(draft, "ENCOUNTER_FLEE", events)
	events.append(DomainEventScript.make("EncounterFleeStarted", {"survivor_ids":pending_ids,"reason":reason}))


func _confirm_flee(draft: Dictionary, player_id: String, payload: Dictionary, rng, events: Array) -> Dictionary:
	var survivor := _survivor_by_id(draft, payload.get("survivor_id", ""))
	if survivor.is_empty() or survivor.id not in draft.encounter.get("flee_pending_ids", []):
		return _invalid("TARGET_ILLEGAL", "Survivor is not awaiting an encounter flee choice")
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control this survivor")
	var path_value: Variant = payload.get("path_room_ids", [])
	if not path_value is Array:
		return _invalid("PATH_ILLEGAL", "Flee path must be an array")
	var path: Array = path_value
	if path.size() > 1:
		return _invalid("PATH_ILLEGAL", "Encounter flee is zero or one step")
	if not path.is_empty():
		var path_check: Dictionary = map_graph.validate_path(survivor.room_id, path, draft.map.blocked_edge_ids)
		if not path_check.ok:
			return _invalid("PATH_ILLEGAL", path_check.reason)
		var source_room_id: String = survivor.room_id
		var target_room_id := str(path[0])
		survivor.room_id = target_room_id
		events.append(DomainEventScript.make("ActorMoved", {"actor_id":survivor.id,"from":source_room_id,"to":target_room_id}))
		if target_room_id == "R4":
			_record_noise(draft, target_room_id, "encounter_flee_entry", true, events)
	draft.encounter.flee_pending_ids.erase(survivor.id)
	events.append(DomainEventScript.make("FleeConfirmed", {"survivor_id":survivor.id,"room_id":survivor.room_id}))
	if draft.encounter.flee_pending_ids.is_empty():
		_finish_encounter(draft, rng, events)
	return _valid()


func _finish_encounter(draft: Dictionary, rng, events: Array) -> void:
	var encounter_id: String = draft.encounter.get("id", "")
	var reason: String = draft.encounter.get("end_reason", "")
	events.append(DomainEventScript.make("EncounterEnded", {"encounter_id":encounter_id,"reason":reason}))
	draft.encounter = {}
	draft.return_phase = ""
	_begin_killer_draw(draft, rng, events)


func _remaining_encounter_defenders(draft: Dictionary) -> Array:
	var result: Array = []
	for survivor_id: String in draft.encounter.survivor_ids:
		var survivor := _survivor_by_id(draft, survivor_id)
		if not survivor.is_empty() and survivor.health != "eliminated" and survivor_id not in draft.encounter.attacked_survivor_ids:
			result.append(survivor_id)
	return result


func _clear_encounter_attack_modifier(draft: Dictionary, events: Array) -> void:
	var kept: Array = []
	var removed := false
	for modifier: Dictionary in draft.killer.temporary_modifiers:
		if modifier.get("encounter_attack", false):
			removed = true
		else:
			kept.append(modifier)
	if removed:
		draft.killer.temporary_modifiers = kept
		_update_killer_strength(draft, events)


func _place_blocks(draft: Dictionary, target_edge_ids: Array, relocation_edge_ids: Array, events: Array) -> Dictionary:
	var targets: Array = []
	for edge_value: Variant in target_edge_ids:
		var edge_id := str(edge_value)
		if edge_id.is_empty() or not map_graph.is_blockable(edge_id):
			return _invalid("TARGET_ILLEGAL", "Block target must be a white door")
		if edge_id not in targets:
			targets.append(edge_id)
	var new_targets: Array = []
	for edge_id: String in targets:
		if edge_id not in draft.map.blocked_edge_ids:
			new_targets.append(edge_id)
	var shortage: int = maxi(0, new_targets.size() - int(draft.map.block_supply_remaining))
	if relocation_edge_ids.size() != shortage:
		return _invalid("RESOURCE_MISSING", "Block placement requires %d relocated tokens" % shortage)
	var relocation_seen: Dictionary = {}
	for relocation_value: Variant in relocation_edge_ids:
		var relocation_id := str(relocation_value)
		if relocation_id not in draft.map.blocked_edge_ids or relocation_id in targets or relocation_seen.has(relocation_id):
			return _invalid("TARGET_ILLEGAL", "Relocated block must be a distinct existing block outside the targets")
		relocation_seen[relocation_id] = true
	for relocation_id: String in relocation_edge_ids:
		draft.map.blocked_edge_ids.erase(relocation_id)
		draft.map.block_supply_remaining += 1
		events.append(DomainEventScript.make("BlockRemoved", {"edge_id":relocation_id}))
	for edge_id: String in new_targets:
		draft.map.blocked_edge_ids.append(edge_id)
		draft.map.block_supply_remaining -= 1
		events.append(DomainEventScript.make("BlockPlaced", {"edge_id":edge_id}))
	draft.map.blocked_edge_ids.sort()
	return _valid()


func _relocation_ids(payload: Dictionary) -> Array:
	var relocation_value: Variant = payload.get("relocate_edge_ids", [])
	if relocation_value is Array:
		var result: Array = relocation_value.duplicate()
		var single_id: String = payload.get("relocate_edge_id", "")
		if not single_id.is_empty() and result.is_empty():
			result.append(single_id)
		return result
	return []


func _edge_touches_room(edge_id: String, room_id: String) -> bool:
	if not map_graph.edges_by_id.has(edge_id):
		return false
	var edge: Dictionary = map_graph.edges_by_id[edge_id]
	return edge.a == room_id or edge.b == room_id


func _rooms_within_distance(start_room_id: String, maximum_distance: int) -> Array:
	var distances := {start_room_id:0}
	var queue: Array = [start_room_id]
	while not queue.is_empty():
		var room_id: String = queue.pop_front()
		var distance: int = distances[room_id]
		if distance >= maximum_distance:
			continue
		for neighbor: String in map_graph.neighbors(room_id):
			if not distances.has(neighbor):
				distances[neighbor] = distance + 1
				queue.append(neighbor)
	return distances.keys()


func _add_fear(draft: Dictionary, survivor: Dictionary, source: String, events: Array) -> void:
	if survivor.fear >= 2:
		_record_noise(draft, survivor.room_id, "fear_overflow:%s" % source, true, events)
		return
	var old_fear: int = survivor.fear
	survivor.fear += 1
	events.append(DomainEventScript.make("FearChanged", {"survivor_id":survivor.id,"from":old_fear,"to":survivor.fear}, "survivors"))


func _begin_non_encounter_damage(draft: Dictionary, survivor_ids: Array, source: String, return_phase: String, events: Array) -> void:
	draft.pending_damage = {
		"survivor_ids":survivor_ids.duplicate(),
		"current_survivor_id":"",
		"source":source,
		"return_phase":return_phase,
		"resume_after_response":false,
	}
	_advance_pending_damage(draft, events)


func _advance_pending_damage(draft: Dictionary, events: Array) -> void:
	while not draft.pending_damage.is_empty() and not draft.pending_damage.survivor_ids.is_empty():
		var survivor_id: String = draft.pending_damage.survivor_ids[0]
		var survivor := _survivor_by_id(draft, survivor_id)
		if survivor.is_empty() or survivor.health == "eliminated":
			draft.pending_damage.survivor_ids.pop_front()
			continue
		var amulet_id := _inventory_instance_with_definition(draft, survivor, "ancient_amulet")
		if not amulet_id.is_empty():
			draft.pending_damage.current_survivor_id = survivor_id
			draft.pending_damage.resume_after_response = true
			if draft.phase != "DAMAGE_RESPONSE":
				_transition(draft, "DAMAGE_RESPONSE", events)
			events.append(DomainEventScript.make("DamageResponseRequested", {"survivor_id":survivor_id,"source":draft.pending_damage.source,"card_instance_id":amulet_id}, "survivors"))
			return
		draft.pending_damage.survivor_ids.pop_front()
		_damage_survivor(draft, survivor, draft.pending_damage.source, events)
		if draft.phase == "GAME_OVER":
			draft.pending_damage = {}
			return
	if draft.pending_damage.is_empty():
		return
	var return_phase: String = draft.pending_damage.return_phase
	var should_resume: bool = bool(draft.pending_damage.resume_after_response)
	draft.pending_damage = {}
	if should_resume and draft.phase != "GAME_OVER":
		_transition(draft, return_phase, events)


func _resolve_damage_response(draft: Dictionary, player_id: String, payload: Dictionary, events: Array) -> Dictionary:
	if draft.pending_damage.is_empty():
		return _invalid("PREREQUISITE_MISSING", "No damage response is pending")
	var survivor := _survivor_by_id(draft, draft.pending_damage.current_survivor_id)
	if survivor.is_empty():
		return _invalid("TARGET_ILLEGAL", "Pending damage survivor is missing")
	if survivor.controller_player_id != player_id:
		return _invalid("NOT_CONTROLLER", "Player does not control the damaged survivor")
	var use_amulet: bool = bool(payload.get("use_amulet", false))
	if use_amulet:
		var amulet_id := _inventory_instance_with_definition(draft, survivor, "ancient_amulet")
		if amulet_id.is_empty():
			return _invalid("RESOURCE_MISSING", "Ancient amulet is not available")
		survivor.inventory_instance_ids.erase(amulet_id)
		draft.items.discard.append(amulet_id)
		draft.stats.items_used = int(draft.stats.get("items_used", 0)) + 1
		events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":amulet_id,"reason":"ancient_amulet"}, "survivors"))
		events.append(DomainEventScript.make("DamagePrevented", {"survivor_id":survivor.id,"source":draft.pending_damage.source,"definition_id":"ancient_amulet"}))
	else:
		_damage_survivor(draft, survivor, draft.pending_damage.source, events)
	draft.pending_damage.survivor_ids.pop_front()
	draft.pending_damage.current_survivor_id = ""
	if draft.phase == "GAME_OVER":
		draft.pending_damage = {}
		return _valid()
	_advance_pending_damage(draft, events)
	return _valid()


func _damage_survivor(draft: Dictionary, survivor: Dictionary, source: String, events: Array) -> void:
	var old_health: String = survivor.health
	if old_health == "healthy":
		survivor.health = "injured"
	elif old_health == "injured":
		survivor.health = "eliminated"
	else:
		return
	events.append(DomainEventScript.make("HealthChanged", {"survivor_id":survivor.id,"from":old_health,"to":survivor.health,"source":source}))
	if survivor.health == "eliminated":
		_end_match(draft, "killer", "survivor_eliminated", events)


func _heal_survivor(_draft: Dictionary, survivor: Dictionary, source: String, events: Array) -> void:
	var old_fear: int = int(survivor.fear)
	survivor.health = "healthy"
	survivor.fear = 0
	events.append(DomainEventScript.make("HealthChanged", {"survivor_id":survivor.id,"from":"injured","to":"healthy","source":source}))
	if old_fear > 0:
		events.append(DomainEventScript.make("FearChanged", {"survivor_id":survivor.id,"from":old_fear,"to":0}, "survivors"))


func _inventory_instance_with_definition(draft: Dictionary, survivor: Dictionary, definition_id: String) -> String:
	for instance_id: String in survivor.inventory_instance_ids:
		if draft.items.item_instances.get(instance_id, "") == definition_id:
			return instance_id
	return ""


func _consume_item(draft: Dictionary, survivor: Dictionary, card_instance_id: String, reason: String, events: Array) -> void:
	survivor.inventory_instance_ids.erase(card_instance_id)
	draft.items.discard.append(card_instance_id)
	events.append(DomainEventScript.make("ItemDiscarded", {"card_instance_id":card_instance_id,"reason":reason}, "survivors"))


func _update_killer_strength(draft: Dictionary, events: Array) -> void:
	var old_strength: int = int(draft.killer.get("effective_strength", draft.killer.base_strength))
	var modifier_total := 0
	for modifier: Dictionary in draft.killer.temporary_modifiers:
		modifier_total += int(modifier.get("amount", 0))
	draft.killer.effective_strength = int(draft.killer.base_strength) + modifier_total
	if old_strength != draft.killer.effective_strength:
		events.append(DomainEventScript.make("KillerStrengthChanged", {"from":old_strength,"to":draft.killer.effective_strength}))


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
		if room_id not in draft.revealed_noise_room_ids:
			draft.revealed_noise_room_ids.append(room_id)
		draft.revealed_noise_room_ids.sort()
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
	_enter_killer_turn(draft, events)


func _enter_killer_turn(draft: Dictionary, events: Array) -> void:
	_transition(draft, "KILLER_REAPPEAR", events)
	if draft.killer.is_stealthed:
		draft.killer.is_stealthed = false
		events.append(DomainEventScript.make("KillerReappeared", {"room_id":draft.killer.room_id}))
		if _perform_killer_search(draft, events):
			return
	_transition(draft, "KILLER_FAST", events)


func _begin_next_survivor_round(draft: Dictionary, events: Array) -> void:
	draft.stats.rounds_completed = int(draft.stats.get("rounds_completed", 0)) + 1
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
