extends SceneTree

const GameCommandScript = preload("res://core/command.gd")
const MatchHostScript = preload("res://network/match_host.gd")

var failures: Array[String] = []
var assertions := 0
var command_number := 0


func _initialize() -> void:
	_test_killer_content_and_standard_actions()
	_test_public_inference_and_search_hit()
	_test_fast_skills()
	_test_block_skills_and_supply()
	_test_main_skills()
	_test_draw_upgrade_and_strength_cleanup()
	_test_level_three_unlock_overflow()
	_test_max_level_recycle()
	_test_upgrade_determinism()
	_test_view_projection_and_reappear()
	if failures.is_empty():
		print("Milestone 2 PASS (%d assertions)" % assertions)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("Milestone 2 FAIL (%d failures, %d assertions)" % [failures.size(), assertions])
		quit(1)


func _test_killer_content_and_standard_actions() -> void:
	var host = _new_host(201)
	_expect_eq(host.state.data.killer.definitions.size(), 7, "Butcher has seven skill definitions")
	_expect_eq(host.state.data.killer.hand_limit, 5, "killer hand limit is five")
	_expect_eq(host.state.data.killer.max_level, 5, "Butcher level cap is five")
	_expect_eq(host.state.data.killer.effective_strength, 5, "effective strength starts at five")
	_expect_eq(_all_regular_skill_instances(host).size(), 12, "Butcher starts with twelve regular skill cards")
	_expect_eq(host.state.data.killer.locked_cards.size(), 1, "Brutal Rage is the thirteenth locked card")
	for instance_id: String in host.state.data.killer.skill_instances:
		_expect(host.state.data.killer.definitions.has(host.state.data.killer.skill_instances[instance_id]), "every killer card instance has a definition")

	host.state.data.phase = "KILLER_FAST"
	_accept(host, "EndKillerFast", "player_killer", {})
	_expect_eq(host.state.data.phase, "KILLER_MAIN", "ending fast skills enters main phase")
	_expect_eq(host.state.data.killer.main_actions_remaining, 2, "standard route starts with two actions")
	_accept(host, "KillerSearch", "player_killer", {})
	_expect_eq(host.state.data.phase, "KILLER_MAIN", "a missed first search keeps the main phase")
	_expect_eq(host.state.data.killer.main_actions_remaining, 1, "a missed search consumes one action")
	_expect(not _event_of_type(host.event_log, "KillerSearched").is_empty(), "search emits a public result")
	_accept(host, "KillerMove", "player_killer", {"target_room_id":"R2"})
	_expect_eq(host.state.data.phase, "KILLER_SLOW", "two standard actions enter slow phase")
	_expect_eq(host.state.data.killer.room_id, "R2", "normal killer movement changes rooms")

	var blocked_host = _new_host(202)
	blocked_host.state.data.phase = "KILLER_MAIN"
	blocked_host.state.data.killer.main_actions_remaining = 2
	blocked_host.state.data.killer.room_id = "B1"
	var supply_before: int = blocked_host.state.data.map.block_supply_remaining
	_accept(blocked_host, "KillerMove", "player_killer", {"target_room_id":"B4"})
	_expect("B1--B4" not in blocked_host.state.data.map.blocked_edge_ids, "normal killer movement removes a crossed block")
	_expect_eq(blocked_host.state.data.map.block_supply_remaining, supply_before + 1, "removed block returns to supply")

	var mode_host = _new_host(203)
	mode_host.state.data.phase = "KILLER_MAIN"
	mode_host.state.data.killer.main_actions_remaining = 2
	_accept(mode_host, "KillerSearch", "player_killer", {})
	var chainsaw_id := _skill_instance(mode_host, "revving_chainsaw")
	_set_killer_hand(mode_host, [chainsaw_id])
	var rejected := _submit(mode_host, "UseKillerSkill", "player_killer", {"card_instance_id":chainsaw_id,"path_room_ids":[]})
	_expect(not rejected.accepted, "a main skill cannot replace actions after the standard route starts")
	_expect_eq(rejected.code, "PREREQUISITE_MISSING", "mixed main routes use the prerequisite rejection")


