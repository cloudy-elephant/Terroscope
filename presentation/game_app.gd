extends Control

const LanSessionScript = preload("res://network/lan_session.gd")
const MapBoardScript = preload("res://presentation/map_board.gd")
const FeedbackControllerScript = preload("res://presentation/feedback_controller.gd")

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
var tutorial_label: Label
var tutorial_visible := true
var feedback
var pending_command: Dictionary = {}
var pending_path_selection: Dictionary = {}
var pending_brutal_selection: Dictionary = {}
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
	feedback = FeedbackControllerScript.new()
	add_child(feedback)
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
	top_bar.add_child(_button("教学提示", _toggle_tutorial))
	top_bar.add_child(_button("返回大厅", _show_lobby))
	tutorial_label = Label.new()
	tutorial_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tutorial_label.add_theme_color_override("font_color", Color("d7c47a"))
	game_panel.add_child(tutorial_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_panel.add_child(body)
	map_board = MapBoardScript.new()
	map_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_board.room_clicked.connect(_on_room_clicked)
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
	_render_tutorial(view)
	_render_actions(view)


func _render_info(view: Dictionary) -> void:
	var lines: Array[String] = []
	var killer: Dictionary = view.get("killer", {})
	lines.append("[b]屠夫[/b]　等级 %d　力量 %d%s" % [int(killer.get("level", 0)), int(killer.get("effective_strength", 0)), "　位置 %s" % killer.room_id if killer.has("room_id") else "　潜行中"])
	var objectives: Dictionary = view.get("objectives", {})
	if bool(view.get("firecracker_active", false)):
		lines.append("[color=#ffd166]爆竹生效：本轮所有地点均视为有噪声[/color]")
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
	if view.get("phase", "") == "GAME_OVER":
		var stats: Dictionary = view.get("stats", {})
		lines.append("[b]本局统计[/b]　命令 %d　完整轮次 %d　搜索 %d　物品 %d　交换 %d　遭遇 %d　防守 %d 成 / %d 败" % [
			int(stats.get("commands_accepted", 0)), int(stats.get("rounds_completed", 0)),
			int(stats.get("searches_completed", 0)), int(stats.get("items_used", 0)),
			int(stats.get("exchanges_completed", 0)), int(stats.get("encounters_started", 0)),
			int(stats.get("defenses_succeeded", 0)), int(stats.get("defenses_failed", 0)),
		])
	info_label.text = "\n".join(lines)


func _render_actions(view: Dictionary) -> void:
	_clear_container(action_list)
	pending_command = {}
	pending_path_selection = {}
	pending_brutal_selection = {}
	confirmation_panel.visible = false
	map_board.clear_selection()
	map_board.clear_pending_destination()
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
			var damaged := _view_survivor(view, view.get("pending_damage", {}).get("current_survivor_id", ""))
			if not damaged.is_empty() and _inventory_has(view, damaged, "ancient_amulet"):
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
		_add_path_builder("移动（1～2 步）", "MoveSurvivor", {"actor_id":actor.id}, actor.room_id, 2, view.map.blocked_edge_ids)
		for edge_id: String in view.map.blocked_edge_ids:
			if edge_id in map_board.blockable_edges_touching(actor.room_id):
				_add_command("拆除封锁 %s" % edge_id, "RemoveBlock", {"actor_id":actor.id,"edge_id":edge_id})
		if actor.room_id == "B4":
			_add_command("维修无线电", "RepairRadio", {"actor_id":actor.id})
		if actor.room_id in ["R1", "B1", "G5"]:
			_add_command("搜索", "BeginSearch", {"actor_id":actor.id})
		_add_special_actions(view, actor)
	_add_extra_item_actions(view, actor)
	_add_exchange_actions(view, actor)
	if bool(actor.get("main_action_completed", false)):
		_add_command("结束 %s 的激活" % actor.id, "EndActivation", {"actor_id":actor.id})


func _add_special_actions(view: Dictionary, actor: Dictionary) -> void:
	if actor.id == "marco_carven":
		for card_id: String in view.items.discard:
			if view.items.item_instances.get(card_id, "") in ["adrenaline", "sedatives"]:
				for option: Dictionary in _acquisition_payloads(view, actor.id, card_id, {"actor_id":actor.id,"source_id":"marco_equipped","card_instance_id":card_id}):
					_add_command("装备齐全：取回 %s%s" % [_item_name(view, card_id), option.suffix], "UseSpecialAction", option.payload)
	if actor.id == "william_hooper":
		_add_path_builder("冲刺（1～3 步）", "UseSpecialAction", {"actor_id":actor.id,"source_id":"william_sprint"}, actor.room_id, 3, view.map.blocked_edge_ids)
	if actor.room_id == "B4" and _inventory_has(view, actor, "toolbox"):
		_add_command("使用工具箱维修 +2", "UseSpecialAction", {"actor_id":actor.id,"source_id":"toolbox"})
	if actor.id == "marco_carven" and _inventory_has(view, actor, "marco_medical_kit"):
		for target: Dictionary in view.survivors:
			if target.health == "injured":
				_add_command("医疗包治疗 %s" % target.id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"marco_medical_kit","target_survivor_id":target.id})
	if _inventory_has(view, actor, "trap_parts") and view.map.get("trap_room_id", "").is_empty():
		_add_command("在 %s 放置陷阱" % actor.room_id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"trap_parts"})
	if actor.room_id == "G3" and bool(view.map.get("first_aid_cabinet_available", false)):
		for target: Dictionary in view.survivors:
			if target.room_id == "G3" and target.health == "injured":
				_add_command("急救柜治疗 %s" % target.id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"g3_first_aid_cabinet","target_survivor_id":target.id})


