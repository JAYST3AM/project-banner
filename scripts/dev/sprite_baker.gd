extends Node2D
## Bakes a 3D character into 2D sprite sheets: one pass per facing direction, one capture per frame.
##
## The point of baking rather than drawing: eight directions of a 3D model cannot drift the way eight
## separate images can, and the camera used here is the game's own view, so a sprite is correct for
## the view it is drawn in rather than merely similar to it. Re-bake when the view or the model
## changes and every direction updates together.
##
## Run it windowed, not headless: a headless Godot has no rendering, so there is nothing to capture.
## The window is small and closes itself.
##
## Environment:
##   PB_BAKE_MODEL   path to a .glb/.gltf with a skeleton and an animation, or empty for the
##                   procedural stand-in used to prove the baker works without any asset
##   PB_BAKE_OUT     output directory (default user://bake)
##   PB_BAKE_NAME    file name stem (default "unit")
##   PB_BAKE_FRAMES  frames per direction (default 8)
##   PB_BAKE_SIZE    capture size in pixels (default 64)
##   PB_BAKE_DIRS    directions to bake (default 8)
##   PB_BAKE_PITCH   camera pitch in degrees from horizontal (default 55: high enough to read as a
##                   top-down game, low enough that a side-on sprite still shows the side)
##   PB_BAKE_ANIM    animation name to bake; empty uses the first in the file
##   PB_BAKE_POSE    static pose: if set, no animation is played and this pose index is captured

const DEFAULT_FRAMES := 8
const DEFAULT_SIZE := 64
const DEFAULT_DIRECTIONS := 8
const DEFAULT_PITCH := 55.0

var _viewport: SubViewport
var _camera: Camera3D
var _model: Node3D
var _anim: AnimationPlayer
var _anim_length := 0.0
var _frames := DEFAULT_FRAMES
var _size := DEFAULT_SIZE
var _directions := DEFAULT_DIRECTIONS
var _pitch := DEFAULT_PITCH
var _out_dir := "user://bake"
var _name := "unit"
var _torso: Node3D
var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []
## The model's own size and centre, measured after it is loaded. A generated mesh arrives at whatever
## scale its pipeline chose, so the camera frames what is actually there rather than assuming a
## man-sized box - otherwise a model ten times out of scale renders as a speck in one cell.
var _bounds := AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.7, 1.0))


func _ready() -> void:
	_read_environment()
	_setup_viewport()
	_setup_light()
	_setup_model()
	await _bake()
	get_tree().quit()


func _read_environment() -> void:
	_out_dir = _env("PB_BAKE_OUT", _out_dir)
	_name = _env("PB_BAKE_NAME", _name)
	_frames = int(_env("PB_BAKE_FRAMES", str(DEFAULT_FRAMES)))
	_size = int(_env("PB_BAKE_SIZE", str(DEFAULT_SIZE)))
	_directions = int(_env("PB_BAKE_DIRS", str(DEFAULT_DIRECTIONS)))
	_pitch = float(_env("PB_BAKE_PITCH", str(DEFAULT_PITCH)))
	DirAccess.make_dir_recursive_absolute(_out_dir)


func _env(key: String, fallback: String) -> String:
	var value := OS.get_environment(key)
	return value if not value.is_empty() else fallback


func _setup_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(_size, _size)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_camera = Camera3D.new()
	# Orthographic, because a sprite is a flat projection: perspective would make a man at the back of
	# a formation a different size from a man at the front, and the sheet is drawn as one size.
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 2.2
	_camera.position = Vector3(0.0, 1.0, 2.0)
	_viewport.add_child(_camera)


func _setup_light() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	light.light_energy = 1.15
	_viewport.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25.0, 145.0, 0.0)
	fill.light_energy = 0.45
	_viewport.add_child(fill)
	# A flat ambient, so a man seen from behind is not a silhouette.
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.74, 0.8)
	environment.ambient_light_energy = 0.55
	world.environment = environment
	_viewport.add_child(world)


func _setup_model() -> void:
	var path := OS.get_environment("PB_BAKE_MODEL")
	if path.is_empty():
		_build_standin()
		_frame_model()
		print("sprite baker: no PB_BAKE_MODEL set, using the procedural stand-in")
		return
	if not ResourceLoader.exists(path):
		push_error("sprite baker: no model at %s" % path)
		return
	var scene := load(path) as PackedScene
	_model = scene.instantiate() as Node3D
	_viewport.add_child(_model)
	_frame_model()
	_anim = _find_animation(_model)
	var wanted := OS.get_environment("PB_BAKE_ANIM")
	if _anim != null and not _anim.get_animation_list().is_empty():
		var clip: String = wanted if _anim.has_animation(wanted) else _anim.get_animation_list()[0]
		_anim.play(clip)
		_anim_length = _anim.get_animation(clip).length
		_anim.pause()
		print("sprite baker: model %s, animation %s (%.2fs)" % [path, clip, _anim_length])
	else:
		print("sprite baker: model %s has no animation, baking a single pose from %d directions" % [
			path, _directions])