func _test_public_inference_and_search_hit() -> void:
	var host = _new_host(210)
	host.state.data.phase = "KILLER_FAST"
	host.state.data.revealed_noise_room_ids = ["R4"]
	host.state.data.survivors[0].room_id = "R4"
	var killer_view: Dictionary = host.view_for_side("killer")
	_expect_eq(killer_view.revealed_noise_room_ids, ["R4"], "killer receives the revealed noise clue")
	_expect(not killer_view.survivors[0].has("room_id"), "killer clue view still hides survivor positions")
	_accept(host, "EndKillerFast", "player_killer", {})
	_accept(host, "KillerMove", "player_killer", {"target_room_id":"R4"})
	var search := _accept(host, "KillerSearch", "player_killer", {})
	_expect_eq(host.state.data.phase, "ENCOUNTER_START", "searching the inferred room starts an encounter")
	_expect_eq(host.state.data.encounter.survivor_ids, ["marco_carven"], "search reveals only survivors in the searched room")
	_expect_eq(host.state.data.return_phase, "KILLER_DRAW", "encounter will end the killer turn through draw")
	var encounter_event := _event_of_type(search.events, "EncounterStarted")
	_expect_eq(encounter_event.payload.room_id, "R4", "encounter event identifies the searched room")


func _test_fast_skills() -> void:
	var pursue_host = _new_host(220)
	pursue_host.state.data.phase = "KILLER_FAST"
	pursue_host.state.data.map.blocked_edge_ids = ["R1--R2"]
	pursue_host.state.data.map.block_supply_remaining = 6
	var pursue_id := _skill_instance(pursue_host, "pursue")
	_set_killer_hand(pursue_host, [pursue_id])
	_accept(pursue_host, "UseKillerSkill", "player_killer", {"card_instance_id":pursue_id,"path_room_ids":["R2"]})
	_expect_eq(pursue_host.state.data.killer.room_id, "R2", "Pursue moves one room during the fast phase")
	_expect("R1--R2" not in pursue_host.state.data.map.blocked_edge_ids, "Pursue removes a crossed block as normal movement")
	_expect_eq(pursue_host.state.data.phase, "KILLER_FAST", "fast skill returns to the fast phase")
	_expect(pursue_id in pursue_host.state.data.killer.discard, "played Pursue enters the discard pile")

	var sense_host = _new_host(221)
	sense_host.state.data.phase = "KILLER_FAST"
	sense_host.state.data.survivors[0].room_id = "R2"
	sense_host.state.data.survivors[1].room_id = "G1"
	sense_host.state.data.survivors[2].room_id = "R4"
	var sense_id := _skill_instance(sense_host, "sense")
	_set_killer_hand(sense_host, [sense_id])
	var sensed := _accept(sense_host, "UseKillerSkill", "player_killer", {"card_instance_id":sense_id,"region":"R"})
	var sense_event := _event_of_type(sensed.events, "SenseResolved")
	_expect_eq(sense_event.payload.survivor_ids, ["marco_carven"], "Sense reports the region while Anna's Low Profile excludes her")
	_expect_eq(sense_event.payload.region, "R", "Sense reports the selected region")

	var madness_host = _new_host(222)
	madness_host.state.data.phase = "KILLER_FAST"
	var madness_id := _skill_instance(madness_host, "madness")
	_set_killer_hand(madness_host, [madness_id])
	_accept(madness_host, "UseKillerSkill", "player_killer", {"card_instance_id":madness_id,"edge_id":"R1--R2"})
	_expect("R1--R2" in madness_host.state.data.map.blocked_edge_ids, "Madness places one block")
	_expect_eq(madness_host.state.data.killer.effective_strength, 7, "Madness adds two strength for the turn")
	_expect_eq(madness_host.state.data.killer.temporary_modifiers.size(), 1, "Madness records a temporary modifier")