func _add_extra_item_actions(view: Dictionary, actor: Dictionary) -> void:
	for card_id: String in actor.inventory_instance_ids:
		var definition_id: String = view.items.item_instances.get(card_id, "")
		match definition_id:
			"sedatives":
				if int(actor.fear) > 0:
					_add_command("额外行动：使用镇静剂", "UseItem", {"actor_id":actor.id,"card_instance_id":card_id})
			"firecracker":
				if not bool(view.get("firecracker_active", false)):
					_add_command("额外行动：点燃爆竹", "UseItem", {"actor_id":actor.id,"card_instance_id":card_id})
			"hatchet":
				for edge_id: String in view.map.blocked_edge_ids:
					if edge_id in map_board.blockable_edges_touching(actor.room_id):
						_add_command("额外行动：手斧拆除 %s" % edge_id, "UseItem", {"actor_id":actor.id,"card_instance_id":card_id,"edge_id":edge_id})
			"whiskey_bottle":
				for room_id: String in map_board.neighbors(actor.room_id):
					_add_command("额外行动：向 %s 投掷酒瓶" % room_id, "UseItem", {"actor_id":actor.id,"card_instance_id":card_id,"target_room_id":room_id})
			"adrenaline":
				_add_path_builder("额外行动：肾上腺素（1～4 步）", "UseItem", {"actor_id":actor.id,"card_instance_id":card_id}, actor.room_id, 4, view.map.blocked_edge_ids)


func _add_exchange_actions(view: Dictionary, actor: Dictionary) -> void:
	var limit: int = int(view.items.inventory_limit)
	for target: Dictionary in view.survivors:
		if target.id == actor.id or target.health == "eliminated" or target.room_id != actor.room_id:
			continue
		if target.inventory_instance_ids.size() < limit:
			for card_id: String in actor.inventory_instance_ids:
				var actor_final: Array = actor.inventory_instance_ids.duplicate()
				var target_final: Array = target.inventory_instance_ids.duplicate()
				actor_final.erase(card_id)
				target_final.append(card_id)
				_add_command("交给 %s：%s" % [target.id, _item_name(view, card_id)], "ExchangeItems", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final})
		if actor.inventory_instance_ids.size() < limit:
			for card_id: String in target.inventory_instance_ids:
				var actor_final: Array = actor.inventory_instance_ids.duplicate()
				var target_final: Array = target.inventory_instance_ids.duplicate()
				target_final.erase(card_id)
				actor_final.append(card_id)
				_add_command("从 %s 接收：%s" % [target.id, _item_name(view, card_id)], "ExchangeItems", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final})
		for actor_card: String in actor.inventory_instance_ids:
			for target_card: String in target.inventory_instance_ids:
				var actor_final: Array = actor.inventory_instance_ids.duplicate()
				var target_final: Array = target.inventory_instance_ids.duplicate()
				actor_final[actor_final.find(actor_card)] = target_card
				target_final[target_final.find(target_card)] = actor_card
				_add_command("与 %s 交换：%s ↔ %s" % [target.id, _item_name(view, actor_card), _item_name(view, target_card)], "ExchangeItems", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final})


