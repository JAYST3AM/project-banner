extends Node2D

## Throwaway spike: does a battle read as isometric, with the craftpix character walking around on
## real generated terrain? The projection is view-only - the world stays flat x/y and nothing the
## simulation knows about changes - so this is a look test, not a simulation test. Delete after the
## decision; the placeholder art under assets/dev is not to be committed.
##
## WASD or arrows walk, the wheel zooms, the middle button drags, F frames the field, S writes a
## screenshot. It also writes one by itself after a couple of seconds, so an agent can look at it.

const SHEET := "res://assets/dev/craftpix/walk.png"
const SHEET_COLUMNS := 6
const SHEET_ROWS := 4
const WALK_FPS := 9.0
## The four rows of the sheet, in the pack's own order: facing the viewer, then left, right, away.
const ROW_FRONT := 0
const ROW_LEFT := 1
const ROW_RIGHT := 2
const ROW_BACK := 3

## The view's orbit, in radians, and it is continuous rather than quarter turns. On a square lattice
## of random colours a ninety-degree snap looks like nothing happened, so it is the *motion* that
## reads as an orbit. Drag right to orbit one way, left the other; Q and E still snap a quarter turn
## if you want a whole number.
var _yaw := 0.0
const ORBIT_SENSITIVITY := 0.009
const QUARTER := PI * 0.5
## 2:1 diamonds, which is what makes it look like ground rather than a graph. This is the *default*
## tilt; the player can change it, because a camera angle is a preference. At 1.0 the tiles are square
## and you are looking almost straight down; at 0.15 the ground is a sliver and you are looking across
## it nearly at eye level.
const ISO_Y := 0.5
const PITCH_MIN := 0.15
const PITCH_MAX := 1.0
const PITCH_SENSITIVITY := 0.0025
var _squash := ISO_Y
## How much of a 64-pixel frame one world unit is worth. The character inside the frame is about
## 24 pixels tall, so this makes a man two units - and at the camera zoom below, about 28 screen
## pixels, which is the smallest that still reads as a person.
const UNIT_SCALE := 0.08
const WALK_SPEED := 30.0
const FIELD := Vector2(200.0, 120.0)
const TERRAIN_SEED := 20260916
## Where a screenshot goes. A variable rather than a constant because the auto-orbit writes one
## file per angle.
var shot_path := "F:/VSC Projects/pb-bench/iso/iso_spike.png"
const SHOT_AFTER := 2.5

var _terrain: BattlefieldTerrain = null
var _camera: Camera2D = null
var _hero: Sprite2D = null
var _hero_world := Vector2(60.0, 60.0)
var _hero_facing := Vector2.RIGHT
var _hero_walking := false
var _wanderers: Array[Sprite2D] = []
var _wander_world: Array[Vector2] = []
## Each wanderer's world heading, in radians, and how long until he picks another. Straight lines
## with rare turns, so a change of pose is a real change of direction.
var _wander_heading: Array[float] = []
var _wander_turn: Array[float] = []
const WANDER_SPEED := 14.0
var _panning := false
## Right button held: turning the view. A quarter turn every YAW_DRAG_PIXELS of drag, so the map
## spins under the hand but always stops on an angle the four-direction art can draw honestly.
var _rotating := false
## How far the player has looked aside from the man the camera follows.
var _pan_offset := Vector2.ZERO
var _time := 0.0
var _shot_written := false
var _auto_shots := 0
var _drawn_yaw := 0.0
var _drawn_squash := ISO_Y
var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_terrain = BattlefieldTerrain.generate(
		TERRAIN_SEED, FIELD, GameConfig.load_from("res://data/config/game_config.json"))
	_camera = Camera2D.new()
	add_child(_camera)
	_camera.make_current()
	_hero = _make_soldier(_hero_world)
	for i in 6:
		var spot := Vector2(40.0 + float(i) * 18.0, 30.0 + float(i % 4) * 22.0)
		_wander_world.append(spot)
		_wander_heading.append(float(i) * 0.9)
		_wander_turn.append(2.0 + float(i) * 0.7)
		_wanderers.append(_make_soldier(spot))
	_frame_all()