func _test_block_skills_and_supply() -> void:
	var repeat_host = _new_host(230)
	repeat_host.state.data.phase = "KILLER_SLOW"
	repeat_host.state.data.killer.room_id = "R1"
	repeat_host.state.data.map.blocked_edge_ids = ["R1--R2"]
	repeat_host.state.data.map.block_supply_remaining = 6
	var barricade_id := _skill_instance(repeat_host, "barricade")
	_set_killer_hand(repeat_host, [barricade_id])
	_accept(repeat_host, "UseKillerSkill", "player_killer", {"card_instance_id":barricade_id,"edge_id":"R1--R2"})
	_expect_eq(repeat_host.state.data.map.blocked_edge_ids.count("R1--R2"), 1, "blocking an already blocked door does not stack")
	_expect_eq(repeat_host.state.data.map.block_supply_remaining, 6, "repeated block placement consumes no token")

	var migration_host = _new_host(231)
	migration_host.state.data.phase = "KILLER_FAST"
	migration_host.state.data.map.blocked_edge_ids = ["R1--R2","R1--R4","R4--R5","B1--B2","B1--B3","B2--B3","B3--G2"]
	migration_host.state.data.map.block_supply_remaining = 0
	var madness_id := _skill_instance(migration_host, "madness")
	_set_killer_hand(migration_host, [madness_id])
	var before_migration: String = migration_host.state.canonical_json()
	var missing_relocation := _submit(migration_host, "UseKillerSkill", "player_killer", {"card_instance_id":madness_id,"edge_id":"G1--G3"})
	_expect_eq(missing_relocation.code, "RESOURCE_MISSING", "an eighth block requires an explicit relocation")
	_expect_eq(migration_host.state.canonical_json(), before_migration, "failed block migration is atomic")
	_accept(migration_host, "UseKillerSkill", "player_killer", {"card_instance_id":madness_id,"edge_id":"G1--G3","relocate_edge_id":"R1--R2"})
	_expect("R1--R2" not in migration_host.state.data.map.blocked_edge_ids, "eighth block relocates the selected old token")
	_expect("G1--G3" in migration_host.state.data.map.blocked_edge_ids, "relocated token is placed on the new door")
	_expect_eq(migration_host.state.data.map.blocked_edge_ids.size(), 7, "block count never exceeds seven")
	_expect_eq(migration_host.state.data.map.block_supply_remaining, 0, "migration leaves an empty supply")

	var stay_host = _new_host(232)
	stay_host.state.data.phase = "KILLER_SLOW"
	stay_host.state.data.killer.room_id = "R1"
	stay_host.state.data.map.blocked_edge_ids = []
	stay_host.state.data.map.block_supply_remaining = 7
	var stay_id := _skill_instance(stay_host, "stayyyy")
	var costs := _other_regular_instances(stay_host, stay_id, 4)
	var stay_hand: Array = [stay_id]
	stay_hand.append_array(costs)
	_set_killer_hand(stay_host, stay_hand)
	var bad_cost := _submit(stay_host, "UseKillerSkill", "player_killer", {"card_instance_id":stay_id,"cost_card_instance_ids":costs.slice(0, 3)})
	_expect(not bad_cost.accepted, "STAYYYY rejects fewer than four extra hand cards")
	var stay_result := _accept(stay_host, "UseKillerSkill", "player_killer", {"card_instance_id":stay_id,"cost_card_instance_ids":costs})
	_expect("R1--R2" in stay_host.state.data.map.blocked_edge_ids, "STAYYYY blocks the first white door in the room")
	_expect("R1--R4" in stay_host.state.data.map.blocked_edge_ids, "STAYYYY blocks every white door in the room")
	_expect_eq(stay_host.state.data.map.block_supply_remaining, 5, "STAYYYY consumes one token per newly blocked door")
	_expect(not _has_event(stay_host.events_for_side(stay_result.events, "survivors"), "SkillCostPaid"), "skill cost identities stay hidden from survivors")
	_expect(_has_event(stay_host.events_for_side(stay_result.events, "killer"), "SkillCostPaid"), "killer receives private skill cost events")

	var white_door_host = _new_host(233)
	white_door_host.state.data.phase = "KILLER_FAST"
	var white_door_madness := _skill_instance(white_door_host, "madness")
	_set_killer_hand(white_door_host, [white_door_madness])
	var open_edge := _submit(white_door_host, "UseKillerSkill", "player_killer", {"card_instance_id":white_door_madness,"edge_id":"R2--R3"})
	_expect_eq(open_edge.code, "TARGET_ILLEGAL", "open passages cannot receive block tokens")