func _add_search_resolution_actions(view: Dictionary) -> void:
	var pending: Dictionary = view.items.pending_private_draw
	var card_id: String = pending.card_instance_ids[0]
	for option: Dictionary in _acquisition_payloads(view, pending.survivor_id, card_id, {"take":true}):
		_add_command("获得 %s%s" % [_item_name(view, card_id), option.suffix], "ResolveSearchItem", option.payload)
	_add_command("弃置 %s" % _item_name(view, card_id), "ResolveSearchItem", {"take":false})


func _add_discover_resolution_actions(view: Dictionary) -> void:
	var pending: Dictionary = view.items.pending_private_draw
	for card_id: String in pending.card_instance_ids:
		for option: Dictionary in _acquisition_payloads(view, pending.survivor_id, card_id, {"keep_card_instance_id":card_id}):
			_add_command("保留 %s%s" % [_item_name(view, card_id), option.suffix], "ResolveDiscover", option.payload)


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
					for relocations: Array in _relocation_options(view, [edge_id]):
						var payload := base_payload.duplicate()
						payload.edge_id = edge_id
						payload.relocate_edge_ids = relocations
						_add_command("疯狂：封锁 %s%s" % [edge_id, _relocation_suffix(relocations)], "UseKillerSkill", payload)
			"barricade":
				for edge_id: String in map_board.blockable_edges_touching(view.killer.room_id):
					for relocations: Array in _relocation_options(view, [edge_id]):
						var payload := base_payload.duplicate()
						payload.edge_id = edge_id
						payload.relocate_edge_ids = relocations
						_add_command("路障：%s%s" % [edge_id, _relocation_suffix(relocations)], "UseKillerSkill", payload)
			"stayyyy":
				for costs: Array in _other_hand_card_choices(view, instance_id, 4):
					var targets: Array = map_board.blockable_edges_touching(view.killer.room_id)
					for relocations: Array in _relocation_options(view, targets):
						var payload := base_payload.duplicate()
						payload.cost_card_instance_ids = costs
						payload.relocate_edge_ids = relocations
						_add_command("留下！！封锁当前地点全部门%s" % _relocation_suffix(relocations), "UseKillerSkill", payload)
			"revving_chainsaw":
				var stay_payload := base_payload.duplicate()
				stay_payload.path_room_ids = []
				_add_command("链锯轰鸣：不移动", "UseKillerSkill", stay_payload)
				for room_id: String in map_board.neighbors(view.killer.room_id):
					var payload := base_payload.duplicate()
					payload.path_room_ids = [room_id]
					_add_command("链锯轰鸣：移动到 %s" % room_id, "UseKillerSkill", payload)
			"brutal_rage":
				for costs: Array in _other_hand_card_choices(view, instance_id, 1):
					var cost_name := _killer_card_name(view, costs[0])
					action_list.add_child(_button("残酷暴怒（弃置 %s）：选择路径" % cost_name, Callable(self, "_start_brutal_selection").bind(instance_id, costs.duplicate(), view.duplicate(true))))


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


func _add_path_builder(label: String, command_type: String, payload: Dictionary, start_room_id: String, maximum_steps: int, blocked_edges: Array) -> void:
	if command_type == "MoveSurvivor":
		_add_plain_label(label)
		for path: Array in _legal_paths(start_room_id, maximum_steps, blocked_edges):
			var route_label := "%d 步：%s" % [path.size(), _path_label(path)]
			action_list.add_child(_button(route_label, Callable(self, "_queue_path_command").bind(
				label, command_type, payload.duplicate(true), path.duplicate()
			)))
	action_list.add_child(_button("%s：在地图上逐步选择" % label, Callable(self, "_start_path_selection").bind(
		label, command_type, payload.duplicate(true), start_room_id, maximum_steps, blocked_edges.duplicate()
	)))


func _queue_path_command(label: String, command_type: String, payload: Dictionary, path: Array) -> void:
	var command_payload := payload.duplicate(true)
	command_payload.path_room_ids = path.duplicate()
	_queue_command("%s：%s" % [label, _path_label(path)], command_type, command_payload)