func _make_soldier(world: Vector2) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = load(SHEET)
	sprite.hframes = SHEET_COLUMNS
	sprite.vframes = SHEET_ROWS
	sprite.scale = Vector2(UNIT_SCALE, UNIT_SCALE)
	# A sheet's frame is drawn from its middle; the feet are what stands on the ground.
	sprite.offset = Vector2(0.0, 22.0)
	_place(sprite, world)
	add_child(sprite)
	return sprite


## World (x, y) onto the screen, squashed two to one and turned by the camera's quarter turns.
## Called "to" because the simulation lives in the flat version of this and never learns about the
## other one.
func _to_iso(point: Vector2) -> Vector2:
	var turned := _turn(point)
	return Vector2(turned.x - turned.y, (turned.x + turned.y) * _squash)


## A screen position back into world coordinates - for the mouse, and for turning "up" into a world
## direction no matter which way the diamonds run. The inverse of the orbit is the orbit negated
## twice, which is what the -2 is; the vertical is divided by the tilt rather than multiplied.
func _from_iso(screen: Vector2) -> Vector2:
	var flat := Vector2((screen.x + screen.y / _squash) * 0.5, (screen.y / _squash - screen.x) * 0.5)
	return _turn(flat, -_yaw * 2.0)


## Tilt the camera: how much of the ground's depth is squashed into the screen's vertical. This is the
## angle you are looking at the map from, and it changes the shape of the ground, so the redraw is not
## optional - see the note in _orbit.
func _tilt(delta: float) -> void:
	if is_zero_approx(delta):
		return
	_squash = clampf(_squash + delta, PITCH_MIN, PITCH_MAX)
	queue_redraw()


## Turn the map about its middle by [param extra] radians on top of the view's orbit. Rotating about
## the centre is what keeps the field under the camera as the view swings around it.
func _turn(point: Vector2, extra: float = 0.0) -> Vector2:
	var angle := -(_yaw + extra)
	if is_zero_approx(angle):
		return point
	var centre := FIELD * 0.5
	var p := point - centre
	var c := cos(angle)
	var s := sin(angle)
	return Vector2(p.x * c - p.y * s, p.x * s + p.y * c) + centre


func _place(sprite: Sprite2D, world: Vector2) -> void:
	sprite.position = _to_iso(world)
	# Where this man is standing in the world, kept on the sprite so the camera can follow a locked
	# one without a parallel index of every walker.
	sprite.set_meta("world", world)
	# Depth: a soldier further along the view's depth axis draws in front. This is the whole reason
	# an isometric view needs sorting and a flat one does not.
	sprite.z_index = int(clampf(sprite.position.y * 4.0, -4000.0, 4000.0))


## Lock the camera on to the soldier under a screen position, or let go if there is nobody there.
## Double-click is what a player reaches for to say "him", and it is the same gesture in every game
## that has ever had a follower camera.
func _lock_at(screen: Vector2) -> void:
	# The pointer is in viewport pixels and the world is drawn in canvas space, so the camera's own
	# position and zoom are what turns one into the other.
	var middle := get_viewport().get_visible_rect().size * 0.5
	var world := _from_iso(_camera.position + (screen - middle) / _camera.zoom.x)
	var reach := 3.0
	var best: Sprite2D = null
	var best_distance := INF
	for sprite in [_hero] + _wanderers:
		var spot: Vector2 = sprite.get_meta("world", Vector2.ZERO)
		var distance := spot.distance_to(world)
		if distance < reach and distance < best_distance:
			best = sprite
			best_distance = distance
	if best == null:
		_follow = null
		print("iso spike: camera released, following the player's man again")
		return
	_follow = best
	print("iso spike: camera locked on to a soldier at %s" % str(_focus_world().round()))


