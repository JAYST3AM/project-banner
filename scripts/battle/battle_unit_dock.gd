class_name BattleUnitDock
extends PanelContainer
## A presentation-only battle roster. The caller owns selection and simulation state.
## Each card represents a friendly formation; a missing atlas gets a neutral class sign,
## never an invented portrait. A snapshot fully replaces the displayed roster.
signal body_chosen(body_id: int, additive: bool)

const INK := Color("141816")
const CARD := Color("222823")
const CARD_HOVER := Color("343b32")
const CARD_SELECTED := Color("3d392c")
const EDGE := Color("576052")
const GOLD := Color("e2c787")
const PARCHMENT := Color("e7e0cd")
const MUTED := Color("b5b8a7")
const REINFORCED := Color("73937b")
const DEPLETED := Color("b46b59")

var _row: HBoxContainer = null
var _cards: Dictionary = {}
var _art: UnitArt = null


static func _style(bg: Color, border: Color, width: int = 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(2)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	return style


func _ready() -> void:
	add_theme_stylebox_override("panel", _style(INK, EDGE))
	_art = UnitArt.load_if_present()
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(scroll)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	_row.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(_row)


func _small_label(text: String, points: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", points)
	label.add_theme_color_override("font_color", color)
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _portrait(unit_key: String) -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(57, 72)
	frame.add_theme_stylebox_override("panel", _style(Color("111915"), Color("4e584d")))
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _art != null and _art.has_character(unit_key):
		var rect := _art.uv_rect(unit_key, UnitArt.IDLE, 0)
		var tex := AtlasTexture.new()
		tex.atlas = _art.texture()
		var atlas_size := _art.atlas_size()
		tex.region = Rect2(rect.position * atlas_size, rect.size * atlas_size)
		var image := TextureRect.new()
		image.texture = tex
		image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(image)
	else:
		# A simple class sign avoids claiming a nonexistent sprite is an actual portrait.
		var class_sign := _small_label("✦", 24, MUTED)
		class_sign.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		class_sign.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		frame.add_child(class_sign)
	return frame


func _make_card(body_id: int, unit_key: String) -> Dictionary:
	var button := Button.new()
	button.text = ""
	button.focus_mode = Control.FOCUS_NONE
	button.toggle_mode = true
	button.custom_minimum_size = Vector2(193, 85)
	button.add_theme_stylebox_override("normal", _style(CARD, EDGE))
	button.add_theme_stylebox_override("hover", _style(CARD_HOVER, GOLD))
	button.add_theme_stylebox_override("pressed", _style(CARD_SELECTED, GOLD, 2))
	button.add_theme_stylebox_override("hover_pressed", _style(CARD_SELECTED, GOLD, 2))
	button.add_theme_stylebox_override("disabled", _style(INK, Color("303832")))
	button.tooltip_text = "Select formation · Shift-click to add/remove"
	button.pressed.connect(_choose.bind(body_id))
	_row.add_child(button)

	var contents := HBoxContainer.new()
	contents.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	contents.offset_left = 7.0
	contents.offset_right = -7.0
	contents.offset_top = 5.0
	contents.offset_bottom = -5.0
	contents.add_theme_constant_override("separation", 9)
	contents.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(contents)
	contents.add_child(_portrait(unit_key))

	var text_stack := VBoxContainer.new()
	text_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_stack.add_theme_constant_override("separation", 3)
	text_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	contents.add_child(text_stack)

	var title := _small_label("", 12, PARCHMENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_stack.add_child(title)
	var count := _small_label("", 13, GOLD)
	text_stack.add_child(count)

	var strength := ProgressBar.new()
	strength.custom_minimum_size = Vector2(96.0, 6.0)
	strength.min_value = 0.0
	strength.max_value = 100.0
	strength.show_percentage = false
	strength.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strength.add_theme_stylebox_override("background", _style(Color("10130f"), Color("10130f"), 0))
	strength.add_theme_stylebox_override("fill", _style(REINFORCED, REINFORCED, 0))
	text_stack.add_child(strength)

	var shape := _small_label("", 10, MUTED)
	text_stack.add_child(shape)
	return {"button": button, "title": title, "count": count,
		"strength": strength, "shape": shape, "unit_key": unit_key, "last_state": ""}


## The caller owns the authoritative roster and selection. A snapshot is a full replacement,
## not an incremental patch: removed, enemy and invalid IDs cannot leave stale cards behind.
## A destroyed friendly formation remains visible at zero strength while it is still in the
## snapshot, but its card is disabled and cannot emit selection requests.
func update_bodies(bodies: Array[Dictionary], selected: Array[int]) -> void:
	if _row == null:
		return
	var seen: Dictionary = {}
	var position := 0
	for body in bodies:
		if int(body.get("side", 1)) != 0:
			continue
		var id := int(body.get("id", -1))
		if id < 0 or seen.has(id):
			continue
		seen[id] = true
		var unit_key := str(body.get("type_key", ""))
		if _cards.has(id) and str(_cards[id].get("unit_key", "")) != unit_key:
			_remove_card(id)
		if not _cards.has(id):
			_cards[id] = _make_card(id, unit_key)
		var card: Dictionary = _cards[id]
		var button: Button = card["button"]
		var alive := maxi(0, int(body.get("alive", 0)))
		var started := maxi(1, int(body.get("started", alive)))
		var shape := str(body.get("shape", "line")).to_upper()
		var order := str(body.get("order", "HOLD")).to_upper()
		var name := str(body.get("name", "Formation"))
		var ratio := clampf(float(alive) / float(started), 0.0, 1.0)
		var state := "%s/%d/%d/%s/%s" % [name, alive, started, shape, order]
		if str(card["last_state"]) != state:
			(card["title"] as Label).text = name
			(card["count"] as Label).text = "%d / %d" % [alive, started]
			(card["shape"] as Label).text = "%s · %s" % [shape, order]
			(card["strength"] as ProgressBar).value = ratio * 100.0
			var fill := REINFORCED if ratio > 0.45 else DEPLETED
			(card["strength"] as ProgressBar).add_theme_stylebox_override(
				"fill", _style(fill, fill, 0))
			card["last_state"] = state
		button.disabled = alive <= 0
		button.set_pressed_no_signal(alive > 0 and selected.has(id))
		if _row.get_child(position) != button:
			_row.move_child(button, position)
		position += 1

	var stale: Array[int] = []
	for id in _cards.keys():
		if not seen.has(id):
			stale.append(int(id))
	for id in stale:
		_remove_card(id)


func _remove_card(id: int) -> void:
	if not _cards.has(id):
		return
	var button: Button = _cards[id]["button"]
	_cards.erase(id)
	if is_instance_valid(button):
		if button.get_parent() != null:
			button.get_parent().remove_child(button)
		button.queue_free()


## A request, not an order or a selection mutation. The parent may replace or extend its
## selection based on additive. Only live, currently displayed friendly IDs are eligible.
func request_selection(id: int, additive: bool) -> void:
	if not _cards.has(id):
		return
	var button: Button = _cards[id]["button"]
	if button.disabled:
		return
	body_chosen.emit(id, additive)


func _choose(id: int) -> void:
	request_selection(id, Input.is_key_pressed(KEY_SHIFT))
