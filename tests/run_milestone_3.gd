extends SceneTree

const GameCommandScript = preload("res://core/command.gd")
const MatchHostScript = preload("res://network/match_host.gd")

var failures: Array[String] = []
var assertions := 0
var command_number := 0


func _initialize() -> void:
	_test_encounter_entry_and_single_failure()
	_test_multiple_defenders_trap_and_flee()
	_test_defense_items_and_character_bonus()
	_test_repelling_discard_and_upgrade_resume()
	_test_level_five_amulet_and_healing()
	_test_view_projection_during_interrupts()
	_test_encounter_determinism()
	_test_command_only_match_reaches_game_over()
	if failures.is_empty():
		print("Milestone 3 PASS (%d assertions)" % assertions)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("Milestone 3 FAIL (%d failures, %d assertions)" % [failures.size(), assertions])
		quit(1)


func _test_encounter_entry_and_single_failure() -> void:
	var host = _encounter_host(301, ["marco_carven"], 99)
	_expect_eq(host.state.data.phase, "ENCOUNTER_ATTACK_SKILL", "search enters the attack-skill choice")
	_expect_eq(host.state.data.encounter.attack_index, 0, "new encounter starts before its first attack")
	_expect_eq(host.state.data.encounter.attacked_survivor_ids, [], "new encounter has no attacked survivors")
	_expect_eq(host.state.data.killer.main_actions_remaining, 0, "encounter cancels remaining standard actions")
	_expect(not host.state.data.encounter.id.is_empty(), "encounter receives a stable runtime id")

	var wrong_side := _submit(host, "PassAttackSkill", "player_survivors", {})
	_expect_eq(wrong_side.code, "NOT_CONTROLLER", "survivors cannot make the killer attack-card choice")
	var ordinary_skill_id: String = host.state.data.killer.hand[0]
	var before_bad_skill: String = host.state.canonical_json()
	var bad_skill := _submit(host, "SelectAttackSkill", "player_killer", {"card_instance_id":ordinary_skill_id})
	_expect_eq(bad_skill.code, "TARGET_ILLEGAL", "non-attack Butcher cards cannot be played in the attack window")
	_expect_eq(host.state.canonical_json(), before_bad_skill, "rejected attack-skill selection is atomic")

	_accept(host, "PassAttackSkill", "player_killer", {})
	_expect_eq(host.state.data.phase, "ENCOUNTER_DEFENDER", "passing the attack skill reaches defender choice")
	var bad_defender := _submit(host, "SelectDefender", "player_survivors", {"survivor_id":"william_hooper"})
	_expect_eq(bad_defender.code, "TARGET_ILLEGAL", "only encounter participants may defend")
	_accept(host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	_expect_eq(host.state.data.phase, "ENCOUNTER_ITEM", "defender choice reaches item commitment")
	var roll := _accept(host, "PassDefenseItem", "player_survivors", {})
	var defense_event := _event_of_type(roll.events, "DefenseRolled")
	_expect_eq(defense_event.payload.dice_count, 4, "zero fear rolls four defense dice")
	_expect(not defense_event.payload.success, "strength 99 forces the fixture defense to fail")
	_expect_eq(host.state.data.survivors[0].health, "injured", "first failed defense causes injury")
	_expect_eq(host.state.data.phase, "ENCOUNTER_FLEE", "last participant failure reaches flee choice")

	var finish := _accept(host, "ConfirmFlee", "player_survivors", {"survivor_id":"marco_carven","path_room_ids":[]})
	_expect(_has_event(finish.events, "EncounterEnded"), "final flee choice ends the encounter")
	_expect_eq(host.state.data.encounter, {}, "encounter state clears after every living participant confirms")
	_expect_eq(host.state.data.phase, "SURVIVOR_CHOOSE_ACTOR", "encounter ends through killer draw into the next round")
	_expect_eq(host.state.data.round_index, 2, "completed encounter ends the killer turn")


func _test_multiple_defenders_trap_and_flee() -> void:
	var host = _encounter_host(310, ["marco_carven", "william_hooper"], 99)
	host.state.data.map.trap_room_id = "R1"
	_accept(host, "PassAttackSkill", "player_killer", {})
	_accept(host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	var first_roll := _accept(host, "PassDefenseItem", "player_survivors", {})
	var first_defense := _event_of_type(first_roll.events, "DefenseRolled")
	_expect_eq(first_defense.payload.trap_bonus, 2, "trap adds two after the first encounter roll")
	_expect(_event_index(first_roll.events, "DefenseDiceRolled") < _event_index(first_roll.events, "TrapTriggered"), "trap reveals only after dice are rolled")
	_expect(_event_index(first_roll.events, "TrapTriggered") < _event_index(first_roll.events, "DefenseRolled"), "final defense result follows trap resolution")
	_expect(_has_event(first_roll.events, "TrapTriggered"), "first roll publishes trap consumption")
	_expect_eq(host.state.data.map.trap_room_id, "", "triggered trap is removed")
	_expect_eq(host.state.data.phase, "ENCOUNTER_ATTACK_SKILL", "failed defense with another participant starts a new attack")

	_accept(host, "PassAttackSkill", "player_killer", {})
	var repeated := _submit(host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	_expect_eq(repeated.code, "TARGET_ILLEGAL", "a participant cannot defend twice in one encounter")
	host.state.data.survivors[1].fear = 2
	_accept(host, "SelectDefender", "player_survivors", {"survivor_id":"william_hooper"})
	var second_roll := _accept(host, "PassDefenseItem", "player_survivors", {})
	var second_defense := _event_of_type(second_roll.events, "DefenseRolled")
	_expect_eq(second_defense.payload.dice_count, 2, "two fear removes two defense dice")
	_expect_eq(second_defense.payload.trap_bonus, 0, "trap applies only to the first attack")
	_expect_eq(second_defense.payload.character_bonus, 1, "William gets Persistence when he uses no weapon")
	_expect_eq(host.state.data.encounter.attacked_survivor_ids, ["marco_carven", "william_hooper"], "attacks preserve encounter order")
	_expect_eq(host.state.data.phase, "ENCOUNTER_FLEE", "all attacked survivors move to flee resolution")

	host.state.data.map.blocked_edge_ids.append("R1--R2")
	var before_blocked: String = host.state.canonical_json()
	var blocked := _submit(host, "ConfirmFlee", "player_survivors", {"survivor_id":"marco_carven","path_room_ids":["R2"]})
	_expect_eq(blocked.code, "PATH_ILLEGAL", "flee cannot cross a blocked door")
	_expect_eq(host.state.canonical_json(), before_blocked, "rejected flee is atomic")
	_accept(host, "ConfirmFlee", "player_survivors", {"survivor_id":"marco_carven","path_room_ids":[]})
	var flee_result := _accept(host, "ConfirmFlee", "player_survivors", {"survivor_id":"william_hooper","path_room_ids":["R4"]})
	_expect(_has_event(flee_result.events, "NoiseRevealed"), "fleeing into R4 creates immediate public noise")
	_expect("R4" in host.state.data.noises_last_round, "R4 flee noise survives into the next-round clue history")
	_expect_eq(host.state.data.survivors[1].room_id, "R4", "legal one-step flee changes the survivor room")


func _test_defense_items_and_character_bonus() -> void:
	var illegal_host = _encounter_host(320, ["marco_carven"], 0)
	var shortsword_id := _give_item(illegal_host, "marco_carven", "shortsword")
	var hatchet_id := _give_item(illegal_host, "marco_carven", "hatchet")
	_accept(illegal_host, "PassAttackSkill", "player_killer", {})
	_accept(illegal_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	var before_pair: String = illegal_host.state.canonical_json()
	var illegal_pair := _submit(illegal_host, "SelectDefenseItem", "player_survivors", {"card_instance_ids":[shortsword_id, hatchet_id]})
	_expect_eq(illegal_pair.code, "TARGET_ILLEGAL", "two ordinary defense items cannot be combined")
	_expect_eq(illegal_host.state.canonical_json(), before_pair, "illegal item combination consumes nothing")

	var ammo_host = _encounter_host(321, ["marco_carven"], 0)
	var lone_ammo := _give_item(ammo_host, "marco_carven", "ammo_pack")
	_accept(ammo_host, "PassAttackSkill", "player_killer", {})
	_accept(ammo_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	var ammo_only := _submit(ammo_host, "SelectDefenseItem", "player_survivors", {"card_instance_ids":[lone_ammo]})
	_expect_eq(ammo_only.code, "TARGET_ILLEGAL", "ammunition cannot defend without a revolver")

	var william_host = _encounter_host(322, ["william_hooper"], 0)
	var limestone_id := _give_item(william_host, "william_hooper", "limestone_powder")
	_accept(william_host, "PassAttackSkill", "player_killer", {})
	_accept(william_host, "SelectDefender", "player_survivors", {"survivor_id":"william_hooper"})
	var limestone_result := _accept(william_host, "SelectDefenseItem", "player_survivors", {"card_instance_ids":[limestone_id]})
	var limestone_roll := _event_of_type(limestone_result.events, "DefenseRolled")
	_expect_eq(limestone_roll.payload.item_bonus, 2, "limestone gives two defense")
	_expect_eq(limestone_roll.payload.character_bonus, 1, "non-weapon limestone keeps William's Persistence")
	_expect(limestone_id in william_host.state.data.items.discard, "one-use limestone is discarded on commitment")
	_expect_eq(william_host.state.data.phase, "ENCOUNTER_FLEE", "successful defense immediately ends attacks")

	var revolver_host = _encounter_host(323, ["marco_carven"], 0)
	var revolver_id := _give_item(revolver_host, "marco_carven", "revolver")
	var ammo_id := _give_item(revolver_host, "marco_carven", "ammo_pack")
	_accept(revolver_host, "PassAttackSkill", "player_killer", {})
	_accept(revolver_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	var revolver_result := _accept(revolver_host, "SelectDefenseItem", "player_survivors", {"card_instance_ids":[ammo_id, revolver_id]})
	var revolver_roll := _event_of_type(revolver_result.events, "DefenseRolled")
	_expect_eq(revolver_roll.payload.item_bonus, 4, "revolver plus ammunition gives four defense")
	_expect(revolver_id in revolver_host.state.data.survivors[0].inventory_instance_ids, "infinite revolver remains in inventory")
	_expect(ammo_id in revolver_host.state.data.items.discard, "ammunition is consumed")

	var longsword_host = _encounter_host(324, ["marco_carven"], 0)
	var longsword_id := _give_item(longsword_host, "marco_carven", "longsword")
	var deck_before: int = longsword_host.state.data.killer.deck.size()
	_accept(longsword_host, "PassAttackSkill", "player_killer", {})
	_accept(longsword_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	var longsword_result := _accept(longsword_host, "SelectDefenseItem", "player_survivors", {"card_instance_ids":[longsword_id]})
	var longsword_roll := _event_of_type(longsword_result.events, "DefenseRolled")
	_expect_eq(longsword_roll.payload.item_bonus, 2, "longsword gives two defense")
	_expect(_has_event(longsword_result.events, "SkillDrawn"), "longsword immediately draws one killer skill")
	_expect_eq(longsword_host.state.data.killer.deck.size(), deck_before - 3, "longsword draw and repelling discard remove three deck cards")
	_expect(longsword_id in longsword_host.state.data.survivors[0].inventory_instance_ids, "infinite longsword remains in inventory")
	_expect_eq(longsword_host.state.data.items.definitions.shortsword.defense_bonus, 1, "shortsword data retains its confirmed bonus")
	_expect_eq(longsword_host.state.data.items.definitions.hatchet.defense_bonus, 1, "hatchet data retains its confirmed bonus")


func _test_repelling_discard_and_upgrade_resume() -> void:
	var level_two_host = _encounter_host(330, ["marco_carven"], 0)
	var regular := _regular_skill_instances(level_two_host)
	level_two_host.state.data.killer.hand = []
	level_two_host.state.data.killer.deck = [regular[0]]
	level_two_host.state.data.killer.discard = regular.slice(1)
	_accept(level_two_host, "PassAttackSkill", "player_killer", {})
	_accept(level_two_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	var level_result := _accept(level_two_host, "PassDefenseItem", "player_survivors", {})
	_expect_eq(level_two_host.state.data.killer.level, 2, "repelling across an empty deck upgrades Butcher")
	_expect(_has_event(level_result.events, "KillerLeveled"), "repelling upgrade is public")
	_expect_eq(level_two_host.state.data.killer.pending_deck_discard_count, 0, "repelling discard completes after recycle")
	_expect_eq(level_two_host.state.data.phase, "ENCOUNTER_FLEE", "repelling resumes flee after upgrade")
	_expect_eq(_regular_card_count(level_two_host), 12, "repelling recycle preserves all regular killer cards")

	var level_three_host = _encounter_host(331, ["marco_carven"], 0)
	regular = _regular_skill_instances(level_three_host)
	level_three_host.state.data.killer.level = 2
	level_three_host.state.data.killer.base_strength = 0
	level_three_host.state.data.killer.effective_strength = 0
	level_three_host.state.data.killer.hand = regular.slice(0, 5)
	level_three_host.state.data.killer.deck = []
	level_three_host.state.data.killer.discard = regular.slice(5)
	_accept(level_three_host, "PassAttackSkill", "player_killer", {})
	_accept(level_three_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(level_three_host, "PassDefenseItem", "player_survivors", {})
	_expect_eq(level_three_host.state.data.phase, "KILLER_UNLOCK_DISCARD", "level-three unlock pauses encounter deck discard")
	_expect_eq(level_three_host.state.data.killer.pending_deck_discard_context, "encounter_success", "paused operation remembers encounter context")
	_expect(not level_three_host.state.data.encounter.is_empty(), "encounter remains available during overflow choice")
	var old_hand_id: String = level_three_host.state.data.killer.pending_unlock_discard.eligible_discard_instance_ids[0]
	_accept(level_three_host, "ResolveKillerUnlockOverflow", "player_killer", {"discard_card_instance_id":old_hand_id})
	_expect_eq(level_three_host.state.data.phase, "ENCOUNTER_FLEE", "overflow resolution resumes repelling discard and flee")
	_expect_eq(level_three_host.state.data.killer.level, 3, "encounter discard unlocks level three normally")
	_expect_eq(_all_killer_card_count(level_three_host), 13, "unlock resume preserves all thirteen killer cards")

	var longsword_upgrade_host = _encounter_host(332, ["marco_carven"], 0)
	var longsword_id := _give_item(longsword_upgrade_host, "marco_carven", "longsword")
	regular = _regular_skill_instances(longsword_upgrade_host)
	longsword_upgrade_host.state.data.killer.level = 2
	longsword_upgrade_host.state.data.killer.base_strength = 0
	longsword_upgrade_host.state.data.killer.effective_strength = 0
	longsword_upgrade_host.state.data.killer.hand = regular.slice(0, 5)
	longsword_upgrade_host.state.data.killer.deck = []
	longsword_upgrade_host.state.data.killer.discard = regular.slice(5)
	_accept(longsword_upgrade_host, "PassAttackSkill", "player_killer", {})
	_accept(longsword_upgrade_host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(longsword_upgrade_host, "SelectDefenseItem", "player_survivors", {"card_instance_ids":[longsword_id]})
	_expect_eq(longsword_upgrade_host.state.data.phase, "KILLER_UNLOCK_DISCARD", "longsword draw pauses for level-three overflow")
	_expect_eq(longsword_upgrade_host.state.data.killer.pending_draw_context, "encounter_roll", "paused longsword draw remembers to resume the roll")
	old_hand_id = longsword_upgrade_host.state.data.killer.pending_unlock_discard.eligible_discard_instance_ids[0]
	var resumed_roll := _accept(longsword_upgrade_host, "ResolveKillerUnlockOverflow", "player_killer", {"discard_card_instance_id":old_hand_id})
	_expect(_has_event(resumed_roll.events, "DefenseRolled"), "overflow choice resumes the deferred defense roll")
	_expect_eq(longsword_upgrade_host.state.data.phase, "ENCOUNTER_FLEE", "longsword draw resumes through repelling and flee")


func _test_level_five_amulet_and_healing() -> void:
	var level_five = _new_host(340)
	_set_encounter_positions(level_five, ["marco_carven"])
	level_five.state.data.killer.level = 5
	level_five.state.data.survivors[0].health = "injured"
	var amulet_id := _give_item(level_five, "marco_carven", "ancient_amulet")
	var level_five_result := _accept(level_five, "KillerSearch", "player_killer", {})
	_expect_eq(level_five.state.data.phase, "GAME_OVER", "level-five pre-damage immediately ends on an injured survivor")
	_expect_eq(level_five.state.data.winner, "killer", "encounter elimination awards killer victory")
	_expect_eq(level_five.state.data.end_reason, "survivor_eliminated", "encounter loss uses the elimination reason")
	_expect(amulet_id in level_five.state.data.survivors[0].inventory_instance_ids, "amulet cannot prevent encounter pre-damage")
	_expect(_has_event(level_five_result.events, "MatchEnded"), "level-five elimination emits match end")
	var frozen := _submit(level_five, "PassAttackSkill", "player_killer", {})
	_expect_eq(frozen.code, "MATCH_ENDED", "commands freeze after encounter victory")

	var healthy_level_five = _new_host(341)
	_set_encounter_positions(healthy_level_five, ["marco_carven", "william_hooper", "anna_kubrick"])
	healthy_level_five.state.data.killer.level = 5
	_accept(healthy_level_five, "KillerSearch", "player_killer", {})
	for survivor: Dictionary in healthy_level_five.state.data.survivors:
		_expect_eq(survivor.health, "injured", "level-five encounter injures every healthy participant")
	_expect_eq(healthy_level_five.state.data.phase, "ENCOUNTER_ATTACK_SKILL", "surviving pre-damage continues the encounter")

	var prevent_host = _new_host(342)
	prevent_host.state.data.phase = "KILLER_MAIN"
	prevent_host.state.data.killer.main_actions_remaining = 2
	prevent_host.state.data.survivors[0].room_id = "R1"
	var prevention_amulet := _give_item(prevent_host, "marco_carven", "ancient_amulet")
	var chainsaw_id := _skill_instance(prevent_host, "revving_chainsaw")
	_set_killer_hand(prevent_host, [chainsaw_id])
	_accept(prevent_host, "UseKillerSkill", "player_killer", {"card_instance_id":chainsaw_id,"path_room_ids":[]})
	_expect_eq(prevent_host.state.data.phase, "DAMAGE_RESPONSE", "non-encounter damage pauses for an amulet response")
	_expect_eq(prevent_host.state.data.survivors[0].health, "healthy", "damage waits for the survivor response")
	var wrong_response := _submit(prevent_host, "ResolveDamageResponse", "player_killer", {"use_amulet":true})
	_expect_eq(wrong_response.code, "NOT_CONTROLLER", "killer cannot answer a survivor damage response")
	var prevented := _accept(prevent_host, "ResolveDamageResponse", "player_survivors", {"use_amulet":true})
	_expect(_has_event(prevented.events, "DamagePrevented"), "amulet emits public prevention")
	_expect_eq(prevent_host.state.data.survivors[0].health, "healthy", "amulet prevents one non-encounter damage")
	_expect(prevention_amulet in prevent_host.state.data.items.discard, "used amulet is discarded")
	_expect_eq(prevent_host.state.data.phase, "KILLER_SLOW", "response resumes the interrupted main-skill flow")

	var decline_host = _new_host(343)
	decline_host.state.data.phase = "KILLER_MAIN"
	decline_host.state.data.killer.main_actions_remaining = 2
	decline_host.state.data.survivors[0].room_id = "R1"
	_give_item(decline_host, "marco_carven", "ancient_amulet")
	var decline_chainsaw := _skill_instance(decline_host, "revving_chainsaw")
	_set_killer_hand(decline_host, [decline_chainsaw])
	_accept(decline_host, "UseKillerSkill", "player_killer", {"card_instance_id":decline_chainsaw,"path_room_ids":[]})
	_accept(decline_host, "ResolveDamageResponse", "player_survivors", {"use_amulet":false})
	_expect_eq(decline_host.state.data.survivors[0].health, "injured", "declining amulet applies the pending damage")
	_expect_eq(decline_host.state.data.phase, "KILLER_SLOW", "declined response also resumes killer flow")

	var medical_host = _new_host(344)
	medical_host.state.data.survivors[1].room_id = "R2"
	medical_host.state.data.survivors[1].health = "injured"
	medical_host.state.data.survivors[1].fear = 2
	var medical_kit_id: String = medical_host.state.data.survivors[0].inventory_instance_ids[0]
	_accept(medical_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var healed := _accept(medical_host, "UseSpecialAction", "player_survivors", {"actor_id":"marco_carven","source_id":"marco_medical_kit","target_survivor_id":"william_hooper"})
	_expect_eq(medical_host.state.data.survivors[1].health, "healthy", "Marco's medical kit heals an injured survivor at any room")
	_expect_eq(medical_host.state.data.survivors[1].fear, 0, "medical kit also clears target fear")
	_expect(medical_kit_id in medical_host.state.data.items.discard, "medical kit is discarded after use")
	_expect(_has_event(healed.events, "HealthChanged"), "medical kit healing is event-driven")

	var trap_host = _new_host(345)
	var trap_parts_id := _give_item(trap_host, "marco_carven", "trap_parts")
	_accept(trap_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var trap_placed := _accept(trap_host, "UseSpecialAction", "player_survivors", {"actor_id":"marco_carven","source_id":"trap_parts"})
	_expect_eq(trap_host.state.data.map.trap_room_id, "G1", "trap parts place the unique trap in the user's room")
	_expect(trap_parts_id in trap_host.state.data.items.discard, "placed trap parts are discarded")
	_expect(_has_event(trap_placed.events, "TrapPlaced"), "trap location is recorded for survivors")
	_expect(not _has_event(trap_host.events_for_side(trap_placed.events, "killer"), "TrapPlaced"), "trap remains hidden from the killer until triggered")


func _test_view_projection_during_interrupts() -> void:
	var encounter_host = _encounter_host(350, ["marco_carven"], 99)
	var killer_view: Dictionary = encounter_host.view_for_side("killer")
	_expect_eq(killer_view.encounter.survivor_ids, ["marco_carven"], "killer view includes public encounter participants")
	_expect(not killer_view.survivors[0].has("room_id"), "killer roster still omits hidden survivor positions")
	_expect(not killer_view.has("pending_damage"), "killer view has no survivor response internals")

	var damage_host = _new_host(351)
	damage_host.state.data.phase = "KILLER_MAIN"
	damage_host.state.data.killer.main_actions_remaining = 2
	damage_host.state.data.survivors[0].room_id = "R1"
	var amulet_id := _give_item(damage_host, "marco_carven", "ancient_amulet")
	var chainsaw_id := _skill_instance(damage_host, "revving_chainsaw")
	_set_killer_hand(damage_host, [chainsaw_id])
	var interrupted := _accept(damage_host, "UseKillerSkill", "player_killer", {"card_instance_id":chainsaw_id,"path_room_ids":[]})
	var survivor_view: Dictionary = damage_host.view_for_side("survivors")
	killer_view = damage_host.view_for_side("killer")
	_expect_eq(survivor_view.pending_damage.current_survivor_id, "marco_carven", "survivor view receives its response target")
	_expect_eq(survivor_view.pending_damage.get("source", ""), "revving_chainsaw", "survivor view receives the damage source")
	_expect(not killer_view.has("pending_damage"), "killer projection strips pending response details")
	_expect(amulet_id not in JSON.stringify(killer_view), "killer projection does not leak the amulet instance")
	_expect(_has_event(damage_host.events_for_side(interrupted.events, "survivors"), "DamageResponseRequested"), "survivors receive response request event")
	_expect(not _has_event(damage_host.events_for_side(interrupted.events, "killer"), "DamageResponseRequested"), "killer does not receive the private response request")


func _test_encounter_determinism() -> void:
	var first = _encounter_host(355, ["marco_carven"], 99)
	var second = _encounter_host(355, ["marco_carven"], 99)
	var results: Array = []
	for host in [first, second]:
		_accept(host, "PassAttackSkill", "player_killer", {})
		_accept(host, "SelectDefender", "player_survivors", {"survivor_id":"marco_carven"})
		results.append(_accept(host, "PassDefenseItem", "player_survivors", {}))
	var first_roll := _event_of_type(results[0].events, "DefenseRolled")
	var second_roll := _event_of_type(results[1].events, "DefenseRolled")
	_expect_eq(first_roll.payload.dice_results, second_roll.payload.dice_results, "same seed and commands produce identical defense dice")
	_expect_eq(first_roll.payload.total, second_roll.payload.total, "deterministic dice produce identical defense totals")
	_expect_eq(first.state.data.rng_state, second.state.data.rng_state, "encounter RNG advances deterministically")


func _test_command_only_match_reaches_game_over() -> void:
	var host = _new_host(360)
	var next_room := {"R1":"R2","R2":"R3","R3":"B4","B4":"B5","B5":"G1"}
	var steps := 0
	while host.state.data.phase != "GAME_OVER" and steps < 500:
		steps += 1
		match host.state.data.phase:
			"SURVIVOR_CHOOSE_ACTOR":
				var next_survivor_id := _next_unacted_survivor(host)
				_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":next_survivor_id})
			"SURVIVOR_ACTIVATION":
				var actor_id: String = host.state.data.active_actor_id
				var actor := _survivor(host, actor_id)
				if not actor.main_action_completed:
					_accept(host, "Calm", "player_survivors", {"actor_id":actor_id})
				else:
					_accept(host, "EndActivation", "player_survivors", {"actor_id":actor_id})
			"SURVIVOR_DISCOVER_SELECT":
				_accept(host, "ChooseDiscoverer", "player_survivors", {"survivor_id":"anna_kubrick"})
			"SURVIVOR_DISCOVER_RESOLVE":
				_resolve_first_discover_card(host)
			"KILLER_FAST":
				_accept(host, "EndKillerFast", "player_killer", {})
			"KILLER_MAIN":
				if host.state.data.killer.room_id == "G1":
					_accept(host, "KillerSearch", "player_killer", {})
				else:
					_accept(host, "KillerMove", "player_killer", {"target_room_id":next_room[host.state.data.killer.room_id]})
			"KILLER_SLOW":
				_accept(host, "EndKillerSlow", "player_killer", {})
			"KILLER_UNLOCK_DISCARD":
				var eligible: Array = host.state.data.killer.pending_unlock_discard.eligible_discard_instance_ids
				_accept(host, "ResolveKillerUnlockOverflow", "player_killer", {"discard_card_instance_id":eligible[0]})
			"ENCOUNTER_ATTACK_SKILL":
				_accept(host, "PassAttackSkill", "player_killer", {})
			"ENCOUNTER_DEFENDER":
				_accept(host, "SelectDefender", "player_survivors", {"survivor_id":_preferred_defender(host)})
			"ENCOUNTER_ITEM":
				_accept(host, "PassDefenseItem", "player_survivors", {})
			"ENCOUNTER_FLEE":
				var fleeing_id: String = host.state.data.encounter.flee_pending_ids[0]
				_accept(host, "ConfirmFlee", "player_survivors", {"survivor_id":fleeing_id,"path_room_ids":[]})
			_:
				failures.append("command-only scenario reached unsupported phase %s" % host.state.data.phase)
				break
	_expect(steps < 500, "command-only match terminates within the safety limit")
	_expect_eq(host.state.data.phase, "GAME_OVER", "command-only match reaches a terminal phase")
	_expect_eq(host.state.data.winner, "killer", "command-only scenario reaches killer victory")
	_expect_eq(host.state.data.end_reason, "survivor_eliminated", "command-only scenario ends through encounter elimination")
	_expect(host.state.data.command_sequence > 30, "full scenario advances only through submitted commands")


func _encounter_host(seed_value: int, participant_ids: Array, strength: int):
	var host = _new_host(seed_value)
	_set_encounter_positions(host, participant_ids)
	host.state.data.killer.base_strength = strength
	host.state.data.killer.effective_strength = strength
	_accept(host, "KillerSearch", "player_killer", {})
	return host


func _set_encounter_positions(host, participant_ids: Array) -> void:
	host.state.data.phase = "KILLER_MAIN"
	host.state.data.killer.main_actions_remaining = 2
	host.state.data.killer.main_action_mode = ""
	host.state.data.killer.room_id = "R1"
	for survivor: Dictionary in host.state.data.survivors:
		survivor.room_id = "R1" if survivor.id in participant_ids else "G1"


func _give_item(host, survivor_id: String, definition_id: String) -> String:
	var instance_ids: Array = host.state.data.items.item_instances.keys()
	instance_ids.sort()
	for instance_id: String in instance_ids:
		if host.state.data.items.item_instances[instance_id] != definition_id:
			continue
		for zone_name: String in ["discover_deck", "search_deck", "discard", "team_key_instance_ids"]:
			host.state.data.items[zone_name].erase(instance_id)
		for survivor: Dictionary in host.state.data.survivors:
			survivor.inventory_instance_ids.erase(instance_id)
		_survivor(host, survivor_id).inventory_instance_ids.append(instance_id)
		return instance_id
	return ""


func _skill_instance(host, definition_id: String) -> String:
	var instance_ids: Array = host.state.data.killer.skill_instances.keys()
	instance_ids.sort()
	for instance_id: String in instance_ids:
		if host.state.data.killer.skill_instances[instance_id] == definition_id:
			return instance_id
	return ""


func _set_killer_hand(host, instance_ids: Array) -> void:
	for instance_id: String in instance_ids:
		host.state.data.killer.deck.erase(instance_id)
		host.state.data.killer.discard.erase(instance_id)
		host.state.data.killer.locked_cards.erase(instance_id)
	host.state.data.killer.hand = instance_ids.duplicate()


func _regular_skill_instances(host) -> Array:
	var result: Array = []
	for instance_id: String in host.state.data.killer.skill_instances:
		if not instance_id.begins_with("killer_locked."):
			result.append(instance_id)
	result.sort()
	return result


func _regular_card_count(host) -> int:
	var count := 0
	for zone: Array in [host.state.data.killer.hand, host.state.data.killer.deck, host.state.data.killer.discard]:
		for instance_id: String in zone:
			if not instance_id.begins_with("killer_locked."):
				count += 1
	return count


func _all_killer_card_count(host) -> int:
	return host.state.data.killer.hand.size() + host.state.data.killer.deck.size() + host.state.data.killer.discard.size() + host.state.data.killer.locked_cards.size()


func _next_unacted_survivor(host) -> String:
	for survivor: Dictionary in host.state.data.survivors:
		if survivor.id not in host.state.data.acted_survivor_ids:
			return survivor.id
	return ""


func _preferred_defender(host) -> String:
	var remaining: Array = []
	for survivor_id: String in host.state.data.encounter.survivor_ids:
		if survivor_id not in host.state.data.encounter.attacked_survivor_ids:
			remaining.append(survivor_id)
	for survivor_id: String in remaining:
		if _survivor(host, survivor_id).health == "injured":
			return survivor_id
	return remaining[0]


func _resolve_first_discover_card(host) -> void:
	var pending: Dictionary = host.state.data.items.pending_private_draw
	var keep_id: String = pending.card_instance_ids[0]
	var payload := {"keep_card_instance_id":keep_id}
	var discoverer := _survivor(host, pending.survivor_id)
	if host.state.data.items.item_instances[keep_id] != "key" and discoverer.inventory_instance_ids.size() >= int(host.state.data.items.inventory_limit):
		var final_inventory: Array = discoverer.inventory_instance_ids.slice(0, int(host.state.data.items.inventory_limit) - 1)
		final_inventory.append(keep_id)
		payload.keep_inventory_instance_ids = final_inventory
	_accept(host, "ResolveDiscover", "player_survivors", payload)


func _survivor(host, survivor_id: String) -> Dictionary:
	for survivor: Dictionary in host.state.data.survivors:
		if survivor.id == survivor_id:
			return survivor
	return {}


func _new_host(seed_value: int):
	var host = MatchHostScript.new()
	var started := host.start_match(seed_value)
	_expect(started.ok, "host starts for Milestone 3 scenario")
	return host


func _submit(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	command_number += 1
	return host.submit(GameCommandScript.make(type, "m3-%04d" % command_number, host.state.data.command_sequence, player_id, payload))


func _accept(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	var result := _submit(host, type, player_id, payload)
	_expect(result.accepted, "%s should be accepted; code=%s message=%s" % [type, result.get("code", ""), result.get("message", "")])
	return result


func _event_of_type(events: Array, type: String) -> Dictionary:
	for event: Dictionary in events:
		if event.type == type:
			return event
	return {}


func _event_index(events: Array, type: String) -> int:
	for index in range(events.size()):
		if events[index].type == type:
			return index
	return -1


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
