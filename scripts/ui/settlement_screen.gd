extends Control
## Settlement screen: recruit soldiers, inspect the party, leave town.
##
## The screen owns no game state. It asks [RecruitmentService] what is possible,
## calls it to perform a recruitment, and redraws from the campaign afterwards.
##
## The dressing is the menus' pixel chrome ([PixelStyle]) with a serif for body text: headers,
## prices and numeric values in Silkscreen, names and sentences in EB Garamond. The flavour - unit
## descriptions, trait text, the town's own blurb, a soldier's quick facts - lives in tooltips
## rather than in the layout, because the owner counted the first draft's prose: "descriptions
## need to not be everywhere, you kind of throw text everywhere but can be helpful just maybe a
## hover tool tip maybe?"

const WORLD_MAP_KEY := "world_map"
const BATCH_SIZE := 5

## The menus' palette, so this screen and the menu are one game. Same values as main_menu.gd.
const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
## Panels and cards sit on darker shades of the same body tone, the way the mock drew them.
const RAIL_BODY := Color(0.085, 0.10, 0.125)
const CARD_BODY := Color(0.10, 0.118, 0.15)
const CHIP_BODY := Color(0.055, 0.065, 0.08)

const TITLE_SIZE := 22
const NAME_SIZE := 16
const BODY_SIZE := 14
const SMALL_SIZE := 12.5
const BUTTON_SIZE := 11

var _state: CampaignState = null
var _config: GameConfig = null
var _settlement: Settlement = null
var _recruitment: RecruitmentService = null
var _units: UnitCatalog = null
var _traits: TraitCatalog = null

var _button_styles: Dictionary = {}

var _town_label: Label = null
var _town_meta: Label = null
var _gold_value: Label = null
var _party_value: Label = null
var _lost_value: Label = null
var _date_value: Label = null
var _recruits_value: Label = null
var _leave_button: Button = null

var _recruit_list: VBoxContainer = null
var _roster_list: VBoxContainer = null
var _roster_header: Label = null
var _detail_box: VBoxContainer = null
var _status: Label = null

var _selected_soldier_id: String = ""


func _ready() -> void:
	_state = GameManager.campaign
	if _state == null:
		SceneManager.change_scene("main_menu")
		return
	_config = GameManager.config()
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)

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
	# One theme on the root dresses every tooltip in the screen, so the popover reads as part of
	# the game rather than as the engine's default grey box.
	theme = PixelStyle.tooltip_theme(CARD_BODY, LIGHT.darkened(0.45), UiTheme.TEXT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	add_child(margin)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	margin.add_child(columns)

	columns.add_child(_build_town_panel())
	columns.add_child(_build_recruit_panel())
	columns.add_child(_build_party_panel())


func _build_town_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE))
	panel.custom_minimum_size = Vector2(330.0, 0.0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	panel.add_child(box)

	_town_label = PixelStyle.pixel_label("", TITLE_SIZE, UiTheme.GOLD)
	box.add_child(_town_label)
	_town_meta = PixelStyle.pixel_label("", 10, UiTheme.DIM)
	box.add_child(_town_meta)
	box.add_child(PixelStyle.rule(DARK))

	_gold_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(_stat_row("Gold", _gold_value))
	_party_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(_stat_row("Party", _party_value))
	_lost_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(_stat_row("Lost", _lost_value))
	_date_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(_stat_row("Date", _date_value))
	_recruits_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(_stat_row("Recruits", _recruits_value))
	box.add_child(PixelStyle.rule(DARK))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	_leave_button = _button("", 300.0, 40.0)
	_leave_button.add_theme_color_override("font_color", UiTheme.GOLD)
	_leave_button.pressed.connect(_on_leave)
	box.add_child(_leave_button)
	return panel


func _build_recruit_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		PixelStyle.panel_style(BODY.darkened(0.22), LIGHT.darkened(0.55), OUTLINE))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	panel.add_child(box)

	box.add_child(PixelStyle.pixel_label("AVAILABLE RECRUITS", 12, UiTheme.ACCENT))
	box.add_child(PixelStyle.rule(DARK))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	# The panels inside a scroll reserve the scrollbar's width, so anything right-aligned sat flush
	# against it - the owner, on the detail pane: "the text on the right needs to shift more to the
	# left". A right margin on the content, not a narrower pane: the frames stay where they are.
	var scroll_margin := MarginContainer.new()
	scroll_margin.add_theme_constant_override("margin_right", 16)
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_margin)

	_recruit_list = VBoxContainer.new()
	_recruit_list.add_theme_constant_override("separation", 8)
	_recruit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_child(_recruit_list)

	_status = PixelStyle.body_label("", SMALL_SIZE, UiTheme.DIM, true)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	return panel


