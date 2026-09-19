extends Control
## Battle results: what the fight cost, who earned what, and what it paid.
##
## Reads a [BattleResult] from the scene payload. Holds no game state of its own -
## by the time this screen exists, the consequences have already been written to
## the campaign.
##
## Dressed in the interface's one language (D-133). Deliberately chrome-only: the suites read this
## screen's [method displayed_text] to prove the real fight reached it, so every figure stays a
## visible Label exactly as before, only the furniture changed.

const WORLD_MAP_KEY := "world_map"

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)
const CARD_BODY := Color(0.10, 0.118, 0.15)

var _result: BattleResult = null
var _root: VBoxContainer = null
var _button_styles: Dictionary = {}


func _ready() -> void:
	$Background.color = UiTheme.BG
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(CARD_BODY, LIGHT.darkened(0.45), UiTheme.TEXT)
	var payload := SceneManager.consume_payload()
	_result = payload.get("result") as BattleResult

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 20)
	add_child(margin)

	var panel := PixelStyle.dressed_panel(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE)
	margin.add_child(panel)

	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 8)
	panel.add_child(_root)

	if _result == null:
		_root.add_child(PixelStyle.pixel_label("Battle Results", 22, UiTheme.GOLD))
		_root.add_child(PixelStyle.body_label("No battle result was passed to this screen.", 14,
			UiTheme.DIM, true))
		_add_continue_button()
		return

	_build_result()


func _build_result() -> void:
	var outcome_color := UiTheme.GOOD if _result.player_won() else UiTheme.BAD
	if _result.winner == BattleResult.WINNER_DRAW:
		outcome_color = UiTheme.GOLD
	elif _result.is_withdrawal():
		outcome_color = UiTheme.DIM

	var title := PixelStyle.pixel_label(_result.title(), 34, outcome_color)
	_root.add_child(title)
	_root.add_child(PixelStyle.body_label(_result.headline(), 16, UiTheme.TEXT))
	if _result.is_withdrawal():
		var note := PixelStyle.body_label(
			"Breaking off is not a battle survived, and the field was not yours to take. "
			+ "Kills already made still stand, and the enemy is still out there.",
			13, UiTheme.DIM, true)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(1000.0, 0.0)
		_root.add_child(note)
	_root.add_child(PixelStyle.pixel_label("Day %d, %s   |   lasted %s   |   battle %s" % [
		_result.campaign_day,
		CampaignClock.time_string_from_hour(_result.campaign_hour),
		_result.duration_string(),
		_result.battle_id,
	], 10, UiTheme.DIM))
	_root.add_child(PixelStyle.rule(DARK))

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(columns)

	columns.add_child(_build_losses_panel())
	columns.add_child(_build_survivors_panel())
	columns.add_child(_build_spoils_panel())

	_add_continue_button()


func _build_losses_panel() -> Control:
	var box := _section("Your losses")
	if _result.player_dead.is_empty():
		box.add_child(PixelStyle.body_label("None. Everyone came back.", 14, UiTheme.GOOD))
		return _wrap(box)

	for entry in _result.player_dead:
		box.add_child(PixelStyle.body_label(str(entry.get("name", "?")), 15, UiTheme.BAD))
		box.add_child(PixelStyle.body_label("      %s" % str(entry.get("death_note", "")),
			12.5, UiTheme.DIM, true))

	box.add_child(PixelStyle.rule(DARK))
	box.add_child(PixelStyle.body_label("%d of %d fell" % [_result.player_casualties(), _result.player_total],
		14, UiTheme.TEXT))
	return _wrap(box)


func _build_survivors_panel() -> Control:
	var box := _section("Survivors")
	if _result.player_survivors.is_empty():
		box.add_child(PixelStyle.body_label("Nobody.", 15, UiTheme.BAD))
		return _wrap(box)

	for entry in _result.player_survivors:
		var name_text := str(entry.get("name", "?"))
		var levels := int(entry.get("levels_gained", 0))
		if levels > 0:
			name_text += "   (level %d)" % int(entry.get("level", 1)) + (" +%d" % levels)
		box.add_child(PixelStyle.body_label(name_text, 15, UiTheme.TEXT))
		var detail := "      +%d XP" % int(entry.get("xp_gained", 0))
		var kills := int(entry.get("kills", 0))
		detail += "   %d kill%s" % [kills, "" if kills == 1 else "s"]
		detail += "   %d/%d HP" % [int(entry.get("hp", 0)), int(entry.get("max_hp", 0))]
		box.add_child(PixelStyle.body_label(detail, 12.5, UiTheme.DIM))

	box.add_child(PixelStyle.rule(DARK))
	if _result.is_withdrawal():
		box.add_child(PixelStyle.body_label("%d of %d came away   |   %d XP earned" % [
			_result.player_survivors.size(), _result.player_total, _result.xp_awarded,
		], 14, UiTheme.TEXT))
	else:
		box.add_child(PixelStyle.body_label("%d of %d survived   |   %d XP earned" % [
			_result.player_survivors.size(), _result.player_total, _result.xp_awarded,
		], 14, UiTheme.TEXT))
	return _wrap(box)


