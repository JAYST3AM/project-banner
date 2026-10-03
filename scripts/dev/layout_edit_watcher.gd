class_name LayoutEditWatcher
extends Node
## Dev-only: attaches a layout editor (scripts/dev/layout_edit.gd) to whatever
## screen is current while [code]--layout-edit[/code] is on, and re-attaches
## when the screen changes, so every window in the game can be arranged by
## hand. Spawned only by main.gd behind that flag (the class is preloaded, but
## no watcher exists without the flag). The layer lives inside the screen it
## edits and dies with it, so a scene change simply builds a fresh editor.
##
## Screens with Control roots are edited directly; screens with Node2D roots
## (world map, battles) get a full-rect Control host under the scene so their
## HUD controls can be discovered and moved too.

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
	await get_tree().process_frame
	if not is_instance_valid(scene) or scene != get_tree().current_scene:
		return
	if scene is Control:
		if scene.find_child("layout_edit_layer", true, false) != null:
			return
		var layer = load("res://scripts/dev/layout_edit.gd").new()
		_attached = layer
		layer.start(scene as Control)
		return
	# Node2D-rooted screen: give the editor a full-rect Control to live in and
	# discover from, so the HUD (usually under a CanvasLayer) is reachable.
	if scene.find_child("layout_edit_host", true, false) != null:
		return
	var canvas := CanvasLayer.new()
	canvas.name = "layout_edit_host"
	canvas.layer = 100
	scene.add_child(canvas)
	var host := Control.new()
	host.name = "layout_edit_root"
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(host)
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	await get_tree().process_frame
	# A Control under a CanvasLayer does not inherit a viewport-sized rect on
	# its own; without this the layer measures 0x0 and clamps everything to zero.
	if host.size.x < 1.0 or host.size.y < 1.0:
		host.size = scene.get_viewport().get_visible_rect().size
	var layer = load("res://scripts/dev/layout_edit.gd").new()
	_attached = layer
	layer.start(scene as Node, host)


## Find a Control host for the layer: for Control screens the MarginContainer
## (or the screen itself); for Node2D screens the canvas host created above.
static func host_for(scene: Node) -> Control:
	if scene is Control:
		for child in scene.get_children():
			if child is MarginContainer:
				return child as Control
		return scene as Control
	var root := scene.find_child("layout_edit_root", true, false)
	return root as Control if root != null else null
