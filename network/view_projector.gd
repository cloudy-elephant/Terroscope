class_name ViewProjector
extends RefCounted


static func state_for_side(state: Dictionary, side: String) -> Dictionary:
	if side not in ["survivors", "killer"]:
		return {}
	var view := {
		"match_id": state.match_id,
		"rules_version": state.rules_version,
		"content_version": state.content_version,
		"map_version": state.map_version,
		"schema_version": state.schema_version,
		"command_sequence": state.command_sequence,
		"event_sequence": state.event_sequence,
		"round_index": state.round_index,
		"phase": state.phase,
		"winner": state.winner,
		"end_reason": state.end_reason,
		"map": state.map.duplicate(true),
	}
	if side == "survivors":
		view.active_actor_id = state.active_actor_id
		view.acted_survivor_ids = state.acted_survivor_ids.duplicate()
		view.survivors = state.survivors.duplicate(true)
		view.killer = _survivor_side_killer_view(state.killer)
		view.objectives = state.objectives.duplicate(true)
		view.items = _survivor_item_view(state)
		view.noises_this_round = state.noises_this_round.duplicate(true)
		view.noises_last_round = state.noises_last_round.duplicate()
		view.revealed_noise_room_ids = state.revealed_noise_room_ids.duplicate()
		view.firecracker_active = state.firecracker_active
		view.encounter = state.encounter.duplicate(true)
		view.pending_damage = state.pending_damage.duplicate(true)
	else:
		view.survivors = []
		for survivor: Dictionary in state.survivors:
			view.survivors.append({"id":survivor.id,"health":survivor.health})
		view.killer = _killer_side_killer_view(state.killer)
		view.objectives = {"rescue_started":int(state.objectives.rescue_countdown) >= 0}
		if int(state.objectives.rescue_countdown) >= 0:
			view.objectives.rescue_countdown = state.objectives.rescue_countdown
		view.items = {
			"discover_deck_count": state.items.discover_deck.size(),
			"search_deck_count": state.items.search_deck.size(),
			"team_key_count": state.items.team_key_instance_ids.size(),
		}
		view.noises_last_round = state.noises_last_round.duplicate()
		view.revealed_noise_room_ids = state.revealed_noise_room_ids.duplicate()
		view.firecracker_active = state.firecracker_active
		view.encounter = state.encounter.duplicate(true) if not state.encounter.is_empty() else {}
		view.map.erase("trap_room_id")
		view.map.erase("first_aid_cabinet_available")
	return view


static func events_for_side(events: Array, side: String) -> Array:
	var projected: Array = []
	for event: Dictionary in events:
		var audience: String = event.get("audience", "all")
		if audience == "all" or audience == side:
			projected.append(event.duplicate(true))
	return projected


static func _survivor_side_killer_view(killer: Dictionary) -> Dictionary:
	var result := {
		"id": killer.id,
		"is_stealthed": killer.is_stealthed,
		"level": killer.level,
		"base_strength": killer.base_strength,
		"effective_strength": killer.effective_strength,
	}
	if not killer.is_stealthed:
		result.room_id = killer.room_id
	return result


static func _killer_side_killer_view(killer: Dictionary) -> Dictionary:
	return {
		"id": killer.id,
		"room_id": killer.room_id,
		"is_stealthed": killer.is_stealthed,
		"level": killer.level,
		"base_strength": killer.base_strength,
		"effective_strength": killer.effective_strength,
		"temporary_modifiers": killer.temporary_modifiers.duplicate(true),
		"hand": killer.hand.duplicate(),
		"hand_count": killer.hand.size(),
		"deck_count": killer.deck.size(),
		"discard": killer.discard.duplicate(),
		"discard_count": killer.discard.size(),
		"locked_cards": killer.locked_cards.duplicate(),
		"definitions": killer.definitions.duplicate(true),
		"skill_instances": killer.skill_instances.duplicate(true),
		"unlocked_skill_ids": killer.unlocked_skill_ids.duplicate(),
		"main_actions_remaining": killer.main_actions_remaining,
		"main_action_mode": killer.main_action_mode,
		"pending_draw_count": killer.pending_draw_count,
		"pending_draw_context": killer.pending_draw_context,
		"pending_deck_discard_count": killer.pending_deck_discard_count,
		"pending_deck_discard_context": killer.pending_deck_discard_context,
		"pending_unlock_discard": killer.pending_unlock_discard.duplicate(true),
	}


static func _survivor_item_view(state: Dictionary) -> Dictionary:
	var visible_instance_ids: Array = state.items.discard.duplicate()
	visible_instance_ids.append_array(state.items.team_key_instance_ids)
	for survivor: Dictionary in state.survivors:
		visible_instance_ids.append_array(survivor.inventory_instance_ids)
	visible_instance_ids.append_array(state.items.pending_private_draw.get("card_instance_ids", []))
	var visible_instances: Dictionary = {}
	for instance_id: String in visible_instance_ids:
		if state.items.item_instances.has(instance_id):
			visible_instances[instance_id] = state.items.item_instances[instance_id]
	return {
		"inventory_limit": state.items.inventory_limit,
		"definitions": state.items.definitions.duplicate(true),
		"item_instances": visible_instances,
		"discover_deck_count": state.items.discover_deck.size(),
		"search_deck_count": state.items.search_deck.size(),
		"discard": state.items.discard.duplicate(),
		"team_key_instance_ids": state.items.team_key_instance_ids.duplicate(),
		"team_key_count": state.items.team_key_instance_ids.size(),
		"pending_private_draw": state.items.pending_private_draw.duplicate(true),
	}
