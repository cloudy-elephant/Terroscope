extends SceneTree

const GameCommandScript = preload("res://core/command.gd")
const MatchHostScript = preload("res://network/match_host.gd")

var failures: Array[String] = []
var assertions = 0
var command_counter = 0


func _initialize() -> void:
	_test_movement_and_blocking()
	_test_activation_order()
	_test_remove_block_and_first_aid()
	_test_search_and_draw_noise()
	_test_inventory_capacity()
	_test_discover_noise_and_reveal()
	_test_empty_discover_deck()
	_test_radio_and_victory_routes()
	if failures.is_empty():
		print("Milestone 1 PASS (%d assertions)" % assertions)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("Milestone 1 FAIL (%d failures, %d assertions)" % [failures.size(), assertions])
		quit(1)


func _test_movement_and_blocking() -> void:
	var host = _new_host(1001)
	var marco: Dictionary = host.state.data.survivors[0]
	marco.room_id = "R1"
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var move_result = _accept(host, "MoveSurvivor", "player_survivors", {"actor_id":"marco_carven","path_room_ids":["R4","R5"]})
	_expect_eq(host.state.data.survivors[0].room_id, "R5", "survivor movement applies its complete two-step path")
	_expect_eq(host.state.data.noises_this_round.size(), 1, "entering R4 records one noise source")
	_expect_eq(host.state.data.noises_this_round[0].source, "sterile_room_entry", "R4 noise keeps its source")
	_expect(_has_event(move_result.events, "ActorMoved"), "survivor movement emits ActorMoved")
	var state_after_move: String = host.state.canonical_json()
	var second_action = _submit(host, "Calm", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(second_action.code, "PREREQUISITE_MISSING", "a survivor cannot take a second main action")
	_expect_eq(host.state.canonical_json(), state_after_move, "rejected second action is atomic")

	var blocked_host = _new_host(1002)
	blocked_host.state.data.survivors[0].room_id = "B1"
	_accept(blocked_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var before_blocked_move: String = blocked_host.state.canonical_json()
	var blocked_move = _submit(blocked_host, "MoveSurvivor", "player_survivors", {"actor_id":"marco_carven","path_room_ids":["B4"]})
	_expect_eq(blocked_move.code, "PATH_ILLEGAL", "survivor movement cannot cross a block")
	_expect_eq(blocked_host.state.canonical_json(), before_blocked_move, "an invalid path does not partially move")
	var empty_path = _submit(blocked_host, "MoveSurvivor", "player_survivors", {"actor_id":"marco_carven","path_room_ids":[]})
	_expect_eq(empty_path.code, "PATH_ILLEGAL", "normal movement requires at least one step")


func _test_activation_order() -> void:
	var host = _new_host(1051)
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var premature_end = _submit(host, "EndActivation", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(premature_end.code, "PREREQUISITE_MISSING", "activation cannot end before its main action")
	_accept(host, "Calm", "player_survivors", {"actor_id":"marco_carven"})
	_accept(host, "EndActivation", "player_survivors", {"actor_id":"marco_carven"})
	var repeated_actor = _submit(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	_expect_eq(repeated_actor.code, "TARGET_ILLEGAL", "a survivor cannot activate twice in one round")
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"william_hooper"})
	_expect_eq(host.state.data.active_actor_id, "william_hooper", "survivor side freely chooses another unacted character")


func _test_remove_block_and_first_aid() -> void:
	var block_host = _new_host(1101)
	block_host.state.data.survivors[0].room_id = "B1"
	_accept(block_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var remove_result = _accept(block_host, "RemoveBlock", "player_survivors", {"actor_id":"marco_carven","edge_id":"B1--B4"})
	_expect("B1--B4" not in block_host.state.data.map.blocked_edge_ids, "adjacent block is removed")
	_expect_eq(block_host.state.data.map.block_supply_remaining, 7, "removed block returns to supply")
	_expect(_has_event(remove_result.events, "BlockRemoved"), "block removal is public event")

	var aid_host = _new_host(1102)
	var marco: Dictionary = aid_host.state.data.survivors[0]
	var william: Dictionary = aid_host.state.data.survivors[1]
	marco.room_id = "G3"
	william.room_id = "G3"
	william.health = "injured"
	william.fear = 2
	_accept(aid_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(aid_host, "UseSpecialAction", "player_survivors", {"actor_id":"marco_carven","source_id":"g3_first_aid_cabinet","target_survivor_id":"william_hooper"})
	_expect_eq(aid_host.state.data.survivors[1].health, "healthy", "G3 cabinet heals an injured survivor")
	_expect_eq(aid_host.state.data.survivors[1].fear, 0, "G3 cabinet clears all target fear")
	_expect(not aid_host.state.data.map.first_aid_cabinet_available, "G3 cabinet is consumed after one use")


func _test_search_and_draw_noise() -> void:
	var host = _new_host(1201)
	var toolbox_id := _first_instance(host, "search", "toolbox")
	_move_to_top(host.state.data.items.search_deck, toolbox_id)
	host.state.data.survivors[0].room_id = "B1"
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var begin_result = _accept(host, "BeginSearch", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(host.state.data.phase, "SURVIVOR_SEARCH_RESOLVE", "confirmed search waits in a private resolution phase")
	_expect_eq(host.state.data.items.search_deck.size(), 9, "search draw is committed immediately")
	_expect_eq(host.state.data.noises_this_round.size(), 2, "normal search plus noisy toolbox retain two internal sources")
	_expect(_has_event(begin_result.events, "ItemDrawn"), "search emits a private draw event")
	_accept(host, "ResolveSearchItem", "player_survivors", {"take":false})
	_expect(toolbox_id in host.state.data.items.discard, "discarded search result enters item discard")
	_expect_eq(host.state.data.phase, "SURVIVOR_ACTIVATION", "search resolution returns to the same activation")

	var anna_host = _new_host(1202)
	var anna_toolbox_id := _first_instance(anna_host, "search", "toolbox")
	_move_to_top(anna_host.state.data.items.search_deck, anna_toolbox_id)
	anna_host.state.data.survivors[2].room_id = "G5"
	_accept(anna_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"anna_kubrick"})
	_accept(anna_host, "BeginSearch", "player_survivors", {"actor_id":"anna_kubrick"})
	_expect_eq(anna_host.state.data.noises_this_round.size(), 1, "Anna suppresses search noise but not item draw noise")
	_expect_eq(anna_host.state.data.noises_this_round[0].source, "item_draw:toolbox", "Anna still records toolbox draw noise")

	var key_host = _new_host(1203)
	var key_id := _first_instance(key_host, "search", "key")
	_move_to_top(key_host.state.data.items.search_deck, key_id)
	key_host.state.data.survivors[2].room_id = "G5"
	_accept(key_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"anna_kubrick"})
	_accept(key_host, "BeginSearch", "player_survivors", {"actor_id":"anna_kubrick"})
	_accept(key_host, "ResolveSearchItem", "player_survivors", {"take":true})
	_expect(key_id in key_host.state.data.items.team_key_instance_ids, "taken key enters the public team objective")
	_expect(key_id not in key_host.state.data.survivors[2].inventory_instance_ids, "key does not consume inventory capacity")

	var invalid_host = _new_host(1204)
	_accept(invalid_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var invalid_room = _submit(invalid_host, "BeginSearch", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(invalid_room.code, "TARGET_ILLEGAL", "search is restricted to R1, B1 and G5")
	invalid_host.state.data.survivors[0].room_id = "R1"
	var killer_present = _submit(invalid_host, "BeginSearch", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(killer_present.code, "PREREQUISITE_MISSING", "search is rejected when the killer shares the room")


func _test_inventory_capacity() -> void:
	var host = _new_host(1301)
	var marco: Dictionary = host.state.data.survivors[0]
	marco.room_id = "B1"
	var extra_a := _take_instance_from_deck(host, "discover", "sedatives")
	var extra_b := _take_instance_from_deck(host, "discover", "hatchet")
	marco.inventory_instance_ids.append(extra_a)
	marco.inventory_instance_ids.append(extra_b)
	var drawn_id := _first_instance(host, "search", "toolbox")
	_move_to_top(host.state.data.items.search_deck, drawn_id)
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(host, "BeginSearch", "player_survivors", {"actor_id":"marco_carven"})
	var before_bad_capacity: String = host.state.canonical_json()
	var bad_capacity = _submit(host, "ResolveSearchItem", "player_survivors", {"take":true,"keep_inventory_instance_ids":[extra_a,drawn_id]})
	_expect_eq(bad_capacity.code, "CAPACITY_RESULT_INVALID", "overflow requires a valid final inventory of three")
	_expect_eq(host.state.canonical_json(), before_bad_capacity, "invalid capacity selection leaves pending draw unchanged")
	_accept(host, "ResolveSearchItem", "player_survivors", {"take":true,"keep_inventory_instance_ids":[extra_a,extra_b,drawn_id]})
	_expect_eq(host.state.data.survivors[0].inventory_instance_ids.size(), 3, "inventory is capped at three items")
	_expect(drawn_id in host.state.data.survivors[0].inventory_instance_ids, "new item can be retained during capacity trim")
	_expect("starting.marco_medical_kit.01" in host.state.data.items.discard, "discarded old item enters the common item discard")


func _test_discover_noise_and_reveal() -> void:
	var host = _new_host(1401)
	var key_id := _first_instance(host, "discover", "key")
	var amulet_id := _first_instance(host, "discover", "ancient_amulet")
	_remove_value(host.state.data.items.discover_deck, key_id)
	_remove_value(host.state.data.items.discover_deck, amulet_id)
	host.state.data.items.discover_deck.push_front(amulet_id)
	host.state.data.items.discover_deck.push_front(key_id)
	host.state.data.phase = "SURVIVOR_DISCOVER_SELECT"
	_accept(host, "ChooseDiscoverer", "player_survivors", {"survivor_id":"anna_kubrick"})
	_expect_eq(host.state.data.noises_this_round.size(), 2, "both noisy discover cards retain separate internal sources")
	var resolve_result = _accept(host, "ResolveDiscover", "player_survivors", {"keep_card_instance_id":key_id})
	_expect(amulet_id in host.state.data.items.discard, "discarding a noisy discover card does not cancel its draw")
	_expect_eq(host.state.data.revealed_noise_room_ids, ["G1"], "multiple noise sources in one room reveal one marker")
	_expect_eq(host.state.data.noises_this_round, [], "current noise source log clears after reveal")
	var reveal_event := _event_of_type(resolve_result.events, "NoiseRevealed")
	_expect_eq(reveal_event.payload.room_ids, ["G1"], "killer receives the deduplicated room set")
	_expect_eq(host.state.data.phase, "KILLER_FAST", "discover resolution finishes the survivor turn")
	host.state.data.phase = "KILLER_SLOW"
	_accept(host, "EndKillerSlow", "player_killer", {})
	_expect_eq(host.state.data.noises_last_round, ["G1"], "revealed noise is archived for one survivor round")
	_expect_eq(host.state.data.revealed_noise_room_ids, [], "current board noise clears at survivor turn start")

	var single_host = _new_host(1402)
	var single_id := _first_instance(single_host, "discover", "sedatives")
	single_host.state.data.items.discover_deck = [single_id]
	single_host.state.data.phase = "SURVIVOR_DISCOVER_SELECT"
	_accept(single_host, "ChooseDiscoverer", "player_survivors", {"survivor_id":"anna_kubrick"})
	_accept(single_host, "ResolveDiscover", "player_survivors", {"keep_inventory_instance_ids":[single_id]})
	_expect_eq(single_host.state.data.items.discover_deck.size(), 0, "last discover card is drawn alone")
	_expect(single_id in single_host.state.data.survivors[2].inventory_instance_ids, "single remaining discover card is acquired")


func _test_empty_discover_deck() -> void:
	var loss_host = _host_before_discover(1501)
	loss_host.state.data.items.discover_deck.clear()
	var loss_result = _accept(loss_host, "EndActivation", "player_survivors", {"actor_id":"anna_kubrick"})
	_expect_eq(loss_host.state.data.phase, "GAME_OVER", "empty discover deck ends the match when rescue has not started")
	_expect_eq(loss_host.state.data.winner, "killer", "empty discover deck awards killer victory")
	_expect(_has_event(loss_result.events, "MatchEnded"), "deck exhaustion emits MatchEnded")

	var skip_host = _host_before_discover(1502)
	skip_host.state.data.items.discover_deck.clear()
	skip_host.state.data.objectives.rescue_countdown = 5
	_accept(skip_host, "EndActivation", "player_survivors", {"actor_id":"anna_kubrick"})
	_expect_eq(skip_host.state.data.phase, "KILLER_FAST", "empty discover deck is skipped after rescue starts")
	_expect_eq(skip_host.state.data.winner, "", "rescue exception does not end the match")


func _test_radio_and_victory_routes() -> void:
	var radio_host = _new_host(1601)
	radio_host.state.data.survivors[0].room_id = "B4"
	radio_host.state.data.survivors[1].room_id = "B4"
	radio_host.state.data.objectives.radio_progress = 4
	_accept(radio_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(radio_host, "RepairRadio", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(radio_host.state.data.objectives.radio_progress, 5, "fifth repair completes the radio objective")
	_expect_eq(radio_host.state.data.objectives.rescue_countdown, 5, "fifth repair starts rescue countdown at five")
	_expect_eq(radio_host.state.data.noises_this_round[0].source, "radio_repair", "radio repair creates noise")
	_accept(radio_host, "EndActivation", "player_survivors", {"actor_id":"marco_carven"})
	_accept(radio_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"william_hooper"})
	var repeated_repair = _submit(radio_host, "RepairRadio", "player_survivors", {"actor_id":"william_hooper"})
	_expect_eq(repeated_repair.code, "PREREQUISITE_MISSING", "radio progress cannot increase twice in one round")

	var occupied_radio_host = _new_host(1605)
	occupied_radio_host.state.data.survivors[0].room_id = "B4"
	occupied_radio_host.state.data.killer.room_id = "B4"
	_accept(occupied_radio_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var occupied_repair = _submit(occupied_radio_host, "RepairRadio", "player_survivors", {"actor_id":"marco_carven"})
	_expect_eq(occupied_repair.code, "PREREQUISITE_MISSING", "radio repair is rejected while killer shares B4")

	var rescue_host = _new_host(1602)
	rescue_host.state.data.objectives.radio_progress = 5
	rescue_host.state.data.objectives.rescue_countdown = 5
	for expected_countdown in [4, 3, 2, 1, 0]:
		rescue_host.state.data.phase = "KILLER_SLOW"
		_accept(rescue_host, "EndKillerSlow", "player_killer", {})
		_expect_eq(rescue_host.state.data.objectives.rescue_countdown, expected_countdown, "rescue countdown advances at survivor turn start")
	_expect_eq(rescue_host.state.data.winner, "survivors", "countdown zero awards survivor victory")
	_expect_eq(rescue_host.state.data.end_reason, "rescue_arrived", "radio victory records its reason")

	var key_host = _new_host(1603)
	key_host.state.data.items.team_key_instance_ids = _five_key_instances(key_host)
	key_host.state.data.phase = "KILLER_SLOW"
	_accept(key_host, "EndKillerSlow", "player_killer", {})
	_expect_eq(key_host.state.data.winner, "survivors", "five keys and all survivors at G1 win at survivor turn start")
	_expect_eq(key_host.state.data.end_reason, "main_exit_unlocked", "key victory records its reason")

	var delayed_key_host = _new_host(1604)
	delayed_key_host.state.data.items.team_key_instance_ids = _five_key_instances(delayed_key_host)
	_expect_eq(delayed_key_host.state.data.winner, "", "five keys do not win immediately outside survivor turn start")


func _host_before_discover(seed_value: int):
	var host = _new_host(seed_value)
	host.state.data.phase = "SURVIVOR_ACTIVATION"
	host.state.data.active_actor_id = "anna_kubrick"
	host.state.data.acted_survivor_ids = ["marco_carven", "william_hooper"]
	host.state.data.survivors[2].main_action_completed = true
	return host


func _five_key_instances(host) -> Array:
	var result: Array = []
	for instance_id: String in host.state.data.items.item_instances:
		if host.state.data.items.item_instances[instance_id] == "key":
			result.append(instance_id)
			if result.size() == 5:
				break
	return result


func _first_instance(host, deck_name: String, definition_id: String) -> String:
	var deck: Array = host.state.data.items["%s_deck" % deck_name]
	for instance_id: String in deck:
		if host.state.data.items.item_instances[instance_id] == definition_id:
			return instance_id
	return ""


func _take_instance_from_deck(host, deck_name: String, definition_id: String) -> String:
	var instance_id := _first_instance(host, deck_name, definition_id)
	_remove_value(host.state.data.items["%s_deck" % deck_name], instance_id)
	return instance_id


func _move_to_top(deck: Array, value: String) -> void:
	_remove_value(deck, value)
	deck.push_front(value)


func _remove_value(values: Array, value: String) -> void:
	var index := values.find(value)
	if index >= 0:
		values.remove_at(index)


func _new_host(seed_value: int):
	var host = MatchHostScript.new()
	var started = host.start_match(seed_value)
	_expect(started.ok, "host starts for Milestone 1 scenario")
	return host


func _submit(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	command_counter += 1
	var command := GameCommandScript.make(type, "m1-%04d" % command_counter, host.state.data.command_sequence, player_id, payload)
	return host.submit(command)


func _accept(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	var result := _submit(host, type, player_id, payload)
	_expect(result.accepted, "%s should be accepted; code=%s" % [type, result.get("code", "")])
	return result


func _event_of_type(events: Array, type: String) -> Dictionary:
	for event: Dictionary in events:
		if event.type == type:
			return event
	return {}


func _has_event(events: Array, type: String) -> bool:
	return not _event_of_type(events, type).is_empty()


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)


func _expect_eq(actual: Variant, expected: Variant, message: String) -> void:
	assertions += 1
	if actual != expected:
		failures.append("%s; expected=%s actual=%s" % [message, str(expected), str(actual)])
