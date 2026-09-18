extends Node
## SceneManager (autoload).
##
## Owns every scene transition. Scenes never call [method SceneTree.change_scene_to_file]
## themselves, and they never read "who am I returning to" out of a global - the
## caller passes a payload and the incoming scene consumes it exactly once.
##
## [codeblock]
## SceneManager.change_scene("battle", {"context": ctx})
## # inside battle.gd _ready():
## var ctx = SceneManager.consume_payload().get("context")
## [/codeblock]

signal scene_changed(key: String, instance: Node)
signal scene_change_started(key: String)

const SCENES := {
	"main": "res://scenes/core/main.tscn",
	"main_menu": "res://scenes/ui/main_menu.tscn",
	"world_map": "res://scenes/world/world_map.tscn",
	"settlement": "res://scenes/settlements/settlement.tscn",
	"battle": "res://scenes/battle/battle_field.tscn",
	"battle_results": "res://scenes/battle/battle_results.tscn",
}

var current_key: String = ""
var current_scene: Node = null
var last_key: String = ""

## The scene this manager created itself. Only this node is ever freed on a
## transition - a scene that Godot loaded directly (the boot scene, or the test
## harness) is "protected" and stays alive even while other scenes come and go,
## which is what lets the headless test runner drive real transitions.
var _managed_scene: Node = null

var _pending_key: String = ""
var _pending_payload: Dictionary = {}
var _scheduled: bool = false
var _payload: Dictionary = {}
var _has_payload: bool = false


func has_scene(key: String) -> bool:
	return SCENES.has(key)


func path_for(key: String) -> String:
	return str(SCENES.get(key, ""))


## Queue a transition. Applied at the end of the current frame so it is always
## safe to call from a button signal (the emitting node is still alive).
func change_scene(key: String, payload: Dictionary = {}) -> void:
	if not has_scene(key):
		DebugLogger.error("unknown scene key '%s'" % key, "SceneManager")
		return
	_pending_key = key
	_pending_payload = payload
	scene_change_started.emit(key)
	if not _scheduled:
		_scheduled = true
		_apply_change.call_deferred()


func reload_current() -> void:
	if not current_key.is_empty():
		change_scene(current_key, _payload.duplicate(true))


## The payload handed to the scene that is currently loading, consumed once.
func consume_payload(default_value: Dictionary = {}) -> Dictionary:
	if not _has_payload:
		return default_value
	_has_payload = false
	return _payload


func peek_payload() -> Dictionary:
	return _payload


func _apply_change() -> void:
	# A scene may be started without going through the manager (tests do this).
	_scheduled = false
	if _pending_key.is_empty():
		return
	var key := _pending_key
	var payload := _pending_payload
	_pending_key = ""
	_pending_payload = {}

	var scene_path := path_for(key)
	var packed: PackedScene = load(scene_path)
	if packed == null:
		DebugLogger.error("failed to load scene '%s' (%s)" % [key, scene_path], "SceneManager")
		return

	var instance := packed.instantiate()
	# The scene being replaced: the one this manager made, or - when the game was started straight
	# into a scene, which is how every dev scene and a screen being photographed is run - whatever the
	# tree is showing. Without the second half, a directly-started scene is never freed: the menu the
	# owner was looking at stayed up over the world map it had just opened, because nothing had ever
	# claimed it.
	var previous := _managed_scene
	if previous == null:
		previous = get_tree().current_scene

	_payload = payload
	_has_payload = true

	get_tree().root.add_child(instance)

	last_key = current_key
	current_key = key
	current_scene = instance
	_managed_scene = instance
	get_tree().current_scene = instance

	if previous != null and previous != instance and not previous.is_queued_for_deletion():
		previous.queue_free()

	DebugLogger.info("scene -> %s" % key, "SceneManager")
	scene_changed.emit(key, instance)


## Adopts the scene that Godot loaded from the command line / project settings,
## so [member current_scene] is correct even for the very first scene. Only
## scenes this manager knows about become "managed" (and therefore freeable).
func adopt_initial_scene() -> void:
	var scene := get_tree().current_scene
	current_scene = scene
	if scene == null:
		return
	var path := scene.scene_file_path
	for key in SCENES.keys():
		if str(SCENES[key]) == path:
			current_key = key
			_managed_scene = scene
			return
	current_key = path


## Test helper: run a transition and wait until that exact scene is in the tree.
func change_scene_and_wait(key: String, payload: Dictionary = {}) -> Node:
	change_scene(key, payload)
	while true:
		var result: Array = await scene_changed
		if str(result[0]) == key:
			return result[1] as Node
	return null


## Test helper: wait for a transition that has [b]already been requested[/b], without
## requesting one. Returns the instantiated scene, or null if it never arrives.
##
## This exists because calling [method change_scene_and_wait] on a scene the code
## under test already transitions to starts a [i]second[/i] transition. That second
## transition carries no payload, so it silently overwrites the first one and the
## scene ends up empty - the test then confirms the scene exists while proving
## nothing about what actually reached it. Waiting is not the same as causing.
##
## Safe to call either before or after the transition lands.
func await_scene(key: String, max_frames: int = 900) -> Node:
	if current_key == key and is_instance_valid(current_scene):
		return current_scene
	var frames := 0
	while frames < max_frames:
		frames += 1
		await get_tree().process_frame
		if current_key == key and is_instance_valid(current_scene):
			return current_scene
	DebugLogger.error("await_scene('%s') timed out after %d frames" % [key, max_frames], "SceneManager")
	return null
