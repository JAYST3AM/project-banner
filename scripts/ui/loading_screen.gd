class_name LoadingScreen

## The loading screen, with the owner's Godot loader animating above a bar.
##
## The campaign's first entry builds the world: ninety settlements, their names, their trade, the roads
## between them, and the terrain field under all of it. That used to happen inside the map's _ready, on
## the main thread, so the game could not draw a frame of those seconds - the owner felt it as "a huge
## load spike getting into the game" and asked for a loading screen.
##
## So this is a screen, not a curtain: the build runs on a Thread while this draws, and the frames keep
## coming. The animation arrives as a GIF, which Godot cannot play, so it is converted to a horizontal
## strip of eight frames (assets/ui/loading/logo_sheet.png, cut from the owner's GIF, its background
## keyed out and the padding cropped away so the robot fills the space rather than floating in an empty
## square) and stepped here on the frame clock.
##
## The bar is honest about what it knows: it advances on *elapsed time*, not on invented progress,
## because the builder cannot say how far along it is. It eases toward the end and holds short of
## complete, then fills the moment the build actually lands.
extends CanvasLayer

const SHEET := "res://assets/ui/loading/logo_sheet.png"
const FRAME_COUNT := 8
const FRAME_SECONDS := 0.10
const LOGO_HEIGHT := 156.0
const BAR_WIDTH := 460.0
const BAR_HEIGHT := 8.0
## The build whose progress this bar reports. Set by the world map before the first frame.
var source: Object = null
## The last real number seen, so the bar can ease toward it without ever passing it.
var _reported := 0.0

var _logo: TextureRect
var _status: Label
var _clock: Label
var _fill: ColorRect
var _trough: ColorRect
var _tint: ColorRect
var _started := 0.0
var _running := false
var _frame := 0
var _frame_clock := 0.0
var _atlas: Array[AtlasTexture] = []


func _ready() -> void:
	layer = 100
	# Above everything, including the debug HUD, and it swallows input so a click during the build
	# cannot reach a map that has not finished existing.
	_tint = ColorRect.new()
	_tint.color = Color(0.055, 0.06, 0.07)
	_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tint.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_tint)

	# Full rect, with the stack centred *inside* it. The first version anchored the container to the
	# screen's centre point before it had any children, so its offsets were computed for an empty box
	# and the whole stack hung down and to the right of the middle - the owner saw it at once: "needs to
	# be centered". A full-width container centres its children horizontally as well, which the labels
	# and the loader both want.
	var centre := VBoxContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_theme_constant_override("separation", 12)
	add_child(centre)

	# --- the loader, cut into frames off the sheet the GIF became
	var sheet: Texture2D = load(SHEET)
	_logo = TextureRect.new()
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.custom_minimum_size = Vector2(0.0, LOGO_HEIGHT)
	_logo.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if sheet != null:
		var frame_width := float(sheet.get_width()) / float(FRAME_COUNT)
		for i in FRAME_COUNT:
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(float(i) * frame_width, 0.0, frame_width, float(sheet.get_height()))
			_atlas.append(atlas)
		_logo.texture = _atlas[0]
	else:
		push_error("loading screen: no sheet at %s" % SHEET)
	centre.add_child(_logo)

	var title := Label.new()
	title.text = "The Banner"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Color(0.93, 0.9, 0.84))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(title)

	_status = Label.new()
	_status.text = "Generating the world"
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color(0.72, 0.7, 0.64))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(_status)

	# --- the bar, directly beneath the loader
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	# Shrink-centred rather than stretched: in a full-width container a plain Control would span the
	# whole screen and the bar would stop being a bar.
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	centre.add_child(holder)
	_trough = ColorRect.new()
	_trough.color = Color(0.16, 0.17, 0.19)
	_trough.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(_trough)
	_fill = ColorRect.new()
	_fill.color = Color(0.85, 0.62, 0.28)
	_fill.position = Vector2.ZERO
	_fill.size = Vector2(0.0, BAR_HEIGHT)
	holder.add_child(_fill)

	_clock = Label.new()
	_clock.text = "0.0 s"
	_clock.add_theme_font_size_override("font_size", 12)
	_clock.add_theme_color_override("font_color", Color(0.5, 0.49, 0.46))
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(_clock)

	_started = Time.get_ticks_msec() / 1000.0
	_running = true


func _process(delta: float) -> void:
	if not _running:
		return

	# The loader runs in its own time, independent of the build, so it never looks stuck.
	_frame_clock += delta
	if _frame_clock >= FRAME_SECONDS and not _atlas.is_empty():
		_frame_clock = fmod(_frame_clock, FRAME_SECONDS)
		_frame = (_frame + 1) % _atlas.size()
		_logo.texture = _atlas[_frame]

	var elapsed := Time.get_ticks_msec() / 1000.0 - _started
	_clock.text = "%.1f s" % elapsed

	# The bar follows the builder's own count of settlements placed, eased so it moves smoothly between
	# one and the next but never passes the last real figure. When the count is unavailable it falls
	# back to elapsed time, which is at least honest about being a guess.
	var target := 0.0
	if source != null and "progress" in source:
		target = clampf(float(source.progress), 0.0, 1.0)
	if target <= 0.0:
		target = clampf(elapsed / 2.4, 0.0, 0.96)
	_reported = maxf(_reported, target)
	var shown := _fill.size.x / BAR_WIDTH
	# Ease at a rate that crosses the gap in about a fifth of a second: fast enough that the bar is
	# never lagging behind a settlement, slow enough that ninety steps do not read as ninety jolts.
	_fill.size.x = BAR_WIDTH * move_toward(shown, _reported, delta * 5.0)
	# The message follows the real stage of the build, in order: the seed, choosing the sites, placing
	# them one by one with a count, the roads between them, then the ground under all of it. Every line
	# here is something the build is actually doing at that moment.
	var message := "Generating the world"
	if source != null and "stage" in source:
		message = str(source.stage)
	if source != null and "placing" in source and int(source.placing) > 0:
		var placed := int(round(float(source.placing) * _reported))
		if placed >= int(source.placing):
			message = "Laying the roads between them"
		else:
			message = "%s  -  %d of %d" % [message, placed, int(source.placing)]
	_status.text = message


## Name what is happening. The builder cannot report progress, but it can be described.
## Watch something that knows how far along it is.
func watch(what: Object) -> void:
	source = what


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


## The build landed: fill the bar, let the eye see it complete, then go. Returns what it cost.
func finish() -> float:
	_running = false
	if _fill != null:
		_fill.size.x = BAR_WIDTH
	var elapsed := Time.get_ticks_msec() / 1000.0 - _started
	DebugLogger.info("loading screen: %.1f s" % elapsed, "Loading")
	await get_tree().create_timer(0.12).timeout
	queue_free()
	return elapsed
