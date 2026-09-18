extends Node2D
## The terrain lab: a battlefield on screen, with every channel it carries visible.
##
## A windowed development scene, not a game scene. It exists so that "the ground is wrong" can be
## answered by looking at the data rather than by arguing about it: the field is drawn, the debug
## overlay steps through every channel, and the readout names the seed, the signature and the mix so
## that the picture and the numbers are always the same run.
##
##   godot --path "<project>" res://scenes/dev/terrain_lab.tscn -- --seed=70701 --biome=plains
##
## Flags:
##   --seed=N            the battlefield to grow
##   --biome=ID          which country (see data/terrain/biomes.json)
##   --field=WxH         the field's size in world units
##   --overlay=NAME      start on a channel (see TerrainOverlay.MODE_NAMES)
##   --props=0           grow no props
##   --shot=PATH         save a picture after a few frames and quit - how a change is verified
##   --frames=N          how many frames to wait before the shot (default 4)
##
## Typing a seed and pressing Generate is the whole point of the seed box: the same number must give
## the same battlefield every time.

const DEFAULT_FIELD := Vector2(100.0, 60.0)

var terrain: BattlefieldTerrain = null
var overlay_mode: int = TerrainOverlay.Mode.OFF
var show_props: bool = true

var _seed_value: int = 70701
var _biome_id: String = ""
var _field_size: Vector2 = DEFAULT_FIELD
var _zoom: float = 8.0
var _shot_path: String = ""
var _shot_frames: int = 4

var _ground: ImageTexture = null
var _overlay: ImageTexture = null
var _ground_key: String = ""
var _overlay_key: String = ""
var _frames: int = 0
var _art_ground: TerrainGround = null

var _seed_edit: LineEdit = null
var _readout: Label = null
var _legend: Label = null
var _biome_pick: OptionButton = null
var _mode_pick: OptionButton = null


func _ready() -> void:
	_parse_flags()
	_build_ui()
	# The world sits below the panel rather than under it: the panel is wide, and a battlefield half
	# hidden behind a debug readout is a picture nobody can judge.
	position = Vector2(20.0, 210.0)
	_generate()
	if not _shot_path.is_empty():
		set_process(true)


func _process(_delta: float) -> void:
	if _shot_path.is_empty():
		return
	_frames += 1
	if _frames < _shot_frames:
		return
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(_shot_path)
	if error == OK:
		print("terrain lab: wrote %s (%dx%d)" % [_shot_path, image.get_width(), image.get_height()])
	else:
		print("terrain lab: could not write %s (error %d)" % [_shot_path, error])
	get_tree().quit(0 if error == OK else 1)


func _parse_flags() -> void:
	for raw in OS.get_cmdline_user_args():
		var argument := str(raw)
		if argument.begins_with("--seed="):
			_seed_value = int(argument.trim_prefix("--seed="))
		elif argument.begins_with("--biome="):
			_biome_id = argument.trim_prefix("--biome=")
		elif argument.begins_with("--field="):
			var parts := argument.trim_prefix("--field=").split("x")
			if parts.size() == 2:
				_field_size = Vector2(float(parts[0]), float(parts[1]))
		elif argument.begins_with("--overlay="):
			overlay_mode = TerrainOverlay.mode_from_name(argument.trim_prefix("--overlay="))
		elif argument.begins_with("--props="):
			show_props = argument.trim_prefix("--props=") != "0"
		elif argument.begins_with("--shot="):
			_shot_path = argument.trim_prefix("--shot=")
		elif argument.begins_with("--frames="):
			_shot_frames = maxi(1, int(argument.trim_prefix("--frames=")))
		elif argument.begins_with("--zoom="):
			_zoom = maxf(0.5, float(argument.trim_prefix("--zoom=")))


## ---------- the field ------------------------------------------------------

func _generate() -> void:
	var config := GameManager.config()
	terrain = BattlefieldTerrain.generate(_seed_value, _field_size, config, null, null, _biome_id)
	if show_props:
		terrain.build_props(config, null)
	else:
		terrain.props = null
	scale = Vector2(_zoom, _zoom)
	_ground = null
	_overlay = null
	_ground_key = ""
	_overlay_key = ""
	_sync_art_ground()
	refresh_readout()
	queue_redraw()


