extends Control

const LanSessionScript = preload("res://network/lan_session.gd")
const MapBoardScript = preload("res://presentation/map_board.gd")
const FeedbackControllerScript = preload("res://presentation/feedback_controller.gd")

const PHASE_NAMES := {
	"SETUP":"准备对局", "SURVIVOR_START":"幸存者阶段开始",
	"SURVIVOR_CHOOSE_ACTOR":"选择幸存者", "SURVIVOR_ACTIVATION":"幸存者行动",
	"SURVIVOR_SEARCH_RESOLVE":"处理搜索牌", "SURVIVOR_DISCOVER_SELECT":"选择发现者",
	"SURVIVOR_DISCOVER_RESOLVE":"处理发现牌", "SURVIVOR_REVEAL_NOISE":"公开噪声线索",
	"KILLER_START":"杀手阶段开始", "KILLER_FAST":"杀手快速阶段",
	"KILLER_MAIN":"杀手主要阶段", "KILLER_SLOW":"杀手慢速阶段",
	"KILLER_DRAW":"杀手补充手牌", "KILLER_DECK_DISCARD":"杀手牌库损耗",
	"KILLER_REAPPEAR":"屠夫重新现身", "KILLER_UNLOCK_DISCARD":"技能解锁弃牌",
	"ENCOUNTER_START":"遭遇开始", "ENCOUNTER_ATTACK_SKILL":"遭遇：攻击牌",
	"ENCOUNTER_DEFENDER":"遭遇：选择防守者", "ENCOUNTER_ITEM":"遭遇：防御物品",
	"ENCOUNTER_ROLL":"遭遇：掷防御骰", "ENCOUNTER_FLEE":"遭遇：逃离",
	"DAMAGE_RESPONSE":"伤害响应", "GAME_OVER":"对局结束",
}

const SURVIVOR_NAMES := {
	"marco_carven":"马尔科",
	"william_hooper":"威廉",
	"anna_kubrick":"安娜",
}

const HEALTH_NAMES := {
	"healthy":"健康",
	"injured":"受伤",
	"eliminated":"淘汰",
}

const ACTION_CATEGORIES := [
	{"id":"movement", "label":"移动"},
	{"id":"main", "label":"主要行动"},
	{"id":"items", "label":"物品"},
	{"id":"abilities", "label":"角色能力"},
]

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
var action_category_containers: Dictionary = {}
var action_category_buttons: Dictionary = {}
var current_action_category := ""
var expanded_action_category := "movement"
var confirmation_panel: VBoxContainer
var confirmation_label: Label
var card_zone_title: Label
var card_hand: HBoxContainer
var discard_button: Button
var card_detail_popup: PopupPanel
var card_detail_title: Label
var card_detail_text: RichTextLabel
var log_label: RichTextLabel
var switch_button: Button
var tutorial_label: Label
var tutorial_visible := true
var feedback
var pending_command: Dictionary = {}
var pending_path_selection: Dictionary = {}
var pending_brutal_selection: Dictionary = {}
var event_lines_by_side := {"survivors":[], "killer":[]}


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
	side_panel.custom_minimum_size.x = 420
	body.add_child(side_panel)
	info_label = RichTextLabel.new()
	info_label.bbcode_enabled = true
	info_label.fit_content = false
	info_label.custom_minimum_size.y = 205
	side_panel.add_child(info_label)
	var action_title := Label.new()
	action_title.text = "选择行动"
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

	var card_zone := PanelContainer.new()
	card_zone.custom_minimum_size.y = 126
	game_panel.add_child(card_zone)
	var card_layout := HBoxContainer.new()
	card_layout.add_theme_constant_override("separation", 10)
	card_zone.add_child(card_layout)
	var hand_meta := VBoxContainer.new()
	hand_meta.custom_minimum_size.x = 150
	card_layout.add_child(hand_meta)
	card_zone_title = Label.new()
	card_zone_title.text = "手牌"
	card_zone_title.add_theme_font_size_override("font_size", 18)
	hand_meta.add_child(card_zone_title)
	var hand_hint := Label.new()
	hand_hint.text = "点击卡牌查看完整效果"
	hand_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hand_hint.add_theme_color_override("font_color", Color("aeb8c2"))
	hand_meta.add_child(hand_hint)
	var hand_scroll := ScrollContainer.new()
	hand_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_scroll.custom_minimum_size.y = 116
	card_layout.add_child(hand_scroll)
	card_hand = HBoxContainer.new()
	card_hand.add_theme_constant_override("separation", 8)
	hand_scroll.add_child(card_hand)
	discard_button = _button("弃牌区\n0 张", _show_discard_detail)
	discard_button.custom_minimum_size = Vector2(120, 104)
	discard_button.tooltip_text = "查看当前阵营可见的弃牌"
	card_layout.add_child(discard_button)

	var log_title := Label.new()
	log_title.text = "行动记录 · 仅当前阵营可见"
	log_title.add_theme_font_size_override("font_size", 16)
	game_panel.add_child(log_title)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.custom_minimum_size.y = 88
	game_panel.add_child(log_label)

	card_detail_popup = PopupPanel.new()
	add_child(card_detail_popup)
	var detail_margin := MarginContainer.new()
	detail_margin.add_theme_constant_override("margin_left", 20)
	detail_margin.add_theme_constant_override("margin_right", 20)
	detail_margin.add_theme_constant_override("margin_top", 16)
	detail_margin.add_theme_constant_override("margin_bottom", 16)
	card_detail_popup.add_child(detail_margin)
	var detail_layout := VBoxContainer.new()
	detail_layout.custom_minimum_size = Vector2(470, 310)
	detail_layout.add_theme_constant_override("separation", 12)
	detail_margin.add_child(detail_layout)
	card_detail_title = Label.new()
	card_detail_title.add_theme_font_size_override("font_size", 24)
	detail_layout.add_child(card_detail_title)
	card_detail_text = RichTextLabel.new()
	card_detail_text.bbcode_enabled = true
	card_detail_text.fit_content = false
	card_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_layout.add_child(card_detail_text)
	var close_detail := _button("关闭", func(): card_detail_popup.hide())
	detail_layout.add_child(close_detail)


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
	event_lines_by_side = {"survivors":[], "killer":[]}
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
	_render_card_zone(view)
	_render_narrative_log()
	_render_tutorial(view)
	_render_actions(view)


