extends SceneTree

const SeededRngScript = preload("res://core/seeded_rng.gd")
const GameCommandScript = preload("res://core/command.gd")
const MatchHostScript = preload("res://network/match_host.gd")

var failures: Array[String] = []
var assertions = 0


func _initialize() -> void:
	_test_rng()
	_test_map_and_setup()
	_test_round_and_determinism()
	_test_rejections_and_idempotency()
	if failures.is_empty():
		print("Milestone 0 PASS (%d assertions)" % assertions)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("Milestone 0 FAIL (%d failures, %d assertions)" % [failures.size(), assertions])
		quit(1)


func _test_rng() -> void:
	var first = SeededRngScript.new(42)
	var second = SeededRngScript.new(42)
	var a: Array = []
	var b: Array = []
	for index in range(20):
		a.append(first.next_int())
		b.append(second.next_int())
	_expect_eq(a, b, "same seed produces the same RNG sequence")
	var saved_state = first.snapshot()
	var expected_next = first.next_int()
	first.restore(saved_state)
	_expect_eq(first.next_int(), expected_next, "RNG state can be restored")


func _test_map_and_setup() -> void:
	var host = _new_host(101)
	_expect_eq(host.map_graph.room_count(), 15, "laboratory has 15 rooms")
	_expect_eq(host.map_graph.edge_count(), 19, "laboratory has 19 normal edges")
	for edge: Dictionary in host.map_graph.data.edges:
		_expect(host.map_graph.is_adjacent(edge.a, edge.b), "edge works from a to b: %s" % edge.id)
		_expect(host.map_graph.is_adjacent(edge.b, edge.a), "edge works from b to a: %s" % edge.id)
	_expect(not host.map_graph.is_blockable("R2--R3"), "R2--R3 is not blockable")
	_expect(not host.map_graph.is_adjacent("B1", "G1"), "secret passage I is disabled")
	_expect(not host.map_graph.is_adjacent("R2", "B5"), "secret passage II is disabled")
	_expect_eq(host.state.data.phase, "SURVIVOR_CHOOSE_ACTOR", "bootstrap reaches first survivor choice")
	_expect_eq(host.state.data.round_index, 1, "match starts at round 1")
	_expect_eq(host.state.data.map.blocked_edge_ids, ["B1--B4"], "initial laboratory block is placed")
	_expect_eq(host.state.data.map.block_supply_remaining, 6, "initial block consumes one of seven tokens")
	_expect(host.state.data.map.first_aid_cabinet_available, "G3 first aid cabinet is available")
	for survivor: Dictionary in host.state.data.survivors:
		_expect_eq(survivor.room_id, "G1", "%s starts at G1" % survivor.id)
	_expect_eq(host.state.data.killer.room_id, "R1", "Butcher starts at R1")
	_expect_eq(host.state.data.killer.level, 1, "Butcher starts at level 1")
	_expect_eq(host.state.data.killer.base_strength, 5, "Butcher starts at strength 5")
	_expect_eq(host.state.data.killer.hand.size(), 2, "Butcher draws two starting skills")
	_expect_eq(host.state.data.killer.deck.size(), 10, "Butcher has ten skills left in deck")
	_expect_eq(host.state.data.killer.locked_cards.size(), 1, "Brutal Rage starts locked")
	_expect_eq(host.state.data.items.discover_deck.size(), 27, "discover deck has 27 confirmed cards")
	_expect_eq(host.state.data.items.search_deck.size(), 10, "search deck has 10 confirmed cards")
	_expect_eq(host.state.data.items.item_instances[host.state.data.items.search_deck[-1]], "key", "one search key is fixed at the bottom")
	_expect_eq(host.state.data.survivors[0].inventory_instance_ids.size(), 1, "Marco starts with the medical kit")


func _test_round_and_determinism() -> void:
	var first = _run_round(20260911)
	var second = _run_round(20260911)
	_expect_eq(first.state.canonical_json(), second.state.canonical_json(), "same seed and commands produce identical final state")
	_expect_eq(JSON.stringify(first.event_log), JSON.stringify(second.event_log), "same seed and commands produce identical events")
	_expect_eq(first.state.data.round_index, 2, "empty sandbox advances to round 2")
	_expect_eq(first.state.data.phase, "SURVIVOR_CHOOSE_ACTOR", "round ends at next survivor choice")
	_expect_eq(first.state.data.command_sequence, 15, "one sandbox round accepts 15 commands")
	_expect_eq(first.state.data.killer.room_id, "R3", "two killer moves are applied")
	_expect_eq(first.state.data.acted_survivor_ids, [], "acted survivors reset for next round")