func _build_spoils_panel() -> Control:
	var box := _section("Loot")
	if _result.gold_total() <= 0:
		box.add_child(PixelStyle.body_label(
			"You left the field. Nothing was taken." if _result.is_withdrawal() else "Nothing was taken.",
			14, UiTheme.DIM,
		))
	else:
		box.add_child(PixelStyle.pixel_label("%d gold" % _result.gold_total(), 20, UiTheme.GOLD))
		if _result.gold_from_enemies > 0:
			box.add_child(PixelStyle.body_label("      %d from the fallen" % _result.gold_from_enemies,
				12.5, UiTheme.DIM))
		if _result.gold_from_victory > 0:
			box.add_child(PixelStyle.body_label("      %d for holding the field" % _result.gold_from_victory,
				12.5, UiTheme.DIM))

	if not _result.loot.is_empty():
		box.add_child(PixelStyle.rule(DARK))
		for item in _result.loot:
			box.add_child(PixelStyle.body_label(str(item.get("name", "something")), 14, UiTheme.TEXT))
			box.add_child(PixelStyle.body_label("      sold for %d gold" % int(item.get("value", 0)),
				12.5, UiTheme.DIM))
		box.add_child(PixelStyle.body_label(
			"There is nowhere to keep gear yet, so loot is sold on the spot.", 12.5, UiTheme.DIM, true))

	box.add_child(PixelStyle.rule(DARK))
	box.add_child(PixelStyle.body_label("Enemy: %d of %d put down" % [
		_result.enemy_dead.size(), _result.enemy_total,
	], 14, UiTheme.TEXT))
	if _result.enemy_survivor_count() > 0:
		box.add_child(PixelStyle.body_label(
			"      %d still standing, and they keep the wounds they took" % (
				_result.enemy_survivor_count()
			), 12.5, UiTheme.DIM))
	box.add_child(PixelStyle.body_label("Your kills: %d" % _result.total_player_kills(), 14,
		UiTheme.TEXT))
	return _wrap(box)


func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	box.custom_minimum_size = Vector2(360.0, 0.0)
	box.add_child(PixelStyle.pixel_label(title.to_upper(), 13, UiTheme.ACCENT))
	box.add_child(PixelStyle.rule(DARK))
	return box


func _wrap(box: VBoxContainer) -> Control:
	var panel := PixelStyle.dressed_panel(CARD_BODY, LIGHT.darkened(0.6), OUTLINE)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(box)
	return panel


func _add_continue_button() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	_root.add_child(row)
	var button := PixelStyle.text_button("Continue", _button_styles, 12, Vector2(220.0, 42.0),
		UiTheme.GOLD, UiTheme.DIM)
	button.pressed.connect(continue_to_world_map)
	row.add_child(button)
	button.grab_focus()


## Public because it is the screen's one action, not a private detail of the button:
## the tests drive the same entry point the player's click does.
func continue_to_world_map() -> void:
	SceneManager.change_scene(WORLD_MAP_KEY)


## Read-only view of what this screen was handed. Nothing here changes behaviour;
## it exists so the end-to-end test can assert that the real [BattleResult] reached
## this screen, rather than confirming only that the screen exists.
func displayed_result() -> BattleResult:
	return _result


## Every piece of text the screen is actually showing, in tree order. Lets a test
## check the UI represents the real fight without depending on node paths or layout.
func displayed_text() -> String:
	var parts: Array[String] = []
	_collect_text(self, parts)
	return "\n".join(parts)


func _collect_text(node: Node, into: Array[String]) -> void:
	if node is Label:
		into.append((node as Label).text)
	elif node is Button:
		into.append((node as Button).text)
	for child in node.get_children():
		_collect_text(child, into)
