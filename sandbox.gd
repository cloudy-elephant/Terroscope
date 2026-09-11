extends Node

const MatchHostScript = preload("res://network/match_host.gd")
const GameCommandScript = preload("res://core/command.gd")


func _ready() -> void:
	var host = MatchHostScript.new()
	var started = host.start_match(20260911)
	if not started.ok:
		push_error(started.message)
		get_tree().quit(1)
		return
	print("=== Milestones 0-1: Terrorscape Laboratory rules sandbox ===")
	_print_events(started.events)
	var command_number = 1
	for survivor_id in ["marco_carven", "william_hooper", "anna_kubrick"]:
		_submit(host, GameCommandScript.make("BeginSurvivorActivation", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"survivor_id":survivor_id}))
		command_number += 1
		_submit(host, GameCommandScript.make("Calm", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"actor_id":survivor_id}))
		command_number += 1
		_submit(host, GameCommandScript.make("EndActivation", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"actor_id":survivor_id}))
		command_number += 1
	_submit(host, GameCommandScript.make("ChooseDiscoverer", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"survivor_id":"anna_kubrick"}))
	command_number += 1
	var drawn: Array = host.state.data.items.pending_private_draw.card_instance_ids
	_submit(host, GameCommandScript.make("ResolveDiscover", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_survivors", {"keep_card_instance_id":drawn[0],"keep_inventory_instance_ids":[drawn[0]]}))
	command_number += 1
	_submit(host, GameCommandScript.make("EndKillerFast", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_killer"))
	command_number += 1
	_submit(host, GameCommandScript.make("KillerMove", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_killer", {"target_room_id":"R2"}))
	command_number += 1
	_submit(host, GameCommandScript.make("KillerMove", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_killer", {"target_room_id":"R3"}))
	command_number += 1
	_submit(host, GameCommandScript.make("EndKillerSlow", "sandbox-%02d" % command_number, host.state.data.command_sequence, "player_killer"))
	print("Final: round=%d phase=%s commands=%d rng_state=%d" % [host.state.data.round_index, host.state.data.phase, host.state.data.command_sequence, host.state.data.rng_state])
	get_tree().quit(0)


func _submit(host, command: Dictionary) -> void:
	var result = host.submit(command)
	if not result.accepted:
		push_error("%s rejected: %s" % [command.type, result.code])
		get_tree().quit(1)
		return
	_print_events(result.events)


func _print_events(events: Array) -> void:
	for event: Dictionary in events:
		print("[%03d] %s %s" % [event.event_sequence, event.type, JSON.stringify(event.payload)])
