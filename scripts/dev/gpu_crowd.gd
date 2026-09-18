extends Node2D
## Dev-only probe: a battle whose soldiers are simulated on the GPU.
##
## [b]What this is.[/b] The game's own battlefield - the production terrain generator, the
## formation lattice, the soldier look and the instanced renderer - with the per-soldier work
## running in compute shaders over state that lives in the GPU's buffers: build a spatial
## grid, read a soldier's neighbours, push them apart, land blows on the enemy, take the
## blows, march. Four dispatches a tick, a readback of the positions and the hit points, one
## [MultiMesh] buffer assignment - the idiom [SoldierField] already uses to hand a whole army
## to the renderer. The game-owned battle field subclasses this node to supply campaign
## soldiers; opening this scene directly remains the standalone probe.
##
## [b]What it is not.[/b] Not the game's simulation. There is no targeting, no defence, no
## cooldown, no terrain effect on movement, no formations with orders, no morale and no
## campaign. It is the same *shape* of work at a size the CPU cannot reach, built to price
## the boundary before anything is committed to it.
##
## Usage:
## [codeblock]
## godotc --path "<project>" res://scenes/dev/gpu_crowd.tscn -- \
##     --agents=6000 --ticks-per-frame=1 --max-fps=60
## [/codeblock]
## Switches: [code]--agents=[/code], [code]--ticks-per-frame=[/code],
## [code]--readback-every=[/code] (read the picture back every N ticks),
## [code]--max-fps=[/code] (0 = uncapped), [code]--seed=[/code], [code]--out=[/code]
## (where the one screenshot goes), [code]--seconds=[/code] (quit after this long; 0 runs
## until the window is closed).

const SHADER_PATH := "res://shaders/dev/crowd_sim.glsl"
const LG_CELL := 3.0
const SEPARATION := 2.6
## The spearman's reach. It must exceed the separation distance or the settled front line
## physically cannot strike - the game's own combat suite guards exactly this.
const REACH := 3.4
## Hit points one attacker takes off a neighbour within reach, a tick. Slow enough that a
## line grinds rather than evaporates: a hundred hit points at this rate is a long fight.
const BLOW := 0.25
const HP_MAX := 100.0
const DT := 0.05
## Units a second a soldier walks to his place in the line; the game's spearman is about
## this fast.
const WALK := 6.0
## The most a soldier may be pushed by the separation in one tick. It has to be able to beat
## the step he was walking: a collision that loses to a walk is a soldier walking through his
## neighbour, which is exactly what it looked like before this was raised.
## The furthest a body may be pushed in one tick, in world units. It is a *per-tick* limit, which is
## why it is scaled by the clock where it is handed to the shader: at a slower tick a longer time
## passes between corrections, so the cap has to travel further. Set for sixty ticks a second, which
## is why the arithmetic below leaves it untouched at that rate and doubles it at thirty. Without
## this, contact loosened at thirty ticks - 1,578 pair-ticks below the separation floor against 64
## at sixty - because a body could not be pushed out of another's space in the time one tick allows.
const MAX_PUSH := 0.6
## The agreed physical minimum between two enemies, in world units: the separation distance
## with a five per cent tolerance. The proof run records the closest enemy gap on every tick
## and counts any pair inside this - the audit's item 1, and the number that has to be zero.
const MIN_ENEMY_GAP := SEPARATION * 0.95
## How many formations a side deploys with by default. The count is the knob that makes a battle
## small enough for a person to command: three a side is a legion each, four or five is a skirmish
## a player can actually pick up and place before it starts.
## The smallest battle the scene will run: thirty men against thirty. It is a test of commands,
## not of crowds, and the floor used to be a compute workgroup - sixty-four - which quietly turned
## a thirty-a-side run into a thirty-two-a-side one.
const MIN_AGENTS := 60
const DEFAULT_BODIES_PER_SIDE := 3
var bodies_per_side := DEFAULT_BODIES_PER_SIDE
## Men in one unit. Read by the size presets; the deployment divides the army by the unit count.
var per_unit := 0
## The frontage of one body, in files. A thousand men in forty files is twenty-five ranks:
## a legion that reads as a block, not a queue.
const BODY_FILES := 40
## How close the front ranks have to be before a body stops advancing: the separation the men
## themselves keep. Bodies whose front ranks stand at 2.6 stop; closer than that and the press
## would be fighting the separation for ever, which is what a 2.0 threshold measured - the front
## settled at 2.11 where the agreed minimum is 2.47, because the bodies were asking for 2.0.
const CONTACT := SEPARATION
## How close a body gets before it stops leaning in: the men's own separation, with a hair to
## spare so the line settles *inside* melee reach instead of on the edge of it. Stopping the press
## the moment "somebody is in reach" left the front at 3.2-3.4, where only the occasional pair
## could strike and the battle crawled along at sixteen blows a tick. The separation solver holds
## the men themselves at 2.6 whatever the anchors ask for, so pressing this close cannot crush
## them; it only decides whether the two lines are actually fighting.
const ENGAGE := SEPARATION * 1.05
## How fast a body can swing round, in radians a second, and why turning is worth having at all:
## the shader already builds every man's place in the line from the body's forward vector, so a
## body that turns swings its whole lattice with it and the men walk to their new places - the
## reference's order_face_toward, in the small. Bodies aim at the nearest enemy body.
const TURN_RATE := 1.2
## How much further than the nearest enemy a body's current target may be before it switches. The
## reference keeps its target until something better is clearly better; without a margin, a body
## between two equidistant enemies would flap between them every tick.
const RETENTION := 1.4
## How close a body has to be to an advance point to consider itself arrived, in world units.
const ARRIVED := 1.5

## ---------- target acquisition (Phase 4.3 slice 1) -------------------------
## A soldier's opponent is remembered while it is alive, hostile and within this radius, and
## re-chosen on its own staggered cadence. The shipped values are the reference's (D-080..D-083):
## the cadence is four ticks and the retention radius is the reference's 32 units, kept equal to
## its search ceiling so a remembered opponent is never released only to be found again. The GPU
## searches the same 3x3 neighbourhood the separation already reads, so the radius mostly decides
## whether an opponent that has walked off is released rather than chased.
const TARGET_CADENCE := 4
const TARGET_RETENTION := 32.0
const TARGET_SWITCH_ADVANTAGE := 1.25
const TARGET_SEARCH_RADIUS := 8.0
const TARGET_IMMEDIATE_ON_CONTACT_LOSS := true
## The counter block the shader and this script must agree on. [0..7] and the per-body gaps at
## [8..13] are the collision proof; the target counters follow them. The clear pass in the shader
## resets all of them every tick, so these are per-tick counts and the totals below are summed on
## the CPU.
const COUNTER_SLOTS := 96
## Where the per-body nearest-enemy distances start in the counter block. The shader's
## BODY_GAP_BASE is the same number; the two are read together or not at all.
const BODY_GAP_BASE := 32
const PARAM_SLOTS := 26
const CNT_DROPPED := 0
const CNT_PROBES := 1
const CNT_BLOWS := 2
const CNT_FALLEN := 3
const CNT_INSIDE_HALF := 4
const CNT_CLOSEST_GAP := 5
const CNT_MAX_STEP := 6
const CNT_BELOW_MINIMUM := 7
const CNT_ACQUISITIONS := 14
const CNT_RETENTIONS := 15
const CNT_RE_SEARCHES := 16
const CNT_RELEASES_FAR := 17
const CNT_INVALID_DEAD := 18
const CNT_IMMEDIATE := 19
const CNT_SCHEDULED := 20
const CNT_SWITCHES := 21
const CNT_EMPTY := 22

## Formation orders, the same shape as the reference's: a body is either holding, advancing to a
## place, or engaging an enemy body. Nothing else changes a body's mind, which is what makes the
## choice reviewable - and it is the hierarchy the roadmap asks for: army, then body, then men.
enum Order { HOLD, ADVANCE, ENGAGE }
## A body that has stopped presses forward at this speed, which is the game's own rule: ranks
## on rigid slots leave the nearest living enemy outside every reach once the front rank has
## fallen, and a stalled battle has to lean into the gap rather than freeze.
const PRESS := 1.0
## How far from his place a soldier starts: the ranks dress on the way in, which is the
## first thing a formation does.
const JITTER := 2.5
## The health bar over a soldier's head, in world units.
const BAR_WIDTH := 2.2
const BAR_HEIGHT := 0.5
const BAR_LIFT := 0.4
const SLOT_CAPACITY := 64
## How many relaxation rounds of the separation run after the walk each tick. One is not enough:
## a pressed front is pulled by several neighbours at once and a single capped correction leaves
## a residual that never closes (measured: a 1.49-unit gap where 2.47 is the agreed minimum).
## Rounds re-measure against where everyone now stands, which is how the reference resolves
## overlaps. Three clears the front with room to spare; the cost is one extra neighbour pass each.
const SETTLE_ROUNDS := 3


## The settle rounds this clock needs. Three were tuned at sixty ticks a second; at a slower tick a
## body crosses twice the ground between one chance to correct and the next, so the same number of
## rounds leaves overlaps standing. Measured at thirty ticks: 1,578 pair-ticks below the separation
## floor against 64 at sixty - and scaling the step cap did not move it (1,720), which is what proved
## the constraint is how often neighbours are re-measured, not how far one body may be pushed.
func settle_rounds() -> int:
	return SETTLE_ROUNDS * maxi(1, roundi(60.0 / maxf(1.0, tick_hz)))
## How often cohesion is measured, in ticks. The slot arithmetic it needs costs 6.5 ms of the
## pack at 20,000 soldiers; nothing in the simulation reads the number, so a quarter of the rate
## is five samples a second for a fifth of the cost. What it is NOT is a cheaper estimate: the
## ticks in between keep the last real reading rather than pretending to a fresh one.
const COHESION_EVERY := 4
const WORKGROUP := 256
## The drawn soldier, in world units: the radius the game's disc uses, rim included.
const DISC_RADIUS := 1.1
const DISC_CORE := 0.72
const TEX_SIZE := 32
const COLOR_OUTLINE := Color("0f1216")
const COLOR_PLAYER := Color("4fa8e0")
const COLOR_ENEMY := Color("e06c6c")
const COLOR_FALLEN := Color("2a2f36")
## Where each field of one instance sits inside a [member MultiMesh.buffer] slice. Measured
## on this build by the render bench (`buffer probe: stride=12, x_x=0, y_y=5, origin_x=3,
## origin_y=7, color=8`), which is the same layout [SoldierField] writes.
const STRIDE := 12
const AT_X_X := 0
const AT_Y_Y := 5
const AT_ORIGIN_X := 3
const AT_ORIGIN_Y := 7
const AT_COLOR := 8

var agents := 6000
## Fraction of a band to shift the enemy's bodies down the field, for demoing the turn.
var oblique := 0.0
## Scripted events for testing the orders, all at fixed ticks so a run is repeatable: destroy the
## enemy's body in this band at this tick (target reassignment), or hold the player's body in this
## band from this tick (advance against hold).
var wipe_band := -1
var wipe_at := 0
## What fraction of the wiped body's living men are killed. 1.0 is the whole body, which is what
## the order tests want; the acquisition rule check uses a half so the bereaved hunters still have
## a living opponent in their local window to find.
var wipe_fraction := 1.0
var hold_band := -1
var hold_at := 0
var advance_band := -1
var advance_at := 0
var advance_by := 120.0
var _wiped := false
var _held := false
var _advanced := false
## 0 means "run the battle on the game's own fixed clock" - twenty ticks a second, whatever
## the frame rate is doing. `--ticks-per-frame=N` overrides it with a fixed number of ticks
## per rendered frame, which is the stress setting, not the game's.
var ticks_per_frame := 0
## The battle clock, in ticks a second, when `--ticks-per-frame` is not overriding it. The owner's
## call, made after measuring: 60 costs 0.4 M soldier-ticks a second at 6,000 soldiers and holds the
## frame rate at 730, where 144 took the repack to a whole core. The reference game's own step is
## 20 Hz and stays 20 Hz - that is a gameplay decision in the reference, not a rendering one, and
## this scene uses 60 because it is a look-and-feel test bed, not the campaign's clock.
var tick_hz := _config_tick_rate()


## The battle clock from the game's own config, so the dev scene and the game it stands in for cannot
## disagree about what a second of fighting is. Falls back to sixty if the file is unreadable.
static func _config_tick_rate() -> float:
	var path := "res://data/config/game_config.json"
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			var battle: Variant = (parsed as Dictionary).get("battle", {})
			if typeof(battle) == TYPE_DICTIONARY:
				return maxf(1.0, float((battle as Dictionary).get("tick_rate", 60.0)))
	return 60.0
var _tick_accumulator := 0.0
var readback_every := 1
var max_fps := 0
var run_seconds := 0.0
## When the first screenshot is taken, in seconds of wall clock. The default is early; a run whose
## armies take longer to meet passes a later value so the shot catches the fighting.
var shot_at := 6.0
var seed_value := 780780
var out_dir := "F:/VSC Projects/pb-bench/gpu_crowd"
## How far the camera is pushed in past the fit-the-field zoom: at 1.0 the whole field is
## visible and a six-thousand-man army is a dot matrix, which is not what a battle looks
## like. The camera follows the fighting once it starts.
var zoom_factor := 2.5

# ---- The view: an isometric camera, Total War fashion -------------------------------------------
#
# The projection is view-only. The simulation lives in the flat x/y plane and never learns about
# any of this: positions are turned about the field's middle and laid down as 2:1 diamonds for the
# picture, and the ground sprite is given the same transform so the two cannot disagree.
const PITCH_MIN := 0.15
const PITCH_MAX := 1.0
const PAN_SPEED := 260.0
const ZOOM_MIN := 0.4
const ZOOM_MAX := 8.0
const ZOOM_STEP := 1.14
const TILT_STEP := 0.02
const YAW_DRAG := 0.006
var yaw := 0.0
var squash := 0.5
## The flat, top-down view this scene started with, kept because a comparison shot is evidence.
var flat_view := false
var _camera_zoom := 1.0
var _zoom_target := 1.0
var _follow_action := true
var _rotating := false
var _panning := false
var _last_mouse := Vector2.ZERO
const TILT_DRAG := 0.004
var _view_root: Node2D = null
## A world point a scripted camera should look at (`--cam-at=x,y`), or INF for none.
var cam_at := Vector2(INF, INF)


## A world point's offset from the field's middle, in the picture: turned by the view's orbit, then
## laid down as 2:1 diamonds. Everything drawn standing *on* the ground uses this, and the field's
## middle is the picture's origin - the camera is what moves over it, which is why nothing here
## needs to know where the camera is. (It did, in the first version of this, and panning cancelled
## itself out on screen: the offset was measured from the camera and the camera was drawn at the
## offset. The field's middle is a fixed thing; the camera is not.)
func _iso(point: Vector2) -> Vector2:
	var q := point - field * 0.5
	if flat_view:
		return q
	var angle := -yaw
	var turned := Vector2(q.x * cos(angle) - q.y * sin(angle), q.x * sin(angle) + q.y * cos(angle))
	return Vector2(turned.x - turned.y, (turned.x + turned.y) * squash)


## A viewport position back into the flat world - for the wheel's zoom-at-the-cursor, and for
## anything that later wants to click a soldier. The exact inverse of _iso, in the same order.
func _uniso(screen: Vector2) -> Vector2:
	var zoom := _picture_scale()
	var view_centre := Vector2(get_viewport().get_visible_rect().size) * 0.5
	var s := (screen - view_centre) / maxf(zoom, 0.0001) + _camera.position
	if flat_view:
		return s + field * 0.5
	var flat := Vector2((s.x + s.y / squash) * 0.5, (s.y / squash - s.x) * 0.5)
	var angle := yaw
	var back := Vector2(flat.x * cos(angle) - flat.y * sin(angle), flat.x * sin(angle) + flat.y * cos(angle))
	return back + field * 0.5


## How many screen pixels one unit of picture space is worth at the current zoom.
func _picture_scale() -> float:
	var window := Vector2(get_viewport().get_visible_rect().size)
	var fit := minf(window.x / (field.x + 8.0), window.y / (field.y + 8.0))
	return fit * _camera_zoom * zoom_factor


## The same projection as an affine transform, for the one thing that cannot be repositioned point
## by point: the ground sprite. World space in, picture space out (origin at the field's middle).
func _view_transform() -> Transform2D:
	if flat_view:
		return Transform2D(0.0, -field * 0.5)
	var basis := Transform2D(Vector2(1.0, squash), Vector2(-1.0, squash), Vector2.ZERO)
	var spin := Transform2D(-yaw, Vector2.ZERO)
	var combined := basis * spin
	var centre := field * 0.5
	return Transform2D(combined.x, combined.y, -(combined * centre))