func _test_main_skills() -> void:
	var chainsaw_host = _new_host(240)
	chainsaw_host.state.data.phase = "KILLER_MAIN"
	chainsaw_host.state.data.killer.main_actions_remaining = 2
	chainsaw_host.state.data.survivors[0].room_id = "R1"
	chainsaw_host.state.data.survivors[0].fear = 2
	chainsaw_host.state.data.survivors[1].room_id = "R2"
	chainsaw_host.state.data.survivors[2].room_id = "G1"
	var chainsaw_id := _skill_instance(chainsaw_host, "revving_chainsaw")
	_set_killer_hand(chainsaw_host, [chainsaw_id])
	var chainsaw := _accept(chainsaw_host, "UseKillerSkill", "player_killer", {"card_instance_id":chainsaw_id,"path_room_ids":["R2"]})
	_expect_eq(chainsaw_host.state.data.survivors[0].fear, 2, "fear overflow does not increase fear beyond two")
	_expect(_has_event(chainsaw.events, "NoiseRevealed"), "fear overflow creates immediate public noise")
	_expect("R1" in chainsaw_host.view_for_side("killer").revealed_noise_room_ids, "immediate fear noise persists in the killer state projection")
	_expect_eq(chainsaw_host.state.data.survivors[1].fear, 1, "chainsaw gives fear within distance one before moving")
	_expect_eq(chainsaw_host.state.data.survivors[1].health, "injured", "chainsaw damages survivors in the final room")
	_expect_eq(chainsaw_host.state.data.phase, "KILLER_SLOW", "level-one chainsaw consumes the main choice")

	var early_host = _new_host(241)
	early_host.state.data.phase = "KILLER_FAST"
	early_host.state.data.killer.level = 3
	var early_chainsaw := _skill_instance(early_host, "revving_chainsaw")
	_set_killer_hand(early_host, [early_chainsaw])
	var early_reject := _submit(early_host, "UseKillerSkill", "player_killer", {"card_instance_id":early_chainsaw,"path_room_ids":[]})
	_expect_eq(early_reject.code, "WRONG_PHASE", "chainsaw is not fast before level four")
	early_host.state.data.killer.level = 4
	_accept(early_host, "UseKillerSkill", "player_killer", {"card_instance_id":early_chainsaw,"path_room_ids":[]})
	_expect_eq(early_host.state.data.phase, "KILLER_FAST", "chainsaw becomes a fast skill at level four")

	var rage_host = _new_host(242)
	rage_host.state.data.phase = "KILLER_MAIN"
	rage_host.state.data.killer.main_actions_remaining = 2
	rage_host.state.data.map.blocked_edge_ids = ["R1--R2"]
	rage_host.state.data.map.block_supply_remaining = 6
	rage_host.state.data.survivors[0].room_id = "R3"
	var rage_id := _skill_instance(rage_host, "brutal_rage")
	var rage_cost := _other_regular_instances(rage_host, rage_id, 1)
	_set_killer_hand(rage_host, [rage_id, rage_cost[0]])
	_accept(rage_host, "UseKillerSkill", "player_killer", {"card_instance_id":rage_id,"cost_card_instance_ids":rage_cost,"path_segments":[["R2"],["R3"]]})
	_expect_eq(rage_host.state.data.phase, "ENCOUNTER_START", "Brutal Rage repeats after breaking a block and stops on a search hit")
	_expect_eq(rage_host.state.data.killer.room_id, "R3", "Brutal Rage applies its movement segments in order")
	_expect("R1--R2" not in rage_host.state.data.map.blocked_edge_ids, "Brutal Rage removes a crossed block")

	var invalid_rage_host = _new_host(243)
	invalid_rage_host.state.data.phase = "KILLER_MAIN"
	invalid_rage_host.state.data.killer.main_actions_remaining = 2
	invalid_rage_host.state.data.map.blocked_edge_ids = []
	var invalid_rage_id := _skill_instance(invalid_rage_host, "brutal_rage")
	var invalid_cost := _other_regular_instances(invalid_rage_host, invalid_rage_id, 1)
	_set_killer_hand(invalid_rage_host, [invalid_rage_id, invalid_cost[0]])
	var before: String = invalid_rage_host.state.canonical_json()
	var invalid_rage := _submit(invalid_rage_host, "UseKillerSkill", "player_killer", {"card_instance_id":invalid_rage_id,"cost_card_instance_ids":invalid_cost,"path_segments":[["R2"],["R3"]]})
	_expect(not invalid_rage.accepted, "Brutal Rage cannot repeat when the preceding move removed no block")
	_expect_eq(invalid_rage_host.state.canonical_json(), before, "rejected Brutal Rage is atomic")


