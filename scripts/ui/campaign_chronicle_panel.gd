class_name CampaignChroniclePanel
extends PanelContainer
## Read-only campaign history window. No hidden game-state changes, scene
## transitions or clock manipulation: closing it only changes presentation.
signal close_requested()

var _rows: VBoxContainer = null
var _event_snapshot: Array[Dictionary] = []

const BACK := Color("171d22")
const FRAME := Color("626c70")


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = BACK
	style.border_color = FRAME
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(14.0)
	add_theme_stylebox_override("panel", style)

	# Centre within the CanvasLayer's viewport. The panel is purposely fixed
	# width with a scrollable history so longer games remain readable.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -300.0
	offset_right = 300.0
	offset_top = -228.0
	offset_bottom = 228.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	add_child(content)

	var header := HBoxContainer.new()
	content.add_child(header)
	var name := PixelStyle.pixel_label("CAMPAIGN CHRONICLE", 16, UiTheme.GOLD)
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name)
	var close := Button.new()
	close.text = "X"
	close.custom_minimum_size = Vector2(32.0, 30.0)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(close)

	content.add_child(PixelStyle.body_label(
		"The company's journeys, recruits and battles.", 12, UiTheme.DIM, true))
	content.add_child(PixelStyle.rule(Color("414b52")))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	content.add_child(scroll)

	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 10)
	scroll.add_child(_rows)
	_rebuild()
	visible = false


func set_events(events: Array[Dictionary]) -> void:
	_event_snapshot = events.duplicate(true)
	if _rows != null:
		_rebuild()


func event_count() -> int:
	return _event_snapshot.size()


func _rebuild() -> void:
	if _rows == null:
		return
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()

	if _event_snapshot.is_empty():
		_rows.add_child(PixelStyle.body_label(
			"Your company's history has yet to be written.", 13, UiTheme.DIM, true))
		return

	for event in _event_snapshot:
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 2)
		_rows.add_child(group)

		var day := int(event.get("day", 1))
		var hour := float(event.get("hour", 0.0))
		var kind := str(event.get("kind", "event")).to_upper()
		group.add_child(PixelStyle.pixel_label(
			"DAY %d  %s  ·  %s" % [
				day, CampaignClock.time_string_from_hour(hour), kind],
			10, UiTheme.ACCENT))
		var title := PixelStyle.body_label(str(event.get("title", "")),
			15, UiTheme.TEXT, true)
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		group.add_child(title)

		var detail_text := str(event.get("detail", ""))
		if not detail_text.is_empty():
			var detail := PixelStyle.body_label(detail_text, 12, UiTheme.DIM, true)
			detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			group.add_child(detail)
		group.add_child(PixelStyle.rule(Color("343d43")))