## The camera, once a frame. Panning is in *view* directions - W is up the screen, not up the field -
## which is what the games this is modelled on do, and the only thing that stays sane once the map
## can be turned. Zoom is smoothed so a wheel notch is a movement rather than a jump, and the
## fighting is followed until the player takes the view in hand.
func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	var pan := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		pan.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		pan.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		pan.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		pan.y += 1.0
	if pan != Vector2.ZERO:
		_follow_action = false
		_camera.position += pan.normalized() * (PAN_SPEED * delta / maxf(_camera_zoom, 0.05))
	if _follow_action:
		_camera.position = _camera.position.lerp(_iso(_focus), clampf(delta * 2.0, 0.0, 1.0))
	_camera_zoom = lerpf(_camera_zoom, _zoom_target, clampf(delta * 12.0, 0.0, 1.0))
	_camera.zoom = Vector2.ONE * _picture_scale()
	if _view_root != null:
		_view_root.transform = _view_transform()


## Zoom toward the cursor: the ground under the pointer stays under the pointer. That is the gesture
## every strategy game has, and the reason _uniso exists at all. The correction is solved for the
## zoom the player is going to end up at, not the one they are passing through.
func _zoom_at(screen: Vector2, factor: float) -> void:
	var wanted := clampf(_zoom_target * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(wanted, _zoom_target):
		return
	var anchor := _uniso(screen)
	var old_scale := _picture_scale()
	_zoom_target = wanted
	var new_scale := _picture_scale() * (wanted / maxf(_camera_zoom, 0.0001))
	var here := _iso(anchor)
	_camera.position = here - (here - _camera.position) * (old_scale / maxf(new_scale, 0.0001))


## Tilt the ground: how much of its depth is laid into the screen's vertical. 0.5 is 2:1 diamonds,
## 1.0 is looking straight down, and 0.15 is looking across it nearly at eye level.
func _tilt(delta: float) -> void:
	squash = clampf(squash + delta, PITCH_MIN, PITCH_MAX)


## The controls, deliberately the ones the genre has taught everyone: the wheel zooms at the cursor,
## the middle button turns the map, Q and E snap a quarter turn, the brackets tilt it, and F frames
## the field again (which also hands the camera back to the fighting).
func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed:
			match button.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_zoom_at(button.position, ZOOM_STEP)
				MOUSE_BUTTON_WHEEL_DOWN:
					_zoom_at(button.position, 1.0 / ZOOM_STEP)
				MOUSE_BUTTON_LEFT:
					# The left hand is for holding things: a formation, or a box drawn around
					# several. During the deployment it also drags a formation into its place.
					_press_at = button.position
					_left_held = true
					var under := _body_at(_uniso(button.position))
					if _deploying and _is_mine(under):
						_drag_body = under
						_drag_grab = _uniso(button.position) - _anchor_of(under)
					else:
						_box_active = true
						_box_from = button.position
						_box_to = button.position
				MOUSE_BUTTON_RIGHT:
					# Tap to command, drag to look: the right button is where the genre puts
					# both, so the drag has to be told from the tap by how far the hand moved.
					_right_held = true
					_right_moved = 0.0
					_right_at = button.position
					_rotating = true
					_last_mouse = button.position
				MOUSE_BUTTON_MIDDLE:
					# The other half of the convention: middle drags the ground itself.
					_panning = true
					_last_mouse = button.position
		else:
			match button.button_index:
				MOUSE_BUTTON_LEFT:
					_left_held = false
					if _drag_body >= 0:
						_drag_body = -1
					elif _box_active:
						_box_active = false
						if button.position.distance_to(_press_at) < 6.0:
							_click_select(_uniso(button.position), button.shift_pressed)
						else:
							_box_select(_uniso(_box_from), _uniso(button.position), button.shift_pressed)
				MOUSE_BUTTON_RIGHT:
					_right_held = false
					_rotating = false
					if _right_moved < RIGHT_DRAG_SLOP:
						_right_click(_uniso(button.position))
				MOUSE_BUTTON_MIDDLE:
					_panning = false
	elif event is InputEventMouseMotion and _drag_body >= 0:
		# Placing a formation before the fight: its anchor goes where the hand goes, and every
		# man in it is drawn to his slot from that anchor. Placement is not a special case in
		# the simulation - it is one anchor, the same number the march moves.
		_place_body(_drag_body, _uniso((event as InputEventMouseMotion).position) - _drag_grab)
	elif event is InputEventMouseMotion and _box_active:
		_box_to = (event as InputEventMouseMotion).position
	elif event is InputEventMouseMotion and _rotating:
		var motion := event as InputEventMouseMotion
		_right_moved += motion.relative.length()
		yaw = wrapf(yaw + motion.relative.x * YAW_DRAG, -PI, PI)
		# Up on the screen is further from the ground: drag up to look down on it, drag down to look
		# across it towards the horizon.
		_tilt(motion.relative.y * TILT_DRAG)
		_last_mouse = motion.position
	elif event is InputEventMouseMotion and _panning:
		var motion := event as InputEventMouseMotion
		_follow_action = false
		_camera.position -= motion.relative / maxf(_picture_scale(), 0.0001)
		_last_mouse = motion.position
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_Q:
				yaw = wrapf(yaw + PI * 0.25, -PI, PI)
			KEY_E:
				yaw = wrapf(yaw - PI * 0.25, -PI, PI)
			KEY_BRACKETLEFT:
				_tilt(-TILT_STEP * 3.0)
			KEY_BRACKETRIGHT:
				_tilt(TILT_STEP * 3.0)
			KEY_F:
				_follow_action = true
				_zoom_target = 1.0
				_camera.position = _iso(_focus)
			KEY_SPACE:
				# The battle is a plan until the player says go. Space is that word, and space
				# is also how you get the camera back later, so it does whichever is wanted.
				if _deploying:
					_start_battle()
				else:
					_follow_action = not _follow_action
			KEY_I:
				flat_view = not flat_view
				print("gpu crowd: view | %s" % ("flat, looking straight down" if flat_view else "isometric"))
			KEY_H:
				_order_stance(_selected, true)
			KEY_U:
				_order_stance(_selected, false)
			KEY_L:
				_set_formation(_selected, "line")
			KEY_C:
				_set_formation(_selected, "column")
			KEY_O:
				_set_formation(_selected, "loose")
			KEY_K:
				_set_autonomy(not _manual)
			KEY_F1:
				if _help_panel != null:
					_help_panel.visible = not _help_panel.visible
			KEY_P:
				_clock_paused = not _clock_paused
				print("gpu crowd: %s" % ("paused" if _clock_paused else "running"))
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				var digit := (event as InputEventKey).keycode - KEY_0
				if (event as InputEventKey).ctrl_pressed:
					_group_assign(digit)
				else:
					_group_recall(digit)

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var buf_state: RID
var buf_push: RID
var buf_cursor: RID
var buf_slots: RID
var buf_params: RID
var buf_counters: RID
var buf_tallies: RID
var buf_meta: RID
var buf_damage: RID
var buf_corr: RID
var buf_attrs: RID
var buf_bodies: RID
var buf_stats: RID
## The remembered opponent and its next awareness tick, one ivec4 a soldier. See the shader.
var buf_targets: RID
var uniform_set: RID
## The bodies, ten numbers each: anchor.xy, forward.xy, files, ranks, spacing, engaged.
## Advanced on the CPU - six of them - and read by every soldier in the shader.
var _body_state := PackedFloat32Array()
var _bodies := 0
## The owner of each body. The probe has an equal number on both sides, while campaign
## battles may not; keeping this separate avoids manufacturing empty formations.
var _body_side := PackedInt32Array()

var field := Vector2(200.0, 120.0)
var grid := Vector2i(0, 0)
var mm: MultiMesh
var instances := PackedFloat32Array()

var _tick := 0
var _tick_usec := 0
var _readback_usec := 0
## Four ints a man, straight from the tallies buffer: see [method tally].
var _tallies := PackedInt32Array()
var _pack_usec := 0
var _frame_delta := 0.0
var _frames := 0
var _ticks_window := 0
var _readback_counter := 0
var _elapsed := 0.0
var _reported := false
var _reports := 0
var _shot_taken := 0
var _alive := Vector2i(0, 0)
var _fallen := 0
var _label: Label = null
var _camera: Camera2D = null
var _focus := Vector2.ZERO
## The health bars and the formation boxes: two instances a soldier and one line a body, the
## same two things the battle view draws for a formed battle.
var _bars: MultiMesh = null
var _bar_buffer := PackedFloat32Array()
var _solid: ImageTexture = null
var _bars_reported := false
var _outlines: Array[Line2D] = []
var _frozen := false
var _verdict := ""
var _max_inside := 0
## The front of the living, per body: the furthest any living man of that body stands in its
## direction of advance. Body b's own edge is what its room is measured from, and its opposite
## number's edge - same band, other side - is what it is measured against. Kept per body rather
## than per side, because one flank meeting the enemy must not stop the other two from closing.
var _body_front := PackedFloat32Array()
## Each body's heading, in radians. Side 0 starts facing +x, side 1 facing -x, and both turn
## toward the nearest enemy body at TURN_RATE. Written into the body state as a forward vector;
## everything else - slots, dressing, the advance - follows from it.
var _heading := PackedFloat32Array()
## Orders, and how they are carried out: one order and at most one target per body.
var _order := PackedInt32Array()
var _order_target := PackedInt32Array()
var _order_point := PackedVector2Array()
## 1 where the owner (a demo run, or the campaign one day) ordered the body to hold, as opposed to
## a body that is holding merely because it has nothing left to fight. Only the second kind stands
## up again when a new enemy appears.
var _hold_ordered := PackedInt32Array()
## Living men per body and the mean distance each man stands from his place in the line - the two
## numbers that say whether a body is still a body. Both come free from the pack that draws the
## picture; neither is estimated here.
var _body_alive := PackedInt32Array()
var _body_cohesion := PackedFloat32Array()
## Each man's body, file and rank, kept from the deployment so the pack can measure how far he
## stands from his place in the line without reading the attributes back off the GPU every tick.
var _man_body := PackedInt32Array()
var _man_file := PackedInt32Array()
var _man_rank := PackedInt32Array()
## The meta buffer as last read back, so a scripted event can write truthfully into it.
var _meta_bytes := PackedByteArray()
## The position buffer as last read back, for the determinism checksums.
var _state_bytes := PackedByteArray()
## Each soldier's remembered opponent as last read back, and the live count of soldiers each body
## has engaging each enemy body (bodies x bodies). Both are diagnostics: nothing in the simulation
## reads them.
var _targets := PackedInt32Array()
var _target_engage := PackedInt32Array()
## Cumulative target counters, summed on the CPU from the shader's per-tick block.
var _tgt_totals := PackedInt32Array()
## Print a state checksum every this many ticks (0 = never). Off unless asked for: it walks the
## whole field in GDScript, which is fine in a test and wasted work in a demo.
var checksum_every := 0
var _last_checksum_tick := -1
## The shipped target-acquisition behaviour. `PB_TGT_MODE=legacy` (or `--tgt-mode=legacy`)
## restores the behaviour this slice replaces - every enemy neighbour inside reach is struck and
## no opponent is remembered - in the same build, so a benchmark is a paired run rather than a
## comparison against an older log. This is the project's existing convention. See D-119.
var target_legacy := false
## The cadence and the acquisition constants, overridable so a probe or a benchmark can sweep
## them the way the reference permits. The shipped defaults are the reference's own.
var target_cadence := TARGET_CADENCE
var target_retention := TARGET_RETENTION
var target_switch_advantage := TARGET_SWITCH_ADVANTAGE
var target_search_radius := TARGET_SEARCH_RADIUS
var target_immediate := TARGET_IMMEDIATE_ON_CONTACT_LOSS
## Rule checks: run the acquisition rules through the live GPU simulation, print PASS/FAIL and
## quit. The scene simulates on the rendering device and cannot run headless, so this is the only
## honest way to check the GPU rules. The reference's own suite pins the same rules headlessly in
## `tests/test_target_acquisition.gd`; this scene does not pretend to replace it.
var rule_checks := false
## How many ticks to run before the rule checks expect contact. 0 = estimate from the field.
var rule_advance_ticks := 0
## Profile mode: draw no health bars, so the repack can be measured with and without them. Bars are
## presentation only; nothing in the simulation reads them, and the report still says how many
## would have been drawn.
var draw_bars := true
## How many times a body has changed its mind about who it is fighting, and why - printed rather
## than inferred, because "reassignment works" is a claim that needs evidence.
var _target_switches := 0
var _last_switch := ""
## The measured closest living enemy, per body, straight from the shader's own counters: the
## number the anchors are driven off. Kept alongside the edges because the edges are still what
## the debug line prints, and because a stale edge is what caused the deadlock this replaced.
var _body_gap := PackedFloat32Array()
var _per_side := 0
var _per_body := 0
## The proof of the collision, kept over the whole run: the closest enemy gap seen on any tick
## and the tick it happened, the total number of pairs found inside the agreed minimum, the
## furthest single step anyone took, and the most men the grid failed to hold.
var _worst_gap := 999.0
var _worst_gap_tick := 0
var _violations := 0
var _max_step := 0.0
var _dropped_max := 0
var _step_reported := false
## The lowest hit points anyone alive is carrying, taken from the same pack that draws the bars, so
## it costs nothing extra. If the line is locked and nobody is dying, this is what says whether
## blows are still landing or the damage has stopped.
var _weakest_hp := 999.0
## Where the repack's time actually goes, in microseconds, so the optimisation starts from a
## measurement rather than a guess: the per-soldier loop (state traversal, colours, the two bar
## quads), the bar buffer hand-off, and the MultiMesh submission.
var _loop_usec := 0
var _bars_usec := 0
var _submit_usec := 0


func _ready() -> void:
	_parse_args()
	Engine.max_fps = max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# What machine is actually drawing: the roadmap's Phase 1, and the first thing any
	# benchmark must state.
	print(DeviceReport.report())
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("gpu crowd: no rendering device (a headless run has nothing to measure)")
		return
	_build()
	if rule_checks:
		_frozen = true
		_run_rule_checks()
		get_tree().quit(0)


func _parse_args() -> void:
	# The environment switch is read first so an explicit command-line argument can override it,
	# the way the rest of the project treats PB_* flags.
	if OS.get_environment("PB_TGT_MODE").to_lower() in ["legacy", "off", "0", "false", "no"]:
		target_legacy = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--agents="):
			agents = maxi(MIN_AGENTS, int(arg.substr(9)))
			_agents_given = true
		elif arg.begins_with("--target-cadence="):
			target_cadence = maxi(1, int(arg.substr(17)))
		elif arg.begins_with("--retention="):
			target_retention = maxf(0.0, float(arg.substr(12)))
		elif arg.begins_with("--tgt-mode="):
			target_legacy = arg.substr(11).to_lower() == "legacy"
		elif arg == "--legacy-targeting":
			target_legacy = true
		elif arg == "--rule-checks":
			rule_checks = true
		elif arg.begins_with("--rule-advance="):
			rule_advance_ticks = maxi(0, int(arg.substr(15)))
		elif arg.begins_with("--ticks-per-frame="):
			ticks_per_frame = maxi(0, int(arg.substr(18)))
		elif arg.begins_with("--tick-hz="):
			tick_hz = maxf(1.0, float(arg.substr(10)))
		elif arg.begins_with("--oblique="):
			# Shifts the enemy's bands down the field by a fraction of a band, so the two sides
			# are not lined up body for body. The bodies then have to turn to face their enemy,
			# which is the only way to see that turning works at all: lined up square, both sides
			# face each other down the x axis already and nothing ever rotates.
			oblique = float(arg.substr(10))
		elif arg.begins_with("--wipe-band="):
			wipe_band = int(arg.substr(12))
		elif arg.begins_with("--wipe-at="):
			wipe_at = int(arg.substr(10))
		elif arg.begins_with("--wipe-fraction="):
			wipe_fraction = clampf(float(arg.substr(16)), 0.0, 1.0)
		elif arg.begins_with("--hold-band="):
			hold_band = int(arg.substr(12))
		elif arg.begins_with("--hold-at="):
			hold_at = int(arg.substr(10))
		elif arg.begins_with("--advance-band="):
			advance_band = int(arg.substr(15))
		elif arg.begins_with("--advance-at="):
			advance_at = int(arg.substr(13))
		elif arg.begins_with("--advance-by="):
			advance_by = float(arg.substr(13))
		elif arg.begins_with("--checksum-every="):
			checksum_every = maxi(0, int(arg.substr(17)))
		elif arg.begins_with("--bodies="):
			# How many formations a side: the size of the battle the player is asked to command.
			bodies_per_side = clampi(int(arg.substr(9)), 1, 30)
		elif arg.begins_with("--per-unit="):
			# How many men stand in one unit. The other half of a battle's size: thirty units of
			# thirty is eighteen hundred men, and thirty units of a hundred is six thousand.
			per_unit = maxi(4, int(arg.substr(11)))
		elif arg == "--thirty":
			# The scale the tests are run at from now on: thirty units a side, thirty men in each.
			bodies_per_side = 30
			per_unit = 30
			if not _agents_given:
				agents = bodies_per_side * 2 * per_unit
		elif arg == "--skirmish":
			# The scale a person can actually command: four formations a side of a hundred and
			# fifty, which is a battle you can pick up and place before it starts.
			bodies_per_side = 4
			if not _agents_given:
				agents = bodies_per_side * 2 * 150
		elif arg.begins_with("--shot-at="):
			# When the screenshot is taken, in seconds. Six is right for a deployment; a battle
			# that has to march into contact first wants longer.
			shot_at = float(arg.substr(10))
		elif arg.begins_with("--unit="):
			unit_type = arg.substr(7)
		elif arg == "--legacy-damage":
			real_strikes = false
		elif arg == "--trace":
			trace_orders = true
		elif arg == "--manual":
			# Autonomy off from the first tick: nothing on the player's side moves until it is
			# told to. The only way to test input honestly.
			_manual = true
		elif arg == "--deploy":
			# Start as a plan rather than a fight: formations are yours to place until Space.
			_deploying = true
		elif arg.begins_with("--at="):
			# A scripted order, in place of a hand on the mouse. See _parse_script.
			_parse_script(arg)
		elif arg.begins_with("--yaw-deg="):
			yaw = deg_to_rad(float(arg.substr(10)))
		elif arg.begins_with("--pitch="):
			squash = clampf(float(arg.substr(8)), PITCH_MIN, PITCH_MAX)
		elif arg.begins_with("--cam-zoom="):
			_zoom_target = clampf(float(arg.substr(11)), ZOOM_MIN, ZOOM_MAX)
		elif arg.begins_with("--cam-at="):
			# A world point to look at, applied once the camera exists; a scripted camera also
			# takes the view out of the fighting's hands, because a test that drifts is not a test.
			var parts := arg.substr(9).split(",")
			if parts.size() == 2:
				cam_at = Vector2(float(parts[0]), float(parts[1]))
				_follow_action = false
		elif arg == "--top-down":
			flat_view = true
		elif arg == "--no-bars":
			draw_bars = false
		elif arg.begins_with("--readback-every="):
			readback_every = maxi(1, int(arg.substr(17)))
		elif arg.begins_with("--max-fps="):
			max_fps = maxi(0, int(arg.substr(10)))
		elif arg.begins_with("--zoom="):
			zoom_factor = maxf(0.1, float(arg.substr(7)))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--out="):
			out_dir = arg.substr(6)
		elif arg.begins_with("--seconds="):
			run_seconds = maxf(0.0, float(arg.substr(10)))
		elif arg.begins_with("--shot-at="):
			shot_at = maxf(0.0, float(arg.substr(10)))


func _build() -> void:
	# The engine imports a .glsl file as an RDShaderFile; a run that has not imported it yet
	# gets null here rather than a silent no-op (run `--import` after touching the shader).
	var shader_file: RDShaderFile = load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		push_error("gpu crowd: %s did not load as an RDShaderFile" % SHADER_PATH)
		return
	var spirv := shader_file.get_spirv()
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		push_error("gpu crowd: shader compile error: %s" % compile_error)
		return
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("gpu crowd: the shader did not compile")
		return
	pipeline = rd.compute_pipeline_create(shader)

	field = _field_for(agents)
	# The field grows to fit the army rather than the army being squeezed into the field: an army
	# of thirty formations needs six hundred units of depth to deploy in, not the hundred and sixty
	# nine the three-legion scene was drawn on. Nothing in the simulation depends on the field's
	# size - it is the ground, and ground is whatever the battle needs.
	var needed_depth := float(bodies_per_side) * BAND_NEEDS
	if field.y < needed_depth:
		field.y = needed_depth
	grid = Vector2i(ceili(field.x / LG_CELL), ceili(field.y / LG_CELL))
	var cells := grid.x * grid.y

	var state := PackedFloat32Array()
	state.resize(agents * 4)
	var meta := PackedFloat32Array()
	meta.resize(agents * 4)
	var attrs := PackedFloat32Array()
	attrs.resize(agents * 4)
	var battle_config := GameManager.config()
	hit_chance = battle_config.get_float("battle.base_hit_chance", 0.75)
	defence_mitigation = battle_config.get_float("battle.defence_mitigation", 0.05)
	_load_unit_stats()
	_deploy(state, meta, attrs)

	buf_state = _storage(state.to_byte_array(), agents * 16)
	buf_push = _storage(PackedByteArray(), agents * 16)
	buf_cursor = _storage(PackedByteArray(), cells * 4)
	buf_slots = _storage(PackedByteArray(), cells * SLOT_CAPACITY * 4)
	# The size of the block the shader is actually handed. It was a remembered constant once, and
	# adding four parameters without adding four to it made every frame fail to build its pipeline:
	# 13,635 errors, a thousand milliseconds a frame, and a tick rate nobody could explain.
	var param_values := _params()
	buf_params = _storage(param_values.to_byte_array(), param_values.size() * 4)
	buf_counters = _storage(PackedByteArray(), COUNTER_SLOTS * 4)
	# What each man carries into the fight, from the game's own unit definitions: attack, defence,
	# the reach of his weapon, and how many ticks pass between his blows.
	buf_stats = _storage(_stats.to_byte_array(), agents * 16)
	buf_meta = _storage(meta.to_byte_array(), agents * 16)
	buf_damage = _storage(PackedByteArray(), agents * 4)
	# Kills, damage dealt and who did for each of the fallen: four uints a man, matching the
	# shader's uvec4 to the byte. The campaign's resolver needs all three to write its result, and
	# this is where a whole battle stops being only a picture and becomes an outcome.
	buf_tallies = _storage(PackedByteArray(), agents * 16)
	# The separation correction being accumulated this round, in fixed-point integers: ivec4 a man.
	buf_corr = _storage(PackedByteArray(), agents * 16)
	buf_attrs = _storage(attrs.to_byte_array(), agents * 16)
	buf_bodies = _storage(_body_state.to_byte_array(), _bodies * 8 * 4)
	# Every soldier starts with nobody remembered and a look phase taken from its own index, so
	# the first look is staggered across the cadence rather than massed on tick one. This is the
	# schedule D-080 requires to be a property of the soldier, not of the moment.
	var targets := PackedInt32Array()
	targets.resize(agents * 4)
	var interval := maxi(1, target_cadence)
	for i in agents:
		targets[i * 4 + 0] = -1
		targets[i * 4 + 1] = i % interval
	buf_targets = _storage(targets.to_byte_array(), agents * 16)
	_tgt_totals.resize(COUNTER_SLOTS)
	_tgt_totals.fill(0)

	var uniforms: Array[RDUniform] = []
	uniforms.append(_uniform(0, buf_state))
	uniforms.append(_uniform(1, buf_push))
	uniforms.append(_uniform(2, buf_cursor))
	uniforms.append(_uniform(3, buf_slots))
	uniforms.append(_uniform(4, buf_params))
	uniforms.append(_uniform(5, buf_counters))
	uniforms.append(_uniform(6, buf_meta))
	uniforms.append(_uniform(7, buf_damage))
	uniforms.append(_uniform(8, buf_attrs))
	uniforms.append(_uniform(9, buf_bodies))
	uniforms.append(_uniform(10, buf_corr))
	uniforms.append(_uniform(11, buf_targets))
	uniforms.append(_uniform(12, buf_stats))
	uniforms.append(_uniform(13, buf_tallies))
	uniform_set = rd.uniform_set_create(uniforms, shader, 0)

	_build_ground()
	_build_view()
	_build_hud()
	_build_help()
	if cam_at != Vector2(INF, INF):
		# A scripted camera looks at a world point named in world terms; the camera lives in
		# picture space, so this is where the two are married.
		_camera.position = _iso(cam_at)
		print("gpu crowd: view | scripted camera at world (%.0f, %.0f), yaw %.0f deg, pitch %.2f, zoom %.2f" % [
			cam_at.x, cam_at.y, rad_to_deg(yaw), squash, _zoom_target])
	else:
		print("gpu crowd: view | %s, yaw %.0f deg, pitch %.2f (right-drag orbits, wheel zooms at the cursor, middle-drag pans, WASD pans, Q/E quarter turn, [ ] tilts, F frames, I toggles flat)" % [
			"flat" if flat_view else "isometric", rad_to_deg(yaw), squash])
	if _deploying:
		_center_on_side(0)
	print("gpu crowd: command | left-click select (shift adds), drag a box, right-click ground to move, right-click an enemy to attack, H hold, U engage, L/C/O line-column-loose, Ctrl+1..5 group, 1..5 recall, Space starts the battle, P pauses" if _deploying else \
			"gpu crowd: command | left-click select (shift adds), drag a box, right-click ground to move, right-click an enemy to attack, H hold, U engage, L/C/O line-column-loose, Ctrl+1..5 group, 1..5 recall, Space follows the fighting, P pauses")
	print("gpu crowd: %d soldiers, %d a side | grid %dx%d (cell %.1f) | field %.0fx%.0f | reach %.1f | blow %.2f/attacker | targeting %s (cadence %d, retention %.0f)" % [
		agents, agents / 2, grid.x, grid.y, LG_CELL, field.x, field.y, REACH, BLOW,
		"legacy" if target_legacy else "acquire/keep/release", target_cadence, target_retention])


## Both armies drawn up the way the battle scene draws them up: ranks and files of a body's
## lattice, inset from their own edge of the field, facing one another.
## Three bodies a side, the way the battle scene draws a legion up: a lattice of files and
## ranks per body, the bodies stacked in bands across the field, each inset from its own
## edge and facing the enemy. Every soldier is told which body he belongs to and which file
## and rank are his; where he stands starts a little off his place, so the ranks dress on the
## way in.
func _deploy(state: PackedFloat32Array, meta: PackedFloat32Array, attrs: PackedFloat32Array) -> void:
	var per_side := agents / 2
	var per_body := ceili(float(per_side) / float(bodies_per_side))
	# Kept, not just local: the pack needs the same band arithmetic the deployment used, or a
	# body's leading edge would be measured from the wrong men.
	_per_side = per_side
	_per_body = per_body
	# The frontage is the line's width, and it has to fit the field: three bodies a side are
	# stacked down the field, so each one gets a third of its height to stand in. Forty files
	# (104 units) is the legion look this scene wants, but at 300 a side the field is a fraction
	# of that, and a body clamped against the field edge reports nonsense - the baseline ladder
	# measured "steps" of 114 units a tick at 600 soldiers because men were being clamped, not
	# marched. So: forty files where they fit, fewer where they do not.
	var band_height := field.y / float(bodies_per_side)
	var files := mini(BODY_FILES, maxi(4, int((band_height - BAND_MARGIN * 2.0) / SEPARATION)))
	# The line's width, remembered: a formation the player re-forms into a column and back into a
	# line has to become the line it was, which means keeping the width it was deployed with.
	_line_files = files
	var ranks := ceili(float(per_body) / float(files))
	var depth := float(ranks - 1) * SEPARATION
	var frontage := float(files - 1) * SEPARATION
	# How far apart the bodies stand: their own frontage plus a margin to fight in, but never
	# more than a third of the field each - at small sizes "frontage + 20" pushed the outer two
	# bodies off the field edge, and the first tick then dragged their men back inside (measured:
	# a 49-unit "step" at tick 1 on a 600-soldier run).
	var band := minf(frontage + 20.0, field.y / float(bodies_per_side))
	var inset := field.x * 0.12
	# The oblique demo shifts the two sides apart in y so their bodies have to turn to face each
	# other. Taken out of whatever slack the field has left rather than added on top: the bands
	# already fill most of its height, and a shift that pushed men past the edge would be measured
	# as a deployment fault (a 27-unit first-tick drag) rather than the turn it is meant to show.
	var slack := maxf(0.0, field.y - ((bodies_per_side - 1) * band + frontage)) * 0.5
	_bodies = bodies_per_side * 2
	_body_side.resize(_bodies)
	_body_state.resize(_bodies * 8)
	_heading.resize(_bodies)
	_order.resize(_bodies)
	_order_target.resize(_bodies)
	_order_point.resize(_bodies)
	_body_alive.resize(_bodies)
	_body_cohesion.resize(_bodies)
	_hold_ordered.resize(_bodies)
	for b in _bodies:
		_body_side[b] = b / bodies_per_side
		_body_alive[b] = 0
		_hold_ordered[b] = 0
	for b in _bodies:
		# Every body starts with an order to engage and no target: the first tick picks one. The
		# reference gives its formations orders at the start of a battle too, and a body with no
		# target and an engage order is exactly what "march until you meet someone" is made of.
		_order[b] = Order.ENGAGE
		_order_target[b] = -1
		_order_point[b] = Vector2.ZERO
	for b in _bodies:
		var side := b / bodies_per_side
		var band_index := b % bodies_per_side
		var centre_y := field.y * 0.5 + (float(band_index) - float(bodies_per_side - 1) * 0.5) * band
		if side == 1:
			centre_y += oblique * slack
		else:
			centre_y -= oblique * slack
		var dir := 1.0 if side == 0 else -1.0
		# Both sides start facing each other down the field's x axis; the turn comes later, when
		# there is an enemy to face.
		_heading[b] = 0.0 if side == 0 else PI
		var forward := Vector2(cos(_heading[b]), sin(_heading[b]))
		_body_state[b * 8 + 0] = inset if side == 0 else field.x - inset
		_body_state[b * 8 + 1] = centre_y
		_body_state[b * 8 + 2] = forward.x
		_body_state[b * 8 + 3] = forward.y
		_body_state[b * 8 + 4] = float(files)
		_body_state[b * 8 + 5] = float(ranks)
		_body_state[b * 8 + 6] = SEPARATION
		_body_state[b * 8 + 7] = 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_man_body.resize(agents)
	_man_file.resize(agents)
	_man_rank.resize(agents)
	for i in agents:
		var side := 0 if i < per_side else 1
		var within := i % per_side
		var band_index := mini(bodies_per_side - 1, within / per_body)
		var in_body := within % per_body
		var file := in_body % files
		var rank := in_body / files
		var b := side * bodies_per_side + band_index
		var heading := Vector2(_body_state[b * 8 + 2], _body_state[b * 8 + 3])
		var right := Vector2(-heading.y, heading.x)
		var anchor := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
		# The same construct the shader uses for a man's place in the line: files across the
		# frontage, ranks back along the heading, both measured from the body's anchor. Deploying
		# any other way would leave the men walking to their places before the battle even starts.
		var place := anchor \
			+ right * ((float(file) - float(files - 1) * 0.5) * SEPARATION) \
			+ heading * ((float(rank) - float(ranks - 1) * 0.5) * SEPARATION)
		state[i * 4 + 0] = place.x + rng.randf_range(-JITTER, JITTER)
		state[i * 4 + 1] = place.y + rng.randf_range(-JITTER, JITTER)
		meta[i * 4 + 0] = hp_max
		meta[i * 4 + 1] = float(side)
		attrs[i * 4 + 0] = float(b)
		attrs[i * 4 + 1] = float(file)
		attrs[i * 4 + 2] = float(rank)
		_man_body[i] = b
		_man_file[i] = file
		_man_rank[i] = rank
		# How many men each body actually deployed with: the first tick's target selection reads
		# this before the first pack has run, and a body wrongly believed empty would make every
		# body on the field stand down on tick one.
		_body_alive[b] += 1
	# Audit the deployment itself: a man whose place is outside the field gets dragged back inside
	# by the first tick, which the proof run then reports as a "step" tens of units long. Cheaper
	# to catch here than to chase through the shader.
	var outside := 0
	var worst := Vector2.ZERO
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in agents:
		var px := state[i * 4 + 0]
		var py := state[i * 4 + 1]
		lo = Vector2(minf(lo.x, px), minf(lo.y, py))
		hi = Vector2(maxf(hi.x, px), maxf(hi.y, py))
		if px < 0.0 or px > field.x or py < 0.0 or py > field.y:
			outside += 1
			worst = Vector2(maxf(absf(px - clampf(px, 0.0, field.x)), worst.x),
				maxf(absf(py - clampf(py, 0.0, field.y)), worst.y))
	print("gpu crowd: deployed %d men, extent x %.1f..%.1f y %.1f..%.1f, field %s, outside %d (worst pull %.1f, %.1f)" % [
		agents, lo.x, hi.x, lo.y, hi.y, str(field), outside, worst.x, worst.y])
	print("gpu crowd: %d bodies a side, %d files x %d ranks each (%d a body), spacing %.1f, depth %.0f" % [
		bodies_per_side, files, ranks, per_body, SEPARATION, depth])


## How much room a body's living men have before they are standing on the enemy - measured as the
## distance from its men to the nearest living enemy anywhere, straight from the shader, which
## already takes exactly that measurement every tick.
##
## [b]Why not the leading man's x[/b]: that was the first version of this rule, and it deadlocked
## the battle. Two bodies' leading men can sit in different bands down the field, so comparing
## their x read as "2.3 apart, no room" while the nearest real enemy pair stood 3.52 away - past
## the 3.4 reach. Nobody could fight and nobody could close: 228 dead, then two lines staring at
## each other for ever.
	# A deployment is a plan, not a press: every body stands where it was put until the player
	# says go. Without this the formations advance and start killing each other while the player
	# is still deciding, which is both a bad battle and a bad test of one - measured, the
	# deployment screen was already landing 2,200 blows a second.
	if _deploying:
		for b in _bodies:
			# An *ordered* hold, not the other kind: a body that is merely holding because it has
			# nothing to fight stands up again the moment an enemy appears, which is how the
			# deployment screen came to be landing blows while the player was still placing men.
			_order[b] = Order.HOLD
			_hold_ordered[b] = 1

func _body_room(b: int) -> float:
	if _body_gap.size() < _bodies:
		return 9999.0
	return _body_gap[b]


func _side_of_body(b: int) -> int:
	if b >= 0 and b < _body_side.size():
		return _body_side[b]
	# The body's own recorded side - not arithmetic on bodies_per_side, which is a *layout* number
	# for the developer scene's bands and says nothing about a campaign field, where one side may
	# have several bodies and the sides are not the same size. This exact line, left as arithmetic,
	# made every body from b=1 up read as the enemy: a campaign battle built from two defending
	# bodies and one attacking one resolved in four ticks with one side "empty" and nobody dead.
	if b >= 0 and b < _body_side.size():
		return _body_side[b]
	return 0


## The bodies, once a tick. Six little bodies on the CPU; the shader does the thousand men each of
## them owns.
##
## One rule holds the whole thing together: [b]a body advances only while its living men still have
## room ahead of them[/b]. The anchors are what every man's place in the line hangs off, so marching
## an anchor into the enemy walks that body's rear ranks forward for ever and squeezes the front
## ranks into each other, however well the separation itself is solved. Measured on the proof run
## before this rule: the front settled at a 1.59-unit gap where the agreed minimum is 2.47.
##
## The same rule is what unseats a stalemate: when the enemy's front rank falls, the enemy's living
## edge steps back, room opens, and the body leans in again - the corpse-gap advance, but driven by
## where the men actually stand rather than by a timer.
## The name a body is known by in the logs: P for the player's side, E for the enemy's, then the
## band down the field. Used by every diagnostic line so a human can follow one body through.
func _body_name(b: int) -> String:
	var ordinal := 0
	for other in b:
		if _side_of_body(other) == _side_of_body(b):
			ordinal += 1
	return "%s%d" % ["P" if _side_of_body(b) == 0 else "E", ordinal]


## A body changing its mind about who it is fighting is a rare, reviewable event, so it is printed
## the moment it happens rather than left to be inferred from a later diagnostic line.
func _note_switch(text: String) -> void:
	_target_switches += 1
	_last_switch = text
	print("gpu crowd: target switch | %s" % text)


## Destroy an enemy body - or a fraction of it, when a rule check needs survivors nearby - at a
## tick the caller chooses. This is how target reassignment is tested: the body that was fighting
## it must pick a new enemy within a few ticks and carry on, and if it cannot, that is a defect
## rather than something to discover in a real campaign. A whole-body wipe (`fraction` = 1) is the
## scripted event the order tests use; the acquisition rule check passes 0.5 so that the men who
## lose an opponent still have a living enemy in the local window to find.
func _wipe_body(band: int, fraction: float = 1.0, stripe: bool = false) -> void:
	_wiped = true
	var target_body := bodies_per_side + band
	var data := _meta_bytes.to_float32_array()
	var living := PackedInt32Array()
	for i in agents:
		if _man_body[i] == target_body and data[i * 4 + 2] < 0.5:
			living.append(i)
	var killed := 0
	if stripe:
		# Every other living man, from the front backwards. The men left standing are the
		# neighbours a bereaved hunter can find at once, which is the case the rule is about.
		for k in range(living.size() - 1, -1, -2):
			var i := living[k]
			data[i * 4 + 0] = 0.0
			data[i * 4 + 2] = 1.0
			killed += 1
	else:
		var want := living.size() if fraction >= 1.0 else int(ceil(float(living.size()) * clampf(fraction, 0.0, 1.0)))
		# The front rank is the *highest* rank, and agent index runs up files fastest then ranks, so
		# the last indices are the men facing the enemy. A partial wipe takes those, which are the
		# men a hunter is likely to be remembering; a whole-body wipe takes everyone regardless.
		for k in range(living.size() - 1, maxi(-1, living.size() - 1 - want), -1):
			var i := living[k]
			data[i * 4 + 0] = 0.0
			data[i * 4 + 2] = 1.0
			killed += 1
	_meta_bytes = data.to_byte_array()
	rd.buffer_update(buf_meta, 0, _meta_bytes.size(), _meta_bytes)
	print("gpu crowd: scripted | %s destroyed at tick %d, %d of %d men - whoever was fighting it must find someone else" % [
		_body_name(target_body), _tick, killed, living.size()])


## Order the player's body in this band to hold, at a tick the caller chooses, so advance and hold
## can be compared in one run: two bodies lean in, one does not, and the anchors say which.
func _hold_body(band: int) -> void:
	_held = true
	_order[band] = Order.HOLD
	_hold_ordered[band] = 1
	print("gpu crowd: scripted | %s ordered to hold at tick %d" % [_body_name(band), _tick])


## Order the player's body in this band to advance a fixed distance straight ahead of where it
## stands, at a tick the caller chooses. The order should carry it exactly that far and then let
## it go - arrival is measured against the point that was given, not against "it looks right".
func _advance_body(band: int, distance: float) -> void:
	_advanced = true
	var b := band
	var forward := Vector2(cos(_heading[b]), sin(_heading[b]))
	var from := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
	_order[b] = Order.ADVANCE
	_order_point[b] = from + forward * distance
	print("gpu crowd: scripted | %s ordered to advance %.0f to (%.0f, %.0f) at tick %d" % [
		_body_name(b), distance, _order_point[b].x, _order_point[b].y, _tick])


## Where this body is fighting, as an index, or -1: what the reassignment tests read.
func _select_target(b: int) -> void:
	var side := _side_of_body(b)
	var mine := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
	var best := -1
	var best_distance := INF
	for other in _bodies:
		if _side_of_body(other) == side:
			continue
		if _body_alive[other] <= 0:
			continue
		var distance := mine.distance_to(
			Vector2(_body_state[other * 8 + 0], _body_state[other * 8 + 1]))
		if distance < best_distance:
			best_distance = distance
			best = other
	var current := _order_target[b]
	if best == -1:
		# Nothing left to fight. A body ordered to hold stays held; any other body stands.
		if _order[b] != Order.HOLD:
			_order[b] = Order.HOLD
			_order_target[b] = -1
			_note_switch("%s: no enemy left standing" % _body_name(b))
		return
	if current >= 0 and current != best and _body_alive[current] > 0:
		var current_distance := mine.distance_to(
			Vector2(_body_state[current * 8 + 0], _body_state[current * 8 + 1]))
		if current_distance <= best_distance * RETENTION:
			return
		_note_switch("%s: %s -> %s at tick %d (%.1f better than %.1f)" % [
			_body_name(b), _body_name(current), _body_name(best), _tick, best_distance, current_distance])
	elif current >= 0 and _body_alive[current] <= 0:
		_note_switch("%s: target %s destroyed at tick %d -> %s (%.1f away)" % [
			_body_name(b), _body_name(current), _tick, _body_name(best), best_distance])
	_order_target[b] = best
	if _order[b] == Order.HOLD and _hold_ordered[b] == 0:
		# It was only standing because it had nothing to fight. Now it has.
		_order[b] = Order.ENGAGE


## Where a body should be looking: at the target it selected. Zero when there is nothing left to
## face, in which case the body keeps whatever heading it had.
func _aim_for(b: int) -> Vector2:
	var target := _order_target[b]
	if target < 0 or _body_alive[target] <= 0:
		return Vector2.ZERO
	var mine := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
	var theirs := Vector2(_body_state[target * 8 + 0], _body_state[target * 8 + 1])
	var away := theirs - mine
	if away.length() < 0.001:
		return Vector2.ZERO
	return away.normalized()


func _advance_bodies() -> void:
	for b in _bodies:
		var side := _side_of_body(b)
		# Who are we fighting, if anyone? One selection a tick, retained until it is destroyed or
		# clearly beaten, and it is what the facing and the engagement below are driven by.
		_select_target(b)
		# Face the target, no faster than a body can turn. Every man's place in the line is built
		# from this vector, so the whole lattice - and the dressing - swings with it. A deployment
		# is the one time a body keeps the facing it was given: a formation that turns itself while
		# the player is still placing it is the formation making a decision for him.
		var aim := _aim_for(b) if not _deploying else Vector2.ZERO
		if aim != Vector2.ZERO:
			var want := wrapf(aim.angle() - _heading[b], -PI, PI)
			_heading[b] += clampf(want, -TURN_RATE * DT, TURN_RATE * DT)
		var forward := Vector2(cos(_heading[b]), sin(_heading[b]))
		_body_state[b * 8 + 2] = forward.x
		_body_state[b * 8 + 3] = forward.y
		var mine := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
		if _body_state[b * 8 + 7] < 0.5:
			var depth := (_body_state[b * 8 + 5] - 1.0) * SEPARATION
			for other in _bodies:
				if _side_of_body(other) == side:
					continue
				var other_depth := (_body_state[other * 8 + 5] - 1.0) * SEPARATION
				# Bodies are metres apart in both axes now that they can face any way, so the
				# engagement test is a real distance between anchors, not a difference in x.
				var gap := mine.distance_to(
					Vector2(_body_state[other * 8 + 0], _body_state[other * 8 + 1])) \
					- (depth + other_depth) * 0.5
				if gap <= CONTACT:
					_body_state[b * 8 + 7] = 1.0
					break
		# Now the order. A body that has stopped leans at the press rate, a walking body at the
		# walk rate - and only while nobody is in reach of its men, so the anchors never march the
		# rear ranks into a crush. In reach means there is a fight to have; out of reach means the
		# front has cleared (the fallen took it with them) and the body leans in until it finds the
		# enemy again. That is the game's own anti-stalemate rule with the gap measured, not assumed.
		var rate := PRESS if _body_state[b * 8 + 7] > 0.5 else WALK
		var move := Vector2.ZERO
		match _order[b]:
			Order.HOLD:
				pass
			Order.ADVANCE:
				var to_point := _order_point[b] - mine
				var remaining := to_point.length()
				if remaining <= ARRIVED:
					_order[b] = Order.HOLD
					_hold_ordered[b] = 1
					print("gpu crowd: scripted | %s arrived at (%.0f, %.0f) on tick %d and holds there" % [
						_body_name(b), mine.x, mine.y, _tick])
				else:
					move = (to_point / remaining) * minf(remaining, rate * DT)
			Order.ENGAGE:
				if _body_room(b) > ENGAGE:
					move = forward * (rate * DT)
		if move != Vector2.ZERO:
			mine += move
			_body_state[b * 8 + 0] = mine.x
			_body_state[b * 8 + 1] = mine.y
	rd.buffer_update(buf_bodies, 0, _body_state.to_byte_array().size(), _body_state.to_byte_array())


## One tick: clear the grid, the blow tally and the correction, rebuild the grid, probe every
## neighbour (damage, contact, the collision proof), walk and take the blows, then settle the
## separation over three rounds of accumulate-and-apply. Every pass that reads what the last one
## wrote gets a barrier between them.
##
## The settling comes last on purpose: the final positions of the tick are the separated ones, so
## no soldier can end a tick standing inside another, however the walk happened to fall. And each
## round is two passes - accumulate, then apply - because a round that read its neighbours while
## writing its own position made every run of the same battle come out differently.
func _run_tick() -> void:
	# The cadence reads the simulation tick, so the params buffer is refreshed before every
	# dispatch. It is one buffer write a tick and it is what makes the schedule deterministic:
	# no wall clock is ever read to decide when a soldier looks.
	var params_bytes := _params().to_byte_array()
	rd.buffer_update(buf_params, 0, params_bytes.size(), params_bytes)
	var cl := rd.compute_list_begin()
	var groups_agents := (agents + WORKGROUP - 1) / WORKGROUP
	var cells := grid.x * grid.y
	# The clear pass covers the grid cursors, the agents' blow tally and correction, and the
	# counter block that follows them - hence agents + COUNTER_SLOTS, not agents + 4: too few
	# threads and the counter block's tail is never reset, which quietly turns every "this tick"
	# figure into a running total. Two fewer and the anchors would never be told the front had
	# cleared.
	var clear_threads := maxi(cells, agents + COUNTER_SLOTS)
	var groups_clear := (clear_threads + WORKGROUP - 1) / WORKGROUP
	for mode in 4:
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
		rd.compute_list_set_push_constant(cl, _push_constant(mode), 16)
		rd.compute_list_dispatch(cl, groups_clear if mode == 0 else groups_agents, 1, 1)
		rd.compute_list_add_barrier(cl)
	for round in settle_rounds():
		for mode in [4, 5]:
			rd.compute_list_bind_compute_pipeline(cl, pipeline)
			rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
			rd.compute_list_set_push_constant(cl, _push_constant(mode), 16)
			rd.compute_list_dispatch(cl, groups_agents, 1, 1)
			rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	# The tick counter moves here, once per tick, so the awareness schedule is a function of the
	# simulation tick and not of how many ticks a frame happened to run. Advancing it per frame
	# instead let several ticks in one frame share a tick number, which made the battle depend on
	# the frame rate.
	_tick += 1


func _process(delta: float) -> void:
	if not pipeline.is_valid():
		return
	var started := Time.get_ticks_usec()
	var ticks_now := 0
	if not _frozen and not _clock_paused:
		if ticks_per_frame > 0:
			for i in ticks_per_frame:
				_advance_bodies()
				_run_tick()
			ticks_now = ticks_per_frame
		else:
			# The game's own clock: a fixed step, however fast the frame is drawn. The
			# budget stops a machine that has been asleep from trying to catch up in one
			# frame and hitching.
			_tick_accumulator += delta
			var step := 1.0 / maxf(1.0, tick_hz)
			var budget := 8
			while _tick_accumulator >= step and budget > 0:
				_advance_bodies()
				_run_tick()
				_tick_accumulator -= step
				budget -= 1
				ticks_now += 1
	# The tick loop's own cost, measured before anything this frame does with the result.
	_tick_usec = Time.get_ticks_usec() - started
	# `_tick` itself is advanced by the tick, inside `_run_tick`, so it is the simulation's clock
	# and not the frame's.
	_ticks_window += ticks_now
	# Scripted events for the order tests, fired at fixed ticks so a run is repeatable: a body
	# destroyed outright (does its enemy find a new one?), or a body ordered to hold (does it stop
	# while its neighbours lean in?).
	if not _frozen:
		if wipe_band >= 0 and not _wiped and _tick >= wipe_at:
			_wipe_body(wipe_band, wipe_fraction)
		if hold_band >= 0 and not _held and _tick >= hold_at:
			_hold_body(hold_band)
		if advance_band >= 0 and not _advanced and _tick >= advance_at:
			_advance_body(advance_band, advance_by)
		# Orders from the scripted list, fired at their tick. They go through the same functions
		# the mouse calls, so a scripted order is not a second implementation of an order.
		_apply_scripted_input()
	# The picture is rebuilt on the simulation's clock, not the frame's: the frame rate is the
	# renderer's business and repacking an unchanged army on every frame is work with no result.
	if ticks_now > 0:
		_readback_counter += ticks_now
		_track_proof()
		if checksum_every > 0 and _tick / checksum_every != _last_checksum_tick:
			_last_checksum_tick = _tick / checksum_every
			print("gpu crowd: checksum | %s" % _checksums())
	if _readback_counter >= maxi(1, readback_every):
		_readback_counter = 0
		_readback_and_pack()
		_update_marks()
		if not _frozen and (_alive.x == 0 or _alive.y == 0):
			_freeze()

	_frame_delta += delta
	_frames += 1
	_elapsed += delta
	if _frame_delta >= 0.5:
		_report()
		_reports += 1
		if _reports % 5 == 0:
			_report_bodies()
		_frame_delta = 0.0
		_frames = 0
	_update_camera(delta)
	if _shot_taken == 0 and _elapsed > shot_at:
		_shot_taken = 1
		_save_shot(_shot_taken)
	elif _shot_taken == 1 and _elapsed > 45.0:
		_shot_taken = 2
		_save_shot(_shot_taken)
	if run_seconds > 0.0 and _elapsed >= run_seconds and not _reported:
		_reported = true
		var counters := rd.buffer_get_data(buf_counters).to_int32_array()
		print("gpu crowd: final | %d soldiers | ticks %d | blows %d | fallen %d | overflow %d" % [
			agents, _tick, counters[2], counters[3], counters[0]])
		print("gpu crowd: collision proof | %s" % _proof_line())
		# The outcome side of the same reading: every kill the tallies credit must be a man who
		# actually fell, or the campaign would be told a story the field does not support.
		var fallen := _fallen
		# w, not z: z is *this tick's* attacker and is cleared every tick by design, so a man
		# who fell long ago reads -1 there. The killer's id is kept in w.
		var attributed := 0
		for i in agents:
			if tally(i).w >= 0:
				attributed += 1
		print("gpu crowd: outcome | fallen %d, kills credited %d, attributed %d | damage dealt %d hundredths" % [
			fallen, kills_credited(), attributed, _damage_dealt_total()])
		get_tree().quit(0)


## The battle is over when a side has nobody left: the winner and the butcher's bill go on the
## panel in words, which is what the game's own results screen does.
func _freeze() -> void:
	_frozen = true
	if _alive.x > 0:
		_verdict = "VICTORY   %d survivors   %d fallen" % [_alive.x, _fallen]
	else:
		_verdict = "DEFEAT   %d survivors   %d fallen" % [_alive.y, _fallen]
	print("gpu crowd: battle resolved: %s (ticks %d)" % [_verdict, _tick])


## The audit's item 1, taken on every tick the simulation advances: the closest enemy gap
## anywhere on the field, how many pairs are inside the agreed minimum, the furthest step anyone
## took, and how many men the grid could not hold. A single sampled readback cannot support a
## collision claim, so this runs on every tick and keeps the worst of the run.
func _track_proof() -> void:
	var counters := rd.buffer_get_data(buf_counters).to_int32_array()
	if counters.size() < 8:
		return
	# 4294967295 comes back as -1: nothing was measured this tick, which is not a gap of zero.
	if counters[5] >= 0:
		var gap := float(counters[5]) / 1000.0
		if gap < _worst_gap:
			_worst_gap = gap
			_worst_gap_tick = _tick
	_violations += counters[7]
	# The per-body nearest-enemy distances, as measured by the shader this tick. A sentinel
	# (nothing seen) reads as "no enemy anywhere near", which is exactly how a body with no men
	# left, or a body opposite a wiped-out enemy, should behave: walk on.
	if counters.size() >= BODY_GAP_BASE + _bodies:
		var gaps := PackedFloat32Array()
		gaps.resize(_bodies)
		for b in _bodies:
			gaps[b] = 9999.0 if counters[BODY_GAP_BASE + b] < 0 else float(counters[BODY_GAP_BASE + b]) / 1000.0
		_body_gap = gaps
	var step := float(counters[6]) / 1000.0
	if step > 2.0 and not _step_reported:
		# A "step" this big is not a walk: the cap on both the walk and the correction is 0.6.
		# It has always meant a man was dragged back inside the field from outside it, which is a
		# deployment-scale problem, not a solver one - so say when it first happens.
		_step_reported = true
		print("gpu crowd: first oversized step %.2f at tick %d" % [step, _tick])
	_max_step = maxf(_max_step, step)
	_dropped_max = maxi(_dropped_max, counters[0])
	# The target counters are per-tick like the rest of the block; the report quotes totals, so
	# they are summed here, where the block has just been read for the collision proof anyway.
	if _tgt_totals.size() < COUNTER_SLOTS:
		_tgt_totals.resize(COUNTER_SLOTS)
	for k in range(CNT_ACQUISITIONS, COUNTER_SLOTS):
		_tgt_totals[k] += counters[k]


func _proof_line() -> String:
	return "closest enemy gap %.2f (tick %d)   below %.2f: %d   furthest step %.2f   dropped %d" % [
		_worst_gap, _worst_gap_tick, MIN_ENEMY_GAP, _violations, _max_step, _dropped_max]


## The order a body is under, as a word, for the diagnostic line.
func _order_name(o: int) -> String:
	return ["HOLD", "ADVANCE", "ENGAGE"][o] if o >= 0 and o <= Order.ENGAGE else "?"


## Print the six bodies: order and target, men still standing and how tightly they hold their
## places, where the anchor is, and which way it faces. Six lines every few seconds is cheap, and
## when a body stops advancing or changes its mind this says why in one look.
func _report_bodies() -> void:
	if _body_front.size() < _bodies or _body_state.size() < _bodies * 8:
		return
	var parts := PackedStringArray()
	for b in _bodies:
		var target := _order_target[b]
		var aiming := "target --"
		if target >= 0 and _body_alive[target] > 0:
			var away := Vector2(_body_state[target * 8 + 0], _body_state[target * 8 + 1]) \
				- Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
			var error := rad_to_deg(absf(wrapf(away.angle() - _heading[b], -PI, PI)))
			aiming = "target %s %.0f away, facing error %.0f deg" % [
				_body_name(target), away.length(), error]
		parts.append("%s %-7s alive %4d coh %.2f  %s  anchor %.0f,%.0f facing %.0f" % [
			_body_name(b), _order_name(_order[b]), _body_alive[b], _body_cohesion[b],
			aiming, _body_state[b * 8 + 0], _body_state[b * 8 + 1], rad_to_deg(_heading[b])])
	print("gpu crowd: bodies | %s" % " | ".join(parts))
	# What each body's living soldiers are actually engaging, by enemy body: the acquisition
	# rule's effect on the fight, printed beside the body-level target selection above. In
	# legacy mode the shader remembers nobody, so every body reads as engaging nobody.
	var engaging := PackedStringArray()
	for b in _bodies:
		var against := PackedStringArray()
		for e in _bodies:
			if _side_of_body(e) == _side_of_body(b):
				continue
			var engaged := _target_engage[b * _bodies + e] if _target_engage.size() >= _bodies * _bodies else 0
			if engaged > 0:
				against.append("%s %d" % [_body_name(e), engaged])
		engaging.append("%s -> %s" % [
			_body_name(b), " ".join(against) if not against.is_empty() else "nobody"])
	print("gpu crowd: engaging | %s" % " | ".join(engaging))


## The target-acquisition figures: acquisitions, retentions, re-searches and releases, summed
## over the run, with the average look rate they add up to. Printed every report beside the
## performance line. In legacy mode the acquisition path never runs and the counters stay zero.
func _report_targeting() -> void:
	if target_legacy:
		print("gpu crowd: targeting | legacy: every enemy neighbour inside reach is struck, no opponent is remembered")
		return
	var ticks := maxi(1, _tick)
	var looks := _tgt_totals[CNT_SCHEDULED] + _tgt_totals[CNT_IMMEDIATE]
	print("gpu crowd: targeting | acquisitions %d | retentions %d | re-searches %d | releases %d | immediate %d | switches %d | empty looks %d | looks/tick %.0f | %.3f looks per soldier-tick" % [
		_tgt_totals[CNT_ACQUISITIONS], _tgt_totals[CNT_RETENTIONS], _tgt_totals[CNT_RE_SEARCHES],
		_tgt_totals[CNT_RELEASES_FAR], _tgt_totals[CNT_IMMEDIATE], _tgt_totals[CNT_SWITCHES],
		_tgt_totals[CNT_EMPTY], float(looks) / float(ticks),
		float(looks) / float(maxi(1, agents) * ticks)])


## ---------- rule checks ----------------------------------------------------
## The acquisition rules run through the live GPU simulation and printed as PASS/FAIL. This scene
## cannot run headless - it simulates on the rendering device - so a headless suite cannot cover
## the GPU copy of the rules; the reference's own `tests/test_target_acquisition.gd` pins the same
## rules headlessly on the CPU path, and this is the honest GPU-side counterpart. It is a
## development probe: run it with `--rule-checks` and it quits when it is done.

## One tick the way the frame loop drives it, with the readback the rule checks inspect.
func _sim_step_rules() -> void:
	_advance_bodies()
	_run_tick()
	_track_proof()
	_readback_and_pack()


func _any_body_engaged() -> bool:
	for b in _bodies:
		if _body_state[b * 8 + 7] > 0.5:
			return true
	return false


## One soldier's remembered opponent, read straight from the GPU buffer so the checks can see the
## authoritative answer rather than the last packed diagnostic.
func _read_target_of(index: int) -> int:
	var arr := rd.buffer_get_data(buf_targets).to_int32_array()
	return arr[index * 4 + 0] if arr.size() >= index * 4 + 4 else -1


## Stage a solitary pair on the GPU: every other soldier is marked fallen, the two are placed at
## the given distance apart, and the first remembers the second with a look due immediately. Used
## by the release and hysteresis checks, which must see one opponent and no crowd.
func _stage_solitary(s: int, a: int, base: Vector2, distance: float) -> void:
	var meta := rd.buffer_get_data(buf_meta)
	var marr := meta.to_float32_array()
	for i in agents:
		marr[i * 4 + 2] = 1.0
		marr[i * 4 + 0] = 100.0
	marr[s * 4 + 2] = 0.0
	marr[a * 4 + 2] = 0.0
	meta = marr.to_byte_array()
	rd.buffer_update(buf_meta, 0, meta.size(), meta)
	var state := rd.buffer_get_data(buf_state)
	var sarr := state.to_float32_array()
	sarr[s * 4 + 0] = base.x
	sarr[s * 4 + 1] = base.y
	sarr[a * 4 + 0] = base.x + distance
	sarr[a * 4 + 1] = base.y
	state = sarr.to_byte_array()
	rd.buffer_update(buf_state, 0, state.size(), state)
	var tg := rd.buffer_get_data(buf_targets)
	var tarr := tg.to_int32_array()
	for i in agents:
		tarr[i * 4 + 0] = -1
		tarr[i * 4 + 1] = 0
	tarr[s * 4 + 0] = a
	tg = tarr.to_byte_array()
	rd.buffer_update(buf_targets, 0, tg.size(), tg)


## The same staging for three soldiers: s remembers a, while b stands somewhere else. No other
## soldier is alive, so the local search can only answer with those two.
func _stage_trio(s: int, a: int, b: int, base: Vector2, a_dist: float, b_dist: float) -> void:
	var meta := rd.buffer_get_data(buf_meta)
	var marr := meta.to_float32_array()
	for i in agents:
		marr[i * 4 + 2] = 1.0
		marr[i * 4 + 0] = 100.0
	marr[s * 4 + 2] = 0.0
	marr[a * 4 + 2] = 0.0
	marr[b * 4 + 2] = 0.0
	meta = marr.to_byte_array()
	rd.buffer_update(buf_meta, 0, meta.size(), meta)
	var state := rd.buffer_get_data(buf_state)
	var sarr := state.to_float32_array()
	sarr[s * 4 + 0] = base.x
	sarr[s * 4 + 1] = base.y
	sarr[a * 4 + 0] = base.x + a_dist
	sarr[a * 4 + 1] = base.y
	sarr[b * 4 + 0] = base.x + b_dist
	sarr[b * 4 + 1] = base.y
	state = sarr.to_byte_array()
	rd.buffer_update(buf_state, 0, state.size(), state)
	var tg := rd.buffer_get_data(buf_targets)
	var tarr := tg.to_int32_array()
	for i in agents:
		tarr[i * 4 + 0] = -1
		tarr[i * 4 + 1] = 0
	tarr[s * 4 + 0] = a
	tg = tarr.to_byte_array()
	rd.buffer_update(buf_targets, 0, tg.size(), tg)


func _run_rule_checks() -> void:
	print("gpu crowd: rule checks | mode %s | cadence %d | retention %.0f | search %.0f | immediate %s" % [
		"legacy" if target_legacy else "targeting", target_cadence, target_retention,
		target_search_radius, str(target_immediate)])
	# The schedule before any tick: phases taken from the soldier's own index must be spread
	# across the cadence rather than massed on one tick. See D-080.
	var phases := PackedInt32Array()
	phases.resize(maxi(1, target_cadence))
	for i in agents:
		phases[i % maxi(1, target_cadence)] += 1
	print("gpu crowd: rule | staggering: initial look phases over %d soldiers = %s" % [agents, str(phases)])

	var advance := rule_advance_ticks
	if advance <= 0:
		advance = int((field.x - field.x * 0.24) / (WALK * DT * 2.0)) + 240
	for i in advance:
		_sim_step_rules()
		if _alive.x > 0 and _alive.y > 0 and _any_body_engaged():
			break
	print("gpu crowd: rule | lines met after %d ticks, alive %d v %d" % [_tick, _alive.x, _alive.y])
	for i in 60:
		_sim_step_rules()
	if target_legacy:
		print("gpu crowd: rule checks | SKIPPED: target acquisition is off in legacy mode")
		return
	_check_retention()
	_check_wipe()
	_check_release()
	_check_hysteresis()
	print("gpu crowd: rule checks | done at tick %d" % _tick)


## An opponent that is alive and inside the soldier's reach is kept, and no scheduled look replaces
## it with a neighbour. The check reads the remembered opponent from the GPU buffer each tick and
## only counts a soldier whose previous opponent is still alive and still in reach.
func _check_retention() -> void:
	var previous := _targets.duplicate()
	var expected := 0
	var kept := 0
	var needless := 0
	for tick in 120:
		_sim_step_rules()
		var meta := _meta_bytes.to_float32_array()
		var pos := _state_bytes.to_float32_array()
		for i in agents:
			var t: int = previous[i]
			if t < 0 or t >= agents:
				continue
			if meta[i * 4 + 2] > 0.5 or meta[t * 4 + 2] > 0.5:
				continue
			var dx := pos[i * 4] - pos[t * 4]
			var dy := pos[i * 4 + 1] - pos[t * 4 + 1]
			if dx * dx + dy * dy > REACH * REACH:
				continue
			expected += 1
			if _targets[i] == t:
				kept += 1
			else:
				needless += 1
		previous = _targets.duplicate()
	var verdict := "PASS" if needless == 0 else "FAIL"
	print("gpu crowd: rule | acquisition kept while alive and in reach: %s (%d soldier-ticks with an in-reach live opponent, %d kept, %d needless changes)" % [
		verdict, expected, kept, needless])


## A stripe of an enemy body's front rank is destroyed and the men hunting it watched. The hard
## rule is the reference's: a remembered opponent must not survive a bereaved soldier's tick, and a
## soldier whose opponent was in reach must replace it rather than stand over the corpse. Out-of-
## reach losses are reported rather than required to resolve within the cadence, because the GPU's
## search is the local window (two rungs, about nine units) and not the reference's escalating
## ladder to 32: a soldier that lost an opponent which was never local has nobody to find until one
## arrives. The stripe is the scenario's own extension of `--wipe-band`: killing every other man
## leaves each bereaved hunter a living neighbour, which is the case the rule is actually about.
func _check_wipe() -> void:
	var wiped_body := bodies_per_side + 1
	var hunters := PackedInt32Array()
	var old := PackedInt32Array()
	var near := PackedByteArray()
	var pos := _state_bytes.to_float32_array()
	for i in agents:
		var t: int = _targets[i]
		if t >= 0 and t < agents and _man_body[t] == wiped_body:
			hunters.append(i)
			old.append(t)
			var dx := pos[i * 4] - pos[t * 4]
			var dy := pos[i * 4 + 1] - pos[t * 4 + 1]
			near.append(1 if dx * dx + dy * dy <= REACH * REACH else 0)
	if hunters.is_empty():
		print("gpu crowd: rule | wipe replacement: FAIL (no soldier held an E1 man as its opponent; run more ticks)")
		return
	_wipe_body(1, 1.0, true)
	_sim_step_rules()
	var meta := _meta_bytes.to_float32_array()
	# Only the soldiers whose remembered opponent is actually dead are the ones being replaced.
	var bereaved := PackedInt32Array()
	for k in hunters.size():
		if meta[old[k] * 4 + 2] > 0.5:
			bereaved.append(k)
	if bereaved.is_empty():
		print("gpu crowd: rule | wipe replacement: FAIL (the stripe died but no remembered opponent did)")
		return
	var resolved := PackedByteArray()
	resolved.resize(hunters.size())
	var same_tick := 0
	var immediate_expected := 0
	var immediate_same_tick := 0
	var still_dead_target := 0
	for k in bereaved:
		var i := hunters[k]
		if near[k] == 1:
			immediate_expected += 1
		if meta[i * 4 + 2] > 0.5:
			resolved[k] = 2
			continue
		var t: int = _targets[i]
		if t == old[k]:
			still_dead_target += 1
		elif t >= 0:
			resolved[k] = 1
			same_tick += 1
			if near[k] == 1:
				immediate_same_tick += 1
	for tick in target_cadence:
		_sim_step_rules()
		meta = _meta_bytes.to_float32_array()
		for k in bereaved:
			if resolved[k] != 0:
				continue
			var i := hunters[k]
			if meta[i * 4 + 2] > 0.5:
				resolved[k] = 2
				continue
			var t: int = _targets[i]
			if t >= 0 and t != old[k]:
				resolved[k] = 1
	var within := 0
	var fell := 0
	var near_within := 0
	var near_fell := 0
	var near_unresolved := 0
	for k in bereaved:
		if resolved[k] == 1:
			within += 1
			if near[k] == 1:
				near_within += 1
		elif resolved[k] == 2:
			fell += 1
			if near[k] == 1:
				near_fell += 1
		elif near[k] == 1:
			near_unresolved += 1
	# The hard rule is that a loss taken inside reach is replaced: a soldier whose opponent died
	# in front of it must not stand over the corpse. The out-of-reach losses are reported rather
	# than required to resolve within the cadence, because the GPU's search is the local window
	# (two rungs, about nine units) rather than the reference's escalating ladder to 32: a man who
	# lost an opponent that was never local has nobody to find until one arrives.
	var verdict := "PASS" if still_dead_target == 0 and near_unresolved == 0 else "FAIL"
	print("gpu crowd: rule | wipe replacement: %s (%d soldiers hunted E1, %d lost their opponent; in reach %d reacquired on the wipe tick and %d within a cadence of %d, %d fell, %d unresolved; all bereaved: %d of %d within a cadence, %d fell, %d still holding the dead opponent)" % [
		verdict, hunters.size(), bereaved.size(), immediate_same_tick, near_within, immediate_expected,
		near_fell, near_unresolved, within, bereaved.size(), fell, still_dead_target])


## An opponent that walks beyond the retention radius is released rather than chased, and no
## opponent inside the search's own reach is taken again from that distance.
func _check_release() -> void:
	var s := -1
	var a := -1
	var meta := _meta_bytes.to_float32_array()
	for i in agents:
		if meta[i * 4 + 2] > 0.5:
			continue
		if int(meta[i * 4 + 1]) == 0 and s < 0:
			s = i
		elif int(meta[i * 4 + 1]) == 1 and a < 0:
			a = i
	if s < 0 or a < 0:
		print("gpu crowd: rule | release out of relevance: FAIL (no pair to stage)")
		return
	var base := Vector2(field.x * 0.5, field.y * 0.5)
	_stage_solitary(s, a, base, 4.0)
	_run_tick()
	var held := _read_target_of(s)
	_stage_solitary(s, a, base, target_retention + 8.0)
	_run_tick()
	var released := _read_target_of(s)
	var verdict := "PASS" if held == a and released == -1 else "FAIL"
	print("gpu crowd: rule | release out of relevance: %s (at 4 units kept as opponent %d; at %.0f units, beyond the %.0f radius, released to %d)" % [
		verdict, held, target_retention + 8.0, target_retention, released])


## Two similar enemies must not exchange the answer. The first stage puts the rival a hair closer
## than the remembered opponent and a look due; hysteresis must keep the remembered one. The second
## puts the rival unmistakably closer; the remembered opponent must then be abandoned.
func _check_hysteresis() -> void:
	var s := -1
	var a := -1
	var b := -1
	var meta := _meta_bytes.to_float32_array()
	for i in agents:
		if meta[i * 4 + 2] > 0.5:
			continue
		if int(meta[i * 4 + 1]) == 0 and s < 0:
			s = i
		elif int(meta[i * 4 + 1]) == 1:
			if a < 0:
				a = i
			elif b < 0:
				b = i
	if s < 0 or a < 0 or b < 0:
		print("gpu crowd: rule | hysteresis (two similar enemies): FAIL (no trio to stage)")
		return
	var base := Vector2(field.x * 0.5, field.y * 0.5)
	_stage_trio(s, a, b, base, 4.0, 3.5)
	_run_tick()
	var hair := _read_target_of(s)
	_stage_trio(s, a, b, base, 4.0, 0.5)
	_run_tick()
	var clear := _read_target_of(s)
	var verdict := "PASS" if hair == a and clear == b else "FAIL"
	print("gpu crowd: rule | hysteresis (two similar enemies): %s (a rival 0.5 nearer kept opponent %d; a rival 3.5 nearer took opponent %d)" % [
		verdict, hair, clear])


## The state checksums for the determinism gate: one hash for the men's positions, one for their
## hit points and fallen flags, one for the formations' anchors and headings. Printed every
## `--checksum-every=N` ticks, so two runs of the same seed can be compared tick by tick without
## dumping a field of six thousand men, and a difference can be attributed to a system rather than
## to "the battle".
##
## Quantised to a thousandth of a unit before hashing, deliberately: two runs that agree to three
## decimals are the same battle as far as the game is concerned, and a checksum that fires on
## noise would be worse than none.
const CHECKSUM_SEED := 0x811C9DC5


func _fnv_step(h: int, value: int) -> int:
	for shift in [0, 8, 16, 24]:
		h = (h ^ ((value >> shift) & 0xFF)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return h


func _hash_floats(values: PackedFloat32Array, scale: float) -> int:
	var h := CHECKSUM_SEED
	for v in values:
		h = _fnv_step(h, int(round(v * scale)))
	return h


func _hash_ints(values: PackedInt32Array) -> int:
	var h := CHECKSUM_SEED
	for v in values:
		h = _fnv_step(h, v)
	return h


## Everything that decides what happens next: where every man stands, what condition he is in, and
## where every formation is and which way it faces.
func _checksums() -> String:
	var positions := _hash_floats(_state_bytes.to_float32_array(), 1000.0)
	var condition := _hash_floats(_meta_bytes.to_float32_array(), 100.0)
	# Every other word of the body state: anchors and headings, not the latched engaged flag.
	var shape := PackedFloat32Array()
	for b in _bodies:
		shape.append(_body_state[b * 8 + 0])
		shape.append(_body_state[b * 8 + 1])
		shape.append(_body_state[b * 8 + 2])
		shape.append(_body_state[b * 8 + 3])
	var bodies := _hash_floats(shape, 1000.0)
	var standing := _hash_ints(_body_alive)
	return "tick %6d  positions %08x  condition %08x  formations %08x  standing %08x" % [
		_tick, positions, condition, bodies, standing]


func _report() -> void:
	var counters := rd.buffer_get_data(buf_counters).to_int32_array()
	var fps := float(_frames) / maxf(_frame_delta, 0.0001)
	var ticks_per_second := float(_ticks_window) / maxf(_frame_delta, 0.0001)
	_ticks_window = 0
	_max_inside = maxi(_max_inside, counters[4])
	if _label != null:
		var state_line := _verdict if _verdict != "" else "alive %d v %d    fallen %d    blows %.1fk/s    weakest man %.0f%%    inside an enemy %d (worst %d)    grid overflow %d" % [
			_alive.x, _alive.y, _fallen,
			float(counters[2]) * ticks_per_second / 1000.0, _weakest_hp,
			counters[4], _max_inside, counters[0]]
		_label.text = "GPU BATTLE   %d soldiers in %d legions a side, simulated by the GPU\nfps %.0f   ticks %.0f/s   tick %.2f ms   readback %.2f ms   pack %.2f ms\n%s\n%s\n%s" % [
			agents, bodies_per_side, fps, ticks_per_second,
			float(_tick_usec) / 1000.0, float(_readback_usec) / 1000.0, float(_pack_usec) / 1000.0,
			_command_line(), state_line, _proof_line()]
	print("gpu crowd: %5.1f fps | %7.1f ticks/s | %d soldiers = %.1fM agent-ticks/s | tick %.2f ms | readback %.2f ms | pack %.2f ms (loop %.2f, bars %.2f, submit %.2f) | alive %d v %d | fallen %d | blows %d | probes %d | now %.2f | inside %d (worst %d) | %s | overflow %d" % [
		fps, ticks_per_second, agents, ticks_per_second * float(agents) / 1000000.0,
		float(_tick_usec) / 1000.0, float(_readback_usec) / 1000.0, float(_pack_usec) / 1000.0,
		float(_loop_usec) / 1000.0, float(_bars_usec) / 1000.0, float(_submit_usec) / 1000.0,
		_alive.x, _alive.y, _fallen, counters[2], counters[1],
		-1.0 if counters[5] < 0 else float(counters[5]) / 1000.0,
		counters[4], _max_inside, _proof_line(), counters[0]])
	_report_targeting()


## Copy the GPU's state back and rebuild the picture. Factored out of `_process` so the rule
## checks can drive a tick without a rendered frame; the timing marks it sets are unused there.
## What a man has done and who did for him, from the tallies buffer: x = his kills, y = hundredths
## of a hit point he has dealt, z = the blow that killed him or -1 while he lives. This is the
## outcome the campaign's resolver wants, and the reason the compute path can produce a BattleResult
## rather than only a picture.
func tally(index: int) -> Vector4i:
	if index < 0 or index >= _tallies.size() / 4:
		return Vector4i.ZERO
	return Vector4i(_tallies[index * 4], _tallies[index * 4 + 1], _tallies[index * 4 + 2], _tallies[index * 4 + 3])


## Every hundredth of a hit point dealt, summed - the other half of the same reading.
func _damage_dealt_total() -> int:
	var total := 0
	var count := _tallies.size() / 4
	for i in count:
		total += _tallies[i * 4 + 1]
	return total


func kills_credited() -> int:
	var total := 0
	var count := _tallies.size() / 4
	for i in count:
		total += _tallies[i * 4]
	return total


func _readback_and_pack() -> void:
	var read_started := Time.get_ticks_usec()
	var state_bytes := rd.buffer_get_data(buf_state)
	var meta_bytes := rd.buffer_get_data(buf_meta)
	_tallies = rd.buffer_get_data(buf_tallies).to_int32_array()
	var target_bytes := rd.buffer_get_data(buf_targets)
	_readback_usec = Time.get_ticks_usec() - read_started
	var pack_started := Time.get_ticks_usec()
	_pack(state_bytes, meta_bytes, target_bytes)
	_pack_usec = Time.get_ticks_usec() - pack_started
	var submit_started := Time.get_ticks_usec()
	mm.buffer = instances
	_submit_usec = Time.get_ticks_usec() - submit_started


## Copy what the GPU produced into the instance buffer the renderer draws: each soldier's
## position and colour, the fallen greyed out. This is the whole per-soldier CPU cost of the
## picture.
func _pack(state_bytes: PackedByteArray, meta_bytes: PackedByteArray, target_bytes: PackedByteArray) -> void:
	# Kept so a scripted event (the wipe, below) can write the same buffer the picture is drawn
	# from: the men it kills grey out exactly as if they had fallen in the fight.
	_meta_bytes = meta_bytes
	_state_bytes = state_bytes
	var source := state_bytes.to_float32_array()
	var meta := meta_bytes.to_float32_array()
	var target_raw := target_bytes.to_int32_array()
	# Each soldier's remembered opponent, and how many of each body's living men are engaging
	# each enemy body. Diagnostics only.
	_targets.resize(agents)
	_target_engage.resize(_bodies * _bodies)
	_target_engage.fill(0)
	var alive_player := 0
	var alive_enemy := 0
	_weakest_hp = 999.0
	# Each body's own leading edge, recomputed from where the living actually stand: the anchors
	# are held against these next tick, so they have to come from the men, not from the slots.
	var front := PackedFloat32Array()
	front.resize(_bodies)
	for b in _bodies:
		front[b] = -9999.0 if _side_of_body(b) == 0 else 9999.0
	# Living men per body, and how far each of them stands from his place in the line. The second
	# number is the body's cohesion: a body whose men are on their places is a body, one whose men
	# are strung out behind their slots is a crowd following an anchor.
	var living_men := PackedInt32Array()
	var slot_error := PackedFloat32Array()
	living_men.resize(_bodies)
	slot_error.resize(_bodies)
	var loop_started := Time.get_ticks_usec()
	var focus_sum := Vector2.ZERO
	var bars := 0
	for i in agents:
		var base := i * STRIDE
		var position := Vector2(source[i * 4 + 0], source[i * 4 + 1])
		# Where he stands in the world, and where that lands in the picture. The simulation only
		# ever hears about the first; the view is the second, measured from the field's middle, so
		# the camera stays a pure viewport the player moves over it. The bars lift in picture space,
		# so they stay level however the ground is turned.
		var picture := _iso(position)
		var bi := _man_body[i]
		var target := target_raw[i * 4 + 0] if target_raw.size() >= i * 4 + 4 else -1
		_targets[i] = target
		instances[base + AT_ORIGIN_X] = picture.x
		instances[base + AT_ORIGIN_Y] = picture.y
		var colour := COLOR_FALLEN
		if meta[i * 4 + 2] < 0.5:
			# The lowest hit points anyone alive is carrying: if the line is locked and nobody is
			# dying, this is what says whether blows are landing at all or the damage has stopped.
			_weakest_hp = minf(_weakest_hp, meta[i * 4 + 0])
			living_men[bi] += 1
			# Cohesion - how far this man stands from the place the body's geometry gives him -
			# is measured every fourth tick rather than every one. It costs a slot calculation
			# and a distance per man (6.5 ms of the pack at 20,000 soldiers, measured), nothing
			# in the simulation reads it, and at a quarter of the rate it still samples five
			# times a second: fine for a diagnostic, fine for the morale work to come.
			if _tick % COHESION_EVERY == 0:
				var head := Vector2(_body_state[bi * 8 + 0], _body_state[bi * 8 + 1])
				var fwd := Vector2(_body_state[bi * 8 + 2], _body_state[bi * 8 + 3])
				var right := Vector2(-fwd.y, fwd.x)
				var files := _body_state[bi * 8 + 4]
				var ranks := _body_state[bi * 8 + 5]
				var spacing := _body_state[bi * 8 + 6]
				var place := head \
					+ right * ((float(_man_file[i]) - (files - 1.0) * 0.5) * spacing) \
					+ fwd * ((float(_man_rank[i]) - (ranks - 1.0) * 0.5) * spacing)
				slot_error[bi] += position.distance_to(place)
			focus_sum += position
			if _side_of_body(bi) == 0:
				colour = COLOR_PLAYER
				alive_player += 1
				front[bi] = maxf(front[bi], position.x)
			else:
				colour = COLOR_ENEMY
				alive_enemy += 1
				front[bi] = minf(front[bi], position.x)
			# Which enemy body this living man is actually engaging, for the targeting report.
			# The target must still be alive; a man whose opponent died this tick is counted as
			# engaging nobody until the next tick replaces it.
			if target >= 0 and target < agents and meta[target * 4 + 2] < 0.5:
				_target_engage[bi * _bodies + _man_body[target]] += 1
			# Two instances a soldier: the background first, then the fill on top of it. Skipped in
			# the profile mode that exists to measure what they cost - nothing else changes, and
			# the count of bars says so, so a run cannot be mistaken for a battle without bars.
			if draw_bars:
				var lift := picture + Vector2(-BAR_WIDTH * 0.5, -DISC_RADIUS - BAR_LIFT)
				_write_bar(bars, lift, Vector2(BAR_WIDTH, BAR_HEIGHT), Color(0.05, 0.06, 0.07, 0.85))
				bars += 1
				var ratio := clampf(meta[i * 4 + 0] / hp_max, 0.0, 1.0)
				var fill := Color(0.45, 0.85, 0.45) if ratio > 0.35 else Color(0.9, 0.35, 0.3)
				_write_bar(bars, lift + Vector2(BAR_WIDTH * (1.0 - ratio) * 0.5, 0.0),
					Vector2(maxf(BAR_WIDTH * ratio, 0.05), BAR_HEIGHT), fill)
				bars += 1
		instances[base + AT_COLOR + 0] = colour.r
		instances[base + AT_COLOR + 1] = colour.g
		instances[base + AT_COLOR + 2] = colour.b
		instances[base + AT_COLOR + 3] = 1.0
	_loop_usec = Time.get_ticks_usec() - loop_started
	var submit_started := Time.get_ticks_usec()
	_bars.buffer = _bar_buffer
	_bars.visible_instance_count = bars
	_bars_usec = Time.get_ticks_usec() - submit_started
	if not _bars_reported:
		_bars_reported = true
		print("gpu crowd: bars: instances %d visible %d buffer %d first origin (%.1f, %.1f) size (%.2f, %.2f) colour %.2f" % [
			_bars.instance_count, _bars.visible_instance_count, _bar_buffer.size(),
			_bar_buffer[AT_ORIGIN_X], _bar_buffer[AT_ORIGIN_Y], _bar_buffer[AT_X_X], _bar_buffer[AT_Y_Y],
			_bar_buffer[AT_COLOR + 3]])
	_alive = Vector2i(alive_player, alive_enemy)
	_fallen = agents - alive_player - alive_enemy
	# The lines, as they now stand: the anchors are held against these next tick.
	_body_front = front
	for b in _bodies:
		_body_alive[b] = living_men[b]
		if _tick % COHESION_EVERY == 0:
			# Only on the ticks it was actually measured: the other three keep the last reading,
			# which is what "sampled five times a second" has to mean if it is to be honest.
			_body_cohesion[b] = slot_error[b] / float(living_men[b]) if living_men[b] > 0 else 0.0
	var living := alive_player + alive_enemy
	if living > 0:
		_focus = focus_sum / float(living)


func _build_view() -> void:
	var node := MultiMeshInstance2D.new()
	node.texture = _make_disc_texture()
	node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(node)
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	mm.instance_count = agents
	mm.visible_instance_count = agents
	node.multimesh = mm

	instances.resize(agents * STRIDE)
	var scale := DISC_RADIUS * 2.0
	for i in agents:
		var base := i * STRIDE
		instances[base + AT_X_X] = scale
		instances[base + AT_Y_Y] = scale
		instances[base + AT_COLOR + 3] = 1.0

	_build_bars()

	var camera := Camera2D.new()
	add_child(camera)
	camera.make_current()
	# The picture's origin is the field's middle, so the camera starts there and moves over the
	# picture: panning, zooming and orbiting are three things done to the camera, and the terrain,
	# the men and their bars are all drawn in picture space without ever being told about it.
	camera.position = Vector2.ZERO
	var window := Vector2(get_viewport().get_visible_rect().size)
	var zoom := minf(window.x / (field.x + 8.0), window.y / (field.y + 8.0))
	camera.zoom = Vector2(zoom, zoom) * zoom_factor
	_camera = camera
	_camera_zoom = 1.0
	_zoom_target = 1.0
	_focus = field * 0.5


## Health bars the way the battle view draws them: two instances a soldier, a dark background
## and a fill whose colour reads the hit points. Only the living carry one.
func _build_bars() -> void:
	_solid = _make_solid_texture()
	var node := MultiMeshInstance2D.new()
	node.texture = _solid
	node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	node.z_index = 5
	add_child(node)
	_bars = MultiMesh.new()
	_bars.transform_format = MultiMesh.TRANSFORM_2D
	_bars.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_bars.mesh = quad
	_bars.instance_count = agents * 2
	_bars.visible_instance_count = 0
	node.multimesh = _bars
	_bar_buffer.resize(agents * 2 * STRIDE)


## One box a body, drawn the way the battle view's formation debug draws it: the ground the
## body means to hold.
func _build_outlines() -> void:
	for b in _bodies:
		var line := Line2D.new()
		line.width = 0.4
		line.closed = true
		line.default_color = COLOR_PLAYER if _side_of_body(b) == 0 else COLOR_ENEMY
		line.z_index = -5
		add_child(line)
		_outlines.append(line)


func _update_outlines() -> void:
	for b in _bodies:
		if b >= _outlines.size():
			return
		var anchor := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
		var half_span := (_body_state[b * 8 + 4] - 1.0) * SEPARATION * 0.5 + 2.0
		var half_depth := (_body_state[b * 8 + 5] - 1.0) * SEPARATION * 0.5 + 2.0
		_outlines[b].points = PackedVector2Array([
			anchor + Vector2(-half_depth, -half_span),
			anchor + Vector2(half_depth, -half_span),
			anchor + Vector2(half_depth, half_span),
			anchor + Vector2(-half_depth, half_span)])


func _write_bar(index: int, origin: Vector2, size: Vector2, colour: Color) -> void:
	var base := index * STRIDE
	_bar_buffer[base + AT_X_X] = size.x
	_bar_buffer[base + AT_Y_Y] = size.y
	_bar_buffer[base + AT_ORIGIN_X] = origin.x + size.x * 0.5
	_bar_buffer[base + AT_ORIGIN_Y] = origin.y + size.y * 0.5
	_bar_buffer[base + AT_COLOR + 0] = colour.r
	_bar_buffer[base + AT_COLOR + 1] = colour.g
	_bar_buffer[base + AT_COLOR + 2] = colour.b
	_bar_buffer[base + AT_COLOR + 3] = colour.a


func _make_solid_texture() -> ImageTexture:
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 1.0))
	return ImageTexture.create_from_image(image)


