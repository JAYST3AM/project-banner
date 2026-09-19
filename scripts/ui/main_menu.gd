extends Control
## The face of the game.
##
## A painted valley with a commander looking down at it, and the game's own name hanging in the
## quiet part of the sky. The interface on top of it is built here rather than in the scene file,
## the way the rest of this project's screens are, and it is dressed by [PixelStyle] so that the
## first thing the player touches is made of the same deliberate pixels as everything else.
##
## The one thing PixelStyle cannot enforce from its own file: every node that draws its textures
## sets its texture filter to nearest, or the GPU smooths the pixels into porridge.
##
## The four read-only accessors at the bottom are load-bearing: [code]test_legacy_menu.gd[/code]
## drives this screen through them, and it is the only thing proving the menu can open an old save
## without falling over. They read state, not node paths, so this layout can change around them.

const BACKGROUND_PATH := "res://assets/ui/main_menu_bg.png"
const COLUMN_WIDTH := 372.0
## How wide a button is. Not the column's width: a menu of full-width bars reads as a form, and
## these are three short words. The text block above them keeps the column, because a tagline wants
## room to wrap.
const BUTTON_WIDTH := 216.0
const TITLE_SIZE := 46
const TAGLINE_SIZE := 13
const BUTTON_SIZE := 15
const BUTTON_HEIGHT := 46.0
const SMALL_SIZE := 12

# One body tone, one accent, spent only on the state that is answering the mouse.
const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const SCRIM := Color(0.03, 0.04, 0.06, 0.86)

var _font: Font = null
var _settings: SettingsPanel = null
var _button_styles: Dictionary = {}
var _continue_button: Button = null
var _status: Label = null
var _name_input: LineEdit = null
var _seed_input: LineEdit = null
var _new_panel: Control = null


func _ready() -> void:
	_font = PixelStyle.pixel_font()
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	_build_background()
	_build_column()
	_refresh_continue_state()


func _build_background() -> void:
	if ResourceLoader.exists(BACKGROUND_PATH):
		var picture := TextureRect.new()
		picture.set_anchors_preset(Control.PRESET_FULL_RECT)
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		# Covered, not stretched: the painting keeps its proportions and the frame is filled
		# whatever shape the window is. A background stretched to fit makes a made-up valley look
		# made up.
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.texture = load(BACKGROUND_PATH)
		add_child(picture)
	else:
		# A missing picture is a missing asset, not a reason to show nothing.
		var flat := ColorRect.new()
		flat.color = Color(0.05, 0.06, 0.08)
		flat.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(flat)

	# The left third of the painting is sky, and sky is no place to read a menu off. A scrim that
	# fades out by the middle keeps the text legible without hiding the valley.
	var fade := Gradient.new()
	fade.colors = PackedColorArray([SCRIM, SCRIM, Color(SCRIM.r, SCRIM.g, SCRIM.b, 0.55), Color(0, 0, 0, 0)])
	fade.offsets = PackedFloat32Array([0.0, 0.28, 0.52, 0.78])
	var gradient := GradientTexture2D.new()
	gradient.gradient = fade
	gradient.fill_from = Vector2(0.0, 0.5)
	gradient.fill_to = Vector2(1.0, 0.5)
	gradient.width = 256
	gradient.height = 4
	var scrim := TextureRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim.stretch_mode = TextureRect.STRETCH_SCALE
	scrim.texture = gradient
	add_child(scrim)


func _build_column() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 68)
	margin.add_theme_constant_override("margin_right", 24)
	add_child(margin)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 8)
	column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	column.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	margin.add_child(column)

	column.add_child(_label("PROJECT BANNER", TITLE_SIZE, UiTheme.GOLD))
	var tagline := _label("A persistent medieval world. Individual soldiers. Permanent consequences.",
		TAGLINE_SIZE, Color(0.72, 0.74, 0.78))
	tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tagline.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	column.add_child(tagline)
	column.add_child(_gap(18))

	_continue_button = _button("Continue")
	_continue_button.pressed.connect(_on_continue)
	column.add_child(_continue_button)
	var new_button := _button("New Campaign")
	new_button.pressed.connect(_on_new_pressed)
	column.add_child(new_button)
	var settings_button := _button("Settings")
	settings_button.pressed.connect(_on_settings)
	column.add_child(settings_button)
	var quit_button := _button("Quit")
	quit_button.pressed.connect(_on_quit)
	column.add_child(quit_button)
	column.add_child(_gap(10))

	_status = _label("", SMALL_SIZE, Color(0.66, 0.68, 0.72))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(COLUMN_WIDTH, 46)
	column.add_child(_status)

	_build_new_panel(column)
	_continue_button.grab_focus()
	# Dev-only: "--settings-panel" opens it, because a screenshot cannot click a button.
	if DevFlags.settings_panel():
		_on_settings()


## Settings, lazily built: the panel is shared with the Esc menu and carries its own furniture
## (D-137). Built on first use so the front screen opens without it when nobody asks.
func _on_settings() -> void:
	if _settings == null:
		_settings = SettingsPanel.new()
		add_child(_settings)
	_settings.open()


