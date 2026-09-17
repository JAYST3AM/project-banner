extends Node2D
## Dev-only probe: a battle whose soldiers are simulated on the GPU.
##
## [b]What this is.[/b] The game's own battlefield - the production terrain generator, the
## formation lattice, the soldier look and the instanced renderer - with the per-soldier work
## running in compute shaders over state that lives in the GPU's buffers: build a spatial
## grid, read a soldier's neighbours, push them apart, land blows on the enemy, take the
## blows, march. Four dispatches a tick, a readback of the positions and the hit points, one
## [MultiMesh] buffer assignment - the idiom [SoldierField] already uses to hand a whole army
## to the renderer. Nothing in the game calls it.
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
const MAX_PUSH := 0.6
## The agreed physical minimum between two enemies, in world units: the separation distance
## with a five per cent tolerance. The proof run records the closest enemy gap on every tick
## and counts any pair inside this - the audit's item 1, and the number that has to be zero.
const MIN_ENEMY_GAP := SEPARATION * 0.95
const BODIES_PER_SIDE := 3
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
## The battle's clock, in ticks a second: the same fixed step the game's own battles use.
var tick_hz := 20.0
var _tick_accumulator := 0.0
var readback_every := 1
var max_fps := 0
var run_seconds := 0.0
var seed_value := 780780
var out_dir := "F:/VSC Projects/pb-bench/gpu_crowd"
## How far the camera is pushed in past the fit-the-field zoom: at 1.0 the whole field is
## visible and a six-thousand-man army is a dot matrix, which is not what a battle looks
## like. The camera follows the fighting once it starts.
var zoom_factor := 2.5

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var buf_state: RID
var buf_push: RID
var buf_cursor: RID
var buf_slots: RID
var buf_params: RID
var buf_counters: RID
var buf_meta: RID
var buf_damage: RID
var buf_corr: RID
var buf_attrs: RID
var buf_bodies: RID
var uniform_set: RID
## The bodies, ten numbers each: anchor.xy, forward.xy, files, ranks, spacing, engaged.
## Advanced on the CPU - six of them - and read by every soldier in the shader.
var _body_state := PackedFloat32Array()
var _bodies := 0

var field := Vector2(200.0, 120.0)
var grid := Vector2i(0, 0)
var mm: MultiMesh
var instances := PackedFloat32Array()

var _tick := 0
var _tick_usec := 0
var _readback_usec := 0
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
## Print a state checksum every this many ticks (0 = never). Off unless asked for: it walks the
## whole field in GDScript, which is fine in a test and wasted work in a demo.
var checksum_every := 0
var _last_checksum_tick := -1
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


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--agents="):
			agents = maxi(WORKGROUP, int(arg.substr(9)))
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
	grid = Vector2i(ceili(field.x / LG_CELL), ceili(field.y / LG_CELL))
	var cells := grid.x * grid.y

	var state := PackedFloat32Array()
	state.resize(agents * 4)
	var meta := PackedFloat32Array()
	meta.resize(agents * 4)
	var attrs := PackedFloat32Array()
	attrs.resize(agents * 4)
	_deploy(state, meta, attrs)

	buf_state = _storage(state.to_byte_array(), agents * 16)
	buf_push = _storage(PackedByteArray(), agents * 16)
	buf_cursor = _storage(PackedByteArray(), cells * 4)
	buf_slots = _storage(PackedByteArray(), cells * SLOT_CAPACITY * 4)
	buf_params = _storage(_params().to_byte_array(), 13 * 4)
	buf_counters = _storage(PackedByteArray(), 14 * 4)
	buf_meta = _storage(meta.to_byte_array(), agents * 16)
	buf_damage = _storage(PackedByteArray(), agents * 4)
	# The separation correction being accumulated this round, in fixed-point integers: ivec4 a man.
	buf_corr = _storage(PackedByteArray(), agents * 16)
	buf_attrs = _storage(attrs.to_byte_array(), agents * 16)
	buf_bodies = _storage(_body_state.to_byte_array(), _bodies * 8 * 4)

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
	uniform_set = rd.uniform_set_create(uniforms, shader, 0)

	_build_ground()
	_build_view()
	_build_hud()
	print("gpu crowd: %d soldiers, %d a side | grid %dx%d (cell %.1f) | field %.0fx%.0f | reach %.1f | blow %.2f/attacker" % [
		agents, agents / 2, grid.x, grid.y, LG_CELL, field.x, field.y, REACH, BLOW])


