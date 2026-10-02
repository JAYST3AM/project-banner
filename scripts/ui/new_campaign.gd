extends Control
## The New Campaign screen (D-168): one place where a campaign is founded.
##
## This is the whole of pre-campaign setup - the company's name, the banner it marches
## under and the world it marches into - on one full-screen surface. The owner's brief
## was explicit: no popup form followed by a second window; the player stays here until
## they either go Back or press Start Campaign.
##
## The campaign does not exist until Start Campaign (the D-167 contract, kept): this
## screen collects the name, the seed and the painted banner locally, and only
## [method start] calls [method GameManager.new_campaign] and moves to the world map.
## Back or Escape returns to the menu and creates nothing.
##
## The banner workspace is [BannerWorkspace], the same component the paint prototype's
## tools were approved in - one source of truth for banner editing. The left rail lists
## the sections a creation screen will eventually hold; only the ones that genuinely
## exist are interactive, the rest are plainly marked as later so nothing pretends to
## exist before it does (the owner's rule). The right column carries the world's seed and
## a live summary of what Start Campaign will found.
##
## The read-only accessors under "for the tests" exist so a suite can drive this screen
## through the same methods its buttons drive - not a parallel test path.

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const DIM := Color(0.66, 0.68, 0.72)
const SMALL_SIZE := 12

## The rail's sections. `ready` is the honest switch: true means the section is on this
## screen today; false renders as a plainly marked "later" line, and the founder creator
## will flip them on as those systems are built. Nothing here is a control until it has
## something to control.
const SECTIONS: Array = [
	["company", "COMPANY", true],
	["founder", "FOUNDER", false],
	["appearance", "APPEARANCE", false],
	["backstory", "BACKSTORY", false],
	["culture", "CULTURE", false],
	["starting", "STARTING CONDITIONS", false],
	["rules", "CAMPAIGN RULES", false],
]

var _font: Font = null
var _button_styles: Dictionary = {}
var _workspace: BannerWorkspace = null
var _name_input: LineEdit = null
var _seed_input: LineEdit = null
var _summary: Label = null


func _ready() -> void:
	var payload: Dictionary = SceneManager.consume_payload()
	_font = PixelStyle.pixel_font()
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY, UiTheme.ACCENT, UiTheme.TEXT)
	_build()
	var incoming: Variant = payload.get("banner", null)
	if incoming is BannerData:
		_workspace.install_banner(incoming as BannerData)
	if payload.has("campaign_name"):
		_name_input.text = str(payload.get("campaign_name"))
	if payload.has("seed_value"):
		_seed_input.text = str(payload.get("seed_value"))
	_refresh_summary()
	DebugLogger.info("new campaign screen opened", "NewCampaign")


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------

func _build() -> void:
	var background := ColorRect.new()
	background.color = Color(0.05, 0.06, 0.08)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	column.add_child(PixelStyle.pixel_label("FOUND YOUR COMPANY", 22, UiTheme.GOLD))
	column.add_child(PixelStyle.body_label(
		"Raise a company, paint the banner it marches under, and choose the world it marches into.",
		15, DIM))
	column.add_child(PixelStyle.rule(LIGHT.darkened(0.3)))

	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 22)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(main)
	_build_rail(main)
	_build_company_section(main)
	_build_world_column(main)

	column.add_child(PixelStyle.rule(LIGHT.darkened(0.3)))
	_build_actions(column)