## Naming a campaign and choosing its world is a second decision, so it lives behind the button
## that means it rather than in front of the one that means continue.
func _build_new_panel(column: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", PixelStyle.panel_style(BODY, LIGHT.darkened(0.3), OUTLINE))
	panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	panel.visible = false
	column.add_child(panel)
	_new_panel = panel

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	panel.add_child(inner)
	inner.add_child(_label("NEW CAMPAIGN", SMALL_SIZE, UiTheme.GOLD))
	inner.add_child(_label("Campaign name", SMALL_SIZE, Color(0.66, 0.68, 0.72)))
	_name_input = LineEdit.new()
	_name_input.custom_minimum_size = Vector2(0, 32)
	_name_input.max_length = 48
	_name_input.text = GameManager.config().get_string("campaign.default_campaign_name", "A New Banner")
	_dress_field(_name_input)
	inner.add_child(_name_input)
	inner.add_child(_label("World seed (blank = random)", SMALL_SIZE, Color(0.66, 0.68, 0.72)))
	_seed_input = LineEdit.new()
	_seed_input.custom_minimum_size = Vector2(0, 32)
	_seed_input.max_length = 18
	_seed_input.placeholder_text = "random"
	_dress_field(_seed_input)
	inner.add_child(_seed_input)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	inner.add_child(row)
	var begin := _button("Begin")
	begin.pressed.connect(_on_new_campaign)
	row.add_child(begin)
	var cancel := _button("Cancel")
	cancel.pressed.connect(_close_new_panel)
	row.add_child(cancel)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _new_panel != null and _new_panel.visible:
		_close_new_panel()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------------------------
# Behaviour. Unchanged in substance from the menu this replaces: a campaign name and an optional
# seed, Continue offered only when a save exists and this build can read it, and a quit.
# ---------------------------------------------------------------------------------------------

func _on_new_pressed() -> void:
	if _new_panel == null:
		return
	_new_panel.visible = true
	_name_input.grab_focus()
	_name_input.select_all()


func _close_new_panel() -> void:
	if _new_panel != null:
		_new_panel.visible = false
	if _continue_button != null:
		_continue_button.grab_focus()


func _on_new_campaign() -> void:
	var seed_value := 0
	var raw_seed := _seed_input.text.strip_edges()
	if not raw_seed.is_empty():
		seed_value = int(raw_seed) if raw_seed.is_valid_int() else RngService.stable_hash(raw_seed)
	GameManager.new_campaign(_name_input.text, seed_value)
	SceneManager.change_scene("world_map")


func _on_continue() -> void:
	if not GameManager.continue_campaign():
		_refresh_continue_state()
		return
	SceneManager.change_scene("world_map")


func _on_quit() -> void:
	DebugLogger.info("quit requested from main menu", "MainMenu")
	get_tree().quit()


## Continue is only offered when a save actually exists and this build can read it.
func _refresh_continue_state() -> void:
	var summary := GameManager.continue_summary()
	var available := not summary.is_empty()
	_continue_button.disabled = not available
	if available:
		_status.text = "Saved campaign: %s - Day %d %s - %d gold - %d soldiers" % [
			summary.get("campaign_name", "?"),
			int(summary.get("day", 1)),
			CampaignClock.time_string_from_hour(float(summary.get("hour", 8.0))),
			int(summary.get("player_gold", 0)),
			int(summary.get("party_active", summary.get("party_size", 0))),
		]
		var lost := int(summary.get("party_lost", 0))
		if lost > 0:
			_status.text += " (%d lost)" % lost
		if SaveManager.is_save_too_new():
			_continue_button.disabled = true
			_status.text = "That save was written by a newer version of the game (save v%d) and cannot be opened." % int(
				summary.get("save_version", 0))
	else:
		_status.text = "No saved campaign found."
	DebugLogger.info("main menu: continue %s" % ("offered" if available and not _continue_button.disabled else "not available"),
		"MainMenu")


# ---------------------------------------------------------------------------------------------
# Furniture
# ---------------------------------------------------------------------------------------------

func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label


func _gap(height: int) -> Control:
	var space := Control.new()
	space.custom_minimum_size = Vector2(0, float(height))
	return space


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
	# Shrink, not fill: inside a vertical box the default is to stretch to the widest thing in the
	# column, which is how three short words became three long bars.
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	PixelStyle.dress_button(button, _button_styles, _font, BUTTON_SIZE, UiTheme.TEXT,
		Color(0.45, 0.47, 0.51))
	return button


func _dress_field(field: LineEdit) -> void:
	field.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	field.add_theme_stylebox_override("normal",
		PixelStyle.panel_style(Color(0.10, 0.12, 0.15), LIGHT.darkened(0.5), OUTLINE))
	field.add_theme_stylebox_override("focus",
		PixelStyle.panel_style(Color(0.13, 0.15, 0.19), UiTheme.ACCENT, UiTheme.ACCENT))
	if _font != null:
		field.add_theme_font_override("font", _font)
	field.add_theme_font_size_override("font_size", SMALL_SIZE)
	field.add_theme_color_override("font_color", UiTheme.TEXT)
	field.add_theme_color_override("font_placeholder_color", Color(0.45, 0.47, 0.51))
	field.add_theme_color_override("caret_color", UiTheme.ACCENT)


# ---------------------------------------------------------------------------------------------
# Read-only access for the tests. They read state rather than node paths, so the layout above can
# change without breaking the thing that proves this screen can open an old save. See the header.
# ---------------------------------------------------------------------------------------------

func continue_available() -> bool:
	return not _continue_button.disabled


func status_text() -> String:
	return _status.text


func offered_campaign_name() -> String:
	return str(GameManager.continue_summary().get("campaign_name", ""))


## Press Continue. This is the button's own handler, made callable by name so a test drives the
## real path rather than a copy of it - not a test-only mutation hook.
func press_continue() -> void:
	_on_continue()