func _find_animation(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation(child)
		if found != null:
			return found
	return null


## A box-headed stand-in with swinging limbs. It exists so the baker can be verified - directions,
## frames, sheet layout - before any real model is available, and so a future failure can be told
## apart from a model problem.
func _build_standin() -> void:
	_model = Node3D.new()
	_viewport.add_child(_model)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.55, 0.6, 0.7)
	var accent := StandardMaterial3D.new()
	accent.albedo_color = Color(0.6, 0.25, 0.25)

	var torso := MeshInstance3D.new()
	var torso_mesh := BoxMesh.new()
	torso_mesh.size = Vector3(0.34, 0.5, 0.2)
	torso.mesh = torso_mesh
	torso.material_override = accent
	torso.position = Vector3(0, 1.05, 0)
	_model.add_child(torso)
	_torso = torso

	var head := MeshInstance3D.new()
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.22, 0.22, 0.22)
	head.mesh = head_mesh
	head.material_override = skin
	head.position = Vector3(0, 1.42, 0)
	head.name = "head"
	_model.add_child(head)

	for side in [-1.0, 1.0]:
		var arm := MeshInstance3D.new()
		var arm_mesh := BoxMesh.new()
		arm_mesh.size = Vector3(0.12, 0.46, 0.12)
		arm.mesh = arm_mesh
		arm.material_override = skin
		arm.position = Vector3(0.23 * side, 1.05, 0)
		arm.name = "arm_%d" % int(side)
		_model.add_child(arm)
		_arms.append(arm)

		var leg := MeshInstance3D.new()
		var leg_mesh := BoxMesh.new()
		leg_mesh.size = Vector3(0.13, 0.5, 0.13)
		leg.mesh = leg_mesh
		leg.material_override = skin
		leg.position = Vector3(0.09 * side, 0.5, 0)
		leg.name = "leg_%d" % int(side)
		_model.add_child(leg)
		_legs.append(leg)

	# A nose, so "which way is he facing" is answerable in a still image instead of a guess.
	var nose := MeshInstance3D.new()
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.06, 0.06, 0.08)
	nose.mesh = nose_mesh
	nose.material_override = accent
	nose.position = Vector3(0, 1.42, -0.14)
	_model.add_child(nose)


## Every mesh under the model, so its real extent can be measured whatever the file's origin is.
func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node as MeshInstance3D)
	for child in node.get_children():
		found.append_array(_all_meshes(child))
	return found


## Measure the model and point the camera at its middle from eight compass directions, at the game's
## pitch. A direction of zero looks at the model's front, and each step turns the camera to its left.
## Orthographic projection means distance never changes how big the model is drawn - only the declared
## size does - so the fit comes from the model's own bounding box.
func _frame_model() -> void:
	var meshes := _all_meshes(_model)
	if not meshes.is_empty():
		var box := meshes[0].global_transform * meshes[0].get_aabb()
		for mesh in meshes:
			box = box.merge(mesh.global_transform * mesh.get_aabb())
		_bounds = box
	var extent := maxf(maxf(_bounds.size.x, _bounds.size.y), _bounds.size.z)
	print("sprite baker: model measures %s, framing on its centre %s" % [
		str(_bounds.size), str(_bounds.get_center())])
	_aim(0)


func _aim(index: int) -> void:
	var centre := _bounds.get_center()
	var extent := maxf(maxf(_bounds.size.x, _bounds.size.y), _bounds.size.z)
	var distance := maxf(extent * 2.5, 0.5)
	var yaw := TAU * float(index) / float(_directions)
	var lift := sin(deg_to_rad(_pitch)) * distance
	var flat := cos(deg_to_rad(_pitch)) * distance
	_camera.size = extent * 1.35
	_camera.position = centre + Vector3(sin(yaw) * flat, lift, cos(yaw) * flat)
	_camera.look_at(centre, Vector3.UP)


func _bake() -> void:
	var sheet := Image.create(_size * _frames, _size * _directions, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	var captures := 0
	for direction in _directions:
		_aim(direction)
		for frame in _frames:
			_pose(direction, frame)
			await RenderingServer.frame_post_draw
			var shot := _viewport.get_texture().get_image()
			if shot == null:
				push_error("sprite baker: no capture for direction %d frame %d" % [direction, frame])
				continue
			shot.save_png("%s/%s_%d_%02d.png" % [_out_dir, _name, direction, frame])
			sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, Vector2i(_size, _size)),
				Vector2i(frame * _size, direction * _size))
			captures += 1
	var sheet_path := "%s/%s_sheet.png" % [_out_dir, _name]
	sheet.save_png(sheet_path)
	print("sprite baker: %d captures across %d directions x %d frames -> %s" % [
		captures, _directions, _frames, sheet_path])


## Place the model at one instant of its animation, or swing the stand-in's limbs when there is no
## animation to play. The angle is index * 45 degrees, the same convention the camera uses.
func _pose(direction: int, frame: int) -> void:
	var phase := TAU * float(frame) / float(_frames)
	if _anim != null:
		_anim.seek(phase / TAU * _anim_length, true)
		return
	if _legs.is_empty():
		return
	var swing := sin(phase) * 0.5
	_legs[0].rotation.x = swing
	_legs[1].rotation.x = -swing
	if _arms.size() == 2:
		_arms[0].rotation.x = -swing * 0.7
		_arms[1].rotation.x = swing * 0.7
	if _torso != null:
		_torso.rotation.y = 0.0
		_torso.position.y = 1.05 + absf(sin(phase * 2.0)) * 0.02