func _test_draw_upgrade_and_strength_cleanup() -> void:
	var host = _new_host(250)
	var regular := _all_regular_skill_instances(host)
	host.state.data.phase = "KILLER_SLOW"
	host.state.data.killer.level = 1
	host.state.data.killer.base_strength = 5
	host.state.data.killer.temporary_modifiers = [{"definition_id":"madness","amount":2}]
	host.state.data.killer.effective_strength = 7
	host.state.data.killer.hand = regular.slice(0, 5)
	var original_hand: Array = host.state.data.killer.hand.duplicate()
	host.state.data.killer.deck = [regular[5]]
	host.state.data.killer.discard = regular.slice(6)
	var result := _accept(host, "EndKillerSlow", "player_killer", {})
	_expect_eq(host.state.data.killer.level, 2, "empty deck upgrades Butcher before continuing the draw")
	_expect_eq(host.state.data.killer.base_strength, 6, "level two permanently raises base strength")
	_expect_eq(host.state.data.killer.effective_strength, 6, "turn end removes Madness while retaining level-two strength")
	_expect_eq(host.state.data.killer.temporary_modifiers, [], "temporary strength is cleared at turn end")
	_expect_eq(host.state.data.killer.hand, original_hand, "full-hand draws discard new cards instead of old hand cards")
	_expect_eq(host.state.data.round_index, 2, "completed killer draw enters the next round")
	_expect_eq(host.state.data.phase, "SURVIVOR_CHOOSE_ACTOR", "draw completion reaches the survivor choice")
	_expect(_has_event(result.events, "KillerLeveled"), "upgrade emits the public level event")
	_expect_eq(_regular_card_count(host), 12, "upgrade and recycle preserve all twelve regular cards")


func _test_level_three_unlock_overflow() -> void:
	var host = _new_host(260)
	var regular := _all_regular_skill_instances(host)
	host.state.data.phase = "KILLER_SLOW"
	host.state.data.killer.level = 2
	host.state.data.killer.base_strength = 6
	host.state.data.killer.effective_strength = 6
	host.state.data.killer.hand = regular.slice(0, 5)
	host.state.data.killer.deck = []
	host.state.data.killer.discard = regular.slice(5)
	_accept(host, "EndKillerSlow", "player_killer", {})
	_expect_eq(host.state.data.phase, "KILLER_UNLOCK_DISCARD", "level-three overflow pauses the draw for a hand choice")
	_expect_eq(host.state.data.killer.level, 3, "deck exhaustion advances to level three")
	_expect_eq(host.state.data.killer.hand.size(), 6, "Brutal Rage enters the full hand before trimming")
	var unlocked_id: String = host.state.data.killer.pending_unlock_discard.unlocked_card_instance_id
	_expect_eq(host.state.data.killer.skill_instances[unlocked_id], "brutal_rage", "the level-three card is Brutal Rage")
	var invalid := _submit(host, "ResolveKillerUnlockOverflow", "player_killer", {"discard_card_instance_id":unlocked_id})
	_expect_eq(invalid.code, "TARGET_ILLEGAL", "the newly unlocked card cannot pay its own overflow")
	var old_hand_id: String = host.state.data.killer.pending_unlock_discard.eligible_discard_instance_ids[0]
	_accept(host, "ResolveKillerUnlockOverflow", "player_killer", {"discard_card_instance_id":old_hand_id})
	_expect_eq(host.state.data.phase, "SURVIVOR_CHOOSE_ACTOR", "overflow choice resumes and completes the pending draw")
	_expect_eq(host.state.data.killer.hand.size(), 5, "unlock resolution restores the five-card limit")
	_expect(unlocked_id in host.state.data.killer.hand, "Brutal Rage remains in hand after overflow resolution")
	_expect_eq(host.state.data.killer.locked_cards, [], "Brutal Rage leaves the locked area")
	_expect_eq(_all_killer_card_count(host), 13, "unlock and continued draw preserve all thirteen skill cards")