func _start_path_selection(label: String, command_type: String, payload: Dictionary, start_room_id: String, maximum_steps: int, blocked_edges: Array) -> void:
	pending_path_selection = {
		"label":label,
		"command_type":command_type,
		"payload":payload.duplicate(true),
		"start_room_id":start_room_id,
		"current_room_id":start_room_id,
		"maximum_steps":maximum_steps,
		"blocked_edge_ids":blocked_edges.duplicate(),
		"path_room_ids":[],
	}
	_render_path_selection()


func _render_path_selection() -> void:
	_clear_container(action_list)
	var path: Array = pending_path_selection.path_room_ids
	var current_room_id: String = pending_path_selection.current_room_id
	var legal_rooms := _legal_neighbors(current_room_id, pending_path_selection.blocked_edge_ids)
	map_board.set_selection(legal_rooms, path)
	_add_plain_label("%s\n已选 %d / %d 步：%s" % [
		pending_path_selection.label,
		path.size(),
		int(pending_path_selection.maximum_steps),
		_path_label(path) if not path.is_empty() else "请选择第一步",
	])
	if path.size() < int(pending_path_selection.maximum_steps):
		for room_id: String in legal_rooms:
			action_list.add_child(_button("第 %d 步：%s %s" % [path.size() + 1, room_id, map_board.room_name(room_id)], Callable(self, "_append_path_room").bind(room_id)))
	if not path.is_empty():
		action_list.add_child(_button("完成路径", _finish_path_selection))
		action_list.add_child(_button("撤回上一步", _undo_path_step))
	action_list.add_child(_button("取消路径选择", _cancel_path_selection))


func _append_path_room(room_id: String) -> void:
	if pending_path_selection.is_empty():
		return
	if room_id not in _legal_neighbors(pending_path_selection.current_room_id, pending_path_selection.blocked_edge_ids):
		return
	pending_path_selection.path_room_ids.append(room_id)
	pending_path_selection.current_room_id = room_id
	_render_path_selection()


func _undo_path_step() -> void:
	if pending_path_selection.is_empty() or pending_path_selection.path_room_ids.is_empty():
		return
	pending_path_selection.path_room_ids.pop_back()
	pending_path_selection.current_room_id = pending_path_selection.start_room_id if pending_path_selection.path_room_ids.is_empty() else pending_path_selection.path_room_ids.back()
	_render_path_selection()


func _finish_path_selection() -> void:
	if pending_path_selection.is_empty() or pending_path_selection.path_room_ids.is_empty():
		return
	var selection := pending_path_selection.duplicate(true)
	var payload: Dictionary = selection.payload
	payload.path_room_ids = selection.path_room_ids
	var label := "%s：%s" % [selection.label, " → ".join(selection.path_room_ids)]
	pending_path_selection = {}
	_render_actions(session.current_view)
	_queue_command(label, selection.command_type, payload)


func _cancel_path_selection() -> void:
	pending_path_selection = {}
	map_board.clear_selection()
	_render_actions(session.current_view)


func _on_room_clicked(room_id: String) -> void:
	if not pending_path_selection.is_empty():
		_append_path_room(room_id)
		return
	_set_game_status("地点 %s；请从右侧选择对应行动" % room_id)


func _queue_command(label: String, command_type: String, payload: Dictionary) -> void:
	pending_command = {"type":command_type,"payload":payload.duplicate(true),"label":label}
	var path_value: Variant = payload.get("path_room_ids", [])
	if path_value is Array and not path_value.is_empty():
		map_board.set_pending_destination(str(path_value.back()))
	else:
		map_board.clear_pending_destination()
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
	map_board.clear_pending_destination()


func _switch_debug_side() -> void:
	var target := "killer" if session.local_side == "survivors" else "survivors"
	session.set_debug_side(target)


func _acquisition_payloads(view: Dictionary, survivor_id: String, card_id: String, initial: Dictionary) -> Array:
	if view.items.item_instances.get(card_id, "") == "key":
		return [{"payload":initial.duplicate(true),"suffix":""}]
	var survivor := _view_survivor(view, survivor_id)
	var candidates: Array = survivor.inventory_instance_ids.duplicate()
	candidates.append(card_id)
	var limit: int = int(view.items.inventory_limit)
	if candidates.size() <= limit:
		return [{"payload":initial.duplicate(true),"suffix":""}]
	var combinations: Array = []
	_collect_combinations(candidates, limit, 0, [], combinations)
	var result: Array = []
	for kept: Array in combinations:
		var payload := initial.duplicate(true)
		payload.keep_inventory_instance_ids = kept
		var names: Array[String] = []
		for instance_id: String in kept:
			names.append(_item_name(view, instance_id))
		result.append({"payload":payload,"suffix":"（最终保留：%s）" % "、".join(names)})
	return result


