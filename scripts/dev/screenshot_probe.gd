extends Node
## Dev-only: save one PNG of the game's own window once the scene has arrived, then optionally
## quit (D-137 follow-up).
##
## This lives on the tree root rather than on the boot scene, because the boot scene is replaced
## the moment a campaign or the menu starts - and a coroutine dies with the node that owns it, so
## a probe parented to the boot scene would wait forever on a timer nobody is left to hear.
##
## The capture comes from the viewport texture: the game's own pixels, no matter what window is on
## top of it. Desktop screen grabs behind a focus-stealing Windows session made verification
## screenshots a coin flip; this does not care.
##
## Flags: "--screenshot=<path>", "--screenshot-delay=<ms>", "--screenshot-quit" (see DevFlags).


func _ready() -> void:
	var path := DevFlags.screenshot_path()
	if path.is_empty():
		return
	await get_tree().create_timer(DevFlags.screenshot_delay_ms() / 1000.0).timeout
	# One more drawn frame, so the shot holds a complete frame and not a half-built one.
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		DebugLogger.info("dev flag: window saved to %s" % path, "Screenshot")
	else:
		DebugLogger.warn("dev flag: window save failed (%d) for %s" % [error, path], "Screenshot")
	if DevFlags.screenshot_quit():
		get_tree().quit()
