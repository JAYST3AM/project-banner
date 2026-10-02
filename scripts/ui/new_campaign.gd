extends Control
## The New Campaign screen (D-168): one place where a campaign is founded, wearing the
## approved mockup's composition (visual pass, 2026-10-02).
##
## This is the whole of pre-campaign setup - the company's name, the banner it marches
## under and the world it marches into - on one full-screen surface. The owner's brief was
## explicit: no popup form followed by a second window; the player stays here until they
## either go Back or press Start Campaign.
##
## The campaign does not exist until Start Campaign (the D-167 contract, kept): this screen
## collects the name, the seed and the painted banner locally, and only [method start] calls
## [method GameManager.new_campaign] and moves to the world map. Back or Escape returns to
## the menu and creates nothing.
##
## Composition, following the mockup: a titled header over the scene; a left rail of
## creation steps (Company live; the founder steps plainly locked with "(Coming Soon)" -
## tiles, not controls, so nothing pretends to exist before it does); framed COMPANY
## DETAILS and BANNER EDITOR panels in the centre, the editor hosting [BannerWorkspace];
## framed WORLD SETTINGS and CAMPAIGN PREVIEW panels on the right; and a framed action bar
## carrying Back to Main Menu and the gold-trimmed START CAMPAIGN.
##
## The layout is deliberate about the project's fixed 1280x720 UI units (canvas_items
## stretch): nothing may clip, at any window size, so the centre works to a measured budget.
##
## The read-only accessors under "for the tests" exist so a suite can drive this screen
## through the same methods its buttons drive - not a parallel test path.

const BACKGROUND_PATH := "res://assets/ui/main_menu_bg.png"

const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const DIM := Color(0.66, 0.68, 0.72)
const SMALL_SIZE := 12
const GOLD := Color(0.91, 0.81, 0.55)
const BRONZE := Color(0.48, 0.36, 0.24)
const PANEL_FILL := Color(0.085, 0.10, 0.13)
const CARD_FILL := Color(0.09, 0.105, 0.135)
const PARCHMENT := Color(0.76, 0.63, 0.38)
const PARCHMENT_EDGE := Color(0.54, 0.42, 0.22)
const PARCHMENT_TEXT := Color(0.14, 0.10, 0.05)
const LOCKED_FILL := Color(0.075, 0.085, 0.11)

## The rail's steps. `ready` is the honest switch: true means the step is on this screen
## today; false renders as a plainly locked tile. The founder creator will flip them on as
## those systems are built - nothing here is a control until it has something to control.
const SECTIONS: Array = [
	["company", "COMPANY", "Name & Banner", true],
	["founder", "FOUNDER", "(Coming Soon)", false],
	["appearance", "APPEARANCE", "(Coming Soon)", false],
	["backstory", "BACKSTORY", "(Coming Soon)", false],
	["culture", "CULTURE / RACE", "(Coming Soon)", false],
	["class", "CLASS", "(Coming Soon)", false],
	["subclass", "SUBCLASS", "(Coming Soon)", false],
	["starting", "STARTING CONDITIONS", "(Coming Soon)", false],
	["rules", "CAMPAIGN RULES", "(Coming Soon)", false],
]

var _font: Font = null
var _button_styles: Dictionary = {}
var _icon_styles: Dictionary = {}
var _start_styles: Dictionary = {}
var _workspace: BannerWorkspace = null
var _name_input: LineEdit = null
var _seed_input: LineEdit = null
var _sum_company: Label = null
var _sum_banner: Label = null
var _sum_seed: Label = null
var _sum_options: Label = null
var _preview_thumb: BannerWorkspace.BannerView = null


func _ready() -> void:
	var payload: Dictionary = SceneManager.consume_payload()
	_font = PixelStyle.pixel_font()
	_button_styles = PixelStyle.button_styles(Color(0.13, 0.15, 0.19), Color(0.38, 0.42, 0.48),
		DARK, UiTheme.ACCENT, OUTLINE)
	_icon_styles = _build_icon_styles(_button_styles)
	_start_styles = PixelStyle.button_styles(Color(0.22, 0.34, 0.20), Color(0.46, 0.60, 0.35),
		DARK, GOLD, PARCHMENT_EDGE)
	theme = PixelStyle.tooltip_theme(Color(0.13, 0.15, 0.19), UiTheme.ACCENT, UiTheme.TEXT)
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


