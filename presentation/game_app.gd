extends Control

const LanSessionScript = preload("res://network/lan_session.gd")
const MapBoardScript = preload("res://presentation/map_board.gd")

const PHASE_NAMES := {
	"SURVIVOR_CHOOSE_ACTOR":"选择幸存者", "SURVIVOR_ACTIVATION":"幸存者行动",
	"SURVIVOR_SEARCH_RESOLVE":"处理搜索牌", "SURVIVOR_DISCOVER_SELECT":"选择发现者",
	"SURVIVOR_DISCOVER_RESOLVE":"处理发现牌", "KILLER_FAST":"杀手快速阶段",
	"KILLER_MAIN":"杀手主要阶段", "KILLER_SLOW":"杀手慢速阶段",
	"KILLER_UNLOCK_DISCARD":"技能解锁弃牌", "ENCOUNTER_ATTACK_SKILL":"遭遇：攻击牌",
	"ENCOUNTER_DEFENDER":"遭遇：选择防守者", "ENCOUNTER_ITEM":"遭遇：防御物品",
	"ENCOUNTER_FLEE":"遭遇：逃离", "DAMAGE_RESPONSE":"伤害响应", "GAME_OVER":"对局结束",
}

var session
var lobby_panel: VBoxContainer
var lobby_status: Label
var address_input: LineEdit
var port_input: SpinBox
var ready_button: Button
var start_button: Button
var game_panel: VBoxContainer
var phase_label: Label
var side_label: Label
var map_board
var info_label: RichTextLabel
var action_list: VBoxContainer
var confirmation_panel: VBoxContainer
var confirmation_label: Label
var log_label: RichTextLabel
var switch_button: Button
var pending_command: Dictionary = {}
var event_lines: Array[String] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	session = LanSessionScript.new()
	add_child(session)
	session.lobby_changed.connect(_on_lobby_changed)
	session.match_started.connect(_on_match_started)
	session.view_changed.connect(_on_view_changed)
	session.command_completed.connect(_on_command_completed)
	session.session_status_changed.connect(_set_lobby_status)
	session.connection_lost.connect(_on_connection_lost)
	_build_ui()
	_show_lobby()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("111820")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	move_child(background, 0)

	lobby_panel = VBoxContainer.new()
	lobby_panel.set_anchors_preset(Control.PRESET_CENTER)
	lobby_panel.position = Vector2(-260, -235)
	lobby_panel.size = Vector2(520, 470)
	lobby_panel.add_theme_constant_override("separation", 12)
	add_child(lobby_panel)
	var title := Label.new()
	title.text = "恶夜杀机 · 实验室"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	lobby_panel.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "2 人局域网 · 主机权威规则"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_panel.add_child(subtitle)
	var fixed_content := Label.new()
	fixed_content.text = "地图：实验室\n杀手：屠夫\n幸存者：马尔科 / 威廉 / 安娜"
	fixed_content.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_panel.add_child(fixed_content)
	var host_row := HBoxContainer.new()
	host_row.alignment = BoxContainer.ALIGNMENT_CENTER
	lobby_panel.add_child(host_row)
	host_row.add_child(_button("创建房间 · 幸存者", func(): _create_room("survivors")))
	host_row.add_child(_button("创建房间 · 杀手", func(): _create_room("killer")))
	var join_row := HBoxContainer.new()
	join_row.alignment = BoxContainer.ALIGNMENT_CENTER
	lobby_panel.add_child(join_row)
	address_input = LineEdit.new()
	address_input.placeholder_text = "主机 IP"
	address_input.text = "127.0.0.1"
	address_input.custom_minimum_size.x = 190
	join_row.add_child(address_input)
	port_input = SpinBox.new()
	port_input.min_value = 1024
	port_input.max_value = 65535
	port_input.value = LanSessionScript.DEFAULT_PORT
	port_input.custom_minimum_size.x = 110
	join_row.add_child(port_input)
	join_row.add_child(_button("加入", _join_room))
	var ready_row := HBoxContainer.new()
	ready_row.alignment = BoxContainer.ALIGNMENT_CENTER
	lobby_panel.add_child(ready_row)
	ready_button = _button("准备", _toggle_ready)
	start_button = _button("开始对局", _start_network_match)
	ready_row.add_child(ready_button)
	ready_row.add_child(start_button)
	var offline_row := HBoxContainer.new()
	offline_row.alignment = BoxContainer.ALIGNMENT_CENTER
	lobby_panel.add_child(offline_row)
	offline_row.add_child(_button("本机双视图调试", func(): session.start_offline(Time.get_unix_time_from_system(), "survivors")))
	lobby_status = Label.new()
	lobby_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lobby_panel.add_child(lobby_status)

	game_panel = VBoxContainer.new()
	game_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	game_panel.add_theme_constant_override("separation", 8)
	add_child(game_panel)
	var top_bar := HBoxContainer.new()
	game_panel.add_child(top_bar)
	side_label = Label.new()
	side_label.custom_minimum_size.x = 190
	top_bar.add_child(side_label)
	phase_label = Label.new()
	phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_label.add_theme_font_size_override("font_size", 20)
	top_bar.add_child(phase_label)
	switch_button = _button("切换阵营视图", _switch_debug_side)
	top_bar.add_child(switch_button)
	top_bar.add_child(_button("返回大厅", _show_lobby))

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_panel.add_child(body)
	map_board = MapBoardScript.new()
	map_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_board.room_clicked.connect(func(room_id): _set_game_status("地点 %s；请从右侧选择对应行动" % room_id))
	body.add_child(map_board)
	var side_panel := VBoxContainer.new()
	side_panel.custom_minimum_size.x = 430
	body.add_child(side_panel)
	info_label = RichTextLabel.new()
	info_label.bbcode_enabled = true
	info_label.fit_content = false
	info_label.custom_minimum_size.y = 205
	side_panel.add_child(info_label)
	var action_title := Label.new()
	action_title.text = "可用命令"
	action_title.add_theme_font_size_override("font_size", 18)
	side_panel.add_child(action_title)
	var action_scroll := ScrollContainer.new()
	action_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_panel.add_child(action_scroll)
	action_list = VBoxContainer.new()
	action_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_scroll.add_child(action_list)
	confirmation_panel = VBoxContainer.new()
	confirmation_panel.add_theme_constant_override("separation", 6)
	side_panel.add_child(confirmation_panel)
	confirmation_label = Label.new()
	confirmation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	confirmation_panel.add_child(confirmation_label)
	var confirm_row := HBoxContainer.new()
	confirmation_panel.add_child(confirm_row)
	confirm_row.add_child(_button("确认提交", _confirm_pending_command))
	confirm_row.add_child(_button("取消", _cancel_pending_command))
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.custom_minimum_size.y = 150
	game_panel.add_child(log_label)