func _test_max_level_recycle() -> void:
	var host = _new_host(265)
	var regular := _all_regular_skill_instances(host)
	host.state.data.phase = "KILLER_SLOW"
	host.state.data.killer.level = 5
	host.state.data.killer.base_strength = 6
	host.state.data.killer.effective_strength = 6
	host.state.data.killer.hand = regular.slice(0, 5)
	host.state.data.killer.deck = []
	host.state.data.killer.discard = regular.slice(5)
	var result := _accept(host, "EndKillerSlow", "player_killer", {})
	_expect_eq(host.state.data.killer.level, 5, "recycling at maximum level does not advance past five")
	_expect(not _has_event(result.events, "KillerLeveled"), "maximum-level recycling emits no false level event")
	_expect_eq(_regular_card_count(host), 12, "maximum-level recycling preserves the regular deck")
	_expect_eq(host.state.data.phase, "SURVIVOR_CHOOSE_ACTOR", "maximum-level recycling still completes the turn")


func _test_upgrade_determinism() -> void:
	var first = _upgrade_fixture(266)
	var second = _upgrade_fixture(266)
	_expect_eq(first.state.data.killer.deck, second.state.data.killer.deck, "same seed produces the same recycled killer deck")
	_expect_eq(first.state.data.killer.discard, second.state.data.killer.discard, "same seed produces the same full-hand draw discards")
	_expect_eq(first.state.data.rng_state, second.state.data.rng_state, "killer deck rebuild advances RNG deterministically")


func _test_view_projection_and_reappear() -> void:
	var host = _new_host(270)
	host.state.data.killer.is_stealthed = true
	host.state.data.survivors[0].room_id = "B4"
	host.state.data.survivors[0].fear = 2
	host.state.data.objectives.radio_progress = 3
	host.state.data.noises_this_round = [{"room_id":"B4","source":"radio_repair","immediate":false}]
	host.state.data.revealed_noise_room_ids = ["R4"]
	var survivor_view: Dictionary = host.view_for_side("survivors")
	var killer_view: Dictionary = host.view_for_side("killer")
	_expect_eq(survivor_view.survivors[0].room_id, "B4", "survivor view retains exact survivor locations")
	_expect(not survivor_view.killer.has("room_id"), "survivor view hides a stealthed killer location")
	_expect(not survivor_view.killer.has("hand"), "survivor view hides the killer hand")
	_expect(not survivor_view.has("rng_state"), "projected views never expose RNG state")
	_expect(not survivor_view.items.has("discover_deck"), "survivor view exposes deck counts instead of future order")
	_expect(not killer_view.survivors[0].has("room_id"), "killer view strips survivor positions")
	_expect(not killer_view.survivors[0].has("fear"), "killer view strips survivor fear")
	_expect(not killer_view.survivors[0].has("inventory_instance_ids"), "killer view strips survivor inventory")
	_expect(not killer_view.objectives.has("radio_progress"), "killer view strips radio progress")
	_expect(not killer_view.objectives.has("rescue_countdown"), "killer view hides countdown before rescue starts")
	_expect(not killer_view.has("noises_this_round"), "killer view hides unrevealed current noise")
	_expect_eq(killer_view.revealed_noise_room_ids, ["R4"], "killer view includes only revealed current noise")
	_expect(not killer_view.map.has("first_aid_cabinet_available"), "killer view hides first-aid cabinet use")
	_expect(not killer_view.killer.has("deck"), "killer receives deck count without future deck order")
	_expect(killer_view.killer.has("hand"), "killer retains its private hand")
	host.state.data.objectives.rescue_countdown = 4
	killer_view = host.view_for_side("killer")
	_expect_eq(killer_view.objectives.rescue_countdown, 4, "rescue countdown becomes public after rescue starts")

	var sample_events := [
		{"type":"PrivateSurvivor","audience":"survivors","payload":{}},
		{"type":"PrivateKiller","audience":"killer","payload":{}},
		{"type":"Public","audience":"all","payload":{}},
	]
	_expect_eq(host.events_for_side(sample_events, "survivors").size(), 2, "survivor event projection filters killer-private events")
	_expect_eq(host.events_for_side(sample_events, "killer").size(), 2, "killer event projection filters survivor-private events")

	host.state.data.phase = "SURVIVOR_REVEAL_NOISE"
	host.state.data.killer.room_id = "R1"
	for survivor: Dictionary in host.state.data.survivors:
		survivor.room_id = "G1"
	var reappear_events: Array = []
	host.rule_engine._enter_killer_turn(host.state.data, reappear_events)
	_expect(not host.state.data.killer.is_stealthed, "reappear clears stealth")
	_expect_eq(host.state.data.phase, "KILLER_FAST", "missed free reappear search continues to fast skills")
	_expect(_has_event(reappear_events, "KillerReappeared"), "reappear publishes the killer room")
	_expect(_has_event(reappear_events, "KillerSearched"), "reappear performs the original free search")