func _render_info(view: Dictionary) -> void:
	var lines: Array[String] = []
	var killer: Dictionary = view.get("killer", {})
	lines.append("屠夫　等级 %d　力量 %d%s" % [int(killer.get("level", 0)), int(killer.get("effective_strength", 0)), "　位置 %s" % killer.room_id if killer.has("room_id") else "　潜行中"])
	var objectives: Dictionary = view.get("objectives", {})
	if bool(view.get("firecracker_active", false)):
		lines.append("[color=#ffd166]爆竹生效：本轮所有地点均视为有噪声[/color]")
	if session.local_side == "survivors":
		lines.append("钥匙 %d / 5　无线电 %d / 5　救援 %s" % [view.items.get("team_key_count", 0), objectives.get("radio_progress", 0), str(objectives.get("rescue_countdown", "未启动"))])
		for survivor: Dictionary in view.get("survivors", []):
			var item_names: Array[String] = []
			for instance_id: String in survivor.get("inventory_instance_ids", []):
				item_names.append(_item_name(view, instance_id))
			lines.append("%s　%s　%s　恐惧 %d　物品：%s" % [_survivor_name(survivor.id), survivor.get("room_id", "?"), _health_name(survivor.health), int(survivor.get("fear", 0)), "、".join(item_names) if not item_names.is_empty() else "无"])
	else:
		lines.append("技能手牌 %d　牌库 %d　弃牌 %d　钥匙 %d" % [killer.get("hand_count", 0), killer.get("deck_count", 0), killer.get("discard_count", 0), view.items.get("team_key_count", 0)])
		for survivor: Dictionary in view.get("survivors", []):
			lines.append("%s　%s" % [_survivor_name(survivor.id), _health_name(survivor.health)])
	if not view.get("encounter", {}).is_empty():
		var attacked_names: Array[String] = []
		for survivor_id: String in view.encounter.attacked_survivor_ids:
			attacked_names.append(_survivor_name(survivor_id))
		lines.append("[color=#ffd166]遭遇地点 %s · 已攻击 %s[/color]" % [view.encounter.room_id, "、".join(attacked_names) if not attacked_names.is_empty() else "无人"])
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
	_clear_action_list()
	pending_command = {}
	pending_path_selection = {}
	pending_brutal_selection = {}
	confirmation_panel.visible = false
	map_board.clear_selection()
	map_board.clear_pending_destination()
	var phase: String = view.get("phase", "")
	if phase == "GAME_OVER":
		_add_plain_label("%s获胜：%s" % [_side_name(view.get("winner", "")), _end_reason_name(view.get("end_reason", ""))])
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
					_add_command("激活 %s" % _survivor_name(survivor.id), "BeginSurvivorActivation", {"survivor_id":survivor.id})
		"SURVIVOR_ACTIVATION":
			_add_survivor_activation_actions(view)
		"SURVIVOR_SEARCH_RESOLVE":
			_add_search_resolution_actions(view)
		"SURVIVOR_DISCOVER_SELECT":
			for survivor: Dictionary in view.survivors:
				_add_command("由 %s 发现" % _survivor_name(survivor.id), "ChooseDiscoverer", {"survivor_id":survivor.id})
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
					_add_command("由 %s 防守" % _survivor_name(survivor_id), "SelectDefender", {"survivor_id":survivor_id})
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
	_begin_action_categories("movement" if not bool(actor.get("main_action_completed", false)) else "items")
	if not bool(actor.get("main_action_completed", false)):
		_set_action_category("movement")
		_add_path_builder("移动（1～2 步）", "MoveSurvivor", {"actor_id":actor.id}, actor.room_id, 2, view.map.blocked_edge_ids)
		_set_action_category("main")
		_add_command("冷静", "Calm", {"actor_id":actor.id})
		for edge_id: String in view.map.blocked_edge_ids:
			if edge_id in map_board.blockable_edges_touching(actor.room_id):
				_add_command("拆除封锁 %s" % edge_id, "RemoveBlock", {"actor_id":actor.id,"edge_id":edge_id})
		if actor.room_id == "B4":
			_add_command("维修无线电", "RepairRadio", {"actor_id":actor.id})
		if actor.room_id in ["R1", "B1", "G5"]:
			_add_command("搜索", "BeginSearch", {"actor_id":actor.id})
		_add_location_main_actions(view, actor)
		_set_action_category("abilities")
		_add_character_ability_actions(view, actor)
	_set_action_category("items")
	if not bool(actor.get("main_action_completed", false)):
		_add_item_main_actions(view, actor)
	_add_extra_item_actions(view, actor)
	_add_exchange_actions(view, actor)
	if bool(actor.get("main_action_completed", false)):
		_set_action_category("main")
		_add_command("结束 %s 的激活" % _survivor_name(actor.id), "EndActivation", {"actor_id":actor.id})
	_finalize_action_categories()