func _test_rejections_and_idempotency() -> void:
	var host = _new_host(77)
	var original = host.state.canonical_json()
	var wrong_phase = host.submit(GameCommandScript.make("EndKillerFast", "wrong-phase", 0, "player_killer"))
	_expect(not wrong_phase.accepted, "wrong phase command is rejected")
	_expect_eq(wrong_phase.code, "WRONG_PHASE", "wrong phase uses the specified rejection code")
	_expect_eq(host.state.canonical_json(), original, "rejected command leaves state unchanged")

	var wrong_controller = host.submit(GameCommandScript.make("BeginSurvivorActivation", "wrong-controller", 0, "player_killer", {"survivor_id":"marco_carven"}))
	_expect_eq(wrong_controller.code, "NOT_CONTROLLER", "controller validation is enforced")
	_expect_eq(host.state.data.command_sequence, 0, "rejection does not consume command sequence")

	var accepted_command = GameCommandScript.make("BeginSurvivorActivation", "once", 0, "player_survivors", {"survivor_id":"marco_carven"})
	var first_result = host.submit(accepted_command)
	var after_first = host.state.canonical_json()
	var duplicate_result = host.submit(accepted_command)
	_expect(first_result.accepted and duplicate_result.accepted, "duplicate accepted command returns its stored result")
	_expect_eq(host.state.data.command_sequence, 1, "duplicate command is applied exactly once")
	_expect_eq(host.state.canonical_json(), after_first, "duplicate command does not mutate state")

	var stale = host.submit(GameCommandScript.make("Calm", "stale", 0, "player_survivors", {"actor_id":"marco_carven"}))
	_expect_eq(stale.code, "STALE_STATE", "stale sequence is rejected")
	_expect_eq(host.state.data.command_sequence, 1, "stale command does not consume sequence")


func _run_round(seed_value: int):
	var host = _new_host(seed_value)
	var command_number = 1
	for survivor_id in ["marco_carven", "william_hooper", "anna_kubrick"]:
		_accept(host, GameCommandScript.make("BeginSurvivorActivation", "test-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"survivor_id":survivor_id}))
		command_number += 1
		_accept(host, GameCommandScript.make("Calm", "test-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"actor_id":survivor_id}))
		command_number += 1
		_accept(host, GameCommandScript.make("EndActivation", "test-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"actor_id":survivor_id}))
		command_number += 1
	_accept(host, GameCommandScript.make("ChooseDiscoverer", "test-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"survivor_id":"anna_kubrick"}))
	command_number += 1
	var drawn: Array = host.state.data.items.pending_private_draw.card_instance_ids
	_accept(host, GameCommandScript.make("ResolveDiscover", "test-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"keep_card_instance_id":drawn[0]}))
	command_number += 1
	_accept(host, GameCommandScript.make("EndKillerFast", "test-%02d" % command_number, host.state.data.command_sequence, "player_killer"))
	command_number += 1
	_accept(host, GameCommandScript.make("KillerMove", "test-%02d" % command_number, host.state.data.command_sequence, "player_killer", {"target_room_id":"R2"}))
	command_number += 1
	_accept(host, GameCommandScript.make("KillerMove", "test-%02d" % command_number, host.state.data.command_sequence, "player_killer", {"target_room_id":"R3"}))
	command_number += 1
	_accept(host, GameCommandScript.make("EndKillerSlow", "test-%02d" % command_number, host.state.data.command_sequence, "player_killer"))
	return host


func _new_host(seed_value: int):
	var host = MatchHostScript.new()
	var result = host.start_match(seed_value)
	_expect(result.ok, "host starts successfully")
	return host


func _accept(host, command: Dictionary) -> void:
	var result = host.submit(command)
	_expect(result.accepted, "%s is accepted (%s)" % [command.type, result.get("code", "")])


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)


func _expect_eq(actual: Variant, expected: Variant, message: String) -> void:
	assertions += 1
	if actual != expected:
		failures.append("%s; expected=%s actual=%s" % [message, str(expected), str(actual)])