func _show_lobby() -> void:
	if session != null and session.mode != "idle":
		session.shutdown()
	pending_command = {}
	lobby_panel.visible = true
	game_panel.visible = false
	ready_button.visible = false
	start_button.visible = false
	lobby_status.text = "创建房间、输入主机 IP 加入，或直接进入本机双视图调试。"


func _create_room(side: String) -> void:
	var result: Dictionary = session.create_room(side, int(port_input.value))
	if result.ok:
		ready_button.visible = true
		start_button.visible = true
		var addresses: Array = session.get_local_addresses()
		lobby_status.text = "房间已创建。IP：%s  端口：%d" % [", ".join(addresses) if not addresses.is_empty() else "127.0.0.1", int(port_input.value)]
	else:
		lobby_status.text = result.message


func _join_room() -> void:
	var result: Dictionary = session.join_room(address_input.text.strip_edges(), int(port_input.value))
	ready_button.visible = bool(result.ok)
	start_button.visible = false
	if not result.ok:
		lobby_status.text = result.message


func _toggle_ready() -> void:
	var current_ready := false
	if session.mode == "host" and not session.lobby_snapshot.is_empty():
		current_ready = bool(session.lobby_snapshot.players.host.ready)
	elif session.mode == "client" and not session.lobby_snapshot.is_empty():
		current_ready = bool(session.lobby_snapshot.players.client.ready)
	var result: Dictionary = session.set_ready(not current_ready)
	if not result.ok:
		lobby_status.text = result.message