## The soldier's disc, drawn the way the game draws it: a dark rim with a solid middle that
## takes the per-instance team colour.
func _make_disc_texture() -> ImageTexture:
	var image := Image.create_empty(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(TEX_SIZE) * 0.5
	var units_per_pixel := (DISC_RADIUS * 2.0) / float(TEX_SIZE)
	var edge := units_per_pixel * 1.25
	for py in TEX_SIZE:
		for px in TEX_SIZE:
			var local := Vector2(float(px) + 0.5 - half, float(py) + 0.5 - half) * units_per_pixel
			var distance := local.length()
			var body := 1.0 - smoothstep(DISC_CORE - edge, DISC_CORE + edge, distance)
			var rim := 1.0 - smoothstep(DISC_RADIUS - edge, DISC_RADIUS + edge, distance)
			var ink := COLOR_OUTLINE.lerp(Color(1.0, 1.0, 1.0, 1.0), body)
			image.set_pixel(px, py, Color(ink.r, ink.g, ink.b, rim))
	return ImageTexture.create_from_image(image)


## The battlefield for an army this size: the same density the battle scene gives six hundred
## soldiers, so a bigger army gets a bigger field rather than a crush.
func _field_for(count: int) -> Vector2:
	var ratio := maxf(1.0, float(count) / 600.0)
	var scale := sqrt(ratio)
	return Vector2(floorf(200.0 * scale), floorf(120.0 * scale))


## The game's own ground: produced by the production terrain generator for this seed and
## field, baked one pixel a cell with the elevation shading the battle view uses.
func _build_ground() -> void:
	var config := GameManager.config()
	var ground := BattlefieldTerrain.generate(seed_value, field, config)
	var cols := maxi(1, ground.cols)
	var rows := maxi(1, ground.rows)
	var image := Image.create_empty(cols, rows, false, Image.FORMAT_RGBA8)
	var tallest := maxf(0.001, ground.max_height())
	for y in rows:
		for x in cols:
			var index := y * cols + x
			var colour := ground.colour_of_cell(index)
			var relief := ground.height_of_cell(index) / tallest
			if relief > 0.5:
				colour = colour.lightened((relief - 0.5) * 0.55)
			else:
				colour = colour.darkened((0.5 - relief) * 0.45)
			image.set_pixel(x, y, colour)
	var sprite := Sprite2D.new()
	sprite.texture = ImageTexture.create_from_image(image)
	sprite.centered = false
	# One pixel a cell, stretched over the field - the same thing the battle view's
	# single-call ground draw does.
	sprite.scale = Vector2(field.x / float(cols), field.y / float(rows))
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.z_index = -20
	# The ground is the one thing drawn as a plane rather than a point per soldier, so it gets the
	# projection as an honest affine transform - the same one _iso() applies point by point, built
	# from the same two constants, so the men cannot end up standing beside their own ground.
	_view_root = Node2D.new()
	add_child(_view_root)
	_view_root.add_child(sprite)
	# The marks the player makes live on the ground, between it and the men: a child of the view
	# root, so the same transform lays them down, and below the men in depth, so a selection ring
	# is under the formation rather than over it.
	var paint := Node2D.new()
	paint.set_script(load("res://scripts/dev/battle_paint.gd"))
	paint.z_index = -10
	_view_root.add_child(paint)
	_paint = paint


## A corner panel in the game's own styling, so what the picture is and what it costs can be
## read off the screen rather than out of a log.
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -600.0
	panel.offset_top = 12.0
	panel.offset_right = -12.0
	layer.add_child(panel)
	_label = UiTheme.label("", 13, UiTheme.TEXT)
	panel.add_child(_label)


func _save_shot(index: int) -> void:
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out_dir)
	var path := "%s/battle_%d_%d.png" % [out_dir, agents, index]
	var err := image.save_png(path)
	print("gpu crowd: shot %s (%s)" % [path, "written" if err == OK else "failed %d" % err])