## Both armies drawn up the way the battle scene draws them up: ranks and files of a body's
## lattice, inset from their own edge of the field, facing one another.
## Three bodies a side, the way the battle scene draws a legion up: a lattice of files and
## ranks per body, the bodies stacked in bands across the field, each inset from its own
## edge and facing the enemy. Every soldier is told which body he belongs to and which file
## and rank are his; where he stands starts a little off his place, so the ranks dress on the
## way in.
func _deploy(state: PackedFloat32Array, meta: PackedFloat32Array, attrs: PackedFloat32Array) -> void:
	var per_side := agents / 2
	var per_body := ceili(float(per_side) / float(BODIES_PER_SIDE))
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
	var band_height := field.y / float(BODIES_PER_SIDE)
	var files := mini(BODY_FILES, maxi(4, int(band_height / SEPARATION)))
	var ranks := ceili(float(per_body) / float(files))
	var depth := float(ranks - 1) * SEPARATION
	var frontage := float(files - 1) * SEPARATION
	# How far apart the bodies stand: their own frontage plus a margin to fight in, but never
	# more than a third of the field each - at small sizes "frontage + 20" pushed the outer two
	# bodies off the field edge, and the first tick then dragged their men back inside (measured:
	# a 49-unit "step" at tick 1 on a 600-soldier run).
	var band := minf(frontage + 20.0, field.y / float(BODIES_PER_SIDE))
	var inset := field.x * 0.12
	# The oblique demo shifts the two sides apart in y so their bodies have to turn to face each
	# other. Taken out of whatever slack the field has left rather than added on top: the bands
	# already fill most of its height, and a shift that pushed men past the edge would be measured
	# as a deployment fault (a 27-unit first-tick drag) rather than the turn it is meant to show.
	var slack := maxf(0.0, field.y - ((BODIES_PER_SIDE - 1) * band + frontage)) * 0.5
	_bodies = BODIES_PER_SIDE * 2
	_body_state.resize(_bodies * 8)
	_heading.resize(_bodies)
	_order.resize(_bodies)
	_order_target.resize(_bodies)
	_order_point.resize(_bodies)
	_body_alive.resize(_bodies)
	_body_cohesion.resize(_bodies)
	_hold_ordered.resize(_bodies)
	for b in _bodies:
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
		var side := b / BODIES_PER_SIDE
		var band_index := b % BODIES_PER_SIDE
		var centre_y := field.y * 0.5 + (float(band_index) - float(BODIES_PER_SIDE - 1) * 0.5) * band
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
		var band_index := mini(BODIES_PER_SIDE - 1, within / per_body)
		var in_body := within % per_body
		var file := in_body % files
		var rank := in_body / files
		var b := side * BODIES_PER_SIDE + band_index
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
		meta[i * 4 + 0] = HP_MAX
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
		BODIES_PER_SIDE, files, ranks, per_body, SEPARATION, depth])


## How much room a body's living men have before they are standing on the enemy - measured as the
## distance from its men to the nearest living enemy anywhere, straight from the shader, which
## already takes exactly that measurement every tick.
##
## [b]Why not the leading man's x[/b]: that was the first version of this rule, and it deadlocked
## the battle. Two bodies' leading men can sit in different bands down the field, so comparing
## their x read as "2.3 apart, no room" while the nearest real enemy pair stood 3.52 away - past
## the 3.4 reach. Nobody could fight and nobody could close: 228 dead, then two lines staring at
## each other for ever.
func _body_room(b: int) -> float:
	if _body_gap.size() < BODIES_PER_SIDE * 2:
		return 9999.0
	return _body_gap[b]


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
	return "%s%d" % ["P" if b / BODIES_PER_SIDE == 0 else "E", b % BODIES_PER_SIDE]


## A body changing its mind about who it is fighting is a rare, reviewable event, so it is printed
## the moment it happens rather than left to be inferred from a later diagnostic line.
func _note_switch(text: String) -> void:
	_target_switches += 1
	_last_switch = text
	print("gpu crowd: target switch | %s" % text)


