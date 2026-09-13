extends Control
## Settlement screen: recruit soldiers, inspect the party, leave town.
##
## The screen owns no game state. It asks [RecruitmentService] what is possible,
## calls it to perform a recruitment, and redraws from the campaign afterwards.

const WORLD_MAP_KEY := "world_map"
const BATCH_SIZE := 5

var _state: CampaignState = null
var _config: GameConfig = null
var _settlement: Settlement = null
var _recruitment: RecruitmentService = null
var _units: UnitCatalog = null
var _traits: TraitCatalog = null

var _town_label: Label = null
var _town_meta: Label = null
var _stats_label: Label = null
var _description: Label = null
var _leave_button: Button = null

var _recruit_list: VBoxContainer = null
var _roster_list: VBoxContainer = null
var _roster_header: Label = null
var _detail: Label = null
var _status: Label = null

var _selected_soldier_id: String = ""


func _ready() -> void:
	_state = GameManager.campaign
	if _state == null:
		SceneManager.change_scene("main_menu")
		return
	_config = GameManager.config()

	var payload := SceneManager.consume_payload()
	var settlement_id := str(payload.get("settlement_id", _state.current_settlement_id))
	_settlement = _state.settlement(settlement_id)
	if _settlement == null:
		DebugLogger.warn("settlement screen opened for unknown id '%s'" % settlement_id, "Settlement")
		SceneManager.change_scene(WORLD_MAP_KEY)
		return

	# Standing inside a settlement is what makes it entered.
	_state.current_settlement_id = _settlement.id
	_settlement.restock_if_due(_state.clock.day, _config.get_int("world.restock_days", 4))

	_recruitment = RecruitmentService.build(_state, _config)
	_units = _recruitment.units
	_traits = TraitCatalog.load_from()

	_build_layout()
	_refresh()
	DebugLogger.info("entered %s" % _settlement.name, "Settlement")

	_apply_dev_autorecruit()


## Dev-only: run the real recruit button handler on entry so an automated run
## exercises the same code path a click does.
func _apply_dev_autorecruit() -> void:
	var count := DevFlags.autorecruit_count()
	if count <= 0:
		return
	DebugLogger.info("dev flag: autorecruiting %d" % count, "Settlement")
	_on_recruit_pressed("peasant_recruit", count)
	if DevFlags.autoleave_town():
		DebugLogger.info("dev flag: leaving town immediately", "Settlement")
		_on_leave()


## ---------- layout -------------------------------------------------------

func _build_layout() -> void:
	$Background.color = UiTheme.BG

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	add_child(margin)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 12)
	margin.add_child(columns)

	columns.add_child(_build_town_panel())
	columns.add_child(_build_recruit_panel())
	columns.add_child(_build_party_panel())