func _params() -> PackedFloat32Array:
	return PackedFloat32Array([
		float(agents), float(grid.x), float(grid.y), LG_CELL, SEPARATION,
		DT, field.x, field.y, WALK, REACH, BLOW, MAX_PUSH * (60.0 / maxf(1.0, tick_hz)), MIN_ENEMY_GAP,
		float(_tick), float(maxi(1, target_cadence)), target_retention,
		target_switch_advantage, 0.0 if target_legacy else 1.0, target_search_radius,
		1.0 if target_immediate else 0.0,
		# [22..25] the strike model: the reference's own numbers, read from the config so the
		# scene cannot drift from the game by a constant somebody typed twice.
		hit_chance, defence_mitigation, tick_hz, 1.0 if real_strikes else 0.0])


func _push_constant(mode: int) -> PackedByteArray:
	return PackedInt32Array([mode, 0, 0, 0]).to_byte_array()


func _uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _storage(data: PackedByteArray, size: int) -> RID:
	var bytes := data
	if bytes.size() < size:
		bytes.resize(size)
	return rd.storage_buffer_create(size, bytes)


# =============================================================================================
# The player's hands.
#
# Everything below exists for one purpose: to let a person command a battle small enough to hold
# in his head. The end-game battles will not be simulated - the fight is decided by what the
# player chose before it started and by what he asks for while it runs - so the thing that has to
# be built and tested is the asking, not the marching.
#
# The rule that keeps it honest: nothing here is a parallel system. A click writes into the same
# _order / _order_target / _order_point arrays a scripted event writes into, and the simulation
# cannot tell a player from a script. Input is authority; a ring or an order line is the only
# decoration in the whole file.
# =============================================================================================

