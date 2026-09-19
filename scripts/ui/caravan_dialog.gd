class_name CaravanDialog
extends PanelContainer
## The meeting prompt (D-139): a caravan on the road, what it carries, and what the player wants to
## do about it. The world is paused while this is open - that is the world map's job, not the
## dialog's; this only reports intent (same split as the encounter dialog, D-133 dressing).
##
## The Trade button is real: it buys one crate off the cart at the catalogue's value plus the
## trader's margin, out of the player's own coin. The rest of the trade economy is still cargo.

signal trade_requested()
signal ask_requested()
signal farewell_requested()

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)

var _title: Label = null
var _line: Label = null
var _note: Label = null
var _trade_button: Button = null


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.5), OUTLINE))
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(520.0, 0.0)
	offset_left = -260.0
	offset_top = -150.0
	offset_right = 260.0
	offset_bottom = 150.0
	visible = false
	_build()


func _build() -> void:
	var styles := PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY, LIGHT.darkened(0.45), UiTheme.TEXT)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	_title = PixelStyle.pixel_label("", 19, UiTheme.GOLD)
	box.add_child(_title)
	box.add_child(PixelStyle.rule(DARK))

	_line = PixelStyle.body_label("", 14.5, UiTheme.TEXT)
	_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line.custom_minimum_size = Vector2(480.0, 62.0)
	box.add_child(_line)

	_note = PixelStyle.body_label("", 14, UiTheme.GOLD, true)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(480.0, 40.0)
	box.add_child(_note)
	box.add_child(PixelStyle.rule(DARK))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	_trade_button = PixelStyle.text_button("Buy a crate", styles, 11, Vector2(160.0, 42.0),
		UiTheme.GOLD, UiTheme.DIM)
	_trade_button.pressed.connect(func() -> void: trade_requested.emit())
	row.add_child(_trade_button)

	var ask_button := PixelStyle.text_button("Ask about the road", styles, 11, Vector2(160.0, 42.0),
		UiTheme.TEXT, UiTheme.DIM)
	ask_button.pressed.connect(func() -> void: ask_requested.emit())
	row.add_child(ask_button)

	var farewell_button := PixelStyle.text_button("Farewell", styles, 11, Vector2(160.0, 42.0),
		UiTheme.TEXT, UiTheme.DIM)
	farewell_button.pressed.connect(func() -> void: farewell_requested.emit())
	row.add_child(farewell_button)


## Show the meeting for one caravan. Every number comes from the caravan itself.
func show_meeting(caravan: WorldParty, service: CaravanService, state: CampaignState) -> void:
	_title.text = caravan.display_name.to_upper()
	var guards := service.guards_of(caravan)
	var guard_count := state.active_member_count(guards) if guards != null else 0
	var guard_line := "unguarded" if guard_count <= 0 else "%d guards" % guard_count
	_line.text = "Well met, banner. %s  (%s.)" % [service.road_report(caravan), guard_line]
	_note.text = "They will sell what they carry, and tell you what they know."
	_trade_button.disabled = caravan.cargo.is_empty()
	visible = true
	if is_inside_tree():
		_trade_button.grab_focus()


## A line under the traders' answer: the result of a purchase, or whatever the road report said.
func set_note(text: String) -> void:
	_note.text = text


## After a sale the cart is lighter; the button follows it.
func refresh_after_trade(caravan: WorldParty) -> void:
	_trade_button.disabled = caravan.cargo.is_empty()
	if caravan.cargo.is_empty():
		_note.text += " The cart is empty now, bar the smell."


func hide_dialog() -> void:
	visible = false


## Everything the dialog is currently saying, for the suite: the meeting's claims are data, so they
## should be assertable, not just photographable.
func summary() -> String:
	return "%s | %s | %s" % [_title.text, _line.text, _note.text]