func _build_town_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.custom_minimum_size = Vector2(330.0, 0.0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_town_label = UiTheme.label("", 26, UiTheme.GOLD)
	box.add_child(_town_label)
	_town_meta = UiTheme.dim_label("")
	box.add_child(_town_meta)
	box.add_child(UiTheme.heading_rule())

	_stats_label = UiTheme.label("", 15, UiTheme.TEXT)
	box.add_child(_stats_label)
	box.add_child(UiTheme.heading_rule())

	_description = UiTheme.label("", 13, UiTheme.DIM)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.custom_minimum_size = Vector2(300.0, 0.0)
	box.add_child(_description)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	_leave_button = UiTheme.button("Leave %s" % "Town", 300.0)
	_leave_button.pressed.connect(_on_leave)
	box.add_child(_leave_button)
	return panel


func _build_recruit_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	box.add_child(UiTheme.header("Available Recruits", 17))
	box.add_child(UiTheme.dim_label("Men willing to swear service here today."))
	box.add_child(UiTheme.heading_rule())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_recruit_list = VBoxContainer.new()
	_recruit_list.add_theme_constant_override("separation", 8)
	_recruit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_recruit_list)

	_status = UiTheme.label("", 13, UiTheme.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	return panel


func _build_party_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.custom_minimum_size = Vector2(400.0, 0.0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_roster_header = UiTheme.header("Your Party", 17)
	box.add_child(_roster_header)
	box.add_child(UiTheme.heading_rule())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0.0, 200.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_roster_list = VBoxContainer.new()
	_roster_list.add_theme_constant_override("separation", 4)
	_roster_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_roster_list)

	box.add_child(UiTheme.heading_rule())
	_detail = UiTheme.label("Select a soldier to see their record.", 13, UiTheme.DIM)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(370.0, 210.0)
	_detail.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	box.add_child(_detail)
	return panel


## ---------- refresh ------------------------------------------------------

func _refresh() -> void:
	_leave_button.text = "Leave %s" % _settlement.name
	_town_label.text = _settlement.name
	var owner_text := _settlement.owner_faction_id
	owner_text = "unclaimed" if owner_text.is_empty() else owner_text.replace("_", " ").capitalize()
	_town_meta.text = "%s  |  %s  |  population %d" % [
		_settlement.type_display(), owner_text, _settlement.population,
	]
	_stats_label.text = "\n".join([
		"Gold:        %d" % _state.player_gold,
		"Party:       %d / %d" % [_state.player_party.size(), _recruitment.max_party_size()],
		"Date:        %s" % _state.clock.full_string(),
		"Recruits:    %d here today" % _settlement.total_recruits_available(),
	])
	_description.text = _settlement.description

	_rebuild_recruit_rows()
	_rebuild_roster()
	_refresh_detail()


func _rebuild_recruit_rows() -> void:
	for child in _recruit_list.get_children():
		child.queue_free()

	var any_row := false
	for unit_type_id in _units.recruitable_ids():
		var stock := _recruitment.available_at(_settlement, unit_type_id)
		if stock <= 0:
			continue
		any_row = true
		_recruit_list.add_child(_build_recruit_row(unit_type_id, stock))

	if not any_row:
		_recruit_list.add_child(UiTheme.dim_label(
			"Nobody here is looking for service. Come back in a few days."
		))


func _build_recruit_row(unit_type_id: String, stock: int) -> Control:
	var definition := _units.get_definition(unit_type_id)
	var check := _recruitment.can_recruit(_settlement, unit_type_id)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := UiTheme.label(definition.display_name, 16, UiTheme.TEXT)
	box.add_child(title)
	box.add_child(UiTheme.dim_label(definition.description))

	var facts := UiTheme.label(
		"Hit points %d   Attack %d   Defence %d   %s" % [
			definition.hp,
			definition.attack,
			definition.defence,
			"Fights at range" if definition.ranged else "Fights hand to hand",
		], 12, UiTheme.DIM)
	box.add_child(facts)

	box.add_child(UiTheme.heading_rule())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)

	var price := UiTheme.label("%d gold" % definition.recruit_cost, 15, UiTheme.GOLD)
	price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(price)
	row.add_child(UiTheme.dim_label("%d available" % stock))

	var affordable := _recruitment.affordable_count(_settlement, unit_type_id)

	var one := UiTheme.button("Recruit", 92.0)
	one.disabled = not bool(check.get("ok", false))
	one.tooltip_text = str(check.get("message", ""))
	one.pressed.connect(_on_recruit_pressed.bind(unit_type_id, 1))
	row.add_child(one)

	if BATCH_SIZE > 1:
		var many := UiTheme.button("Recruit %d" % BATCH_SIZE, 92.0)
		many.disabled = affordable < 2
		many.tooltip_text = "Recruit up to %d" % BATCH_SIZE
		many.pressed.connect(_on_recruit_pressed.bind(unit_type_id, BATCH_SIZE))
		row.add_child(many)

	if not bool(check.get("ok", false)):
		box.add_child(UiTheme.label(str(check.get("message", "")), 12, UiTheme.BAD))

	return panel