func _build_party_panel() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE))
	panel.custom_minimum_size = Vector2(400.0, 0.0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	panel.add_child(box)

	_roster_header = PixelStyle.pixel_label("", 12, UiTheme.ACCENT)
	box.add_child(_roster_header)
	box.add_child(PixelStyle.rule(DARK))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0.0, 200.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	var scroll_margin := MarginContainer.new()
	scroll_margin.add_theme_constant_override("margin_right", 16)
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(scroll_margin)

	_roster_list = VBoxContainer.new()
	_roster_list.add_theme_constant_override("separation", 5)
	_roster_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_child(_roster_list)

	box.add_child(PixelStyle.rule(DARK))

	var detail_scroll := ScrollContainer.new()
	detail_scroll.custom_minimum_size = Vector2(0.0, 220.0)
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(detail_scroll)

	# The record's values are right-aligned, so the same reservation applies: without it the column
	# of numbers ends under the scrollbar instead of beside a margin.
	var detail_margin := MarginContainer.new()
	detail_margin.add_theme_constant_override("margin_right", 16)
	detail_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(detail_margin)

	_detail_box = VBoxContainer.new()
	_detail_box.add_theme_constant_override("separation", 7)
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_margin.add_child(_detail_box)
	return panel


## ---------- shared dressing ----------------------------------------------

## A button in the menus' own furniture, one size smaller: the same nine-patch, the same accent
## spent on hover.
func _button(text: String, min_width := 0.0, min_height := 32.0) -> Button:
	var node := Button.new()
	node.text = text
	PixelStyle.dress_button(node, _button_styles, PixelStyle.pixel_font(), BUTTON_SIZE,
		UiTheme.TEXT, UiTheme.DIM)
	node.custom_minimum_size = Vector2(min_width, min_height)
	return node


## The shape every stat row in this screen has: name in the serif (dim, taking the slack), value in
## Silkscreen (light, right against the panel edge), so the numbers line up down the column.
func _stat_row(label_text: String, value: Label) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := PixelStyle.body_label(label_text, BODY_SIZE, UiTheme.DIM)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	row.add_child(value)
	return row


## ---------- refresh ------------------------------------------------------

func _refresh() -> void:
	_leave_button.text = "LEAVE %s" % _settlement.name.to_upper()
	_town_label.text = _settlement.name.to_upper()
	_town_label.tooltip_text = _settlement.description
	var owner_text := _settlement.owner_faction_id
	owner_text = "unclaimed" if owner_text.is_empty() else owner_text.replace("_", " ").capitalize()
	_town_meta.text = "%s | %s | POP %d" % [
		_settlement.type_display().to_upper(), owner_text.to_upper(), _settlement.population,
	]
	_gold_value.text = "%d" % _state.player_gold
	_party_value.text = "%d / %d" % [
		_state.active_member_count(_state.player_party), _recruitment.max_party_size(),
	]
	var lost := _state.fallen_member_count(_state.player_party)
	_lost_value.text = "%d" % lost
	_lost_value.add_theme_color_override("font_color", UiTheme.BAD if lost > 0 else UiTheme.TEXT)
	_date_value.text = _state.clock.full_string()
	_recruits_value.text = "%d" % _settlement.total_recruits_available()

	_rebuild_recruit_rows()
	_rebuild_roster()
	_refresh_detail()


func _rebuild_recruit_rows() -> void:
	for child in _recruit_list.get_children():
		child.queue_free()
		_recruit_list.remove_child(child)

	var any_row := false
	for unit_type_id in _units.recruitable_ids():
		var stock := _recruitment.available_at(_settlement, unit_type_id)
		if stock <= 0:
			continue
		any_row = true
		_recruit_list.add_child(_build_recruit_row(unit_type_id, stock))

	if not any_row:
		_recruit_list.add_child(PixelStyle.body_label(
			"Nobody here is looking for service. Come back in a few days.",
			SMALL_SIZE, UiTheme.DIM, true))


func _build_recruit_row(unit_type_id: String, stock: int) -> Control:
	var definition := _units.get_definition(unit_type_id)
	var check := _recruitment.can_recruit(_settlement, unit_type_id)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		PixelStyle.panel_style(CARD_BODY, LIGHT.darkened(0.6), OUTLINE))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The flavour moves off the card's face and onto the card: lean rows, prose on hover.
	if not definition.description.is_empty():
		panel.tooltip_text = definition.description

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	panel.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)

	var name_label := PixelStyle.body_label(definition.display_name, NAME_SIZE, UiTheme.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	head.add_child(PixelStyle.pixel_label("%d GOLD" % definition.recruit_cost, 11, UiTheme.GOLD))
	head.add_child(PixelStyle.pixel_label("%d LEFT" % stock, 9, UiTheme.DIM))

	box.add_child(PixelStyle.chip_row([
		["HP", str(definition.hp)],
		["ATK", str(definition.attack)],
		["DEF", str(definition.defence)],
		["RANGED" if definition.ranged else "MELEE", ""],
	], CHIP_BODY, LIGHT.darkened(0.6), UiTheme.DIM, UiTheme.TEXT))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)

	var affordable := _recruitment.affordable_count(_settlement, unit_type_id)
	var unit_word := definition.display_name.to_lower()

	var one := _button("RECRUIT", 108.0)
	one.disabled = not bool(check.get("ok", false))
	one.tooltip_text = str(check.get("message", "")) if one.disabled \
		else "Recruit one %s for %d gold." % [unit_word, definition.recruit_cost]
	one.pressed.connect(_on_recruit_pressed.bind(unit_type_id, 1))
	row.add_child(one)

	if BATCH_SIZE > 1:
		var many := _button("RECRUIT %d" % BATCH_SIZE, 108.0)
		many.disabled = affordable < 2
		many.tooltip_text = "Recruit up to %d %ss for %d gold each." % [
			BATCH_SIZE, unit_word, definition.recruit_cost,
		] if not many.disabled else "Not enough gold for a batch of %d." % BATCH_SIZE
		many.pressed.connect(_on_recruit_pressed.bind(unit_type_id, BATCH_SIZE))
		row.add_child(many)

	if not bool(check.get("ok", false)):
		box.add_child(PixelStyle.body_label(str(check.get("message", "")), SMALL_SIZE, UiTheme.BAD))

	return panel