## Destroy an enemy body outright, at a tick the caller chooses. This is how target reassignment is
## tested: the body that was fighting it must pick a new enemy within a few ticks and carry on,
## and if it cannot, that is a defect rather than something to discover in a real campaign.
func _wipe_body(band: int) -> void:
	_wiped = true
	var target_body := BODIES_PER_SIDE + band
	var data := _meta_bytes.to_float32_array()
	var killed := 0
	for i in agents:
		if _man_body[i] == target_body and data[i * 4 + 2] < 0.5:
			data[i * 4 + 0] = 0.0
			data[i * 4 + 2] = 1.0
			killed += 1
	_meta_bytes = data.to_byte_array()
	rd.buffer_update(buf_meta, 0, _meta_bytes.size(), _meta_bytes)
	print("gpu crowd: scripted | %s destroyed at tick %d, %d men - whoever was fighting it must find someone else" % [
		_body_name(target_body), _tick, killed])


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
	var side := b / BODIES_PER_SIDE
	var mine := Vector2(_body_state[b * 8 + 0], _body_state[b * 8 + 1])
	var best := -1
	var best_distance := INF
	for other in _bodies:
		if other / BODIES_PER_SIDE == side:
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
		var side := b / BODIES_PER_SIDE
		# Who are we fighting, if anyone? One selection a tick, retained until it is destroyed or
		# clearly beaten, and it is what the facing and the engagement below are driven by.
		_select_target(b)
		# Face the target, no faster than a body can turn. Every man's place in the line is built
		# from this vector, so the whole lattice - and the dressing - swings with it.
		var aim := _aim_for(b)
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
				if other / BODIES_PER_SIDE == side:
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
	var cl := rd.compute_list_begin()
	var groups_agents := (agents + WORKGROUP - 1) / WORKGROUP
	var cells := grid.x * grid.y
	# The clear pass covers the grid cursors, the agents' blow tally and correction, and the
	# fourteen counters that follow them - hence agents + 14, not agents + 4: too few threads and
	# the counter block's tail is never reset, which quietly turns every "this tick" figure into a
	# running total. Two fewer and the anchors would never be told the front had cleared.
	var clear_threads := maxi(cells, agents + 14)
	var groups_clear := (clear_threads + WORKGROUP - 1) / WORKGROUP
	for mode in 4:
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
		rd.compute_list_set_push_constant(cl, _push_constant(mode), 16)
		rd.compute_list_dispatch(cl, groups_clear if mode == 0 else groups_agents, 1, 1)
		rd.compute_list_add_barrier(cl)
	for round in SETTLE_ROUNDS:
		for mode in [4, 5]:
			rd.compute_list_bind_compute_pipeline(cl, pipeline)
			rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
			rd.compute_list_set_push_constant(cl, _push_constant(mode), 16)
			rd.compute_list_dispatch(cl, groups_agents, 1, 1)
			rd.compute_list_add_barrier(cl)
	rd.compute_list_end()


func _process(delta: float) -> void:
	if not pipeline.is_valid():
		return
	var started := Time.get_ticks_usec()
	var ticks_now := 0
	if not _frozen:
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
	_tick += ticks_now
	_ticks_window += ticks_now
	# Scripted events for the order tests, fired at fixed ticks so a run is repeatable: a body
	# destroyed outright (does its enemy find a new one?), or a body ordered to hold (does it stop
	# while its neighbours lean in?).
	if not _frozen:
		if wipe_band >= 0 and not _wiped and _tick >= wipe_at:
			_wipe_body(wipe_band)
		if hold_band >= 0 and not _held and _tick >= hold_at:
			_hold_body(hold_band)
		if advance_band >= 0 and not _advanced and _tick >= advance_at:
			_advance_body(advance_band, advance_by)
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
		var read_started := Time.get_ticks_usec()
		var state_bytes := rd.buffer_get_data(buf_state)
		var meta_bytes := rd.buffer_get_data(buf_meta)
		_readback_usec = Time.get_ticks_usec() - read_started
		var pack_started := Time.get_ticks_usec()
		_pack(state_bytes, meta_bytes)
		_pack_usec = Time.get_ticks_usec() - pack_started
		mm.buffer = instances
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
	if _camera != null:
		_camera.position = _camera.position.lerp(_focus, 0.08)
	if _shot_taken == 0 and _elapsed > 6.0:
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
	if counters.size() >= 8 + BODIES_PER_SIDE * 2:
		var gaps := PackedFloat32Array()
		gaps.resize(BODIES_PER_SIDE * 2)
		for b in BODIES_PER_SIDE * 2:
			gaps[b] = 9999.0 if counters[8 + b] < 0 else float(counters[8 + b]) / 1000.0
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
	if _body_front.size() < BODIES_PER_SIDE * 2 or _body_state.size() < _bodies * 8:
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
		_label.text = "GPU BATTLE   %d soldiers in %d legions a side, simulated by the GPU\nfps %.0f   ticks %.0f/s   tick %.2f ms   readback %.2f ms   pack %.2f ms\n%s\n%s" % [
			agents, BODIES_PER_SIDE, fps, ticks_per_second,
			float(_tick_usec) / 1000.0, float(_readback_usec) / 1000.0, float(_pack_usec) / 1000.0,
			state_line, _proof_line()]
	print("gpu crowd: %5.1f fps | %7.1f ticks/s | %d soldiers = %.1fM agent-ticks/s | tick %.2f ms | readback %.2f ms | pack %.2f ms | alive %d v %d | fallen %d | blows %d | probes %d | now %.2f | inside %d (worst %d) | %s | overflow %d" % [
		fps, ticks_per_second, agents, ticks_per_second * float(agents) / 1000000.0,
		float(_tick_usec) / 1000.0, float(_readback_usec) / 1000.0, float(_pack_usec) / 1000.0,
		_alive.x, _alive.y, _fallen, counters[2], counters[1],
		-1.0 if counters[5] < 0 else float(counters[5]) / 1000.0,
		counters[4], _max_inside, _proof_line(), counters[0]])