func _rebuild_roster() -> void:
	for child in _roster_list.get_children():
		child.queue_free()

	_roster_header.text = "Your Party  (%d / %d)" % [
		_state.player_party.size(), _recruitment.max_party_size(),
	]

	var members := _state.party_members(_state.player_party)
	if members.is_empty():
		_roster_list.add_child(UiTheme.dim_label(
			"No soldiers yet. Recruit someone to carry a spear for you."
		))
		return

	for soldier in members:
		var button := UiTheme.button(_roster_line(soldier), 360.0)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_color_override("font_color", _roster_color(soldier))
		button.pressed.connect(_on_roster_pressed.bind(soldier.id))
		_roster_list.add_child(button)


func _roster_line(soldier: Soldier) -> String:
	return "%s   Lv%d %s   %d/%d HP%s" % [
		soldier.full_name(),
		soldier.level,
		_units.display_name(soldier.unit_type_id),
		soldier.hp,
		soldier.max_hp,
		"" if soldier.is_alive() else "   (dead)",
	]


func _roster_color(soldier: Soldier) -> Color:
	if not soldier.is_alive():
		return UiTheme.BAD
	if soldier.hp < soldier.max_hp:
		return UiTheme.GOLD
	return UiTheme.TEXT


func _refresh_detail() -> void:
	if _selected_soldier_id.is_empty():
		_detail.text = "Select a soldier to see their record."
		_detail.add_theme_color_override("font_color", UiTheme.DIM)
		return
	var soldier := _state.soldier(_selected_soldier_id)
	if soldier == null:
		_detail.text = "That soldier is no longer in the party."
		_detail.add_theme_color_override("font_color", UiTheme.DIM)
		return

	_detail.add_theme_color_override("font_color", UiTheme.TEXT)
	var lines: Array[String] = [
		soldier.full_name(),
		"",
		"%s" % _units.display_name(soldier.unit_type_id),
		"Level %d" % soldier.level,
		"",
		"Age:      %d" % soldier.age,
		"HP:       %d/%d" % [soldier.hp, soldier.max_hp],
		"XP:       %d/%d" % [soldier.xp, soldier.xp_to_next(_config)],
		"Kills:    %d" % soldier.kills,
		"Battles:  %d fought, %d survived" % [soldier.battles_fought, soldier.battles_survived],
		"Morale:   %d" % soldier.morale,
		"Loyalty:  %d" % soldier.loyalty,
		"Status:   %s" % soldier.status_display(),
		"",
		"Traits",
	]

	if soldier.traits.is_empty():
		lines.append("  (none yet)")
	else:
		for trait_id in soldier.traits:
			lines.append("  %s - %s" % [
				_traits.display_name(trait_id),
				_traits.description(trait_id),
			])

	lines.append("")
	lines.append("History")
	if soldier.history.is_empty():
		lines.append("  (nothing recorded yet)")
	else:
		for entry in soldier.history:
			lines.append("  Day %d - %s" % [
				int(entry.get("day", 0)),
				str(entry.get("text", "")),
			])

	_detail.text = "\n".join(lines)


## ---------- actions ------------------------------------------------------

func _on_recruit_pressed(unit_type_id: String, count: int) -> void:
	var result := _recruitment.recruit_many(_settlement, unit_type_id, count)
	if bool(result.get("ok", false)):
		var recruited := result.get("recruited", []) as Array
		var names: Array[String] = []
		for soldier in recruited:
			names.append((soldier as Soldier).full_name())
		_status.text = "Recruited %s for %d gold." % [
			", ".join(names), int(result.get("spent", 0)),
		]
		_selected_soldier_id = (recruited[recruited.size() - 1] as Soldier).id
	else:
		_status.text = str(result.get("message", "Nothing was recruited."))
	_refresh()


func _on_roster_pressed(soldier_id: String) -> void:
	_selected_soldier_id = soldier_id
	_refresh_detail()


func _on_leave() -> void:
	SceneManager.change_scene(WORLD_MAP_KEY, {"select_settlement_id": _settlement.id})