func refresh_readout() -> void:
	if _readout == null or terrain == null:
		return
	var types := terrain.counts_by_type()
	var prop_line := "props: none"
	if terrain.props != null:
		prop_line = "props: %d %s" % [terrain.props.count(), str(terrain.props.counts_by_kind())]
	_readout.text = "seed %d   %s   %dx%d cells   signature %s\n%s\n%s\n%s" % [
		terrain.terrain_seed, terrain.biome_id, terrain.cols, terrain.rows, terrain.signature(),
		str(types), prop_line,
		"overlay: %s" % TerrainOverlay.label(overlay_mode),
	]
	if _legend != null:
		_legend.text = TerrainOverlay.legend(terrain, overlay_mode)


## ---------- drawing --------------------------------------------------------

func _draw() -> void:
	if terrain == null:
		return
	if not (_art_ground != null and _art_ground.visible):
		_draw_ground()
	_draw_overlay()
	_draw_props()


## The ground as the game draws it when the biome has art: one shader over the field's own maps.
## Returns false when there is nothing to draw that way, which is how the flat bake stays the
## fallback rather than becoming dead code.
##
## The node is created when the field is generated rather than here: adding a child while a canvas
## item is drawing is a tree change in the middle of a draw pass, which Godot refuses.
func _sync_art_ground() -> void:
	if _art_ground == null:
		_art_ground = TerrainGround.new()
		_art_ground.name = "ArtGround"
		_art_ground.z_index = -10
		add_child(_art_ground)
	_art_ground.show_field(terrain, null, GameManager.config())


## The ground as the game draws it when there is no art: one pixel per cell, in the cell's own
## variant colour, shaded by its height. The lab deliberately draws the *data's* colours here rather
## than the art, because the point of the lab is to see what the field says.
func _draw_ground() -> void:
	var key := "%s:%s" % [terrain.signature(), str(show_props)]
	if _ground == null or _ground_key != key:
		var image := Image.create_empty(maxi(1, terrain.cols), maxi(1, terrain.rows), false, Image.FORMAT_RGBA8)
		var biomes := BiomeCatalog.load_from()
		var lowest := terrain.min_height()
		var span := maxf(0.001, terrain.max_height() - lowest)
		for row in terrain.rows:
			for col in terrain.cols:
				var index := row * terrain.cols + col
				var colour := biomes.variant_colour(terrain.biome_id, terrain.variant_of_cell(index))
				# A little relief so the landforms read, and a hard darkening for anything impassable:
				# the first thing anyone asks of a battlefield picture is where the men can walk.
				var relief := (terrain.height_of_cell(index) - lowest) / span
				colour = colour.lightened((relief - 0.5) * 0.35) if relief > 0.5 else colour.darkened((0.5 - relief) * 0.35)
				if not terrain.is_cell_traversable(index):
					colour = colour.darkened(0.45)
				image.set_pixel(col, row, colour)
		_ground = ImageTexture.create_from_image(image)
		_ground_key = key
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	draw_texture_rect(_ground, Rect2(Vector2.ZERO, terrain.size), false)


func _draw_overlay() -> void:
	if overlay_mode == TerrainOverlay.Mode.OFF:
		return
	var key := "%s:%d" % [terrain.signature(), overlay_mode]
	if _overlay == null or _overlay_key != key:
		var image := TerrainOverlay.bake(terrain, overlay_mode)
		if image == null:
			return
		_overlay = ImageTexture.create_from_image(image)
		_overlay_key = key
	draw_texture_rect(_overlay, Rect2(Vector2.ZERO, terrain.size), false)


## Props are sub-cell objects, so they are drawn as marks rather than as pixels: a circle the size of
## the thing, filled when it obstructs movement.
func _draw_props() -> void:
	if terrain == null or terrain.props == null:
		return
	for index in terrain.props.count():
		var point := terrain.props.position_at(index)
		var radius := maxf(0.5, terrain.props.radius_at(index))
		var colour := Color("ff8a3c")
		if terrain.props.blocks_at(index):
			colour = Color("e04a2c")
			draw_circle(point, radius, colour)
		else:
			draw_circle(point, radius, colour, false, 0.5)


