extends SceneTree

const GameCommandScript = preload("res://core/command.gd")
const MatchHostScript = preload("res://network/match_host.gd")

var failures: Array[String] = []
var assertions := 0
var command_number := 0


func _initialize() -> void:
	_test_confirmed_content_and_extra_items()
	_test_toolbox_and_character_actions()
	_test_complete_item_exchange()
	_test_public_stats()
	await _test_playable_guidance_and_feedback()
	if failures.is_empty():
		print("Milestone 5 PASS (%d assertions)" % assertions)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("Milestone 5 FAIL (%d failures, %d assertions)" % [failures.size(), assertions])
		quit(1)


func _test_confirmed_content_and_extra_items() -> void:
	var host = _new_host(501)
	_expect_eq(host.state.data.items.item_instances.size(), 38, "confirmed item content contains exactly 38 cards")
	_expect_eq(host.state.data.items.discover_deck.size(), 27, "discover deck contains 27 cards")
	_expect_eq(host.state.data.items.search_deck.size(), 10, "search deck contains 10 cards")
	_expect_eq(host.state.data.items.definitions.size(), 15, "all confirmed item definitions are loaded")
	for definition_id: String in ["sedatives", "firecracker", "hatchet", "whiskey_bottle", "adrenaline"]:
		_expect_eq(host.state.data.items.definitions[definition_id].use_timing, "extra", "%s is data-tagged as an extra action" % definition_id)

	var marco := _survivor(host, "marco_carven")
	var sedatives_id := _give_item(host, "marco_carven", "sedatives")
	var firecracker_id := _give_item(host, "marco_carven", "firecracker")
	marco.fear = 2
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var sedatives := _accept(host, "UseItem", "player_survivors", {"actor_id":"marco_carven","card_instance_id":sedatives_id})
	marco = _survivor(host, "marco_carven")
	_expect_eq(marco.fear, 0, "sedatives clear all fear")
	_expect(sedatives_id in host.state.data.items.discard, "sedatives are discarded after use")
	_expect(_has_event(sedatives.events, "FearChanged"), "sedatives publish the private fear change")
	_expect(not marco.main_action_completed, "extra item does not consume the main action")
	var firecracker := _accept(host, "UseItem", "player_survivors", {"actor_id":"marco_carven","card_instance_id":firecracker_id})
	_expect(host.state.data.firecracker_active, "firecracker enables the all-rooms-noisy state")
	_expect(_has_event(firecracker.events, "FirecrackerActivated"), "firecracker state is public")

	var hatchet_host = _new_host(502)
	var hatchet_id := _give_item(hatchet_host, "marco_carven", "hatchet")
	hatchet_host.state.data.map.blocked_edge_ids.append("G1--G3")
	_accept(hatchet_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var hatchet := _accept(hatchet_host, "UseItem", "player_survivors", {"actor_id":"marco_carven","card_instance_id":hatchet_id,"edge_id":"G1--G3"})
	_expect("G1--G3" not in hatchet_host.state.data.map.blocked_edge_ids, "hatchet removes an adjacent existing block")
	_expect(_has_event(hatchet.events, "BlockRemoved"), "hatchet removal is public")

	var whiskey_host = _new_host(503)
	var whiskey_id := _give_item(whiskey_host, "marco_carven", "whiskey_bottle")
	whiskey_host.state.data.map.blocked_edge_ids.append("G1--G3")
	_accept(whiskey_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(whiskey_host, "UseItem", "player_survivors", {"actor_id":"marco_carven","card_instance_id":whiskey_id,"target_room_id":"G3"})
	_expect(_has_noise(whiskey_host, "G3", "whiskey_bottle"), "whiskey creates noise across a blocked adjacent door")

	var adrenaline_host = _new_host(504)
	var adrenaline_id := _give_item(adrenaline_host, "marco_carven", "adrenaline")
	_accept(adrenaline_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	_accept(adrenaline_host, "UseItem", "player_survivors", {"actor_id":"marco_carven","card_instance_id":adrenaline_id,"path_room_ids":["G3", "G4", "R5", "R4"]})
	_expect_eq(_survivor(adrenaline_host, "marco_carven").room_id, "R4", "adrenaline moves along a legal four-step path")
	_expect(_has_noise(adrenaline_host, "R4", "sterile_room_entry"), "adrenaline still applies the R4 entry rule")
	_expect(adrenaline_id in adrenaline_host.state.data.items.discard, "adrenaline is consumed")

	var blocked_host = _new_host(505)
	var blocked_id := _give_item(blocked_host, "marco_carven", "adrenaline")
	blocked_host.state.data.map.blocked_edge_ids.append("G1--G3")
	_accept(blocked_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var before_invalid: String = blocked_host.state.canonical_json()
	var invalid := _submit(blocked_host, "UseItem", "player_survivors", {"actor_id":"marco_carven","card_instance_id":blocked_id,"path_room_ids":["G3"]})
	_expect_eq(invalid.code, "PATH_ILLEGAL", "adrenaline cannot cross a block")
	_expect_eq(blocked_host.state.canonical_json(), before_invalid, "an invalid item path is rejected atomically")


func _test_toolbox_and_character_actions() -> void:
	var toolbox_host = _new_host(510)
	var toolbox_id := _give_item(toolbox_host, "marco_carven", "toolbox")
	var marco := _survivor(toolbox_host, "marco_carven")
	marco.room_id = "B4"
	toolbox_host.state.data.objectives.radio_progress = 3
	_accept(toolbox_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var toolbox := _accept(toolbox_host, "UseSpecialAction", "player_survivors", {"actor_id":"marco_carven","source_id":"toolbox"})
	_expect_eq(toolbox_host.state.data.objectives.radio_progress, 5, "toolbox adds two radio progress")
	_expect_eq(toolbox_host.state.data.objectives.rescue_countdown, 5, "toolbox can start the rescue countdown")
	_expect(toolbox_host.state.data.objectives.repair_increased_this_round, "toolbox consumes the round repair increase")
	_expect(toolbox_id in toolbox_host.state.data.items.discard, "toolbox is discarded")
	_expect(_has_noise(toolbox_host, "B4", "toolbox"), "toolbox creates B4 noise")
	_expect(_has_event(toolbox.events, "RepairAdded"), "toolbox publishes repair progress to survivors")

	var marco_host = _new_host(511)
	var recovered_id := _give_item(marco_host, "marco_carven", "adrenaline")
	var whiskey_id := _give_item(marco_host, "marco_carven", "whiskey_bottle")
	var hatchet_id := _give_item(marco_host, "marco_carven", "hatchet")
	var marco_actor := _survivor(marco_host, "marco_carven")
	marco_actor.inventory_instance_ids.erase(recovered_id)
	marco_host.state.data.items.discard.append(recovered_id)
	_accept(marco_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var before_capacity: String = marco_host.state.canonical_json()
	var missing_capacity := _submit(marco_host, "UseSpecialAction", "player_survivors", {"actor_id":"marco_carven","source_id":"marco_equipped","card_instance_id":recovered_id})
	_expect_eq(missing_capacity.code, "CAPACITY_RESULT_INVALID", "Equipped requires an explicit final inventory when full")
	_expect_eq(marco_host.state.canonical_json(), before_capacity, "rejected Equipped selection changes nothing")
	var medical_id: String = marco_actor.inventory_instance_ids[0]
	var equipped := _accept(marco_host, "UseSpecialAction", "player_survivors", {
		"actor_id":"marco_carven", "source_id":"marco_equipped", "card_instance_id":recovered_id,
		"keep_inventory_instance_ids":[medical_id, whiskey_id, recovered_id],
	})
	marco_actor = _survivor(marco_host, "marco_carven")
	_expect(recovered_id in marco_actor.inventory_instance_ids, "Marco recovers adrenaline from the item discard")
	_expect(hatchet_id in marco_host.state.data.items.discard, "Equipped capacity choice discards the unkept item")
	_expect(marco_actor.main_action_completed, "Equipped consumes Marco's main action")
	_expect(_has_event(equipped.events, "CharacterAbilityUsed"), "Equipped emits a character ability event")

	var william_host = _new_host(512)
	_accept(william_host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"william_hooper"})
	var before_zero: String = william_host.state.canonical_json()
	var zero := _submit(william_host, "UseSpecialAction", "player_survivors", {"actor_id":"william_hooper","source_id":"william_sprint","path_room_ids":[]})
	_expect_eq(zero.code, "PATH_ILLEGAL", "Sprint cannot move zero steps")
	_expect_eq(william_host.state.canonical_json(), before_zero, "invalid Sprint is atomic")
	_accept(william_host, "UseSpecialAction", "player_survivors", {"actor_id":"william_hooper","source_id":"william_sprint","path_room_ids":["G3", "G4", "R5"]})
	var william := _survivor(william_host, "william_hooper")
	_expect_eq(william.room_id, "R5", "Sprint moves one to three legal steps")
	_expect(_has_noise(william_host, "R5", "william_sprint"), "Sprint creates one noise at the final room")
	_expect_eq(_noise_count(william_host, "william_sprint"), 1, "Sprint does not create noise in intermediate rooms")
	_expect(william.main_action_completed, "Sprint consumes William's main action")


func _test_complete_item_exchange() -> void:
	var host = _new_host(520)
	var sedatives_id := _give_item(host, "marco_carven", "sedatives")
	var whiskey_id := _give_item(host, "william_hooper", "whiskey_bottle")
	var marco := _survivor(host, "marco_carven")
	var william := _survivor(host, "william_hooper")
	var medical_id: String = marco.inventory_instance_ids[0]
	william.room_id = "G3"
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"marco_carven"})
	var before_remote: String = host.state.canonical_json()
	var remote := _submit(host, "ExchangeItems", "player_survivors", {
		"actor_id":"marco_carven", "target_survivor_id":"william_hooper",
		"actor_inventory_instance_ids":[whiskey_id], "target_inventory_instance_ids":[medical_id, sedatives_id],
	})
	_expect_eq(remote.code, "TARGET_ILLEGAL", "exchange requires both survivors in the same room")
	_expect_eq(host.state.canonical_json(), before_remote, "invalid remote exchange is atomic")
	william = _survivor(host, "william_hooper")
	william.room_id = "G1"
	var exchanged := _accept(host, "ExchangeItems", "player_survivors", {
		"actor_id":"marco_carven", "target_survivor_id":"william_hooper",
		"actor_inventory_instance_ids":[whiskey_id], "target_inventory_instance_ids":[medical_id, sedatives_id],
	})
	marco = _survivor(host, "marco_carven")
	william = _survivor(host, "william_hooper")
	_expect_eq(marco.inventory_instance_ids, [whiskey_id], "exchange applies the actor's complete final inventory")
	_expect_eq(william.inventory_instance_ids, [medical_id, sedatives_id], "exchange applies the target's complete final inventory")
	_expect(not marco.main_action_completed, "exchange does not consume the main action")
	_expect(_has_event(exchanged.events, "ItemsExchanged"), "exchange is visible to survivors")
	var before_duplicate: String = host.state.canonical_json()
	var duplicate := _submit(host, "ExchangeItems", "player_survivors", {
		"actor_id":"marco_carven", "target_survivor_id":"william_hooper",
		"actor_inventory_instance_ids":[whiskey_id], "target_inventory_instance_ids":[medical_id, medical_id, sedatives_id],
	})
	_expect_eq(duplicate.code, "CAPACITY_RESULT_INVALID", "exchange rejects duplicate assignment")
	_expect_eq(host.state.canonical_json(), before_duplicate, "duplicate exchange is atomic")


func _test_public_stats() -> void:
	var host = _new_host(530)
	_accept(host, "BeginSurvivorActivation", "player_survivors", {"survivor_id":"anna_kubrick"})
	_accept(host, "Calm", "player_survivors", {"actor_id":"anna_kubrick"})
	_expect_eq(host.state.data.stats.commands_accepted, 2, "accepted commands increment the match statistics")
	_expect(not host.view_for_side("survivors").has("stats"), "live survivor view does not expose post-game statistics")
	_expect(not host.view_for_side("killer").has("stats"), "live killer view cannot infer hidden actions from statistics")
	host.state.data.phase = "GAME_OVER"
	_expect_eq(host.view_for_side("survivors").stats, host.view_for_side("killer").stats, "both projected views receive the same aggregate statistics")
	_expect(not host.view_for_side("killer").has("rng_state"), "statistics do not weaken existing hidden-state projection")


func _test_playable_guidance_and_feedback() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var app = scene.instantiate()
	root.add_child(app)
	await process_frame
	_expect(app.get_script() != null, "main scene loads its playable application script")
	if app.get_script() == null:
		app.queue_free()
		return
	var started: Dictionary = app.session.start_offline(540, "survivors")
	_expect(started.ok, "playable client starts for Milestone 5 UI checks")
	_expect(app.tutorial_label.visible and not app.tutorial_label.text.is_empty(), "context tutorial is visible when a match begins")
	_expect(app.feedback != null and app.feedback.audio_player != null, "sound and animation feedback controller is ready")
	_expect_eq(app.map_board.map_data.rooms.size(), 15, "playable board contains the complete laboratory map")
	_expect(app.map_board.room_rect("R1").position.y < app.map_board.room_rect("R2").position.y, "visual board follows the photographed upper-left R1/R2 layout")
	_expect(app.map_board.room_rect("G1").position.x > app.map_board.room_rect("B5").position.x, "visual board follows the photographed lower-right B5/G1 layout")
	var labels := _button_texts(app.action_list)
	_expect(_contains_text(labels, "激活"), "first-time player receives explicit activation choices")
	app.session.submit_command("BeginSurvivorActivation", {"survivor_id":"william_hooper"})
	labels = _button_texts(app.action_list)
	_expect(_contains_text(labels, "冲刺"), "William's original Sprint choices are exposed in the UI")
	_expect(_contains_text(labels, "2 步：G3 医疗室 → G4 东侧过道"), "opening movement exposes the complete two-step route through G3")
	_expect(_contains_text(labels, "2 步：B5 石英岩洞穴 → B4 发电机室"), "opening movement exposes the complete two-step route through B5")
	app._queue_path_command("移动（1～2 步）", "MoveSurvivor", {"actor_id":"william_hooper"}, ["G3", "G4"])
	_expect_eq(app.pending_command.payload.path_room_ids, ["G3", "G4"], "a complete two-step route is queued before host submission")
	app._cancel_pending_command()
	app._start_path_selection("冲刺", "UseSpecialAction", {"actor_id":"william_hooper","source_id":"william_sprint"}, "G1", 3, app.session.current_view.map.blocked_edge_ids)
	_expect("G3" in app.map_board.highlighted_room_ids, "path selection highlights legal adjacent rooms")
	app._on_room_clicked("G3")
	_expect_eq(app.pending_path_selection.path_room_ids, ["G3"], "clicking a highlighted room extends the local preview")
	app._undo_path_step()
	_expect(app.pending_path_selection.path_room_ids.is_empty(), "path selection can undo the latest step")
	app._cancel_path_selection()
	_expect(app.pending_path_selection.is_empty(), "path selection can be cancelled before host submission")
	var brutal_view: Dictionary = app.session.current_view.duplicate(true)
	brutal_view.killer.room_id = "B1"
	brutal_view.map.blocked_edge_ids = ["B1--B4"]
	app._start_brutal_selection("fixture.brutal", ["fixture.cost"], brutal_view)
	_expect(app.action_list.get_child_count() < 50, "Brutal Rage offers one bounded path-selection step at a time")
	app._append_brutal_segment(["B4"])
	_expect_eq(app.pending_brutal_selection.segments.size(), 1, "crossing a block records one local Brutal Rage segment")
	_expect(app.action_list.get_child_count() < 50, "a repeat choice remains bounded after breaking a block")
	app._cancel_brutal_selection()
	_expect(app.pending_brutal_selection.is_empty(), "Brutal Rage path selection can be cancelled before host submission")
	var ended_view: Dictionary = app.session.current_view.duplicate(true)
	ended_view.phase = "GAME_OVER"
	ended_view.winner = "survivors"
	ended_view.end_reason = "test"
	app._render_view(ended_view)
	_expect(_contains_text(_button_texts(app.action_list), "快速重开"), "game-over screen exposes quick restart")
	_expect(app.info_label.text.contains("本局统计"), "game-over screen displays numerical match statistics")
	app.queue_free()


func _give_item(host, survivor_id: String, definition_id: String) -> String:
	for zone_name: String in ["discover_deck", "search_deck", "discard"]:
		var zone: Array = host.state.data.items[zone_name]
		for instance_id: String in zone.duplicate():
			if host.state.data.items.item_instances.get(instance_id, "") == definition_id:
				zone.erase(instance_id)
				_survivor(host, survivor_id).inventory_instance_ids.append(instance_id)
				return instance_id
	_failuresafe("fixture could not find item %s" % definition_id)
	return ""


func _survivor(host, survivor_id: String) -> Dictionary:
	for survivor: Dictionary in host.state.data.survivors:
		if survivor.id == survivor_id:
			return survivor
	return {}


func _new_host(seed_value: int):
	var host = MatchHostScript.new()
	var started: Dictionary = host.start_match(seed_value)
	_expect(started.ok, "host starts for Milestone 5 scenario")
	return host


func _submit(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	command_number += 1
	return host.submit(GameCommandScript.make(type, "m5-%04d" % command_number, host.state.data.command_sequence, player_id, payload))


func _accept(host, type: String, player_id: String, payload: Dictionary) -> Dictionary:
	var result := _submit(host, type, player_id, payload)
	_expect(result.accepted, "%s should be accepted; code=%s message=%s" % [type, result.get("code", ""), result.get("message", "")])
	return result


func _has_noise(host, room_id: String, source: String) -> bool:
	for noise: Dictionary in host.state.data.noises_this_round:
		if noise.room_id == room_id and noise.source == source:
			return true
	return false


func _noise_count(host, source: String) -> int:
	var count := 0
	for noise: Dictionary in host.state.data.noises_this_round:
		if noise.source == source:
			count += 1
	return count


func _event_of_type(events: Array, type: String) -> Dictionary:
	for event: Dictionary in events:
		if event.type == type:
			return event
	return {}


func _has_event(events: Array, type: String) -> bool:
	return not _event_of_type(events, type).is_empty()


func _button_texts(container: Container) -> Array[String]:
	var result: Array[String] = []
	for child: Node in container.get_children():
		if child is Button:
			result.append(child.text)
	return result


func _contains_text(values: Array[String], fragment: String) -> bool:
	for value: String in values:
		if value.contains(fragment):
			return true
	return false


func _failuresafe(message: String) -> void:
	failures.append(message)


func _expect(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)


func _expect_eq(actual: Variant, expected: Variant, message: String) -> void:
	assertions += 1
	if actual != expected:
		failures.append("%s; expected=%s actual=%s" % [message, str(expected), str(actual)])