func _start_network_match() -> void:
	var result: Dictionary = session.start_network_match(Time.get_unix_time_from_system())
	if not result.ok:
		lobby_status.text = result.message


func _on_lobby_changed(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var host_state: Dictionary = snapshot.players.host
	var client_state: Dictionary = snapshot.players.client
	lobby_status.text = "房主：%s / %s　加入者：%s / %s" % [
		host_state.side, "已准备" if host_state.ready else "未准备",
		client_state.side if client_state.connected else "未连接", "已准备" if client_state.ready else "未准备",
	]
	ready_button.visible = true
	start_button.visible = session.mode == "host"
	start_button.disabled = not session.can_start_network_match()
	ready_button.text = "取消准备" if ((session.mode == "host" and host_state.ready) or (session.mode == "client" and client_state.ready)) else "准备"


func _on_match_started(view: Dictionary, events: Array) -> void:
	lobby_panel.visible = false
	game_panel.visible = true
	event_lines.clear()
	_append_events(events)
	_render_view(view)


func _on_view_changed(view: Dictionary, events: Array) -> void:
	_append_events(events)
	_render_view(view)


func _on_command_completed(result: Dictionary) -> void:
	if not bool(result.get("accepted", false)):
		_set_game_status("命令被拒绝：%s · %s" % [result.get("code", ""), result.get("message", "")])


func _on_connection_lost(message: String) -> void:
	if session.mode == "client":
		_show_lobby()
		lobby_status.text = message
	elif game_panel.visible:
		_set_game_status(message)
	else:
		lobby_status.text = message


func _render_view(view: Dictionary) -> void:
	if view.is_empty():
		return
	side_label.text = "当前视图：%s" % ("幸存者" if session.local_side == "survivors" else "杀手")
	var phase: String = view.get("phase", "")
	phase_label.text = "第 %d 轮 · %s" % [int(view.get("round_index", 0)), PHASE_NAMES.get(phase, phase)]
	switch_button.visible = session.mode == "offline"
	map_board.set_view(view)
	_render_info(view)
	_render_actions(view)


func _render_info(view: Dictionary) -> void:
	var lines: Array[String] = []
	var killer: Dictionary = view.get("killer", {})
	lines.append("[b]屠夫[/b]　等级 %d　力量 %d%s" % [int(killer.get("level", 0)), int(killer.get("effective_strength", 0)), "　位置 %s" % killer.room_id if killer.has("room_id") else "　潜行中"])
	var objectives: Dictionary = view.get("objectives", {})
	if session.local_side == "survivors":
		lines.append("钥匙 %d / 5　无线电 %d / 5　救援 %s" % [view.items.get("team_key_count", 0), objectives.get("radio_progress", 0), str(objectives.get("rescue_countdown", "未启动"))])
		for survivor: Dictionary in view.get("survivors", []):
			var item_names: Array[String] = []
			for instance_id: String in survivor.get("inventory_instance_ids", []):
				item_names.append(_item_name(view, instance_id))
			lines.append("[b]%s[/b]　%s　%s　恐惧 %d　物品：%s" % [survivor.id, survivor.get("room_id", "?"), survivor.health, int(survivor.get("fear", 0)), "、".join(item_names) if not item_names.is_empty() else "无"])
	else:
		lines.append("技能手牌 %d　牌库 %d　弃牌 %d　钥匙 %d" % [killer.get("hand_count", 0), killer.get("deck_count", 0), killer.get("discard_count", 0), view.items.get("team_key_count", 0)])
		for survivor: Dictionary in view.get("survivors", []):
			lines.append("%s　%s" % [survivor.id, survivor.health])
	if not view.get("encounter", {}).is_empty():
		lines.append("[color=#ffd166]遭遇地点 %s · 已攻击 %s[/color]" % [view.encounter.room_id, str(view.encounter.attacked_survivor_ids)])
	info_label.text = "\n".join(lines)


func _render_actions(view: Dictionary) -> void:
	_clear_container(action_list)
	pending_command = {}
	confirmation_panel.visible = false
	var phase: String = view.get("phase", "")
	if phase == "GAME_OVER":
		_add_plain_label("%s 获胜：%s" % [view.get("winner", ""), view.get("end_reason", "")])
		if session.mode in ["offline", "host"]:
			action_list.add_child(_button("快速重开", func(): session.restart_match(Time.get_unix_time_from_system())))
		return
	if not _local_side_acts(phase):
		_add_plain_label("等待对方选择……")
		return
	match phase:
		"SURVIVOR_CHOOSE_ACTOR":
			for survivor: Dictionary in view.survivors:
				if survivor.id not in view.acted_survivor_ids:
					_add_command("激活 %s" % survivor.id, "BeginSurvivorActivation", {"survivor_id":survivor.id})
		"SURVIVOR_ACTIVATION":
			_add_survivor_activation_actions(view)
		"SURVIVOR_SEARCH_RESOLVE":
			_add_search_resolution_actions(view)
		"SURVIVOR_DISCOVER_SELECT":
			for survivor: Dictionary in view.survivors:
				_add_command("由 %s 发现" % survivor.id, "ChooseDiscoverer", {"survivor_id":survivor.id})
		"SURVIVOR_DISCOVER_RESOLVE":
			_add_discover_resolution_actions(view)
		"KILLER_FAST":
			_add_killer_skill_actions(view, "fast")
			_add_command("结束快速阶段", "EndKillerFast", {})
		"KILLER_MAIN":
			_add_killer_main_actions(view)
		"KILLER_SLOW":
			_add_killer_skill_actions(view, "slow")
			_add_command("结束慢速阶段", "EndKillerSlow", {})
		"KILLER_UNLOCK_DISCARD":
			for instance_id: String in view.killer.pending_unlock_discard.get("eligible_discard_instance_ids", []):
				_add_command("弃置 %s" % _killer_card_name(view, instance_id), "ResolveKillerUnlockOverflow", {"discard_card_instance_id":instance_id})
		"ENCOUNTER_ATTACK_SKILL":
			_add_command("不使用攻击技能", "PassAttackSkill", {})
		"ENCOUNTER_DEFENDER":
			for survivor_id: String in view.encounter.survivor_ids:
				if survivor_id not in view.encounter.attacked_survivor_ids:
					_add_command("由 %s 防守" % survivor_id, "SelectDefender", {"survivor_id":survivor_id})
		"ENCOUNTER_ITEM":
			_add_defense_item_actions(view)
		"ENCOUNTER_FLEE":
			_add_flee_actions(view)
		"DAMAGE_RESPONSE":
			_add_command("使用古代护符", "ResolveDamageResponse", {"use_amulet":true})
			_add_command("接受伤害", "ResolveDamageResponse", {"use_amulet":false})
		_:
			_add_plain_label("主机正在自动结算……")


func _add_survivor_activation_actions(view: Dictionary) -> void:
	var actor := _view_survivor(view, view.active_actor_id)
	if actor.is_empty():
		return
	if not bool(actor.get("main_action_completed", false)):
		_add_command("冷静", "Calm", {"actor_id":actor.id})
		for room_id: String in _legal_neighbors(actor.room_id, view.map.blocked_edge_ids):
			_add_command("移动到 %s" % room_id, "MoveSurvivor", {"actor_id":actor.id,"path_room_ids":[room_id]})
		for edge_id: String in view.map.blocked_edge_ids:
			if edge_id in map_board.blockable_edges_touching(actor.room_id):
				_add_command("拆除封锁 %s" % edge_id, "RemoveBlock", {"actor_id":actor.id,"edge_id":edge_id})
		if actor.room_id == "B4":
			_add_command("维修无线电", "RepairRadio", {"actor_id":actor.id})
		if actor.room_id in ["R1", "B1", "G5"]:
			_add_command("搜索", "BeginSearch", {"actor_id":actor.id})
		_add_special_actions(view, actor)
	if bool(actor.get("main_action_completed", false)):
		_add_command("结束 %s 的激活" % actor.id, "EndActivation", {"actor_id":actor.id})


func _add_special_actions(view: Dictionary, actor: Dictionary) -> void:
	if actor.id == "marco_carven" and _inventory_has(view, actor, "marco_medical_kit"):
		for target: Dictionary in view.survivors:
			if target.health == "injured":
				_add_command("医疗包治疗 %s" % target.id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"marco_medical_kit","target_survivor_id":target.id})
	if _inventory_has(view, actor, "trap_parts"):
		_add_command("在 %s 放置陷阱" % actor.room_id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"trap_parts"})
	if actor.room_id == "G3" and bool(view.map.get("first_aid_cabinet_available", false)):
		for target: Dictionary in view.survivors:
			if target.room_id == "G3" and target.health == "injured":
				_add_command("急救柜治疗 %s" % target.id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"g3_first_aid_cabinet","target_survivor_id":target.id})