## Orbit the view by [param delta] radians, keeping the ground under the camera and the player's zoom
## exactly where they were. A turn is not allowed to reframe: the reframe is F's job.
func _orbit(delta: float) -> void:
	if is_zero_approx(delta):
		return
	_yaw = fmod(_yaw + delta, TAU)
	# Spin the world *around the player's man*, not around a patch of ground. He stays where the
	# player put him and everything else sweeps past, which is what an isometric camera is for - the
	# lone figure that appeared to "move with the rotation" was simply standing on ground that was
	# turning, which is correct and useless if the camera does not hold him.
	_update_camera()
	# The ground's *shape* changes when the view turns, and Godot only recomputes a _draw() when it is
	# asked. Moving the camera re-renders what is already drawn, so without this the terrain keeps its
	# old shape while the soldiers - separate nodes, repositioned every frame - swing around it. That
	# is precisely "only the units rotate", and a screenshot cannot catch it because capturing a frame
	# forces the redraw.
	queue_redraw()


## The unit the camera is riding, or null for the player's own man. Double-click locks on to a soldier
## and the camera follows him as he walks; F (or a double-click on empty ground) lets go.
var _follow: Sprite2D = null


## Where the camera should be looking: the followed man's world position, live.
func _focus_world() -> Vector2:
	if _follow != null:
		return _follow.get_meta("world", _hero_world)
	return _hero_world


## The camera sits on whoever it is following, plus whatever the player has panned aside to look at.
## This is the one place the camera is positioned: orbiting, tilting and walking all come out of it,
## so a turn spins the world around the followed man and a lock rides along with him as he moves.
func _update_camera() -> void:
	_camera.position = _to_iso(_focus_world()) + _pan_offset


## The snapping version, for a whole quarter at a time, and the one that says so out loud.
func _turn_view(delta: float) -> void:
	_orbit(delta)
	print("iso spike: view snapped to %d degrees (zoom %.1f)" % [int(rad_to_deg(_yaw)), _camera.zoom.x])


func _frame_all() -> void:
	var window := Vector2(get_viewport().get_visible_rect().size)
	# Open at a soldier's scale, not the field's: a whole-field view makes a man five pixels of
	# nothing, which is exactly why the real view draws blocks when it is zoomed out. The camera sits
	# on the player's man, because that is whose battle it is.
	var fit := minf(window.x, window.y) / 60.0
	_pan_offset = Vector2.ZERO
	_update_camera()
	_camera.zoom = Vector2(fit, fit)


func _process(delta: float) -> void:
	_time += delta
	# PB_ISO_AUTO=<radians per second> orbits by itself and writes a shot every two seconds, so a
	# screenshot at one angle can be compared with a screenshot at another. Argument is cheap;
	# two images are not.
	_update_camera()
	# The lock ring is drawn by _draw(), so a followed man walking would leave his ring behind: the
	# ground's draw commands are cached and a camera move re-renders them without recomputing the ring.
	if _follow != null:
		queue_redraw()
	var auto := OS.get_environment("PB_ISO_AUTO")
	if not auto.is_empty():
		_orbit(float(auto) * delta)
		var wanted := int(_time / 2.0)
		if wanted > _auto_shots:
			_auto_shots = wanted
			shot_path = "F:/VSC Projects/pb-bench/iso/auto_%d.png" % wanted
			write_shot()
	if not _shot_written and _time >= SHOT_AFTER:
		_shot_written = true
		write_shot()

	# Keys move the hero the way the screen reads, which is not the way the world reads.
	var screen_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		screen_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		screen_dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		screen_dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		screen_dir.y += 1.0
	_hero_walking = screen_dir != Vector2.ZERO
	if _hero_walking:
		var world_dir := _from_iso(screen_dir).normalized()
		_hero_world += world_dir * WALK_SPEED * delta
		_hero_world.x = clampf(_hero_world.x, 2.0, FIELD.x - 2.0)
		_hero_world.y = clampf(_hero_world.y, 2.0, FIELD.y - 2.0)
		_hero_facing = world_dir
		_advance(_hero, _hero_world, world_dir, true)

	for i in _wanderers.size():
		# Straight lines, with an occasional turn. A man walking in circles changes his pose every
		# second, which makes it impossible to tell whether the *camera* is turning him or he is just
		# walking - and that question is the whole point of this spike.
		_wander_turn[i] = float(_wander_turn[i]) - delta
		var heading: float = float(_wander_heading[i])
		if _wander_turn[i] <= 0.0 or _at_edge(_wander_world[i], heading):
			heading += PI * (0.6 + 0.8 * float(i % 3) * 0.37)
			_wander_turn[i] = 2.5 + float(i % 4) * 1.3
			_wander_heading[i] = heading
		var world_dir := Vector2(cos(heading), sin(heading))
		var next: Vector2 = (_wander_world[i] + world_dir * WANDER_SPEED * delta).clamp(
			Vector2(2.0, 2.0), FIELD - Vector2(2.0, 2.0))
		_wander_world[i] = next
		_advance(_wanderers[i], next, world_dir, true)