## Icon buttons need less padding than word buttons - the base style keeps 14-pixel content
## margins, which would squeeze a 28-pixel square to nothing.
func _build_icon_styles(base: Dictionary) -> Dictionary:
	var styles := {}
	for key in base.keys():
		var style: StyleBoxTexture = (base[key] as StyleBoxTexture).duplicate()
		style.content_margin_left = 3.0
		style.content_margin_right = 3.0
		style.content_margin_top = 3.0
		style.content_margin_bottom = 3.0
		styles[key] = style
	return styles


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------

func _build() -> void:
	_build_background()

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	_build_header(column)

	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(main)
	_build_rail(main)
	_build_centre(main)
	_build_right_column(main)

	_build_actions(column)


## The valley from the main menu, held far back: atmosphere, not a second subject.
func _build_background() -> void:
	if ResourceLoader.exists(BACKGROUND_PATH):
		var picture := TextureRect.new()
		picture.set_anchors_preset(Control.PRESET_FULL_RECT)
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.texture = load(BACKGROUND_PATH)
		picture.modulate = Color(0.42, 0.40, 0.45)
		picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(picture)
	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0.035, 0.04, 0.055, 0.78)
	add_child(scrim)


func _build_header(column: VBoxContainer) -> void:
	var title_row := HBoxContainer.new()
	title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	title_row.add_theme_constant_override("separation", 14)
	column.add_child(title_row)
	title_row.add_child(PixelIcons.icon("diamond", 14, GOLD.darkened(0.2)))
	title_row.add_child(PixelStyle.pixel_label("FOUND YOUR COMPANY", 26, GOLD))
	title_row.add_child(PixelIcons.icon("diamond", 14, GOLD.darkened(0.2)))

	var subtitle := PixelStyle.body_label(
		"Create your company, design its banner, and choose the world it marches into.", 14,
		Color(0.80, 0.82, 0.86))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(subtitle)
	column.add_child(PixelStyle.rule(BRONZE.darkened(0.25)))


## A framed panel with a titled head: the one shape every block on this screen shares.
func _frame(panel: PanelContainer, title: String) -> VBoxContainer:
	var style := PixelStyle.panel_style(PANEL_FILL, BRONZE, OUTLINE)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)
	panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 7)
	title_row.add_child(PixelIcons.icon("diamond", 10, GOLD.darkened(0.15)))
	title_row.add_child(PixelStyle.pixel_label(title, 12, GOLD))
	column.add_child(title_row)
	column.add_child(PixelStyle.rule(BRONZE.darkened(0.35)))
	return column


## The creation rail: a step list where the current step is a parchment tile and the future
## steps are plainly locked. Labels, not buttons - a control that cannot do anything is a
## lie about what the game can do.
func _build_rail(parent: HBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(216.0, 0.0)
	var style := PixelStyle.panel_style(Color(0.055, 0.065, 0.09), BRONZE, OUTLINE)
	style.content_margin_left = 7.0
	style.content_margin_right = 7.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", style)
	panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	parent.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)
	for entry in SECTIONS:
		var row: Array = entry
		column.add_child(_section_tile(str(row[0]), str(row[1]), str(row[2]), bool(row[3])))


func _section_tile(id: String, label: String, sub: String, ready: bool) -> PanelContainer:
	var tile := PanelContainer.new()
	tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var style := StyleBoxFlat.new()
	style.bg_color = PARCHMENT if ready else LOCKED_FILL
	style.border_color = PARCHMENT_EDGE if ready else OUTLINE
	style.set_border_width_all(2 if ready else 1)
	style.set_corner_radius_all(0)
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	tile.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	tile.add_child(row)
	row.add_child(PixelIcons.icon(id, 24,
		Color(0.18, 0.13, 0.07) if ready else Color(0.58, 0.60, 0.63)))

	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	text.add_child(PixelStyle.pixel_label(label, 13 if ready else 12,
		PARCHMENT_TEXT if ready else Color(0.68, 0.70, 0.73)))
	text.add_child(PixelStyle.body_label(sub, 11,
		Color(0.30, 0.23, 0.11) if ready else Color(0.47, 0.49, 0.52)))
	return tile


