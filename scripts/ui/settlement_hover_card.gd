class_name SettlementHoverCard
extends PanelContainer
## The card a settlement grows when the cursor rests on it (D-136): what stands inside, what is
## traded, which houses hold it and how strongly, its wealth, its garrison, and how far it is.
##
## Hover, not click - clicking keeps the action panel, with Travel and Enter. The card never takes
## the mouse: every node inside it ignores the cursor, so resting on a settlement can never eat the
## click that orders the march.
##
## An unvisited place shows only what the road shows: name, kind, and how far. The rest is knowledge
## the party has not earned yet - the scouted-info half of the owner's request.

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.08, 0.094, 0.118)
const CHIP_BODY := Color(0.055, 0.065, 0.08)
const BAR_WIDTH := 66.0
const BAR_HEIGHT := 8.0

var _title: Label = null
var _meta: Label = null
var _body: VBoxContainer = null
var _foot: Label = null
var _shown_id := ""


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.5), OUTLINE))
	custom_minimum_size = Vector2(336.0, 0.0)
	visible = false
	_build()


func _build() -> void:
	theme = PixelStyle.tooltip_theme(BODY, LIGHT.darkened(0.45), UiTheme.TEXT)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	add_child(box)

	_title = PixelStyle.pixel_label("", 15, UiTheme.GOLD)
	box.add_child(_title)
	_meta = PixelStyle.pixel_label("", 9.5, UiTheme.DIM)
	box.add_child(_meta)
	box.add_child(PixelStyle.rule(DARK))

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	box.add_child(_body)

	box.add_child(PixelStyle.rule(DARK))
	_foot = PixelStyle.body_label("", 12.5, UiTheme.DIM, true)
	_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_foot.custom_minimum_size = Vector2(310.0, 0.0)
	box.add_child(_foot)
	_ignore_mouse(self)


## The card never eats the mouse: the cursor is standing on it, and the click under it is what
## orders the march.
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## Show the card for a settlement. [param travel_line] is built by the caller, which owns the travel
## service; the card owns the presentation alone.
func show_settlement(settlement: Settlement, travel_line: String) -> void:
	_shown_id = settlement.id
	_title.text = settlement.name.to_upper()
	_meta.text = "%s | %s | POP %d" % [
		settlement.type_display().to_upper(),
		SettlementDetails.house_display(settlement.owner_faction_id).to_upper(),
		settlement.population,
	]
	for child in _body.get_children():
		child.queue_free()
		_body.remove_child(child)

	if not settlement.visited:
		_body.add_child(PixelStyle.body_label(
			"Unscouted. Nobody here has told you what stands inside, or who holds it.",
			13, UiTheme.DIM, true))
		_foot.text = travel_line
		visible = true
		return

	_house_section(settlement)
	_building_section(settlement)
	_trade_section(settlement)
	_row_section("Garrison", "~%d spears" % settlement.garrison,
		"Wealth", settlement.wealth.to_upper())
	if settlement.last_visited_day > 0:
		_foot.text = "%s   |   Visited Day %d" % [travel_line, settlement.last_visited_day]
	else:
		_foot.text = travel_line
	visible = true


func hide_card() -> void:
	_shown_id = ""
	visible = false


func shown_id() -> String:
	return _shown_id


func _house_section(settlement: Settlement) -> void:
	_body.add_child(PixelStyle.pixel_label("HOUSES", 10, UiTheme.ACCENT))
	for index in settlement.families.size():
		var family: Dictionary = settlement.families[index] as Dictionary
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_label := PixelStyle.body_label(str(family.get("name", "?")), 13, UiTheme.TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		row.add_child(_power_bar(int(family.get("power", 0)), index == 0))
		row.add_child(PixelStyle.pixel_label("%d%%" % int(family.get("power", 0)), 10,
			UiTheme.GOLD if index == 0 else UiTheme.DIM))
		_body.add_child(row)


## A power bar: two rectangles, no layout needed. The owning house carries the accent, because
## there is exactly one house in charge.
func _power_bar(power: int, leading: bool) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	var trough := ColorRect.new()
	trough.color = DARK
	trough.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	holder.add_child(trough)
	var fill := ColorRect.new()
	fill.color = UiTheme.ACCENT if leading else LIGHT
	fill.size = Vector2(maxf(2.0, BAR_WIDTH * float(clampi(power, 0, 100)) / 100.0), BAR_HEIGHT)
	holder.add_child(fill)
	return holder


## Buildings as chips; each building's one-line note travels in its tooltip, so the card stays lean.
func _building_section(settlement: Settlement) -> void:
	_body.add_child(PixelStyle.pixel_label("BUILDINGS", 10, UiTheme.ACCENT))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 5)
	flow.add_theme_constant_override("v_separation", 5)
	for entry in settlement.buildings:
		var info: Dictionary = entry as Dictionary
		var chip_node := PixelStyle.chip(str(info.get("name", "?")), "", CHIP_BODY,
			LIGHT.darkened(0.6), UiTheme.TEXT, UiTheme.TEXT)
		chip_node.tooltip_text = _building_tooltip(info)
		flow.add_child(chip_node)
	_body.add_child(flow)


## The note, plus the state and the materials the building system dressed the building in (D-138).
## Words live in the tooltip (D-133), and the same fields are what a sprite will one day be
## assembled from - so the card is already showing the system's work.
func _building_tooltip(info: Dictionary) -> String:
	var lines: Array[String] = [str(info.get("note", ""))]
	var parts: Array[String] = []
	if info.has("condition_word"):
		parts.append(str(info.get("condition_word")))
	if info.has("roof"):
		parts.append("%s roof" % str(info.get("roof")))
	if info.has("wall"):
		parts.append("%s walls" % str(info.get("wall")))
	if not parts.is_empty():
		lines.append("It looks %s." % ", ".join(parts))
	var around: Array = info.get("attachment_names", []) as Array
	if not around.is_empty():
		lines.append("Around it: %s." % ", ".join(around))
	return "\n".join(lines)


func _trade_section(settlement: Settlement) -> void:
	_body.add_child(PixelStyle.pixel_label("TRADE", 10, UiTheme.ACCENT))
	_body.add_child(PixelStyle.body_label(
		"Produces   %s" % ", ".join(settlement.produces), 13, UiTheme.TEXT))
	_body.add_child(PixelStyle.body_label(
		"Wants      %s" % ", ".join(settlement.wants), 13, UiTheme.DIM))


func _row_section(a_name: String, a_value: String, b_name: String, b_value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var left := PixelStyle.body_label("%s  %s" % [a_name, a_value], 13, UiTheme.TEXT)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	row.add_child(PixelStyle.body_label("%s  %s" % [b_name, b_value], 13, UiTheme.DIM))
	_body.add_child(row)