## Whether a heading has walked a man into the field's edge, so he turns rather than grinding along it.
func _at_edge(world: Vector2, heading: float) -> bool:
	var ahead := world + Vector2(cos(heading), sin(heading)) * 1.5
	return ahead.x <= 2.0 or ahead.y <= 2.0 or ahead.x >= FIELD.x - 2.0 or ahead.y >= FIELD.y - 2.0


## Which drawing each soldier is using, and the world direction it came from. Printed when the player
## lets go of an orbit so the claim "the camera does not change their facing" can be checked from
## outside the window rather than argued about.
func facing_report() -> String:
	var parts: Array[String] = []
	for i in _wanderers.size():
		parts.append("%s@%d" % [
			["front", "left", "right", "back"][_wanderers[i].frame_coords.y],
			int(rad_to_deg(float(_wander_heading[i])))])
	return " ".join(parts)


func _advance(sprite: Sprite2D, world: Vector2, world_dir: Vector2, walking: bool) -> void:
	_place(sprite, world)
	if not walking:
		# Standing still keeps the last pose he walked in, because that is the way he is facing. A
		# soldier is not a camera-facing decal: he faces the way he is going, in the world.
		sprite.frame_coords = Vector2i(0, sprite.frame_coords.y)
		return
	var column := int((_time * WALK_FPS) + float(sprite.get_instance_id() % 7)) % SHEET_COLUMNS
	sprite.frame_coords = Vector2i(column, _row_for(world_dir))


## Which of the sheet's four rows a *world* direction looks like. Deliberately the world's direction
## and not the screen's: deriving it from the screen made every soldier change pose whenever the
## camera orbited, which reads as the map rotating the men rather than the men walking. The price is
## that at some camera angles a man walks "sideways" on screen while still facing the way he is going,
## which is what a world-locked facing means.
func _row_for(world_dir: Vector2) -> int:
	if absf(world_dir.x) >= absf(world_dir.y):
		return ROW_RIGHT if world_dir.x > 0.0 else ROW_LEFT
	return ROW_FRONT if world_dir.y > 0.0 else ROW_BACK


func write_shot() -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	DirAccess.make_dir_recursive_absolute(shot_path.get_base_dir())
	image.save_png(shot_path)
	print("iso spike: wrote %s" % shot_path)