## ---------- the panel ------------------------------------------------------

## Built in code rather than in the scene: it is a tool, it changes as the tool changes, and a scene
## file full of layout is harder to read than a dozen lines that say what the panel does.
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Panel"
	add_child(layer)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 8.0
	panel.offset_top = 8.0
	panel.offset_right = 560.0
	panel.custom_minimum_size = Vector2(552.0, 0.0)
	layer.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)

	var title := Label.new()
	title.text = "Terrain lab - %s" % Time.get_datetime_string_from_system()
	title.add_theme_color_override("font_color", Color("ffd166"))
	column.add_child(title)

	# Seed and biome: the two things a person changes by hand.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)

	var seed_label := Label.new()
	seed_label.text = "seed"
	row.add_child(seed_label)
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(_seed_value)
	_seed_edit.custom_minimum_size = Vector2(120.0, 0.0)
	row.add_child(_seed_edit)

	var biome_label := Label.new()
	biome_label.text = "biome"
	row.add_child(biome_label)
	_biome_pick = OptionButton.new()
	var biomes := BiomeCatalog.load_from()
	for id in biomes.order:
		_biome_pick.add_item("%s (%s)" % [biomes.display_name(id), id])
		if id == terrain_biome_or_default(biomes):
			_biome_pick.select(_biome_pick.item_count - 1)
	row.add_child(_biome_pick)

	var apply := Button.new()
	apply.text = "Generate"
	apply.pressed.connect(_on_generate_pressed)
	row.add_child(apply)

	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	column.add_child(modes)
	var mode_label := Label.new()
	mode_label.text = "show"
	modes.add_child(mode_label)
	_mode_pick = OptionButton.new()
	for index in TerrainOverlay.mode_count():
		_mode_pick.add_item(TerrainOverlay.label(index))
	_mode_pick.select(overlay_mode)
	_mode_pick.item_selected.connect(_on_mode_selected)
	modes.add_child(_mode_pick)
	var props_box := CheckBox.new()
	props_box.text = "props"
	props_box.button_pressed = show_props
	props_box.toggled.connect(_on_props_toggled)
	modes.add_child(props_box)

	var hint := Label.new()
	hint.text = "[Tab] next channel   [Enter] regenerate from the seed box   [R] a new seed"
	hint.add_theme_color_override("font_color", Color("93a0ad"))
	column.add_child(hint)

	_legend = Label.new()
	_legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_legend.custom_minimum_size = Vector2(540.0, 0.0)
	column.add_child(_legend)

	_readout = Label.new()
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.custom_minimum_size = Vector2(540.0, 0.0)
	column.add_child(_readout)


## The biome the picker should open on: whatever the field was asked for, or the project's default.
func terrain_biome_or_default(biomes: BiomeCatalog) -> String:
	return biomes.resolve_id(_biome_id)


func _on_generate_pressed() -> void:
	_apply_seed_box()
	_apply_biome_pick()


func _apply_seed_box() -> void:
	if _seed_edit == null:
		return
	var text := _seed_edit.text.strip_edges()
	if text.is_valid_int():
		_seed_value = text.to_int()
	_generate()


func _apply_biome_pick() -> void:
	if _biome_pick == null:
		return
	var biomes := BiomeCatalog.load_from()
	if _biome_pick.selected >= 0 and _biome_pick.selected < biomes.order.size():
		_biome_id = biomes.order[_biome_pick.selected]
	_generate()


func _on_mode_selected(index: int) -> void:
	overlay_mode = index
	refresh_readout()
	queue_redraw()


func _on_props_toggled(pressed: bool) -> void:
	show_props = pressed
	_generate()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_TAB:
				overlay_mode = TerrainOverlay.next_mode(overlay_mode)
				if _mode_pick != null:
					_mode_pick.select(overlay_mode)
				refresh_readout()
				queue_redraw()
			KEY_ENTER, KEY_KP_ENTER:
				_apply_seed_box()
			KEY_R:
				_seed_value = randi() % 99999
				if _seed_edit != null:
					_seed_edit.text = str(_seed_value)
				_generate()
			KEY_ESCAPE:
				get_tree().quit(0)
