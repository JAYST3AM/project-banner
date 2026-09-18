class_name LoadingScreen

## A loading screen that means it.
##
## The campaign's first entry builds the world: ninety settlements, their names, their trade, the
## roads between them, and the terrain field under all of it. That used to happen inside the map's
## _ready, on the main thread, so the game could not draw a single frame of those five seconds - the
## owner felt it as "a huge load spike getting into the game" and asked for a loading screen.
##
## So this is a screen, not a curtain: the build runs on a Thread while this draws, the frames keep
## coming, and the seconds counter tells the truth about how long it has been going. An indeterminate
## bar rather than a percentage, because the builder cannot say how far along it is and a progress bar
## that invents a number is worse than one that admits it does not have one.
extends CanvasLayer

const BAR_WIDTH := 420.0
const BAR_HEIGHT := 6.0

var _status: Label
var _clock: Label
var _bar: ColorRect
var _tint: ColorRect
var _started := 0.0
var _running := false


func _ready() -> void:
	layer = 100
	# Above everything, including the debug HUD, and it swallows input so a click during the build
	# cannot reach a map that has not finished existing.
	_tint = ColorRect.new()
	_tint.color = Color(0.055, 0.06, 0.07)
	_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tint.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_tint)

	var centre := VBoxContainer.new()
	centre.set_anchors_preset(Control.PRESET_CENTER)
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_theme_constant_override("separation", 14)
	add_child(centre)

	var title := Label.new()
	title.text = "The Banner"
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", Color(0.93, 0.9, 0.84))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(title)

	_status = Label.new()
	_status.text = "Generating the world"
	_status.add_theme_font_size_override("font_size", 17)
	_status.add_theme_color_override("font_color", Color(0.72, 0.7, 0.64))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(_status)

	var bar_holder := Control.new()
	bar_holder.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	centre.add_child(bar_holder)
	var trough := ColorRect.new()
	trough.color = Color(0.16, 0.17, 0.19)
	trough.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar_holder.add_child(trough)
	_bar = ColorRect.new()
	_bar.color = Color(0.85, 0.62, 0.28)
	_bar.size = Vector2(90.0, BAR_HEIGHT)
	bar_holder.add_child(_bar)

	_clock = Label.new()
	_clock.text = "0.0 s"
	_clock.add_theme_font_size_override("font_size", 13)
	_clock.add_theme_color_override("font_color", Color(0.5, 0.49, 0.46))
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(_clock)

	_started = Time.get_ticks_msec() / 1000.0
	_running = true


func _process(_delta: float) -> void:
	if not _running:
		return
	var elapsed := Time.get_ticks_msec() / 1000.0 - _started
	_clock.text = "%.1f s" % elapsed
	# A stripe crossing the trough, wrapping. It says "working", not "this much done".
	var span := BAR_WIDTH - _bar.size.x
	var travel := fmod(elapsed * 260.0, span * 2.0)
	_bar.position.x = travel if travel < span else span * 2.0 - travel


## Name what is happening. The builder cannot report progress, but it can be described.
func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


## What the build actually cost, printed where the log can see it.
func finish() -> float:
	_running = false
	var elapsed := Time.get_ticks_msec() / 1000.0 - _started
	DebugLogger.info("loading screen: %.1f s" % elapsed, "Loading")
	queue_free()
	return elapsed