## How far the right button may travel and still count as a tap. Beyond it the hand was turning the
## camera, not giving an order, and an order that arrives because someone looked around is worse
## than no order at all.
## Room either side of a formation in its band, in the field's own units. The separation solver
## shoves men sideways as well as back, and a formation whose edge is up against the next band's
## edge has nowhere to be shoved to: the men end up in the neighbouring lane and the pair counts as
## a violation at 2.0 against a 2.47 minimum. Measured at four bodies a side in a 169-unit field,
## where the fit left 1.6 units of slack and produced 41,918 such pairs.
const BAND_MARGIN := 6.0
## What one formation needs of the field to stand in: four ranks of depth at the shared spacing,
## plus the sideways room the solver needs. A band thinner than this cannot hold a formation at all,
## and a body squeezed into one ends up standing in its neighbour's band - which is what thirty
## formations a side produced on the old field, where each band was five and a half units tall.
const BAND_NEEDS := 20.0
const RIGHT_DRAG_SLOP := 7.0
const SELECT_COLOUR := Color(1.0, 0.78, 0.24, 0.95)
const ORDER_COLOUR := Color(1.0, 0.95, 0.75, 0.75)
const ENEMY_COLOUR := Color(0.95, 0.35, 0.30, 0.95)
const BOX_COLOUR := Color(1.0, 0.78, 0.24, 0.85)

