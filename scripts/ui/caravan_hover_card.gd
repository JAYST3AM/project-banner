class_name CaravanHoverCard
extends PanelContainer
## The traders' detail card (D-139), shown on hover like the settlement card (D-136): what it
## carries, who guards it, where it is bound and how fast it is going. Every line is read from the
## caravan itself - a card that says "3 spears" is saying three soldiers exist.

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)

var _title: Label = null
var _meta: Label = null
var _body: VBoxContainer = null
var _foot: Label = null
var _shown_id := ""


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.5), OUTLINE))
	custom_minimum_size = Vector2(320.0, 0.0)
	visible = false
	_build()


func _build() -> void:
	theme = PixelStyle.tooltip_theme(BODY, LIGHT.darkened(0.45), UiTheme.TEXT)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	add_child(box)

	_title = PixelStyle.pixel_label("", 14, UiTheme.GOLD)
	box.add_child(_title)
	_meta = PixelStyle.pixel_label("", 9.5, UiTheme.DIM)
	box.add_child(_meta)
	box.add_child(PixelStyle.rule(DARK))

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	box.add_child(_body)

	box.add_child(PixelStyle.rule(DARK))
	_foot = PixelStyle.body_label("", 12.5, UiTheme.DIM, true)
	_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_foot.custom_minimum_size = Vector2(294.0, 0.0)
	box.add_child(_foot)
	_ignore_mouse(self)


## The card never eats the mouse: the cursor is standing on it, and the click under it is what
## orders the march (same rule as the settlement card).
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## Fill and show the card for one caravan. [param service] supplies the pace and the leg clock so
## the card and the simulation cannot disagree about how far out the caravan is.
func show_caravan(caravan: WorldParty, service: CaravanService, state: CampaignState) -> void:
	_shown_id = caravan.id
	_title.text = caravan.display_name.to_upper()
	var speed := service.caravan_speed(caravan)
	var base := maxf(1.0, service.config.get_float("travel.world_units_per_game_hour", 150.0))
	_meta.text = "%d deliveries  |  %d u/h (%.0f%% of a walker's pace)" % [
		caravan.trips, int(round(speed)), 100.0 * speed / base]

	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()

	var from := state.settlement(caravan.from_settlement_id)
	var to := state.settlement(caravan.to_settlement_id)
	if to != null:
		var route := "%s -> %s" % [from.name if from != null else "?", to.name]
		if caravan.path_stops.size() > 2:
			var mids: Array[String] = []
			for i in range(1, caravan.path_stops.size() - 1):
				var mid := state.settlement(caravan.path_stops[i])
				mids.append(mid.name if mid != null else "?")
			route += "  (via %s)" % ", ".join(mids)
		_row("Bound for", route)
	else:
		_row("Bound for", "Somewhere with better prices")

	_row("Carrying", TradeService.describe_cargo(caravan.cargo, _cargo_value(caravan))
		if not caravan.cargo.is_empty() else "An empty cart")

	var guards := service.guards_of(caravan)
	if guards != null:
		var soldiers := state.active_member_count(guards)
		_row("Guards", "%d spears" % soldiers if soldiers > 0 else "Hired, but gone")
	else:
		_row("Guards", "None - travelling alone")

	if to != null and caravan.path_stops.size() >= 2:
		_row("On the road", "~%.1f h out" % service.leg_hours(caravan))
	elif to != null:
		_row("On the road", "loading at %s" % (from.name if from != null else "?"))

	_foot.text = "Traders. They keep to the roads, pay their tolls, and know what your silver is worth."
	visible = true


func _row(name: String, value: String) -> void:
	var value_label := PixelStyle.pixel_label(value, 9.5, UiTheme.TEXT)
	_body.add_child(PixelStyle.stat_row(name, value_label, 13))


func _cargo_value(caravan: WorldParty) -> int:
	var value := 0
	for good in caravan.cargo:
		value += TradeService.value_of(good)
	return value


func hide_card() -> void:
	visible = false


func shown_id() -> String:
	return _shown_id


## Everything the card is currently showing, for the suite. Reads the labels, so a test asserts
## what a player would actually see.
func summary() -> String:
	var parts: Array[String] = [_title.text, _meta.text]
	for child in _body.get_children():
		if child is Label:
			parts.append((child as Label).text)
		else:
			for inner in child.get_children():
				if inner is Label:
					parts.append((inner as Label).text)
	parts.append(_foot.text)
	return " | ".join(parts)