func _draw() -> void:
	if _terrain == null:
		return
	# Proof that a turn or a tilt really redraws the ground, and not just the soldiers on it: this
	# fires once per change rather than once per frame.
	if not is_equal_approx(_drawn_yaw, _yaw) or not is_equal_approx(_drawn_squash, _squash):
		_drawn_yaw = _yaw
		_drawn_squash = _squash
		print("iso spike: ground redrawn at %d degrees, tilt %.2f" % [int(rad_to_deg(_yaw)), _squash])
	# The ground, one diamond per terrain cell, coloured exactly as the real battlefield colours it.
	var cell := _terrain.cell_size
	for index in _terrain.cell_count():
		var corner := Vector2(float(index % _terrain.cols), float(index / _terrain.cols)) * cell
		var points := PackedVector2Array([
			_to_iso(corner),
			_to_iso(corner + Vector2(cell, 0.0)),
			_to_iso(corner + Vector2(cell, cell)),
			_to_iso(corner + Vector2(0.0, cell)),
		])
		draw_colored_polygon(points, _terrain.colour_of_cell(index))
	# A grid, which is the thing that makes the ground's tilt visible: random colour patches turning
	# look static, a lattice shearing as you orbit does not. This was here before the outline replaced
	# it, and its absence is why an orbit looked like nothing was happening.
	var step := 20.0
	var x := 0.0
	while x <= FIELD.x:
		draw_line(_to_iso(Vector2(x, 0.0)), _to_iso(Vector2(x, FIELD.y)), Color(0.0, 0.0, 0.0, 0.16), 1.0)
		x += step
	var y := 0.0
	while y <= FIELD.y:
		draw_line(_to_iso(Vector2(0.0, y)), _to_iso(Vector2(FIELD.x, y)), Color(0.0, 0.0, 0.0, 0.16), 1.0)
		y += step
	# The field's own edges, so a turn is visible: two hundred by one hundred and twenty is a wide
	# diamond, and the same field turned a quarter is a tall one.
	draw_colored_polygon(PackedVector2Array([
		_to_iso(Vector2.ZERO),
		_to_iso(Vector2(FIELD.x, 0.0)),
		_to_iso(FIELD),
		_to_iso(Vector2(0.0, FIELD.y)),
	]), Color(1.0, 1.0, 1.0, 0.06))
	draw_polyline(PackedVector2Array([
		_to_iso(Vector2.ZERO),
		_to_iso(Vector2(FIELD.x, 0.0)),
		_to_iso(FIELD),
		_to_iso(Vector2(0.0, FIELD.y)),
		_to_iso(Vector2.ZERO),
	]), Color(1.0, 1.0, 1.0, 0.35), 1.5)
	# A ring on whoever the camera is riding, so a lock is visible rather than something the player has
	# to infer from the camera moving.
	if _follow != null:
		var ring := _to_iso(_focus_world())
		draw_arc(ring, 4.0, 0.0, TAU, 24, Color(1.0, 0.9, 0.5, 0.85), 1.2)
	# A north arrow, which is the one thing on a noise field that says which way the view is facing:
	# without it a quarter turn of a square lattice of random colours looks like nothing happening.
	var north := _to_iso(Vector2(FIELD.x * 0.5, -14.0))
	var tail := _to_iso(Vector2(FIELD.x * 0.5, 4.0))
	draw_line(tail, north, Color(1.0, 0.85, 0.4, 0.9), 2.0)
	draw_circle(north, 3.0, Color(1.0, 0.85, 0.4, 0.9))
	if _font != null:
		draw_string(_font, north + Vector2(6.0, -4.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
			Color(1.0, 0.85, 0.4, 0.9))


func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.double_click and button.button_index == MOUSE_BUTTON_LEFT:
			_lock_at(button.position)
			return
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom = Vector2(_camera.zoom.x * 1.12, _camera.zoom.y * 1.12)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom = Vector2(_camera.zoom.x / 1.12, _camera.zoom.y / 1.12)
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = button.pressed
			if not button.pressed:
				print("iso spike: orbiting stopped at %d degrees, tilt %.2f" % [
					int(rad_to_deg(_yaw)), _squash])
				print("iso spike: facings %s" % facing_report())
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			_pan_offset -= motion.relative / _camera.zoom.x
			return
		if _rotating:
			# Sideways swings the world around the man; up and down tilts the camera - how much you are
			# looking down at the ground rather than across it. One button, both motions, no mode to
			# remember, and the middle button still pans freely on its own.
			_orbit(motion.relative.x * ORBIT_SENSITIVITY)
			_tilt(-motion.relative.y * PITCH_SENSITIVITY)
			return
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_F:
				_follow = null
				_frame_all()
			KEY_P:
				write_shot()
			KEY_Q:
				_turn_view(-1)
			KEY_E:
				_turn_view(1)
			KEY_S:
				write_shot()