var _paint: Node2D = null
## The bodies in the player's hand. Body ids, not unit ids: the formation is the thing a commander
## picks up, and picking formations is the whole point of the scale this scene is set to.
var _selected: Array[int] = []
## Saved selections, by number key - the gesture every game of this kind teaches.
var _groups := {}
var _deploying := false
var _press_at := Vector2.ZERO
var _left_held := false
var _right_held := false
var _right_moved := 0.0
var _right_at := Vector2.ZERO
var _box_active := false
var _box_from := Vector2.ZERO
var _box_to := Vector2.ZERO
var _drag_body := -1
var _drag_grab := Vector2.ZERO
## The line's own width in files, as deployed. A formation ordered into a column and back into a
## line has to become the line it was, which means remembering the width it was given rather than
## deriving a new one from however many men are left standing.
var _line_files := 0
## The formation shapes, read from the game's own catalog rather than invented here, so the player
## chooses between the same shapes the campaign offers.
var _shapes := {}
## Scripted orders waiting for their tick: what a test uses in place of a hand on the mouse.
## Whether to echo every scripted order with the state it found: a test wants it, a battle does not.
var trace_orders := false
## The reference's own combat constants, read from the game's config: the chance a blow lands, and
## how much of a blow a point of defence takes off.
var hit_chance := 0.75
var defence_mitigation := 0.05
var _script_queue: Array = []
## The stats every man is given in this scene, read from the game's own unit definitions. One unit
## type for now: both sides field the same soldier, which is enough to check the model against the
## reference and not yet enough to check spearmen against archers.
var _stats := PackedFloat32Array()
var unit_type := "spearman"
## What one man's full health is, taken from the game's own definition: ten points, so a spear is
## two blows from a kill. The probe used to carry a hundred, which is why nothing ever died.
var hp_max := HP_MAX
## 1 = the reference's strike model (hit roll, damage spread, defence, weapon rhythm), 0 = the flat
## placeholder it replaced. Kept as a switch so the old behaviour can be measured against the new.
var real_strikes := true


