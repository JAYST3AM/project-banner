extends Node2D
## Boot scene for Project Banner.
##
## Step 0 (development environment): this scene proves the toolchain works
## end-to-end. From Step 1 onward it hands control straight to the main menu.

const TITLE := "PROJECT BANNER"
const SUBTITLE := "Development Environment Operational"

@onready var _title: Label = $UI/Title
@onready var _subtitle: Label = $UI/Subtitle


func _ready() -> void:
	_title.text = TITLE
	_subtitle.text = SUBTITLE
	# Printed so headless runs can assert the scene actually executed.
	print("[Main] %s - %s" % [TITLE, SUBTITLE])
	print("[Main] Godot %s | engine build: %s" % [
		Engine.get_version_info().get("string", "unknown"),
		Engine.get_version_info().get("build", "unknown"),
	])
	print("[Main] Project Banner v%s | renderer: %s" % [
		ProjectSettings.get_setting("application/config/version", "0.0.0"),
		ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),
	])
