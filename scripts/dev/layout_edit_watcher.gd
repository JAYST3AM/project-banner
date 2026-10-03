class_name LayoutEditWatcher
extends Node
## Dev-only: attaches a layout editor (scripts/dev/layout_edit.gd) to whatever
## screen is current while [code]--layout-edit[/code] is on, and re-attaches
## when the screen changes, so every window in the game can be arranged by
## hand. Spawned only by main.gd behind that flag; without it this file never
## loads. The layer lives inside the screen it edits and dies with it, so a
## scene change simply builds a fresh editor for the new window.

var _scene: Node = null
var _attached: Node = null


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	if _attached != null and not is_instance_valid(_attached):
		_attached = null
		_scene = null
	if scene == _scene:
		return
	_scene = scene
	_attached = null
	_attach(scene)


func _attach(scene: Node) -> void:
	if not (scene is Control):
		return
	await get_tree().process_frame
	if not is_instance_valid(scene) or scene != get_tree().current_scene:
		return
	var layer = load("res://scripts/dev/layout_edit.gd").new()
	_attached = layer
	layer.start(scene as Control)