## The unit's numbers, as the campaign would hand them to a battle.
func _load_unit_stats() -> void:
	var attack := 7.0
	var defence := 4.0
	var reach := 2.4
	var cooldown := 1.5
	# The game's soldier carries ten hit points, which is what makes a fight two blows long
	# rather than twenty. The probe carried a hundred and nobody died of anything.
	var hit_points := 10.0
	var path := "res://data/units/unit_types.json"
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("units"):
			for entry in (parsed as Dictionary)["units"]:
				if str(entry.get("id", "")) != unit_type:
					continue
				attack = float(entry.get("attack", attack))
				defence = float(entry.get("defence", defence))
				reach = float(entry.get("attack_range", reach))
				cooldown = float(entry.get("attack_cooldown", cooldown))
				hit_points = float(entry.get("hp", entry.get("max_hp", hit_points)) if entry.get("hp", entry.get("max_hp", null)) != null else hit_points)
				break
	hp_max = maxf(1.0, hit_points)
	_stats.resize(agents * 4)
	for i in agents:
		_stats[i * 4 + 0] = attack
		_stats[i * 4 + 1] = defence
		_stats[i * 4 + 2] = reach
		# The rhythm in ticks, because the shader's clock is the battle's own: a blow every one
		# and a half seconds is ninety ticks at sixty a second, and the tick rate is the game's
		# decision, not the weapon's.
		_stats[i * 4 + 3] = maxf(1.0, cooldown * tick_hz)
	print("gpu crowd: unit %s | attack %.0f defence %.0f reach %.1f | a blow every %.2f s (%.0f ticks) | %d hp" % [
		unit_type, attack, defence, reach, cooldown, maxf(1.0, cooldown * tick_hz), int(hp_max)])
## Whether --agents was given by hand: the skirmish preset only picks a size when nobody else did.
var _agents_given := false
## The battle clock, stopped by the player. The camera and the marks keep working while it is:
## a commander looking at a frozen battle is still a commander looking.
var _clock_paused := false
## Autonomy off: the player's formations hold until they are told, and never choose for themselves.
var _manual := false


## The catalog's shapes, in the probe's terms: a cap on how wide a formation may spread, and a
## multiplier on the shared spacing. A cap below one is a fraction of the line (the loose shape);
## anything above is a count of files (the column's four). Loaded from the game's data file, because
## a second copy of these numbers living in this file would drift from the game's the first time a
## designer touched either.
func _load_shapes() -> void:
	if not _shapes.is_empty():
		return
	_shapes = {
		"line": {"files_cap": 999.0, "spacing": 1.0},
		"column": {"files_cap": 4.0, "spacing": 1.0},
		"loose": {"files_cap": 0.6, "spacing": 1.7},
	}
	var path := "res://data/formations/formation_types.json"
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("formations"):
		return
	for entry in (parsed as Dictionary)["formations"]:
		var id := str(entry.get("id", ""))
		if id.is_empty():
			continue
		_shapes[id] = {
			"files_cap": float(entry.get("max_files", 999)),
			"spacing": float(entry.get("spacing_multiplier", 1.0)),
		}


## The formation under a world point, or -1. Picked by the box its men actually stand in - the
## lattice, measured along the body's own facing - because the anchor is a point in the middle of a
## crowd, and nobody can see it, let alone click it.
func _body_at(world: Vector2) -> int:
	var best := -1
	var best_gap := INF
	for b in _bodies:
		if _body_alive[b] <= 0:
			continue
		var anchor := _anchor_of(b)
		var forward := _forward_of(b)
		var across := Vector2(-forward.y, forward.x)
		var rel := world - anchor
		var spacing := maxf(0.5, _body_state[b * 8 + 6])
		var half_depth := maxf(3.0, (_body_state[b * 8 + 5] - 1.0) * spacing * 0.5) + 3.0
		var half_span := maxf(3.0, (_body_state[b * 8 + 4] - 1.0) * spacing * 0.5) + 3.0
		if absf(rel.dot(forward)) <= half_depth and absf(rel.dot(across)) <= half_span:
			var score := rel.length()
			if score < best_gap:
				best_gap = score
				best = b
	if best >= 0:
		return best
	# Nothing under the pointer: offer the nearest formation within reach of it, so a click just off
	# a line still picks the line up rather than the grass behind it.
	for b in _bodies:
		if _body_alive[b] <= 0:
			continue
		var gap := world.distance_to(_anchor_of(b))
		if gap < best_gap and gap < 14.0:
			best_gap = gap
			best = b
	return best


func _anchor_of(b: int) -> Vector2:
	return Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])


func _forward_of(b: int) -> Vector2:
	var forward := Vector2(_body_state[b * 8 + 2], _body_state[b * 8 + 3])
	return forward if forward != Vector2.ZERO else Vector2.RIGHT


## Side 0 is the player's. The enemy answers to the scenario, not to the mouse.
func _is_mine(b: int) -> bool:
	return b >= 0 and _side_of_body(b) == 0


func _living_selection() -> Array[int]:
	var kept: Array[int] = []
	for b in _selected:
		if b >= 0 and b < _bodies and _body_alive[b] > 0:
			kept.append(b)
	return kept


func _selection_names() -> String:
	var names: Array[String] = []
	for b in _living_selection():
		names.append(_body_name(b))
	return ", ".join(names) if not names.is_empty() else "nothing"


func _announce_selection() -> void:
	print("gpu crowd: selected %s" % _selection_names())


## The command line on the panel: whose formations are in the player's hand, how many are in his
## hand at all, and whether the battle has started. A commander has to be able to read his own
## intentions off the screen, because the alternative is remembering which of four identical blocks
## is in his hand.
func _command_line() -> String:
	var stage := "DEPLOYMENT - drag to place, Space starts the battle" if _deploying else "IN THE FIELD"
	var digits: Array[String] = []
	for digit in _groups.keys():
		digits.append(str(digit))
	digits.sort()
	var groups := "groups %s" % ", ".join(digits) if not digits.is_empty() else "no groups saved"
	return "COMMAND  %s   |   holding: %s   |   %s" % [stage, _selection_names(), groups]