func _collect_combinations(values: Array, count: int, start_index: int, current: Array, output: Array) -> void:
	if current.size() == count:
		output.append(current.duplicate())
		return
	for index in range(start_index, values.size()):
		var next := current.duplicate()
		next.append(values[index])
		_collect_combinations(values, count, index + 1, next, output)


func _relocation_options(view: Dictionary, target_edges: Array) -> Array:
	var new_count := 0
	for edge_id: String in target_edges:
		if edge_id not in view.map.blocked_edge_ids:
			new_count += 1
	var shortage: int = maxi(0, new_count - int(view.map.block_supply_remaining))
	var candidates: Array = []
	for edge_id: String in view.map.blocked_edge_ids:
		if edge_id not in target_edges:
			candidates.append(edge_id)
	if shortage == 0:
		return [[]]
	if candidates.size() < shortage:
		return []
	var result: Array = []
	_collect_combinations(candidates, shortage, 0, [], result)
	return result


func _other_hand_card_choices(view: Dictionary, excluded_id: String, count: int) -> Array:
	var candidates: Array = []
	for instance_id: String in view.killer.hand:
		if instance_id != excluded_id:
			candidates.append(instance_id)
	if candidates.size() < count:
		return []
	var result: Array = []
	_collect_combinations(candidates, count, 0, [], result)
	return result


func _relocation_suffix(relocations: Array) -> String:
	return "" if relocations.is_empty() else "（转移 %s）" % "、".join(relocations)


func _start_brutal_selection(card_instance_id: String, cost_ids: Array, view: Dictionary) -> void:
	pending_brutal_selection = {
		"card_instance_id":card_instance_id,
		"cost_card_instance_ids":cost_ids.duplicate(),
		"segments":[],
		"current_room_id":view.killer.room_id,
		"remaining_blocked_edge_ids":view.map.blocked_edge_ids.duplicate(),
	}
	_render_brutal_selection()


func _render_brutal_selection() -> void:
	_clear_container(action_list)
	var segments: Array = pending_brutal_selection.segments
	_add_plain_label("残酷暴怒路径：%s" % (_segments_label(segments) if not segments.is_empty() else "尚未选择"))
	for path: Array in _all_paths(pending_brutal_selection.current_room_id, 2):
		action_list.add_child(_button("添加移动段：%s" % " → ".join(path), Callable(self, "_append_brutal_segment").bind(path.duplicate())))
	if not segments.is_empty():
		action_list.add_child(_button("完成路径选择", _finish_brutal_selection))
	action_list.add_child(_button("取消残酷暴怒", _cancel_brutal_selection))


func _append_brutal_segment(path: Array) -> void:
	var remaining: Array = pending_brutal_selection.remaining_blocked_edge_ids
	var room_id: String = pending_brutal_selection.current_room_id
	var removed_block := false
	for target_room_id: String in path:
		var crossed_edge: String = map_board.edge_id(room_id, target_room_id)
		if crossed_edge in remaining:
			remaining.erase(crossed_edge)
			removed_block = true
		room_id = target_room_id
	pending_brutal_selection.segments.append(path.duplicate())
	pending_brutal_selection.current_room_id = room_id
	if not removed_block or pending_brutal_selection.segments.size() >= 8:
		_finish_brutal_selection()
	else:
		_render_brutal_selection()


func _finish_brutal_selection() -> void:
	if pending_brutal_selection.is_empty() or pending_brutal_selection.segments.is_empty():
		return
	var selection := pending_brutal_selection.duplicate(true)
	var label := "残酷暴怒：%s" % _segments_label(selection.segments)
	pending_brutal_selection = {}
	_render_actions(session.current_view)
	_queue_command(label, "UseKillerSkill", {
		"card_instance_id":selection.card_instance_id,
		"cost_card_instance_ids":selection.cost_card_instance_ids,
		"path_segments":selection.segments,
	})


func _cancel_brutal_selection() -> void:
	pending_brutal_selection = {}
	map_board.clear_selection()
	_render_actions(session.current_view)