func _add_search_resolution_actions(view: Dictionary) -> void:
	var pending: Dictionary = view.items.pending_private_draw
	var card_id: String = pending.card_instance_ids[0]
	_add_command("获得 %s" % _item_name(view, card_id), "ResolveSearchItem", _acquisition_payload(view, pending.survivor_id, card_id, {"take":true}))
	_add_command("弃置 %s" % _item_name(view, card_id), "ResolveSearchItem", {"take":false})


func _add_discover_resolution_actions(view: Dictionary) -> void:
	var pending: Dictionary = view.items.pending_private_draw
	for card_id: String in pending.card_instance_ids:
		_add_command("保留 %s" % _item_name(view, card_id), "ResolveDiscover", _acquisition_payload(view, pending.survivor_id, card_id, {"keep_card_instance_id":card_id}))


func _add_killer_main_actions(view: Dictionary) -> void:
	if view.killer.main_action_mode != "skill":
		for room_id: String in map_board.neighbors(view.killer.room_id):
			_add_command("移动到 %s" % room_id, "KillerMove", {"target_room_id":room_id})
		_add_command("搜索当前地点", "KillerSearch", {})
	if view.killer.main_action_mode == "":
		_add_killer_skill_actions(view, "main")


func _add_killer_skill_actions(view: Dictionary, timing: String) -> void:
	for instance_id: String in view.killer.hand:
		var definition_id: String = view.killer.skill_instances.get(instance_id, "")
		var definition: Dictionary = view.killer.definitions.get(definition_id, {})
		var effective_timing: String = definition.get("timing", "")
		if definition_id == "revving_chainsaw" and int(view.killer.level) >= int(definition.get("fast_from_level", 99)):
			effective_timing = "fast"
		if effective_timing != timing:
			continue
		var base_payload := {"card_instance_id":instance_id}
		match definition_id:
			"sense":
				for region: String in ["R", "B", "G"]:
					var payload := base_payload.duplicate()
					payload.region = region
					_add_command("%s：感知 %s 区" % [_killer_card_name(view, instance_id), region], "UseKillerSkill", payload)
			"pursue":
				for room_id: String in map_board.neighbors(view.killer.room_id):
					var payload := base_payload.duplicate()
					payload.path_room_ids = [room_id]
					_add_command("追逐到 %s" % room_id, "UseKillerSkill", payload)
			"madness":
				for edge_id: String in map_board.all_blockable_edges():
					var payload := base_payload.duplicate()
					payload.edge_id = edge_id
					payload.merge(_automatic_relocation(view, [edge_id]))
					_add_command("疯狂：封锁 %s" % edge_id, "UseKillerSkill", payload)
			"barricade":
				for edge_id: String in map_board.blockable_edges_touching(view.killer.room_id):
					var payload := base_payload.duplicate()
					payload.edge_id = edge_id
					payload.merge(_automatic_relocation(view, [edge_id]))
					_add_command("路障：%s" % edge_id, "UseKillerSkill", payload)
			"stayyyy":
				var costs := _other_hand_cards(view, instance_id, 4)
				if costs.size() == 4:
					var payload := base_payload.duplicate()
					payload.cost_card_instance_ids = costs
					payload.merge(_automatic_relocation(view, map_board.blockable_edges_touching(view.killer.room_id)))
					_add_command("留下！！封锁当前地点全部门", "UseKillerSkill", payload)
			"revving_chainsaw":
				var stay_payload := base_payload.duplicate()
				stay_payload.path_room_ids = []
				_add_command("链锯轰鸣：不移动", "UseKillerSkill", stay_payload)
				for room_id: String in map_board.neighbors(view.killer.room_id):
					var payload := base_payload.duplicate()
					payload.path_room_ids = [room_id]
					_add_command("链锯轰鸣：移动到 %s" % room_id, "UseKillerSkill", payload)
			"brutal_rage":
				var costs := _other_hand_cards(view, instance_id, 1)
				if costs.size() == 1:
					for room_id: String in map_board.neighbors(view.killer.room_id):
						var payload := base_payload.duplicate()
						payload.cost_card_instance_ids = costs
						payload.path_segments = [[room_id]]
						_add_command("残酷暴怒到 %s" % room_id, "UseKillerSkill", payload)