## The right hand's command: an enemy formation under the pointer is an order to attack it,
## anything else is an order to march there. One button, two orders, decided by what is under it -
## which is why the player never has to learn a modifier.
func _right_click(world: Vector2) -> void:
	var mine := _living_selection()
	if mine.is_empty():
		return
	var target := _body_at(world)
	if target >= 0 and not _is_mine(target):
		_order_attack(mine, target)
	elif target >= 0 and _is_mine(target):
		# Pointing at one's own formation with a selection in hand reads as "form up on that
		# one", not "attack my own men".
		_order_move(mine, _anchor_of(target))
	else:
		_order_move(mine, world)


func _click_select(world: Vector2, add: bool) -> void:
	var hit := _body_at(world)
	if not add:
		_selected.clear()
	if _is_mine(hit) and not _selected.has(hit):
		_selected.append(hit)
	_announce_selection()


func _box_select(from: Vector2, to: Vector2, add: bool) -> void:
	if not add:
		_selected.clear()
	var rect := Rect2(from, to - from).abs()
	for b in _bodies:
		if not _is_mine(b) or _body_alive[b] <= 0:
			continue
		if rect.has_point(_anchor_of(b)) and not _selected.has(b):
			_selected.append(b)
	_announce_selection()


func _group_assign(digit: int) -> void:
	var mine := _living_selection()
	if mine.is_empty():
		return
	_groups[digit] = mine.duplicate()
	print("gpu crowd: group %d is %s" % [digit, _selection_names()])


func _group_recall(digit: int) -> void:
	if not _groups.has(digit):
		print("gpu crowd: no group %d" % digit)
		return
	_selected.clear()
	for b in _groups[digit]:
		if b >= 0 and b < _bodies and _body_alive[b] > 0:
			_selected.append(b)
	_announce_selection()


## The player's order to move: the same ADVANCE a scripted event gives, to a point on the ground.
func _order_move(bodies: Array, point: Vector2) -> void:
	var moved := 0
	for b in bodies:
		if not _is_mine(b) or _body_alive[b] <= 0:
			continue
		_order[b] = Order.ADVANCE
		_order_point[b] = point
		_hold_ordered[b] = 0
		moved += 1
	if moved > 0:
		print("gpu crowd: %s ordered to (%.0f, %.0f)" % [_selection_names(), point.x, point.y])


## The player's order to attack, which outranks whatever the body would have chosen for itself -
## the reference keeps the player's target in its own field for exactly this reason.
func _order_attack(bodies: Array, target: int) -> void:
	if target < 0 or target >= _bodies:
		return
	var sent := 0
	for b in bodies:
		if not _is_mine(b) or _body_alive[b] <= 0:
			continue
		_order[b] = Order.ENGAGE
		_order_target[b] = target
		_hold_ordered[b] = 0
		sent += 1
	if sent > 0:
		print("gpu crowd: %s ordered to attack %s" % [_selection_names(), _body_name(target)])


func _order_stance(bodies: Array, hold: bool) -> void:
	var set := 0
	for b in bodies:
		if not _is_mine(b) or _body_alive[b] <= 0:
			continue
		_order[b] = Order.HOLD if hold else Order.ENGAGE
		_hold_ordered[b] = 1 if hold else 0
		if not hold:
			_order_target[b] = -1
		set += 1
	if set > 0:
		print("gpu crowd: %s told to %s" % [_selection_names(), "hold" if hold else "engage at will"])


## A new shape for a formation: how many files it spreads to, the depth that follows from it, and
## the spacing. Every man is re-laid into that lattice here, on the CPU, and his file and rank go
## back into the attribute buffer the shader slots him from - so the shape the player picks is the
## shape the men walk into, not a label pinned to the old one.
func _set_formation(bodies: Array, kind: String) -> void:
	_load_shapes()
	if not _shapes.has(kind):
		return
	var shape: Dictionary = _shapes[kind]
	var names := _selection_names()
	var changed := 0
	for b in bodies:
		if not _is_mine(b) or _body_alive[b] <= 0:
			continue
		if _relay_body(b, shape):
			changed += 1
	if changed > 0:
		print("gpu crowd: %s re-formed as %s" % [names, kind])


## Lays body b's men out again in the shape asked for and writes their new places into the attribute
## buffer. The fallen are re-laid along with the living: they do not move, and a man's file and rank
## only ever told the walk where to put him while he was alive. Returns whether the body changed.
func _relay_body(b: int, shape: Dictionary) -> bool:
	var count := 0
	for i in agents:
		if _man_body[i] == b:
			count += 1
	if count <= 0:
		return false
	var wide := float(maxi(2, _line_files if _line_files > 0 else _body_state[b * 8 + 4]))
	var cap := float(shape.get("files_cap", 999.0))
	var wanted := wide * cap if cap < 1.0 else minf(wide, cap)
	var files := int(clampf(round(wanted), 2.0, wide))
	# A shape may not be deeper than the station the body stands in. A hundred and fifty men in
	# four files is thirty-eight ranks - ninety-six units of column inside a forty-two unit band,
	# which puts the rear ranks inside the neighbouring formation and the same shape that reads as
	# "go down the road" in open country becomes a crowd standing in another crowd. Measured: a
	# scripted column order produced 34,884 pairs closer than the separation minimum, worst gap
	# 1.76 against 2.47, because the solver was pushing apart men who had nowhere to be pushed to.
	# The station is the honest limit at this scale, and a column is a shape for open ground.
	var station := maxf(4.0, field.y / float(maxi(1, bodies_per_side)) - BAND_MARGIN * 2.0)
	var ranks_that_fit := maxi(2, int(floor(station / SEPARATION)) + 1)
	files = maxi(files, int(ceil(float(count) / float(ranks_that_fit))))
	var ranks := int(ceil(float(count) / float(files)))
	if int(_body_state[b * 8 + 4]) == files and is_equal_approx(_body_state[b * 8 + 6], SEPARATION * float(shape.get("spacing", 1.0))):
		return false
	var spacing := SEPARATION * float(shape.get("spacing", 1.0))
	var bytes := rd.buffer_get_data(buf_attrs)
	var at := 0
	for i in agents:
		if _man_body[i] != b:
			continue
		var lane := at % files
		var rank := at / files
		_man_file[i] = lane
		_man_rank[i] = rank
		bytes.encode_u32(i * 16 + 4, lane)
		bytes.encode_u32(i * 16 + 8, rank)
		at += 1
	rd.buffer_update(buf_attrs, 0, bytes.size(), bytes)
	_body_state[b * 8 + 4] = float(files)
	_body_state[b * 8 + 5] = float(ranks)
	_body_state[b * 8 + 6] = spacing
	return true


## The selection rings, the order lines and the dragging box, refilled every frame. All of it is
## world space: the paint layer is a child of the view root, so the transform that lays the ground
## down lays these on it, and none of it has to be told about panning, turning or zooming.
func _update_marks() -> void:
	if _paint == null:
		return
	var lines: Array = []
	var rects: Array = []
	for b in _living_selection():
		var anchor := _anchor_of(b)
		var across := Vector2(-_forward_of(b).y, _forward_of(b).x)
		var half_span := maxf(2.0, _body_state[b * 8 + 4] * _body_state[b * 8 + 6] * 0.5)
		lines.append([anchor - across * half_span, anchor + across * half_span, SELECT_COLOUR, 1.6, 0.0])
	for b in _selected:
		if b < 0 or b >= _bodies or _body_alive[b] <= 0:
			continue
		var from := _anchor_of(b)
		match _order[b]:
			Order.ADVANCE:
				lines.append([from, _order_point[b], ORDER_COLOUR, 1.1, 3.0])
			Order.ENGAGE:
				var target := _order_target[b]
				if target >= 0 and target < _bodies and _body_alive[target] > 0:
					lines.append([from, _anchor_of(target), ENEMY_COLOUR, 1.1, 3.0])
	if _box_active:
		rects.append([Rect2(_uniso(_box_from), _uniso(_box_to) - _uniso(_box_from)).abs(), BOX_COLOUR, 0.9, 0.10])
	_paint.lines = lines
	_paint.rects = rects
	_paint.queue_redraw()
	if _hint_label != null:
		_hint_label.text = _hint_text()


## Deployment. The battle begins as a plan: the player may drag his formations into place, and the
## enemy stands where the scenario put him. Placement is nothing more than the anchor the march
## moves, so a placed formation is not a special kind of formation - the men walk to the slots that
## follow from where it was put.
func _place_body(b: int, world: Vector2) -> void:
	var margin := 14.0
	var limit := field.x * 0.5 - margin
	var want := Vector2(clampf(world.x, margin, limit), clampf(world.y, margin, field.y - margin))
	_body_state[b * 8 + 0] = want.x
	_body_state[b * 8 + 1] = want.y


## The switch between a battle that fights itself and one that waits to be told. "A lot of movement
## I did not order" is the honest complaint against automatic behaviour, and the answer is to make
## the automatic behaviour optional rather than to argue for it.
func _set_autonomy(on: bool) -> void:
	_manual = not on
	for b in _bodies:
		if _is_mine(b) and _body_alive[b] > 0:
			_order[b] = Order.ENGAGE if on else Order.HOLD
			_hold_ordered[b] = 0 if on else 1
			if on:
				_order_target[b] = -1
	print("gpu crowd: your side %s" % ("fights on its own (autonomy on)" if on else "holds until ordered (autonomy off)"))


func _start_battle() -> void:
	if not _deploying:
		return
	_deploying = false
	for b in _bodies:
		if _is_mine(b) and _body_alive[b] > 0:
			_order[b] = Order.HOLD if _manual else Order.ENGAGE
			_order_target[b] = -1
			_hold_ordered[b] = 0
	print("gpu crowd: the battle begins on tick %d" % _tick)


## A scripted order, written through exactly the same functions the mouse uses. This is how the
## interaction is tested without hands: if a scripted order and a clicked one disagree, then the two
## paths are not one path, and that is a bug worth catching before a player finds it.
func _apply_scripted_input() -> void:
	if _script_queue.is_empty():
		return
	var entry: Array = _script_queue[0]
	if _tick < int(entry[0]):
		return
	_script_queue.remove_at(0)
	if trace_orders:
		print("gpu crowd: [script] tick %d  %s  manual=%s  order[0]=%s  selected=%d  alive P0=%d P1=%d" % [
			_tick, str(entry[1]), str(_manual), _order_name(_order[0]), _selected.size(),
			_body_alive[0], _body_alive[1]])
	match str(entry[1]):
		"select":
			_selected.clear()
			for b in entry[2]:
				if _is_mine(int(b)):
					_selected.append(int(b))
			_announce_selection()
		"move":
			_order_move(_living_selection(), entry[2])
		"attack":
			_order_attack(_living_selection(), int(entry[2]))
		"hold":
			_order_stance(_living_selection(), true)
		"engage":
			_order_stance(_living_selection(), false)
		"shape":
			_set_formation(_living_selection(), str(entry[2]))
		"group":
			_group_assign(int(entry[2]))
		"recall":
			_group_recall(int(entry[2]))
		"start":
			_start_battle()
		"autonomy":
			_set_autonomy(bool(entry[2]))


## Parses one scripted order: --at=TICK:select=0,1 / move=120,300 / attack=1 / hold / engage /
## shape=column / group=1 / recall=1 / start. Every order carries the tick it happens on, because a
## test that cannot say *when* only ever checks the first tick of a battle.
func _parse_script(arg: String) -> void:
	var body := arg
	var when := 0
	if body.begins_with("--at="):
		var rest := body.substr(5)
		var split := rest.find(":")
		if split < 0:
			return
		when = int(rest.substr(0, split))
		body = rest.substr(split + 1)
	if body.begins_with("select="):
		var ids: Array = []
		for piece in body.substr(7).split(",", false):
			ids.append(int(piece))
		_script_queue.append([when, "select", ids])
	elif body.begins_with("move="):
		var bits := body.substr(5).split(",", false)
		if bits.size() == 2:
			_script_queue.append([when, "move", Vector2(float(bits[0]), float(bits[1]))])
	elif body.begins_with("attack="):
		_script_queue.append([when, "attack", int(body.substr(7))])
	elif body == "hold":
		_script_queue.append([when, "hold", 0])
	elif body == "engage":
		_script_queue.append([when, "engage", 0])
	elif body.begins_with("shape="):
		_script_queue.append([when, "shape", body.substr(6)])
	elif body.begins_with("group="):
		_script_queue.append([when, "group", int(body.substr(6))])
	elif body.begins_with("recall="):
		_script_queue.append([when, "recall", int(body.substr(7))])
	elif body == "start":
		_script_queue.append([when, "start", 0])
	elif body == "autonomy=off":
		_script_queue.append([when, "autonomy", false])
	elif body == "autonomy=on":
		_script_queue.append([when, "autonomy", true])


## The controls, on the screen rather than in a log. A battle you cannot work out how to command is
## a battle you cannot test, and the keys had been living in the console where nobody reads them.
##
## Two layers, because they answer different questions: the panel is the reference - everything the
## scene answers to, grouped the way a commander thinks about it - and the line under the battle is
## the next move, which changes as the player picks things up and puts them down.
##
## The rows are data, not code: adding a binding is adding a row, and the panel styles itself.
const HELP_ROWS := [
	["IN YOUR HANDS", ""],
	["left-click", "pick up a unit  ·  shift adds one  ·  drag open ground to box several"],
	["right-click", "ground: march there      an enemy unit: attack it"],
	["right-drag", "orbit the camera  (a tap commands, a drag looks)"],
	["ORDERS", ""],
	["H  /  U", "hold position  /  engage at will"],
	["K", "the whole side: fights on its own  /  holds until ordered"],
	["L  C  O", "line  ·  column  ·  loose"],
	["ctrl+1-5", "save the selection as a group   ·   1-5 calls it back"],
	["THE BATTLE", ""],
	["space", "begin  (and after that, follow the fighting)"],
	["P", "stop and start the battle clock"],
	["THE CAMERA", ""],
	["wheel", "zoom at the cursor  ·  middle-drag pans  ·  WASD pans"],
	["Q  /  E", "quarter turn     [ ]  tilts     F  frames the field"],
	["I", "the flat top-down view, for comparison"],
	["F1", "hide or show this panel"],
]

var _help_panel: PanelContainer = null
var _hint_label: Label = null


func _build_help() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 21
	add_child(layer)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12.0
	panel.offset_top = -418.0
	panel.offset_right = 446.0
	panel.offset_bottom = -12.0
	layer.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	panel.add_child(column)
	var title := UiTheme.label("COMMANDING A BATTLE", 12, UiTheme.ACCENT)
	column.add_child(title)
	for row in HELP_ROWS:
		var heading: String = row[0]
		var body: String = row[1]
		if body.is_empty():
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(0, 6)
			column.add_child(gap)
			column.add_child(UiTheme.label(heading, 11, UiTheme.GOLD))
			continue
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 10)
		column.add_child(line)
		var key := UiTheme.label(heading, 12, UiTheme.ACCENT)
		key.custom_minimum_size = Vector2(96, 0)
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(key)
		line.add_child(UiTheme.label(body, 12, UiTheme.TEXT))
	_help_panel = panel

	# The line under the battle: what to do next, said once, where the eye already is.
	var hint_panel := PanelContainer.new()
	hint_panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	hint_panel.anchor_left = 0.0
	hint_panel.anchor_right = 1.0
	hint_panel.anchor_top = 1.0
	hint_panel.anchor_bottom = 1.0
	hint_panel.offset_left = 462.0
	hint_panel.offset_right = -12.0
	hint_panel.offset_top = -46.0
	hint_panel.offset_bottom = -12.0
	layer.add_child(hint_panel)
	_hint_label = UiTheme.label("", 13, UiTheme.TEXT)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_panel.add_child(_hint_label)


## What the player should do next, given what is in his hand and what stage the battle is at. This
## is the half of the UI that a reference panel cannot do: it knows the state.
func _hint_text() -> String:
	var held := _living_selection().size()
	if _deploying:
		if held > 0:
			return "%d unit%s in your hand — drag to place %s, Space begins the battle" % [
				held, "s" if held != 1 else "", "them" if held != 1 else "it"]
		return "Left-click a unit, or drag a box around several, then drag them into place"
	if held == 0:
		return "Left-click a unit, or drag a box around several"
	if _manual:
		return "%d unit%s in your hand — right-click ground to march, an enemy to attack  ·  K lets them fight on their own" % [
			held, "s" if held != 1 else ""]
	return "%d unit%s in your hand, fighting on its own — right-click to redirect  ·  K takes control back" % [
		held, "s" if held != 1 else ""]


## Put the camera on a side's own army. The field's middle is empty ground - the armies stand at its
## edges - so a deployment that opens looking at the middle looks at nothing at all, which is what
## the first screenshot of this screen showed.
func _center_on_side(side: int) -> void:
	var sum := Vector2.ZERO
	var count := 0
	for b in _bodies:
		if _side_of_body(b) != side or _body_alive[b] <= 0:
			continue
		sum += _anchor_of(b)
		count += 1
	if count > 0:
		_camera.position = _iso(sum / float(count))
		_follow_action = false