func _add_character_ability_actions(view: Dictionary, actor: Dictionary) -> void:
	if actor.id == "marco_carven":
		for card_id: String in view.items.discard:
			if view.items.item_instances.get(card_id, "") in ["adrenaline", "sedatives"]:
				for option: Dictionary in _acquisition_payloads(view, actor.id, card_id, {"actor_id":actor.id,"source_id":"marco_equipped","card_instance_id":card_id}):
					_add_command("装备齐全：取回 %s%s" % [_item_name(view, card_id), option.suffix], "UseSpecialAction", option.payload)
	if actor.id == "william_hooper":
		_add_path_builder("冲刺（1～3 步）", "UseSpecialAction", {"actor_id":actor.id,"source_id":"william_sprint"}, actor.room_id, 3, view.map.blocked_edge_ids)


func _add_item_main_actions(view: Dictionary, actor: Dictionary) -> void:
	if actor.room_id == "B4" and _inventory_has(view, actor, "toolbox"):
		_add_command("使用工具箱维修 +2", "UseSpecialAction", {"actor_id":actor.id,"source_id":"toolbox"})
	if actor.id == "marco_carven" and _inventory_has(view, actor, "marco_medical_kit"):
		for target: Dictionary in view.survivors:
			if target.health == "injured":
				_add_command("医疗包治疗 %s" % _survivor_name(target.id), "UseSpecialAction", {"actor_id":actor.id,"source_id":"marco_medical_kit","target_survivor_id":target.id})
	if _inventory_has(view, actor, "trap_parts") and view.map.get("trap_room_id", "").is_empty():
		_add_command("在 %s 放置陷阱" % actor.room_id, "UseSpecialAction", {"actor_id":actor.id,"source_id":"trap_parts"})