func _add_defense_item_actions(view: Dictionary) -> void:
	_add_command("不使用物品", "PassDefenseItem", {})
	var defender := _view_survivor(view, view.encounter.active_defender_id)
	if defender.is_empty():
		return
	var revolvers: Array = []
	var ammo: Array = []
	for instance_id: String in defender.inventory_instance_ids:
		var definition_id: String = view.items.item_instances.get(instance_id, "")
		if definition_id in ["longsword", "shortsword", "limestone_powder", "hatchet", "revolver"]:
			_add_command("使用 %s" % _item_name(view, instance_id), "SelectDefenseItem", {"card_instance_ids":[instance_id]})
		if definition_id == "revolver":
			revolvers.append(instance_id)
		elif definition_id == "ammo_pack":
			ammo.append(instance_id)
	for revolver_id: String in revolvers:
		for ammo_id: String in ammo:
			_add_command("左轮手枪 + 弹药包", "SelectDefenseItem", {"card_instance_ids":[revolver_id, ammo_id]})


func _add_flee_actions(view: Dictionary) -> void:
	for survivor_id: String in view.encounter.flee_pending_ids:
		var survivor := _view_survivor(view, survivor_id)
		_add_command("%s 留在原地" % survivor_id, "ConfirmFlee", {"survivor_id":survivor_id,"path_room_ids":[]})
		for room_id: String in _legal_neighbors(survivor.room_id, view.map.blocked_edge_ids):
			_add_command("%s 逃到 %s" % [survivor_id, room_id], "ConfirmFlee", {"survivor_id":survivor_id,"path_room_ids":[room_id]})