func _build_centre(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(column)

	var details_panel := PanelContainer.new()
	column.add_child(details_panel)
	var details := _frame(details_panel, "COMPANY DETAILS")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	details.add_child(row)
	row.add_child(PixelStyle.body_label("Company Name", 14, DIM))
	_name_input = LineEdit.new()
	_name_input.custom_minimum_size = Vector2(330.0, 30.0)
	_name_input.max_length = 48
	_name_input.placeholder_text = _default_company_name()
	_dress_field(_name_input)
	_name_input.text_changed.connect(func(_text: String) -> void: _refresh_summary())
	row.add_child(_name_input)

	var editor_panel := PanelContainer.new()
	column.add_child(editor_panel)
	var editor := _frame(editor_panel, "BANNER EDITOR")
	_workspace = BannerWorkspace.new()
	_workspace.banner_changed.connect(_refresh_summary)
	editor.add_child(_workspace)


func _build_right_column(parent: HBoxContainer) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.custom_minimum_size = Vector2(316.0, 0.0)
	parent.add_child(column)

	# --- world settings -------------------------------------------------------------------
	var world_panel := PanelContainer.new()
	column.add_child(world_panel)
	var world := _frame(world_panel, "WORLD SETTINGS")
	world.add_child(PixelStyle.body_label("World Seed", 14, DIM))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	world.add_child(row)
	_seed_input = LineEdit.new()
	_seed_input.custom_minimum_size = Vector2(0.0, 30.0)
	_seed_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_input.max_length = 18
	_seed_input.placeholder_text = "random"
	_dress_field(_seed_input)
	_seed_input.text_changed.connect(func(_text: String) -> void: _refresh_summary())
	row.add_child(_seed_input)
	row.add_child(_icon_button("dice", "A fresh random seed", randomise_seed))
	var hint := PixelStyle.body_label("Leave blank for a random world, or enter a number or word seed.",
		SMALL_SIZE, DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	world.add_child(hint)
	var randomise := Button.new()
	randomise.text = "Randomise Seed"
	randomise.icon = PixelIcons.texture("dice", UiTheme.TEXT)
	randomise.expand_icon = true
	PixelStyle.dress_button(randomise, _button_styles, _font, 13, UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	randomise.custom_minimum_size = Vector2(0.0, 32.0)
	randomise.pressed.connect(randomise_seed)
	world.add_child(randomise)

	# --- campaign preview -----------------------------------------------------------------
	var preview_panel := PanelContainer.new()
	column.add_child(preview_panel)
	var preview := _frame(preview_panel, "CAMPAIGN PREVIEW")
	_sum_company = PixelStyle.pixel_label("", 12, UiTheme.TEXT)
	preview.add_child(PixelStyle.stat_row("Company Name", _sum_company, 13, DIM))

	var banner_row := HBoxContainer.new()
	banner_row.add_theme_constant_override("separation", 8)
	preview.add_child(banner_row)
	banner_row.add_child(PixelStyle.body_label("Banner", 13, DIM))
	var sponge := Control.new()
	sponge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	banner_row.add_child(sponge)
	var thumb_frame := PanelContainer.new()
	thumb_frame.add_theme_stylebox_override("panel", _thumb_style())
	banner_row.add_child(thumb_frame)
	_preview_thumb = BannerWorkspace.BannerView.new()
	_preview_thumb.view_scale = 0.34
	_preview_thumb.custom_minimum_size = Vector2(28.0, 34.0)
	_preview_thumb.banner = null
	thumb_frame.add_child(_preview_thumb)
	_sum_banner = PixelStyle.pixel_label("", 12, UiTheme.TEXT)
	_sum_banner.tooltip_text = "The company's own banner, painted in the editor"
	banner_row.add_child(_sum_banner)

	_sum_seed = PixelStyle.pixel_label("", 12, UiTheme.TEXT)
	preview.add_child(PixelStyle.stat_row("World Seed", _sum_seed, 13, DIM))
	var options_row := HBoxContainer.new()
	options_row.add_theme_constant_override("separation", 6)
	preview.add_child(options_row)
	var options_label := PixelStyle.body_label("Additional Options", 13, DIM)
	options_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	options_row.add_child(options_label)
	options_row.add_child(PixelIcons.icon("rules", 14, Color(0.52, 0.54, 0.57)))
	_sum_options = PixelStyle.pixel_label("Default Settings", 12, Color(0.52, 0.54, 0.57))
	options_row.add_child(_sum_options)


func _thumb_style() -> StyleBoxTexture:
	var style := PixelStyle.panel_style(Color(0.06, 0.07, 0.095), LIGHT_EDGE(), OUTLINE)
	style.content_margin_left = 2.0
	style.content_margin_right = 2.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	return style


func LIGHT_EDGE() -> Color:
	return Color(0.24, 0.27, 0.32)


func _build_actions(column: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	var style := PixelStyle.panel_style(Color(0.055, 0.065, 0.09), BRONZE, OUTLINE)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override("panel", style)
	panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	column.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var back_button := Button.new()
	back_button.text = "Back to Main Menu"
	back_button.icon = PixelIcons.texture("arrow_left", UiTheme.TEXT)
	back_button.expand_icon = true
	PixelStyle.dress_button(back_button, _button_styles, _font, 13, UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	back_button.custom_minimum_size = Vector2(230.0, 38.0)
	back_button.pressed.connect(back)
	row.add_child(back_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var start_button := Button.new()
	start_button.text = "START CAMPAIGN"
	start_button.icon = PixelIcons.texture("class", GOLD)
	start_button.expand_icon = true
	PixelStyle.dress_button(start_button, _start_styles, _font, 16, Color(0.97, 0.93, 0.78),
		Color(0.55, 0.58, 0.52))
	start_button.custom_minimum_size = Vector2(300.0, 44.0)
	start_button.pressed.connect(start)
	row.add_child(start_button)


func _icon_button(icon_name: String, tooltip: String, handler: Callable) -> Button:
	var button := Button.new()
	PixelStyle.dress_button(button, _icon_styles, _font, 11, UiTheme.TEXT, Color(0.45, 0.47, 0.51))
	button.icon = PixelIcons.texture(icon_name, UiTheme.TEXT)
	button.expand_icon = true
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(30.0, 30.0)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	return button


func _dress_field(field: LineEdit) -> void:
	field.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	field.add_theme_stylebox_override("normal",
		PixelStyle.panel_style(Color(0.10, 0.12, 0.15), Color(0.28, 0.31, 0.37), OUTLINE))
	field.add_theme_stylebox_override("focus",
		PixelStyle.panel_style(Color(0.13, 0.15, 0.19), GOLD.darkened(0.15), GOLD.darkened(0.3)))
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
	if _workspace == null or _sum_company == null:
		return
	var banner: BannerData = _workspace.current_banner()
	_sum_company.text = resolved_name()
	_sum_seed.text = _seed_input.text.strip_edges() if not _seed_input.text.strip_edges().is_empty() else "random"
	_sum_banner.text = "Custom Banner" if banner.painted_count() > 0 else "Blank"
	_preview_thumb.banner = banner
	_preview_thumb.queue_redraw()


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
	return "%s / %s / %s" % [_sum_company.text, _sum_seed.text, _sum_banner.text]


## Put the caret in the company-name field. For suites: focus is exactly what makes a
## line edit swallow ui_cancel, so the Escape path cannot be tested without it.
func focus_company_name() -> void:
	_name_input.grab_focus()


func name_field_has_focus() -> bool:
	return _name_input.has_focus()