## The roster deliberately lists the dead too - they are the party's history - so
## the header has to distinguish the record from the force you can actually field.
func _rebuild_roster() -> void:
	for child in _roster_list.get_children():
		child.queue_free()
		_roster_list.remove_child(child)

	var active := _state.active_member_count(_state.player_party)
	var lost := _state.fallen_member_count(_state.player_party)
	var header := "YOUR PARTY | %d / %d ACTIVE" % [active, _recruitment.max_party_size()]
	if lost > 0:
		header += " | %d LOST" % lost
	_roster_header.text = header

	var members := _state.party_members(_state.player_party)
	if members.is_empty():
		_roster_list.add_child(PixelStyle.body_label(
			"No soldiers yet. Recruit someone to carry a spear for you.",
			SMALL_SIZE, UiTheme.DIM, true))
		return

	for soldier in members:
		_roster_list.add_child(_build_roster_row(soldier))


## One row: a portrait slot, the name over their trade, hit points against the right edge. The
## record itself - age, kills, traits, history - is a click away, and a glance of the numbers is
## a hover away.
func _build_roster_row(soldier: Soldier) -> Control:
	var button := _button("", 0.0, 46.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = _soldier_glance(soldier)
	button.pressed.connect(_on_roster_pressed.bind(soldier.id))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var colour := _roster_color(soldier)

	var port := PanelContainer.new()
	port.custom_minimum_size = Vector2(34.0, 34.0)
	var port_style := StyleBoxFlat.new()
	port_style.bg_color = DARK
	port_style.border_color = LIGHT.darkened(0.5)
	port_style.set_border_width_all(1)
	port_style.set_corner_radius_all(0)
	port.add_theme_stylebox_override("panel", port_style)
	port.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var initials := PixelStyle.body_label(_initials(soldier.full_name()), 14, UiTheme.GOLD)
	initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	port.add_child(initials)
	row.add_child(port)

	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(names)
	names.add_child(PixelStyle.body_label(soldier.full_name(), 15, colour))
	names.add_child(PixelStyle.body_label(
		"Lv%d %s" % [soldier.level, _units.display_name(soldier.unit_type_id)],
		SMALL_SIZE, UiTheme.DIM))

	row.add_child(PixelStyle.pixel_label("%d/%d" % [soldier.hp, soldier.max_hp], 10, colour))
	return button


func _initials(full_name_text: String) -> String:
	var parts := full_name_text.split(" ", false)
	if parts.is_empty():
		return "?"
	if parts.size() == 1:
		return parts[0].substr(0, 1).to_upper()
	return (parts[0].substr(0, 1) + parts[parts.size() - 1].substr(0, 1)).to_upper()


## What a hover says about a soldier: the numbers you would look for first, and where the rest is.
func _soldier_glance(soldier: Soldier) -> String:
	var lines: Array[String] = [
		"%s · Lv%d %s" % [
			soldier.full_name(), soldier.level, _units.display_name(soldier.unit_type_id),
		],
		"Age %d · Kills %d · Morale %d · Loyalty %d" % [
			soldier.age, soldier.kills, soldier.morale, soldier.loyalty,
		],
	]
	if not soldier.is_alive():
		lines.append("Fallen.")
	elif not soldier.traits.is_empty():
		var trait_names: Array[String] = []
		for trait_id in soldier.traits:
			trait_names.append(_traits.display_name(trait_id))
		lines.append(", ".join(trait_names))
	lines.append("Click for the full record.")
	return "\n".join(lines)


func _roster_color(soldier: Soldier) -> Color:
	if not soldier.is_alive():
		return UiTheme.BAD
	if soldier.hp < soldier.max_hp:
		return UiTheme.GOLD
	return UiTheme.TEXT


func _refresh_detail() -> void:
	for child in _detail_box.get_children():
		child.queue_free()
		_detail_box.remove_child(child)

	if _selected_soldier_id.is_empty():
		_detail_box.add_child(PixelStyle.body_label(
			"Select a soldier for their record.", SMALL_SIZE, UiTheme.DIM, true))
		return
	var soldier := _state.soldier(_selected_soldier_id)
	if soldier == null:
		_detail_box.add_child(PixelStyle.body_label(
			"That soldier is no longer in the party.", SMALL_SIZE, UiTheme.DIM, true))
		return

	_detail_box.add_child(PixelStyle.body_label(soldier.full_name(), 17, UiTheme.TEXT))
	_detail_box.add_child(PixelStyle.body_label(
		"Lv%d %s%s" % [
			soldier.level, _units.display_name(soldier.unit_type_id),
			"" if soldier.is_alive() else " · fallen",
		], SMALL_SIZE, UiTheme.DIM, true))
	_detail_box.add_child(PixelStyle.rule(DARK))

	_detail_box.add_child(_stat_row("Age", PixelStyle.pixel_label("%d" % soldier.age, 10)))
	_detail_box.add_child(_stat_row("Hit points",
		PixelStyle.pixel_label("%d / %d" % [soldier.hp, soldier.max_hp], 10, _roster_color(soldier))))
	_detail_box.add_child(_stat_row("Experience",
		PixelStyle.pixel_label("%d / %d" % [soldier.xp, soldier.xp_to_next(_config)], 10)))
	_detail_box.add_child(_stat_row("Kills", PixelStyle.pixel_label("%d" % soldier.kills, 10)))
	_detail_box.add_child(_stat_row("Battles",
		PixelStyle.pixel_label("%d fought / %d survived" % [
			soldier.battles_fought, soldier.battles_survived], 10)))
	_detail_box.add_child(_stat_row("Morale", PixelStyle.pixel_label("%d" % soldier.morale, 10)))
	_detail_box.add_child(_stat_row("Loyalty", PixelStyle.pixel_label("%d" % soldier.loyalty, 10)))
	_detail_box.add_child(_stat_row("Status",
		PixelStyle.pixel_label(soldier.status_display().to_upper(), 10)))

	_detail_box.add_child(PixelStyle.rule(DARK))
	_detail_box.add_child(PixelStyle.pixel_label("TRAITS", 10, UiTheme.ACCENT))
	if soldier.traits.is_empty():
		_detail_box.add_child(PixelStyle.body_label(
			"None yet — traits are earned.", SMALL_SIZE, UiTheme.DIM, true))
	else:
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 5)
		flow.add_theme_constant_override("v_separation", 5)
		_detail_box.add_child(flow)
		for trait_id in soldier.traits:
			var chip_node := PixelStyle.chip(_traits.display_name(trait_id), "", CHIP_BODY,
				LIGHT.darkened(0.6), UiTheme.GOLD, UiTheme.TEXT)
			chip_node.tooltip_text = _traits.description(trait_id)
			flow.add_child(chip_node)

	_detail_box.add_child(PixelStyle.rule(DARK))
	_detail_box.add_child(PixelStyle.pixel_label("HISTORY", 10, UiTheme.ACCENT))
	if soldier.history.is_empty():
		_detail_box.add_child(PixelStyle.body_label(
			"Nothing recorded yet.", SMALL_SIZE, UiTheme.DIM, true))
	else:
		for entry in soldier.history:
			var line := PixelStyle.body_label(
				"Day %d — %s" % [int(entry.get("day", 0)), str(entry.get("text", ""))],
				SMALL_SIZE, UiTheme.DIM)
			line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			line.custom_minimum_size = Vector2(320.0, 0.0)
			_detail_box.add_child(line)


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