func _local_side_acts(phase: String) -> bool:
	if phase.begins_with("SURVIVOR") or phase in ["ENCOUNTER_DEFENDER", "ENCOUNTER_ITEM", "ENCOUNTER_FLEE", "DAMAGE_RESPONSE"]:
		return session.local_side == "survivors"
	if phase.begins_with("KILLER") or phase == "ENCOUNTER_ATTACK_SKILL":
		return session.local_side == "killer"
	return false


func _add_command(label: String, command_type: String, payload: Dictionary) -> void:
	action_list.add_child(_button(label, func(): _queue_command(label, command_type, payload)))


func _queue_command(label: String, command_type: String, payload: Dictionary) -> void:
	pending_command = {"type":command_type,"payload":payload.duplicate(true),"label":label}
	confirmation_label.text = "待提交：%s\n确认后由主机验证并结算，接受后不可撤销。" % label
	confirmation_panel.visible = true


func _confirm_pending_command() -> void:
	if pending_command.is_empty():
		return
	var command: Dictionary = pending_command.duplicate(true)
	_cancel_pending_command()
	var result: Dictionary = session.submit_command(command.type, command.payload)
	if result.has("accepted") and not result.get("queued", false) and not bool(result.accepted):
		_on_command_completed(result)


func _cancel_pending_command() -> void:
	pending_command = {}
	confirmation_panel.visible = false
	map_board.clear_selection()