func _add_location_main_actions(view: Dictionary, actor: Dictionary) -> void:
	if actor.room_id == "G3" and bool(view.map.get("first_aid_cabinet_available", false)):
		for target: Dictionary in view.survivors:
			if target.room_id == "G3" and target.health == "injured":
				_add_command("急救柜治疗 %s" % _survivor_name(target.id), "UseSpecialAction", {"actor_id":actor.id,"source_id":"g3_first_aid_cabinet","target_survivor_id":target.id})


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
				_add_command("交给 %s：%s" % [_survivor_name(target.id), _item_name(view, card_id)], "ExchangeItems", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final})
		if actor.inventory_instance_ids.size() < limit:
			for card_id: String in target.inventory_instance_ids:
				var actor_final: Array = actor.inventory_instance_ids.duplicate()
				var target_final: Array = target.inventory_instance_ids.duplicate()
				target_final.erase(card_id)
				actor_final.append(card_id)
				_add_command("从 %s 接收：%s" % [_survivor_name(target.id), _item_name(view, card_id)], "ExchangeItems", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final})
		for actor_card: String in actor.inventory_instance_ids:
			for target_card: String in target.inventory_instance_ids:
				var actor_final: Array = actor.inventory_instance_ids.duplicate()
				var target_final: Array = target.inventory_instance_ids.duplicate()
				actor_final[actor_final.find(actor_card)] = target_card
				target_final[target_final.find(target_card)] = actor_card
				_add_command("与 %s 交换：%s ↔ %s" % [_survivor_name(target.id), _item_name(view, actor_card), _item_name(view, target_card)], "ExchangeItems", {"actor_id":actor.id,"target_survivor_id":target.id,"actor_inventory_instance_ids":actor_final,"target_inventory_instance_ids":target_final})


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
	_begin_action_categories("movement")
	if view.killer.main_action_mode != "skill":
		_set_action_category("movement")
		for room_id: String in map_board.neighbors(view.killer.room_id):
			_add_command("移动到 %s" % room_id, "KillerMove", {"target_room_id":room_id})
		_set_action_category("main")
		_add_command("搜索当前地点", "KillerSearch", {})
	if view.killer.main_action_mode == "":
		_set_action_category("abilities")
		_add_killer_skill_actions(view, "main")
	_finalize_action_categories()


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
					_action_target().add_child(_button("残酷暴怒（弃置 %s）：选择路径" % cost_name, Callable(self, "_start_brutal_selection").bind(instance_id, costs.duplicate(), view.duplicate(true))))


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
		_add_command("%s 留在原地" % _survivor_name(survivor_id), "ConfirmFlee", {"survivor_id":survivor_id,"path_room_ids":[]})
		for room_id: String in _legal_neighbors(survivor.room_id, view.map.blocked_edge_ids):
			_add_command("%s 逃到 %s" % [_survivor_name(survivor_id), room_id], "ConfirmFlee", {"survivor_id":survivor_id,"path_room_ids":[room_id]})


func _local_side_acts(phase: String) -> bool:
	if phase.begins_with("SURVIVOR") or phase in ["ENCOUNTER_DEFENDER", "ENCOUNTER_ITEM", "ENCOUNTER_FLEE", "DAMAGE_RESPONSE"]:
		return session.local_side == "survivors"
	if phase.begins_with("KILLER") or phase == "ENCOUNTER_ATTACK_SKILL":
		return session.local_side == "killer"
	return false


func _add_command(label: String, command_type: String, payload: Dictionary) -> void:
	_action_target().add_child(_button(label, func(): _queue_command(label, command_type, payload)))