## The section rail: where the founder creator will grow. Current sections read bright,
## later ones are dim and plainly marked - labels, not buttons, because a control that
## cannot do anything is a lie about what the game can do.
func _build_rail(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.custom_minimum_size = Vector2(170.0, 0.0)
	parent.add_child(column)

	column.add_child(PixelStyle.pixel_label("SECTIONS", 11, UiTheme.GOLD))
	for entry in SECTIONS:
		var pair: Array = entry
		var ready := bool(pair[2])
		# Only the colour marks the current section: the founder sections are plainly dim
		# and called out below, and nothing here is a control until it has something to control.
		var label := PixelStyle.body_label(str(pair[1]), 14, UiTheme.GOLD if ready else Color(0.36, 0.38, 0.42))
		column.add_child(label)
	var note := PixelStyle.body_label(
		"The founder sections arrive as their systems do - this screen is their home.", SMALL_SIZE, DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(170.0, 0.0)
	column.add_child(note)


## The company: its name, and the banner it marches under. The workspace carries every
## tool the paint prototype proved; the name is the one thing the menu used to own.
func _build_company_section(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(column)

	column.add_child(PixelStyle.pixel_label("COMPANY", 11, UiTheme.GOLD))
	column.add_child(PixelStyle.body_label("Company name", 13, DIM))
	_name_input = LineEdit.new()
	_name_input.custom_minimum_size = Vector2(330.0, 28.0)
	_name_input.max_length = 48
	_name_input.placeholder_text = _default_company_name()
	_dress_field(_name_input)
	_name_input.text_changed.connect(func(_text: String) -> void: _refresh_summary())
	column.add_child(_name_input)

	_workspace = BannerWorkspace.new()
	_workspace.banner_changed.connect(_refresh_summary)
	column.add_child(_workspace)


## The world: its seed today, its settings as they arrive. Below it, the live summary of
## what Start Campaign will found.
func _build_world_column(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.custom_minimum_size = Vector2(310.0, 0.0)
	parent.add_child(column)

	column.add_child(PixelStyle.pixel_label("WORLD", 11, UiTheme.GOLD))
	column.add_child(PixelStyle.body_label("World seed", 13, DIM))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)
	_seed_input = LineEdit.new()
	_seed_input.custom_minimum_size = Vector2(200.0, 28.0)
	_seed_input.max_length = 18
	_seed_input.placeholder_text = "random"
	_dress_field(_seed_input)
	_seed_input.text_changed.connect(func(_text: String) -> void: _refresh_summary())
	row.add_child(_seed_input)
	var random_button := PixelStyle.text_button("Randomise", _button_styles, 12, Vector2(0.0, 28.0),
		UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	random_button.pressed.connect(randomise_seed)
	row.add_child(random_button)
	var hint := PixelStyle.body_label("Blank = a random world; numbers and words both mark one.", SMALL_SIZE, DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(310.0, 0.0)
	column.add_child(hint)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	column.add_child(spacer)
	column.add_child(PixelStyle.rule(LIGHT.darkened(0.3)))
	column.add_child(PixelStyle.pixel_label("CAMPAIGN PREVIEW", 11, UiTheme.GOLD))
	_summary = PixelStyle.body_label("", 13, DIM)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.custom_minimum_size = Vector2(310.0, 0.0)
	column.add_child(_summary)
	var note := PixelStyle.body_label(
		"The campaign is founded when you press Start Campaign. Back leaves the world unfounded.",
		SMALL_SIZE, DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(310.0, 0.0)
	column.add_child(note)


func _build_actions(column: VBoxContainer) -> void:
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	column.add_child(actions)
	var back_button := PixelStyle.text_button("Back", _button_styles, 13, Vector2(140.0, 38.0),
		UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	back_button.pressed.connect(back)
	actions.add_child(back_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	var start_button := PixelStyle.text_button("START CAMPAIGN", _button_styles, 15, Vector2(240.0, 38.0),
		UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	start_button.pressed.connect(start)
	actions.add_child(start_button)


func _dress_field(field: LineEdit) -> void:
	field.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	field.add_theme_stylebox_override("normal",
		PixelStyle.panel_style(Color(0.10, 0.12, 0.15), LIGHT.darkened(0.5), OUTLINE))
	field.add_theme_stylebox_override("focus",
		PixelStyle.panel_style(Color(0.13, 0.15, 0.19), UiTheme.ACCENT, UiTheme.ACCENT))
	if _font != null:
		field.add_theme_font_override("font", _font)
	field.add_theme_font_size_override("font_size", PixelStyle.scaled(13))
	field.add_theme_color_override("font_color", UiTheme.TEXT)
	field.add_theme_color_override("font_placeholder_color", Color(0.45, 0.47, 0.51))
	field.add_theme_color_override("caret_color", UiTheme.ACCENT)


# ---------------------------------------------------------------------------------------------
# The flow: Start Campaign founds the company, Back leaves nothing behind.
# ---------------------------------------------------------------------------------------------

## The name the campaign will carry: what the player typed, or the configured default
## when they typed nothing - a blank field must never resolve to an unusable name.
func resolved_name() -> String:
	var typed := _name_input.text.strip_edges()
	return typed if not typed.is_empty() else _default_company_name()


## The seed the campaign will carry: blank means "random at founding" (0, as
## [method GameManager.new_campaign] has always read it), a number is that number, and
## words get the stable hash the menu always gave them - the same request, the same world.
func resolved_seed() -> int:
	var raw := _seed_input.text.strip_edges()
	if raw.is_empty():
		return 0
	return int(raw) if raw.is_valid_int() else RngService.stable_hash(raw)


## Fill the seed field with a concrete random seed, so the player can see and share the
## world they are about to found (blank would stay random, but invisible).
func randomise_seed() -> void:
	_seed_input.text = str(randi() % 1000000000)
	_refresh_summary()


## START CAMPAIGN. This is the button's own handler, callable by name so the suites drive
## the real path rather than a copy of it.
func start() -> void:
	var name := resolved_name()
	var seed_value := resolved_seed()
	DebugLogger.info("new campaign confirmed: '%s', seed %d, banner %dx%d, %d cells painted" % [
		name, seed_value, _workspace.current_banner().width, _workspace.current_banner().height,
		_workspace.painted_count(),
	], "NewCampaign")
	GameManager.new_campaign(name, seed_value, _workspace.current_banner())
	SceneManager.change_scene("world_map")


func back() -> void:
	DebugLogger.info("new campaign: back to the menu, nothing founded", "NewCampaign")
	SceneManager.change_scene("main_menu")


## Escape returns to the menu from anywhere on the screen - in _input, not
## _unhandled_input, because a focused line edit consumes ui_cancel by itself (Escape is
## how it leaves edit mode), so a player mid-typing would otherwise get no way back
## (D-168 audit).
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		back()
		get_viewport().set_input_as_handled()


func _default_company_name() -> String:
	return GameManager.config().get_string("campaign.default_campaign_name", "A New Banner")


func _refresh_summary() -> void:
	if _summary == null or _workspace == null:
		return
	var banner: BannerData = _workspace.current_banner()
	var raw_seed := _seed_input.text.strip_edges()
	var world := "random - picked when the campaign is founded"
	if not raw_seed.is_empty():
		world = "seed %s" % raw_seed if raw_seed.is_valid_int() else "words '%s' - hash %d" % [
			raw_seed, RngService.stable_hash(raw_seed)]
	_summary.text = "company   %s\nworld     %s\nbanner    %dx%d - %d of %d cells painted" % [
		resolved_name(), world, banner.width, banner.height, banner.painted_count(), banner.allowed_count(),
	]


# ---------------------------------------------------------------------------------------------
# Read-only access for the tests. They read and drive state through the screen's own
# methods, not node paths, so the layout can change around them.
# ---------------------------------------------------------------------------------------------

func company_name() -> String:
	return _name_input.text


## Type a company name, as the field would carry it. For suites.
func set_company_name(text: String) -> void:
	_name_input.text = text
	_refresh_summary()


func seed_text() -> String:
	return _seed_input.text


## Set the world-seed field, as typing would. For suites.
func set_seed_text(text: String) -> void:
	_seed_input.text = text
	_refresh_summary()


func workspace() -> BannerWorkspace:
	return _workspace


func summary_text() -> String:
	return _summary.text


## Put the caret in the company-name field. For suites: focus is exactly what makes a
## line edit swallow ui_cancel, so the Escape path cannot be tested without it.
func focus_company_name() -> void:
	_name_input.grab_focus()


func name_field_has_focus() -> bool:
	return _name_input.has_focus()