## Copy what the GPU produced into the instance buffer the renderer draws: each soldier's
## position and colour, the fallen greyed out. This is the whole per-soldier CPU cost of the
## picture.
func _pack(state_bytes: PackedByteArray, meta_bytes: PackedByteArray) -> void:
	# Kept so a scripted event (the wipe, below) can write the same buffer the picture is drawn
	# from: the men it kills grey out exactly as if they had fallen in the fight.
	_meta_bytes = meta_bytes
	_state_bytes = state_bytes
	var source := state_bytes.to_float32_array()
	var meta := meta_bytes.to_float32_array()
	var alive_player := 0
	var alive_enemy := 0
	_weakest_hp = 999.0
	# Each body's own leading edge, recomputed from where the living actually stand: the anchors
	# are held against these next tick, so they have to come from the men, not from the slots.
	var front := PackedFloat32Array()
	front.resize(BODIES_PER_SIDE * 2)
	for b in BODIES_PER_SIDE * 2:
		front[b] = -9999.0 if b / BODIES_PER_SIDE == 0 else 9999.0
	# Living men per body, and how far each of them stands from his place in the line. The second
	# number is the body's cohesion: a body whose men are on their places is a body, one whose men
	# are strung out behind their slots is a crowd following an anchor.
	var living_men := PackedInt32Array()
	var slot_error := PackedFloat32Array()
	living_men.resize(BODIES_PER_SIDE * 2)
	slot_error.resize(BODIES_PER_SIDE * 2)
	var focus_sum := Vector2.ZERO
	var bars := 0
	for i in agents:
		var base := i * STRIDE
		var position := Vector2(source[i * 4 + 0], source[i * 4 + 1])
		var band := mini(BODIES_PER_SIDE - 1, (i % _per_side) / maxi(_per_body, 1))
		var bi := (0 if i < _per_side else 1) * BODIES_PER_SIDE + band
		instances[base + AT_ORIGIN_X] = position.x
		instances[base + AT_ORIGIN_Y] = position.y
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
			if meta[i * 4 + 1] < 0.5:
				colour = COLOR_PLAYER
				alive_player += 1
				front[bi] = maxf(front[bi], position.x)
			else:
				colour = COLOR_ENEMY
				alive_enemy += 1
				front[bi] = minf(front[bi], position.x)
			# Two instances a soldier: the background first, then the fill on top of it.
			var lift := position + Vector2(-BAR_WIDTH * 0.5, -DISC_RADIUS - BAR_LIFT)
			_write_bar(bars, lift, Vector2(BAR_WIDTH, BAR_HEIGHT), Color(0.05, 0.06, 0.07, 0.85))
			bars += 1
			var ratio := clampf(meta[i * 4 + 0] / HP_MAX, 0.0, 1.0)
			var fill := Color(0.45, 0.85, 0.45) if ratio > 0.35 else Color(0.9, 0.35, 0.3)
			_write_bar(bars, lift + Vector2(BAR_WIDTH * (1.0 - ratio) * 0.5, 0.0),
				Vector2(maxf(BAR_WIDTH * ratio, 0.05), BAR_HEIGHT), fill)
			bars += 1
		instances[base + AT_COLOR + 0] = colour.r
		instances[base + AT_COLOR + 1] = colour.g
		instances[base + AT_COLOR + 2] = colour.b
		instances[base + AT_COLOR + 3] = 1.0
	_bars.buffer = _bar_buffer
	_bars.visible_instance_count = bars
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
	camera.position = field * 0.5
	var window := Vector2(get_viewport().get_visible_rect().size)
	var zoom := minf(window.x / (field.x + 8.0), window.y / (field.y + 8.0))
	camera.zoom = Vector2(zoom, zoom) * zoom_factor
	_camera = camera
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
		line.default_color = COLOR_PLAYER if b / BODIES_PER_SIDE == 0 else COLOR_ENEMY
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
	add_child(sprite)


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
		DT, field.x, field.y, WALK, REACH, BLOW, MAX_PUSH, MIN_ENEMY_GAP])


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