func _add_path_builder(label: String, command_type: String, payload: Dictionary, start_room_id: String, maximum_steps: int, blocked_edges: Array) -> void:
	if command_type == "MoveSurvivor":
		_add_plain_label(label)
		for path: Array in _legal_paths(start_room_id, maximum_steps, blocked_edges):
			var route_label := "%d 步：%s" % [path.size(), _path_label(path)]
			_action_target().add_child(_button(route_label, Callable(self, "_queue_path_command").bind(
				label, command_type, payload.duplicate(true), path.duplicate()
			)))
	_action_target().add_child(_button("%s：在地图上逐步选择" % label, Callable(self, "_start_path_selection").bind(
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
	_clear_action_list()
	var path: Array = pending_path_selection.path_room_ids
	var current_room_id: String = pending_path_selection.current_room_id
	var legal_rooms := _legal_neighbors(current_room_id, pending_path_selection.blocked_edge_ids)
	map_board.set_selection(legal_rooms, path, pending_path_selection.start_room_id)
	_add_plain_label("%s\n已选 %d / %d 步：%s" % [
		pending_path_selection.label,
		path.size(),
		int(pending_path_selection.maximum_steps),
		_path_label(path) if not path.is_empty() else "请选择第一步",
	])
	if path.size() < int(pending_path_selection.maximum_steps):
		for room_id: String in legal_rooms:
			_action_target().add_child(_button("第 %d 步：%s %s" % [path.size() + 1, room_id, map_board.room_name(room_id)], Callable(self, "_append_path_room").bind(room_id)))
	if not path.is_empty():
		_action_target().add_child(_button("完成路径", _finish_path_selection))
		_action_target().add_child(_button("撤回上一步", _undo_path_step))
	_action_target().add_child(_button("取消路径选择", _cancel_path_selection))


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
	if (not path_value is Array or path_value.is_empty()) and payload.get("path_segments", []) is Array:
		path_value = _flatten_segments(payload.get("path_segments", []))
	if path_value is Array and not path_value.is_empty():
		map_board.set_pending_destination(str(path_value.back()), path_value, _command_origin_room(payload))
	else:
		map_board.clear_pending_destination()
	confirmation_label.text = "待提交：%s\n确认后由主机验证并结算，接受后不可撤销。" % label
	confirmation_panel.visible = true


func _command_origin_room(payload: Dictionary) -> String:
	var actor_id: String = payload.get("actor_id", "")
	if not actor_id.is_empty():
		var actor := _view_survivor(session.current_view, actor_id)
		if not actor.is_empty():
			return actor.get("room_id", "")
	return session.current_view.get("killer", {}).get("room_id", "")


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
	_clear_action_list()
	var segments: Array = pending_brutal_selection.segments
	var route := _flatten_segments(segments)
	map_board.set_selection([], route, session.current_view.killer.room_id)
	_add_plain_label("残酷暴怒路径：%s" % (_segments_label(segments) if not segments.is_empty() else "尚未选择"))
	for path: Array in _all_paths(pending_brutal_selection.current_room_id, 2):
		_action_target().add_child(_button("添加移动段：%s" % " → ".join(path), Callable(self, "_append_brutal_segment").bind(path.duplicate())))
	if not segments.is_empty():
		_action_target().add_child(_button("完成路径选择", _finish_brutal_selection))
	_action_target().add_child(_button("取消残酷暴怒", _cancel_brutal_selection))


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


func _flatten_segments(segments: Array) -> Array:
	var route: Array = []
	for segment: Array in segments:
		route.append_array(segment)
	return route


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


func _render_card_zone(view: Dictionary) -> void:
	_clear_container(card_hand)
	if session.local_side == "killer":
		card_zone_title.text = "屠夫技能手牌 · %d / %d" % [view.killer.get("hand", []).size(), int(view.killer.get("hand_limit", 5))]
		for instance_id: String in view.killer.get("hand", []):
			card_hand.add_child(_card_button(view, instance_id, "屠夫", "killer"))
		discard_button.text = "技能弃牌区\n%d 张\n点击查看" % view.killer.get("discard", []).size()
	else:
		card_zone_title.text = "幸存者物品区"
		for survivor: Dictionary in view.get("survivors", []):
			for instance_id: String in survivor.get("inventory_instance_ids", []):
				card_hand.add_child(_card_button(view, instance_id, _survivor_name(survivor.id), "item"))
		var pending: Dictionary = view.get("items", {}).get("pending_private_draw", {})
		for instance_id: String in pending.get("card_instance_ids", []):
			card_hand.add_child(_card_button(view, instance_id, "待处理", "item"))
		discard_button.text = "物品弃牌区\n%d 张\n点击查看" % view.get("items", {}).get("discard", []).size()
	if card_hand.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "当前没有可查看的手牌或物品。"
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		card_hand.add_child(empty)


func _card_button(view: Dictionary, instance_id: String, owner_name: String, kind: String) -> Button:
	var definition := _card_definition(view, instance_id, kind)
	var name: String = definition.get("name_zh", "未知卡牌")
	var timing: String = definition.get("timing_zh", "被动 / 特殊时机")
	var button := _button("%s\n[b]%s[/b]\n%s" % [owner_name, name, timing], Callable(self, "_show_card_detail").bind(kind, instance_id, owner_name))
	button.text = "%s\n%s\n%s" % [owner_name, name, timing]
	button.custom_minimum_size = Vector2(132, 104)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.tooltip_text = "%s：%s" % [name, definition.get("rules_zh", "点击查看详细效果")]
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_stylebox_override("normal", _card_style(Color("243747"), Color("6ca0c8")))
	button.add_theme_stylebox_override("hover", _card_style(Color("324f64"), Color("ffd166")))
	button.add_theme_stylebox_override("pressed", _card_style(Color("182733"), Color("ffd166")))
	return button


func _card_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _card_definition(view: Dictionary, instance_id: String, kind: String) -> Dictionary:
	if kind == "killer":
		var definition_id: String = view.get("killer", {}).get("skill_instances", {}).get(instance_id, instance_id)
		return view.get("killer", {}).get("definitions", {}).get(definition_id, {})
	var definition_id: String = view.get("items", {}).get("item_instances", {}).get(instance_id, instance_id)
	return view.get("items", {}).get("definitions", {}).get(definition_id, {})


func _show_card_detail(kind: String, instance_id: String, owner_name: String) -> void:
	var definition := _card_definition(session.current_view, instance_id, kind)
	card_detail_title.text = definition.get("name_zh", "卡牌详情")
	var card_type := "杀手技能" if kind == "killer" else "幸存者物品"
	var lines: Array[String] = [
		"[color=#aeb8c2]%s · 持有者：%s[/color]" % [card_type, owner_name],
		"使用时机　%s" % definition.get("timing_zh", "按卡牌规则"),
		"",
		definition.get("rules_zh", "该卡牌暂无额外说明。"),
	]
	if bool(definition.get("draw_noise", false)):
		lines.append("\n[color=#ffd166]抽到此牌时会制造噪声。[/color]")
	card_detail_text.text = "\n".join(lines)
	card_detail_popup.popup_centered(Vector2i(510, 360))


func _show_discard_detail() -> void:
	var view: Dictionary = session.current_view
	var kind := "killer" if session.local_side == "killer" else "item"
	var discard: Array = view.get("killer", {}).get("discard", []) if kind == "killer" else view.get("items", {}).get("discard", [])
	var counts: Dictionary = {}
	for instance_id: String in discard:
		var definition := _card_definition(view, instance_id, kind)
		var name: String = definition.get("name_zh", "未知卡牌")
		counts[name] = int(counts.get(name, 0)) + 1
	card_detail_title.text = "技能弃牌区" if kind == "killer" else "物品弃牌区"
	var names: Array = counts.keys()
	names.sort()
	var lines: Array[String] = []
	for name_value: Variant in names:
		var name := str(name_value)
		lines.append("• %s × %d" % [name, int(counts[name])])
	if lines.is_empty():
		lines.append("弃牌区目前为空。")
	card_detail_text.text = "[color=#aeb8c2]共 %d 张，仅显示当前阵营可见信息。[/color]\n\n%s" % [discard.size(), "\n".join(lines)]
	card_detail_popup.popup_centered(Vector2i(510, 360))


func _append_events(events: Array) -> void:
	var side: String = session.local_side
	if side not in event_lines_by_side:
		return
	var event_lines: Array = event_lines_by_side[side]
	for event: Dictionary in events:
		if event.get("log_side", "system") not in ["system", side]:
			continue
		var narrative := _narrate_event(event)
		if not narrative.is_empty():
			event_lines.append("• %s" % narrative)
	while event_lines.size() > 40:
		event_lines.pop_front()
	event_lines_by_side[side] = event_lines
	_render_narrative_log()
	if feedback != null:
		feedback.present(events, map_board)


func _render_narrative_log() -> void:
	var lines: Array = event_lines_by_side.get(session.local_side, [])
	log_label.text = "\n".join(lines) if not lines.is_empty() else "本阵营还没有行动记录。"
	log_label.scroll_to_line(maxi(0, lines.size() - 1))


func _narrate_event(event: Dictionary) -> String:
	var payload: Dictionary = event.get("payload", {})
	match event.get("type", ""):
		"MatchCreated":
			return "实验室对局已经开始。"
		"PhaseChanged":
			var next_phase: String = payload.get("to", "")
			return "阶段推进：%s。" % PHASE_NAMES.get(next_phase, next_phase)
		"ActorMoved":
			return "%s从 %s 移动到 %s。" % [_actor_name(payload.get("actor_id", "")), payload.get("from", "?"), payload.get("to", "?")]
		"FearChanged":
			return "%s的恐惧从 %d 变为 %d。" % [_survivor_name(payload.get("survivor_id", "")), int(payload.get("from", 0)), int(payload.get("to", 0))]
		"BlockPlaced":
			return "在 %s 放置了封锁。" % payload.get("edge_id", "一扇门")
		"BlockRemoved":
			return "%s 的封锁已被移除。" % payload.get("edge_id", "门")
		"RepairAdded":
			return "%s维修了无线电，进度变为 %d / 5。" % [_survivor_name(payload.get("survivor_id", "")), int(payload.get("to", 0))]
		"RescueAdvanced":
			return "救援倒计时更新为 %s。" % str(payload.get("to", "?"))
		"ItemDrawn":
			return "%s抽到了：%s。" % [_survivor_name(payload.get("survivor_id", "")), _item_names(session.current_view, payload.get("card_instance_ids", []))]
		"ItemAcquired":
			return "%s获得了%s。" % [_survivor_name(payload.get("survivor_id", "")), _item_name(session.current_view, payload.get("card_instance_id", ""))]
		"ItemDiscarded":
			return "%s进入物品弃牌区。" % _item_name(session.current_view, payload.get("card_instance_id", ""))
		"ItemsExchanged":
			return "%s与%s完成了物品交换。" % [_survivor_name(payload.get("actor_id", "")), _survivor_name(payload.get("target_survivor_id", ""))]
		"CharacterAbilityUsed":
			return "%s发动了“%s”。" % [_survivor_name(payload.get("survivor_id", "")), _ability_name(payload.get("ability_id", ""))]
		"FirecrackerActivated":
			return "爆竹被点燃，本轮所有地点都视为有噪声。"
		"TrapPlaced":
			return "陷阱已放置在 %s。" % payload.get("room_id", "当前地点")
		"KeyAdded":
			return "队伍找到一把钥匙，现在共有 %d / 5 把。" % int(payload.get("total", 0))
		"NoiseRecorded":
			return "%s产生了噪声。" % payload.get("room_id", "某个地点")
		"NoiseRevealed":
			return "上一轮的噪声线索已经公开。"
		"SkillPlayed":
			return "屠夫打出了“%s”。" % _killer_definition_name(session.current_view, payload.get("definition_id", ""))
		"SkillDrawn":
			return "屠夫抽到了“%s”。" % _killer_card_name(session.current_view, payload.get("card_instance_id", ""))
		"SkillDiscarded", "SkillCostPaid":
			return "“%s”进入技能弃牌区。" % _killer_card_name(session.current_view, payload.get("card_instance_id", ""))
		"SkillUnlocked":
			return "屠夫解锁了“%s”。" % _killer_definition_name(session.current_view, payload.get("definition_id", ""))
		"SkillDeckRebuilt":
			return "技能弃牌已洗回牌库，共 %d 张。" % int(payload.get("card_count", 0))
		"KillerSearched":
			return "屠夫搜索了 %s，%s。" % [payload.get("room_id", "当前地点"), "发现了幸存者" if bool(payload.get("found", false)) else "没有找到幸存者"]
		"SenseResolved":
			return "感知了 %s 区域，发现 %d 名幸存者。" % [payload.get("region", "?"), payload.get("survivor_ids", []).size()]
		"KillerLeveled":
			return "屠夫升到 %d 级，当前力量为 %d。" % [int(payload.get("to", 0)), int(payload.get("strength", 0))]
		"KillerStrengthChanged":
			return "屠夫力量从 %d 变为 %d。" % [int(payload.get("from", 0)), int(payload.get("to", 0))]
		"EncounterStarted":
			return "%s发生遭遇。" % payload.get("room_id", "当前地点")
		"DefenderSelected":
			return "%s准备防守。" % _survivor_name(payload.get("survivor_id", ""))
		"EncounterItemCommitted":
			return "%s选择了防御物品，物品加值为 +%d。" % [_survivor_name(payload.get("survivor_id", "")), int(payload.get("item_bonus", 0))]
		"DefenseDiceRolled":
			return "%s掷出了防御骰：%s。" % [_survivor_name(payload.get("survivor_id", "")), str(payload.get("dice_results", []))]
		"DefenseRolled":
			return "%s的本次防御%s。" % [_survivor_name(payload.get("survivor_id", "")), "成功" if bool(payload.get("success", false)) else "失败"]
		"HealthChanged":
			return "%s的状态从%s变为%s。" % [_survivor_name(payload.get("survivor_id", "")), _health_name(payload.get("from", "")), _health_name(payload.get("to", ""))]
		"DamagePrevented":
			return "%s使用古代护符防止了伤害。" % _survivor_name(payload.get("survivor_id", ""))
		"FleeConfirmed":
			return "%s的逃离位置为 %s。" % [_survivor_name(payload.get("survivor_id", "")), payload.get("room_id", "?")]
		"EncounterEnded":
			return "遭遇已经结束。"
		"MatchEnded":
			return "%s获胜。" % _side_name(payload.get("winner", ""))
	return ""


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


func _begin_action_categories(preferred: String) -> void:
	action_category_containers.clear()
	action_category_buttons.clear()
	expanded_action_category = preferred
	for category: Dictionary in ACTION_CATEGORIES:
		var category_id: String = category.id
		var header := _button("%s (0)" % category.label, Callable(self, "_select_action_category").bind(category_id))
		header.toggle_mode = true
		header.tooltip_text = "展开%s选项" % category.label
		action_list.add_child(header)
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", 5)
		action_list.add_child(body)
		action_category_buttons[category_id] = header
		action_category_containers[category_id] = body
	current_action_category = preferred


func _set_action_category(category_id: String) -> void:
	current_action_category = category_id


func _finalize_action_categories() -> void:
	var first_available := ""
	for category: Dictionary in ACTION_CATEGORIES:
		var category_id: String = category.id
		var body: VBoxContainer = action_category_containers[category_id]
		var count := _button_count(body)
		var header: Button = action_category_buttons[category_id]
		header.text = "%s (%d)" % [category.label, count]
		header.visible = count > 0
		body.visible = false
		if count > 0 and first_available.is_empty():
			first_available = category_id
	if not action_category_containers.has(expanded_action_category) or _button_count(action_category_containers[expanded_action_category]) == 0:
		expanded_action_category = first_available
	_select_action_category(expanded_action_category)


func _select_action_category(category_id: String) -> void:
	if category_id.is_empty() or not action_category_containers.has(category_id):
		return
	expanded_action_category = category_id
	for id_value: Variant in action_category_containers.keys():
		var id := str(id_value)
		var selected := id == category_id
		var body: VBoxContainer = action_category_containers[id]
		body.visible = selected
		var header: Button = action_category_buttons[id]
		header.button_pressed = selected


func _button_count(node: Node) -> int:
	var count := 0
	for child: Node in node.get_children():
		if child is Button:
			count += 1
		count += _button_count(child)
	return count


func _action_target() -> Container:
	if action_category_containers.has(current_action_category):
		var target: Variant = action_category_containers[current_action_category]
		if is_instance_valid(target):
			return target
	return action_list


func _clear_action_list() -> void:
	_clear_container(action_list)
	action_category_containers.clear()
	action_category_buttons.clear()
	current_action_category = ""


func _add_plain_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action_target().add_child(label)


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	return button


func _survivor_name(survivor_id: String) -> String:
	return SURVIVOR_NAMES.get(survivor_id, survivor_id if not survivor_id.is_empty() else "幸存者")


func _actor_name(actor_id: String) -> String:
	return "屠夫" if actor_id == "butcher" else _survivor_name(actor_id)


func _health_name(health: String) -> String:
	return HEALTH_NAMES.get(health, health)


func _side_name(side: String) -> String:
	return "幸存者" if side == "survivors" else "屠夫" if side == "killer" else side


func _end_reason_name(reason: String) -> String:
	var names := {
		"survivor_escaped":"幸存者成功逃离",
		"rescue_arrived":"救援抵达",
		"survivor_eliminated":"有幸存者被淘汰",
	}
	return names.get(reason, reason)


func _ability_name(ability_id: String) -> String:
	var names := {
		"marco_equipped":"装备齐全",
		"william_sprint":"冲刺",
	}
	return names.get(ability_id, ability_id)


func _killer_definition_name(view: Dictionary, definition_id: String) -> String:
	return view.get("killer", {}).get("definitions", {}).get(definition_id, {}).get("name_zh", definition_id)


func _item_names(view: Dictionary, instance_ids: Array) -> String:
	var names: Array[String] = []
	for instance_id: String in instance_ids:
		names.append(_item_name(view, instance_id))
	return "、".join(names) if not names.is_empty() else "一张牌"


func _clear_container(container: Container) -> void:
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _set_lobby_status(message: String) -> void:
	lobby_status.text = message


func _set_game_status(message: String) -> void:
	phase_label.text = message