func _all_paths(start_room_id: String, maximum_steps: int) -> Array:
	var paths: Array = []
	_extend_all_paths(start_room_id, maximum_steps, [], paths)
	return paths


func _extend_all_paths(current_room_id: String, maximum_steps: int, current_path: Array, paths: Array) -> void:
	if current_path.size() >= maximum_steps:
		return
	for neighbor: String in map_board.neighbors(current_room_id):
		var next_path := current_path.duplicate()
		next_path.append(neighbor)
		paths.append(next_path)
		_extend_all_paths(neighbor, maximum_steps, next_path, paths)


func _segments_label(segments: Array) -> String:
	var labels: Array[String] = []
	for segment: Array in segments:
		labels.append(" → ".join(segment))
	return " / ".join(labels)


func _legal_neighbors(room_id: String, blocked_edges: Array) -> Array:
	var result: Array = []
	for neighbor: String in map_board.neighbors(room_id):
		if map_board.edge_id(room_id, neighbor) not in blocked_edges:
			result.append(neighbor)
	return result


func _legal_paths(start_room_id: String, maximum_steps: int, blocked_edges: Array) -> Array:
	var result: Array = []
	_collect_legal_paths(start_room_id, maximum_steps, blocked_edges, [], [start_room_id], result)
	return result


func _collect_legal_paths(current_room_id: String, maximum_steps: int, blocked_edges: Array, current_path: Array, visited: Array, output: Array) -> void:
	if current_path.size() >= maximum_steps:
		return
	for neighbor: String in _legal_neighbors(current_room_id, blocked_edges):
		if neighbor in visited:
			continue
		var next_path := current_path.duplicate()
		next_path.append(neighbor)
		output.append(next_path)
		var next_visited := visited.duplicate()
		next_visited.append(neighbor)
		_collect_legal_paths(neighbor, maximum_steps, blocked_edges, next_path, next_visited, output)


func _path_label(path: Array) -> String:
	var labels: Array[String] = []
	for room_value: Variant in path:
		var room_id := str(room_value)
		labels.append("%s %s" % [room_id, map_board.room_name(room_id)])
	return " → ".join(labels)


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
	if feedback != null:
		feedback.present(events, map_board)


func _toggle_tutorial() -> void:
	tutorial_visible = not tutorial_visible
	if not session.current_view.is_empty():
		_render_tutorial(session.current_view)


func _render_tutorial(view: Dictionary) -> void:
	tutorial_label.visible = tutorial_visible
	if not tutorial_visible:
		return
	var phase: String = view.get("phase", "")
	var tips := {
		"SURVIVOR_CHOOSE_ACTOR":"先选一名本轮尚未行动的幸存者；三人顺序可自由决定。",
		"SURVIVOR_ACTIVATION":"完成恰好一个主要行动；额外物品与同房交换可在主要行动前后使用，最后结束激活。",
		"SURVIVOR_SEARCH_RESOLVE":"抽牌已经发生；选择获得或弃置。超出 3 件时明确选择最终保留物品。",
		"SURVIVOR_DISCOVER_SELECT":"三人行动后选一名发现者；他会抽 2 张并保留 1 张。",
		"SURVIVOR_DISCOVER_RESOLVE":"抽牌已经发生；选定保留牌并处理容量，另一张自动弃置。",
		"KILLER_FAST":"可打出快速技能，也可以结束阶段。根据上一轮公开噪声推断幸存者路线。",
		"KILLER_MAIN":"执行两次移动或搜索，或用一张主要技能替代；搜索命中立即进入遭遇。",
		"KILLER_SLOW":"可打出一张合法慢速技能；结束后抽牌并开始下一轮。",
		"ENCOUNTER_ATTACK_SKILL":"屠夫选择攻击技能或跳过。",
		"ENCOUNTER_DEFENDER":"幸存者选择一名尚未防守的同房角色。",
		"ENCOUNTER_ITEM":"选择至多一件防御物品；左轮手枪可额外搭配一份弹药。",
		"ENCOUNTER_FLEE":"每名存活参与者确认留在原地或移动一步。",
		"DAMAGE_RESPONSE":"若持有古代护符可弃置并防止本次伤害，否则接受伤害。",
		"GAME_OVER":"对局已结束；查看统计后可快速重开。",
	}
	tutorial_label.text = "提示：%s" % tips.get(phase, "主机正在自动结算，请等待阶段推进。")


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