func _switch_debug_side() -> void:
	var target := "killer" if session.local_side == "survivors" else "survivors"
	session.set_debug_side(target)


func _acquisition_payload(view: Dictionary, survivor_id: String, card_id: String, initial: Dictionary) -> Dictionary:
	var payload := initial.duplicate(true)
	if view.items.item_instances.get(card_id, "") == "key":
		return payload
	var survivor := _view_survivor(view, survivor_id)
	var candidates: Array = survivor.inventory_instance_ids.duplicate()
	candidates.append(card_id)
	if candidates.size() > int(view.items.inventory_limit):
		var kept: Array = survivor.inventory_instance_ids.slice(0, int(view.items.inventory_limit) - 1)
		kept.append(card_id)
		payload.keep_inventory_instance_ids = kept
	return payload


func _automatic_relocation(view: Dictionary, target_edges: Array) -> Dictionary:
	var new_count := 0
	for edge_id: String in target_edges:
		if edge_id not in view.map.blocked_edge_ids:
			new_count += 1
	var shortage: int = maxi(0, new_count - int(view.map.block_supply_remaining))
	var relocations: Array = []
	for edge_id: String in view.map.blocked_edge_ids:
		if edge_id not in target_edges and relocations.size() < shortage:
			relocations.append(edge_id)
	return {"relocate_edge_ids":relocations}


func _other_hand_cards(view: Dictionary, excluded_id: String, count: int) -> Array:
	var result: Array = []
	for instance_id: String in view.killer.hand:
		if instance_id != excluded_id:
			result.append(instance_id)
			if result.size() == count:
				break
	return result


func _legal_neighbors(room_id: String, blocked_edges: Array) -> Array:
	var result: Array = []
	for neighbor: String in map_board.neighbors(room_id):
		if map_board.edge_id(room_id, neighbor) not in blocked_edges:
			result.append(neighbor)
	return result


func _view_survivor(view: Dictionary, survivor_id: String) -> Dictionary:
	for survivor: Dictionary in view.get("survivors", []):
		if survivor.id == survivor_id:
			return survivor
	return {}


func _inventory_has(view: Dictionary, survivor: Dictionary, definition_id: String) -> bool:
	for instance_id: String in survivor.get("inventory_instance_ids", []):
		if view.items.item_instances.get(instance_id, "") == definition_id:
			return true
	return false


func _item_name(view: Dictionary, instance_id: String) -> String:
	var definition_id: String = view.items.item_instances.get(instance_id, instance_id)
	return view.items.definitions.get(definition_id, {}).get("name_zh", definition_id)


func _killer_card_name(view: Dictionary, instance_id: String) -> String:
	var definition_id: String = view.killer.skill_instances.get(instance_id, instance_id)
	return view.killer.definitions.get(definition_id, {}).get("name_zh", definition_id)


func _append_events(events: Array) -> void:
	for event: Dictionary in events:
		event_lines.append("[%03d] %s　%s" % [int(event.get("event_sequence", 0)), event.get("type", ""), JSON.stringify(event.get("payload", {}))])
	while event_lines.size() > 80:
		event_lines.pop_front()
	log_label.text = "\n".join(event_lines)
	log_label.scroll_to_line(maxi(0, event_lines.size() - 1))


func _add_plain_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_list.add_child(label)


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	return button


func _clear_container(container: Container) -> void:
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _set_lobby_status(message: String) -> void:
	lobby_status.text = message


func _set_game_status(message: String) -> void:
	phase_label.text = message