func _new_host(seed_value: int):
	var host = MatchHostScript.new()
	var result = host.start_match(seed_value)
	_expect(result.ok, "host starts successfully")
	return host


func _upgrade_fixture(seed_value: int):
	var host = _new_host(seed_value)
	var regular := _all_regular_skill_instances(host)
	host.state.data.phase = "KILLER_SLOW"
	host.state.data.killer.hand = regular.slice(0, 5)
	host.state.data.killer.deck = []
	host.state.data.killer.discard = regular.slice(5)
	_accept(host, "EndKillerSlow", "player_killer", {})
	return host


func _submit(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	command_number += 1
	return host.submit(GameCommandScript.make(type, "m2-%04d" % command_number, host.state.data.command_sequence, player_id, payload))


func _accept(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	var result := _submit(host, type, player_id, payload)
	_expect(result.accepted, "%s is accepted (%s: %s)" % [type, result.get("code", ""), result.get("message", "")])
	return result


func _skill_instance(host, definition_id: String) -> String:
	var instance_ids: Array = host.state.data.killer.skill_instances.keys()
	instance_ids.sort()
	for instance_id: String in instance_ids:
		if host.state.data.killer.skill_instances[instance_id] == definition_id:
			return instance_id
	return ""


func _all_regular_skill_instances(host) -> Array:
	var result: Array = []
	for instance_id: String in host.state.data.killer.skill_instances:
		if not instance_id.begins_with("killer_locked."):
			result.append(instance_id)
	result.sort()
	return result


func _other_regular_instances(host, excluded_id: String, count: int) -> Array:
	var result: Array = []
	for instance_id: String in _all_regular_skill_instances(host):
		if instance_id != excluded_id:
			result.append(instance_id)
			if result.size() == count:
				break
	return result


func _set_killer_hand(host, instance_ids: Array) -> void:
	for instance_id: String in instance_ids:
		host.state.data.killer.deck.erase(instance_id)
		host.state.data.killer.discard.erase(instance_id)
		host.state.data.killer.locked_cards.erase(instance_id)
	host.state.data.killer.hand = instance_ids.duplicate()


func _regular_card_count(host) -> int:
	var count := 0
	for zone: Array in [host.state.data.killer.hand, host.state.data.killer.deck, host.state.data.killer.discard]:
		for instance_id: String in zone:
			if not instance_id.begins_with("killer_locked."):
				count += 1
	return count


func _all_killer_card_count(host) -> int:
	return host.state.data.killer.hand.size() + host.state.data.killer.deck.size() + host.state.data.killer.discard.size() + host.state.data.killer.locked_cards.size()


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
