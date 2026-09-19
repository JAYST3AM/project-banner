class_name DeviceReport
extends RefCounted
## What machine is actually running this build.
##
## [b]Why this exists.[/b] A benchmark that does not say which device drew the frame is not a
## measurement: a build that has silently fallen back to a software rasteriser produces numbers
## that look like a slow GPU and are really a fast CPU. This prints the renderer, the device, the
## vendor, the device class, the resolution, the sync state and the clock for every run, and
## shouts if the device is not real hardware.
##
## Every lookup is guarded: a build that does not expose one of these prints a dash rather than
## failing to load, because a diagnostics helper that can break the game is worse than none.

## Adapter names that mean "no GPU is drawing this".
const SOFTWARE_MARKERS := [
	"llvmpipe", "lavapipe", "swiftshader", "softpipe", "software", "microsoft basic render"]


## One block of text, ready to print or to put in a file.
static func report() -> String:
	var lines := PackedStringArray()
	var adapter := _string(RenderingServer, "get_video_adapter_name")
	var vendor := _string(RenderingServer, "get_video_adapter_vendor")
	var api := _string(RenderingServer, "get_video_adapter_api_version")
	var driver_method := _string(RenderingServer, "get_current_rendering_method")
	var driver_name := _string(RenderingServer, "get_current_rendering_driver_name")
	var device_type := _string(RenderingServer, "get_video_adapter_type")
	var window := DisplayServer.window_get_size()
	var screen := DisplayServer.screen_get_size()
	var memory := OS.get_memory_info()
	lines.append("device:        %s  (%s)" % [adapter, vendor])
	lines.append("device class:  %s" % device_type)
	lines.append("driver:        %s / %s  api %s  server %s" % [
		driver_method, driver_name, api, DisplayServer.get_name()])
	lines.append("rendering:     method %s  vsync %s  fps cap %s  debug %s" % [
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")),
		_vsync_name(DisplayServer.window_get_vsync_mode()),
		str(Engine.max_fps), str(OS.is_debug_build())])
	lines.append("display:       window %dx%d  screen %dx%d" % [window.x, window.y, screen.x, screen.y])
	lines.append("host:          %s  (%d threads)  ram %d MiB free of %d MiB" % [
		OS.get_processor_name(), OS.get_processor_count(),
		int(memory.get("free", 0)) / 1048576, int(memory.get("physical", 0)) / 1048576])
	lines.append("os:            %s" % OS.get_version())
	var lower := adapter.to_lower()
	var software := false
	for marker in SOFTWARE_MARKERS:
		if lower.contains(marker):
			software = true
	if software:
		lines.append("*** WARNING: THIS IS NOT A GPU. %s is a software rasteriser, so every frame"
			% adapter)
		lines.append("*** and every time in this run describes the CPU drawing pixels. Do not")
		lines.append("*** record these numbers as GPU performance.")
	return "\n".join(lines)


## Whether the device drawing the frames is real hardware.
static func is_hardware() -> bool:
	var lower := _string(RenderingServer, "get_video_adapter_name").to_lower()
	for marker in SOFTWARE_MARKERS:
		if lower.contains(marker):
			return false
	return true


static func summary() -> String:
	return "%s (%s)" % [
		_string(RenderingServer, "get_video_adapter_name"),
		_string(RenderingServer, "get_video_adapter_type")]


## One line for the session log: what machine, what driver, what window, what screen. Every
## performance conversation starts with facts, and the facts cost one line.
static func one_line() -> String:
	var window := DisplayServer.window_get_size()
	var hz := DisplayServer.screen_get_refresh_rate()
	var sync := "on" if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED else "off"
	return "%s | %s | window %dx%d | vsync %s%s | %s" % [
		summary(),
		_string(RenderingServer, "get_current_rendering_driver_name"),
		window.x, window.y,
		sync,
		"" if hz <= 0.0 else "  %.0f Hz screen" % hz,
		OS.get_processor_name(),
	]


static func _string(object: Object, method: String) -> String:
	if object == null or not object.has_method(method):
		return "-"
	var value: Variant = object.call(method)
	if value == null:
		return "-"
	return str(value)


static func _vsync_name(mode: DisplayServer.VSyncMode) -> String:
	match mode:
		DisplayServer.VSYNC_ENABLED:
			return "on"
		DisplayServer.VSYNC_DISABLED:
			return "off"
		DisplayServer.VSYNC_ADAPTIVE:
			return "adaptive"
		DisplayServer.VSYNC_MAILBOX:
			return "mailbox"
	return "mode %d" % mode
