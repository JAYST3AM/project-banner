class_name SoldierField
extends MultiMeshInstance2D
## Draws a whole army as instanced meshes instead of one canvas command per soldier.
##
## [b]Why this exists.[/b] [BattleView] draws a soldier with five to seven canvas commands
## issued one soldier at a time from GDScript: an outline disc, a body disc, a facing line, a
## health bar's background and fill, a ranged ring and a selection ring. At six hundred
## soldiers that is a few thousand commands a frame; at twenty thousand it is well over a
## hundred thousand, and every one of them is a GDScript call into the drawing server.
##
## The Step 7.9 render spike measured what that costs, on the machine this is developed on,
## with the simulation frozen and vsync off: [b]133.6 ms a frame at twenty thousand soldiers
## (7.5 fps)[/b], against [b]2.56 ms a frame[/b] for the same army drawn from an instance
## buffer that is rebuilt on the simulation's own cadence and handed over with one assignment
## per frame. At six hundred soldiers the same comparison is 18.8 ms against 2.5 ms - which is
## the 300 v 300 showcase failing to hold 60 fps on the canvas path.
##
## [b]Three instance batches, three draw calls.[/b] Bodies (an outline disc with a white core,
## so the per-instance colour comes through as the team colour), health bars (a background and
## a fill per soldier, two instances each), and facing pips (a thin quad rotated to the
## soldier's facing). Nothing is issued per soldier from GDScript on a frame: the buffers are
## built where the data changes - on a tick - and assigned on every frame, which is an engine
## memcpy rather than a per-soldier loop.
##
## [b]What it draws, and what it deliberately does not (yet).[/b] Bodies, bars and pips, plus
## fallen soldiers darkened. Selection rings and order lines are per-soldier overlays that only
## ever apply to the handful of soldiers a player has picked or ordered, so they stay on
## [BattleView]'s canvas path where their cost is proportional to the selection rather than to
## the army. The ranged ring is not drawn yet: it needs a second texture and a fourth batch,
## and no measured battle needs it at the sizes this exists for.
##
## [b]It cannot change the simulation.[/b] It reads [BattleUnit] state and writes instance
## transforms. It holds no simulator reference between calls, mutates nothing, and is never
## consulted by anything the battle does. Draw order is the caller's: a [SoldierField] added
## after the [BattleView] draws over the ground the view painted, exactly as the per-soldier
## loop did.
##
## [b]The unit sprites.[/b] A fourth batch draws each soldier as a frame from the Tiny RPG
## character atlas - idle, walk, attack, hurt and death - and while it is drawn the disc batch is
## not: the sprite is the unit, not a marker on a base (the owner: "they aren't attachments,
## replace the circles with the knights"). Both sides are the same character, separated by the
## side's tint. The frame is chosen from the soldier's own state (has he moved since the last
## tick, has his cooldown just jumped, was he struck, has he fallen) and the animation clock
## rides the simulation's ticks, so a paused battle holds its pose and animation can never
## outrun the fight. The art is third-party and git-ignored, so the batch exists only when the
## atlas is present AND its instance-buffer layout - custom data included - could be read back
## out of the engine; otherwise the discs are still the whole army, exactly as before.
## [code]PB_UNIT_SPRITES=off[/code] forces that older path for a paired run in one build.

## Texture resolution of the generated discs. Enough that the rim survives a squad-level zoom
## and cheap enough to regenerate in no time at all.
const TEX_SIZE := 32
## The same geometry the canvas path draws: [constant BattleView.UNIT_RADIUS] for the body,
## [code]UNIT_RADIUS + 0.45[/code] for the outline under it, and the health bar's own
## proportions. A comparison between the two paths is only worth reading if they are drawing
## the same thing.
const BODY_RADIUS := 1.5
const OUTLINE_RADIUS := 1.95
const BAR_WIDTH := 3.6
const BAR_HEIGHT := 0.42
const BAR_LIFT := 1.25
const PIP_LENGTH := 2.2
const PIP_THICKNESS := 0.28
const FALLEN_DARKEN := 0.55
const COLOR_OUTLINE := Color("0b1017")

## ---------- the sprite batch -------------------------------------------------
## The frame rects come from the atlas built by [code]tools/build_unit_atlas.py[/code], drawn
## only when it is present. These numbers are the render-side half of that pipeline; the art's
## own half - cell sizes, frame counts, durations - lives in the atlas JSON, and the shader both
## renderers use is [constant UnitArt.SHADER_PATH].
## How far below the soldier's position his frame's anchor point (the body's centre column on
## the cell's bottom edge) is drawn, in world units: his position is the middle of the ground he
## occupies, and his feet belong a little below it so the man stands on his patch rather than
## floating over it.
const FOOT_LIFT := 1.35
## The clearance a health bar keeps above the tallest a soldier can draw, in world units.
const SPRITE_BAR_MARGIN := 0.15
## A cooldown jump larger than this between ticks means a blow landed: the soldier's cooldown
## was reset, which is the only visible trace a strike leaves on the unit.
const STRIKE_COOLDOWN_JUMP := 0.05

## How the instance data is written when [method update_from] is used. [code]setters[/code] is
## the documented API - [method MultiMesh.set_instance_transform_2d] and
## [method MultiMesh.set_instance_color], two calls per instance. [code]buffer[/code] fills one
## [PackedFloat32Array] and assigns [member MultiMesh.buffer]. The buffer layout is measured
## before it is used, never assumed.
var fill_mode: String = "setters"
## Whether the health bars and the facing pips are drawn. They are per-soldier overlays and at
## a zoomed-out camera they are sub-pixel: the caller may drop them (the battle scene drops
## them below a configured zoom) without changing what the army is.
var show_bars := true
var show_facing := true

## Whether the unit sprites are drawn when the art is present. On by default; the environment
## switch [code]PB_UNIT_SPRITES=off[/code] turns the field back into exactly what it drew
## before the sprites existed, which is how a before/after is paired inside one build.
var sprites_enabled: bool = OS.get_environment("PB_UNIT_SPRITES") != "off"
## The battle's tick rate, for the animation clock: a frame of the atlas is held for a fixed
## number of ticks, so the animation runs at the simulation's speed rather than the monitor's.
var anim_rate: float = 30.0
## The unit art, or null when the pack is absent (the discs are then the whole army, as
## before). A caller may inject a specific atlas; the first build loads the local one otherwise.
var art: UnitArt = null

var _body: MultiMesh = null
var _bars: MultiMesh = null
var _pips: MultiMesh = null
var _bars_node: MultiMeshInstance2D = null
var _pips_node: MultiMeshInstance2D = null
var _disc: ImageTexture = null
var _solid: ImageTexture = null
var _capacity := 0
var _last_stats: Dictionary = {}
## The instance buffers built by [method pack] and handed to the engine by [method apply].
var _packed_body: PackedFloat32Array = PackedFloat32Array()
var _packed_bars: PackedFloat32Array = PackedFloat32Array()
var _packed_pips: PackedFloat32Array = PackedFloat32Array()
var _counts := {"body": 0, "bars": 0, "pips": 0}
## Where each field sits inside one instance's slice of [member MultiMesh.buffer]: -1 until a
## probe has read the layout back out of the engine.
var _buffer_ok := false
var _layout: Dictionary = {}

## ---------- the sprite batch's own state --------------------------------------
var _sprites_node: MultiMeshInstance2D = null
var _sprites: MultiMesh = null
var _packed_sprites: PackedFloat32Array = PackedFloat32Array()
var _sprite_count := 0
## Whether the sprite batch exists and its buffer layout was understood. False means the
## discs are the whole army, which is a legitimate outcome, not a failure.
var _sprite_ok := false
var _sprite_layout: Dictionary = {}
## The sprite buffer's field offsets as one flat array - x_x, y_y, origin_x, origin_y,
## colour, custom - and its stride, cached from the probe: a dictionary lookup per soldier per
## tick is exactly the kind of cost this file exists to avoid.
var _sprite_offsets: PackedInt32Array = PackedInt32Array()
var _sprite_stride: int = 0
## The per-soldier sprite step, shared with the compute battlefield: the per-side tables, the
## animation and frame, the placement, the tint and the writes live in it, and it writes only what
## has changed since the last pack. Rebuilt when a layout is adopted, because it needs the offsets.
var _sprite_writer := UnitSpriteWriter.new()
## Per-unit animation state, indexed by unit id: where the soldier stood at the last pack,
## what his cooldown read, when his blow landed, when he was struck, and when he fell.
var _anim_last_position := PackedVector2Array()
var _anim_last_cooldown := PackedFloat32Array()
var _anim_strike_tick := PackedInt32Array()
var _anim_hurt_tick := PackedInt32Array()
var _anim_last_attacked := PackedInt32Array()
var _anim_died_tick := PackedInt32Array()
var _anim_seen := PackedByteArray()


## Build a field for [param simulator] and attach it to [param parent], or return null if the
## battle should keep drawing its soldiers the way it always has. The caller keeps the field and
## drives [method pack] and [method apply]; nothing about the simulation changes either way.
##
## [param rate] is the simulation's ticks a second, which is the animation clock: the sprite
## batch holds each frame for a fixed number of ticks, not for milliseconds of wall time.
static func attach(parent: Node2D, view: BattleView, simulator: BattleSimulator, rate: float = 30.0) -> SoldierField:
	var node := SoldierField.new()
	node.anim_rate = maxf(1.0, rate)
	parent.add_child(node)
	# Sized to the highest id rather than the headcount: the animation state is addressed by
	# unit id, and an army assembled from several parties can have gaps in its ids.
	node.build(_slot_count(simulator))
	node.probe_buffer_layout()
	node.probe_sprite_layout()
	if node.has_usable_buffer() and view != null:
		# The army is the field's to draw now. The view keeps the ground, the debug overlay,
		# the selection rings, the order lines and the damage popups - everything whose cost is
		# proportional to what a player is looking at rather than to how many men are standing.
		view.show_units = false
		# The deployed army is drawn before the first tick, so the buffers are built once here
		# rather than waiting for a frame the battle happens to be running in.
		node.pack(simulator)
		node.apply()
	return node


## How many id-addressed slots the field needs for this army: the highest unit id plus one.
static func _slot_count(simulator: BattleSimulator) -> int:
	var slots := simulator.units.size()
	for unit in simulator.units:
		if unit != null:
			slots = maxi(slots, unit.id + 1)
	return slots


## Whether the instance buffer's layout was read back out of the engine and the fast path is
## usable. False means [method update_from] falls back to the documented setters.
func has_usable_buffer() -> bool:
	return _buffer_ok


func buffer_layout() -> Dictionary:
	return _layout


## Allocate for [param capacity] soldiers. Called once: the instance counts never change, and
## how much of each is drawn is set per call by the buffers themselves.
func build(capacity: int) -> void:
	_capacity = maxi(1, capacity)
	_disc = _make_disc_texture()
	_solid = _make_solid_texture()
	_body = _make_multimesh(_disc, _capacity)
	multimesh = _body
	texture = _disc
	# The generated disc is already antialiased, so it wants to be filtered rather than snapped
	# to the nearest texel the way the project's default filter would.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	# The unit sprites, above the discs and under the bars: built here, before the bars and
	# pips are added, so the child order is also the draw order. A no-op when the art is absent.
	_build_sprite_batch(_capacity)

	# Health bars: a background and a fill per soldier, so two instances each. A plain white
	# pixel scaled to the bar's proportions - the same rectangle the canvas path draws.
	_bars_node = MultiMeshInstance2D.new()
	_bars_node.texture = _solid
	_bars_node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_bars_node)
	_bars = _make_multimesh(_solid, _capacity * 2)
	_bars_node.multimesh = _bars

	# Facing pips: one thin quad per soldier, rotated to its facing.
	_pips_node = MultiMeshInstance2D.new()
	_pips_node.texture = _solid
	_pips_node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_pips_node)
	_pips = _make_multimesh(_solid, _capacity)
	_pips_node.multimesh = _pips


func _make_multimesh(source: Texture2D, instances: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = _make_quad(source)
	mm.instance_count = maxi(1, instances)
	mm.visible_instance_count = 0
	return mm


## A one-unit quad, centred on its transform's origin, so an instance transform's scale is the
## drawn thing's size in world units.
func _make_quad(source: Texture2D) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	return quad


func _make_solid_texture() -> ImageTexture:
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 1.0))
	return ImageTexture.create_from_image(image)


## The disc the canvas path draws: a flat outline colour out to [constant OUTLINE_RADIUS],
## white inside [constant BODY_RADIUS] so the per-instance colour comes through as the team
## colour, and soft edges at both boundaries.
func _make_disc_texture() -> ImageTexture:
	var image := Image.create_empty(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(TEX_SIZE) * 0.5
	var units_per_pixel := (OUTLINE_RADIUS * 2.0) / float(TEX_SIZE)
	var edge := units_per_pixel * 1.25
	for py in TEX_SIZE:
		for px in TEX_SIZE:
			var local := Vector2(float(px) + 0.5 - half, float(py) + 0.5 - half) * units_per_pixel
			var distance := local.length()
			var body := 1.0 - smoothstep(BODY_RADIUS - edge, BODY_RADIUS + edge, distance)
			var rim := 1.0 - smoothstep(OUTLINE_RADIUS - edge, OUTLINE_RADIUS + edge, distance)
			var ink := COLOR_OUTLINE.lerp(Color(1.0, 1.0, 1.0, 1.0), body)
			image.set_pixel(px, py, Color(ink.r, ink.g, ink.b, rim))
	return ImageTexture.create_from_image(image)


## ---------- the two halves of the primary path ----------------------------

## Build every instance buffer and keep it, without touching the multimeshes. This is the half
## that runs where the data changes - on a tick - and it is the only per-soldier GDScript left
## in the render path.
func pack(simulator: BattleSimulator) -> Dictionary:
	var started := Time.get_ticks_usec()
	var stride := _stride()
	var origin_x := int(_layout.get("origin_x", 3))
	var origin_y := int(_layout.get("origin_y", 7))
	var color_at := int(_layout.get("color", 8))
	var x_x := int(_layout.get("x_x", 0))
	var y_y := int(_layout.get("y_y", 5))
	var body_scale := OUTLINE_RADIUS * 2.0
	_packed_body.resize(_capacity * stride)
	_packed_bars.resize(_capacity * 2 * stride)
	_packed_pips.resize(_capacity * stride)
	if _sprite_ok:
		_packed_sprites.resize(_capacity * _sprite_stride)
		if _sprite_writer.capacity() < _capacity:
			# Belt and braces: the writer was reserved when a layout was adopted, and a field
			# whose army grew past it would otherwise write nothing for the new men.
			_sprite_writer.reserve(_capacity)
	var bodies := 0
	var bars := 0
	var pips := 0
	var sprites := 0
	var tick := simulator.tick_index
	var units: Array[BattleUnit] = simulator.units
	for unit in units:
		if unit == null:
			continue
		if bodies >= _capacity:
			break
		var alive := unit.is_alive()
		var team := _team_color(unit)
		var position := unit.position
		# The soldier himself - as a disc only when there is no sprite to draw him with. The
		# owner: "they aren't attachments, replace the circles with the knights" - so while the
		# sprite batch is drawn, the disc batch is not: the sprite is the unit, not a marker on
		# a base. With no art (or PB_UNIT_SPRITES=off) the discs are the whole army as before.
		if not _sprite_ok:
			_write(_packed_body, bodies, stride, x_x, y_y, origin_x, origin_y, color_at,
				body_scale, body_scale, position, _body_color(unit, team, alive))
		bodies += 1
		# And the same soldier as a frame of the atlas, when there is one to draw.
		if _sprite_ok:
			_write_sprite(sprites, unit, position, alive, tick)
			sprites += 1
		if alive and show_bars:
			# The bar's background and its fill, in that order: instance order is draw order
			# inside one multimesh, so the fill lands on top of its own background.
			var ratio := unit.hp_ratio()
			var origin := position + Vector2(-BAR_WIDTH * 0.5, -BODY_RADIUS - bar_lift())
			_write(_packed_bars, bars, stride, x_x, y_y, origin_x, origin_y, color_at,
				BAR_WIDTH, BAR_HEIGHT, origin + Vector2(BAR_WIDTH * 0.5, BAR_HEIGHT * 0.5),
				Color(0.0, 0.0, 0.0, 0.65))
			bars += 1
			var health := BattleView.COLOR_PLAYER if ratio > 0.35 else BattleView.COLOR_ENEMY
			var filled := BAR_WIDTH * ratio
			_write(_packed_bars, bars, stride, x_x, y_y, origin_x, origin_y, color_at,
				filled, BAR_HEIGHT, origin + Vector2(filled * 0.5, BAR_HEIGHT * 0.5),
				health.lightened(0.1))
			bars += 1
		elif alive:
			bars += 2
		if alive and show_facing and unit.facing.length() > 0.01:
			var pip := _pip_transform(unit)
			_write(_packed_pips, pips, stride, x_x, y_y, origin_x, origin_y, color_at,
				PIP_LENGTH, PIP_THICKNESS, pip, team.lightened(0.5))
			pips += 1
		else:
			# A zero-scale instance rather than a shorter count: the instance order has to stay
			# parallel to the soldiers' order for the write-back to be a slice, and a quad of
			# no size draws nothing.
			_write(_packed_pips, pips, stride, x_x, y_y, origin_x, origin_y, color_at,
				0.0, 0.0, position, Color(0.0, 0.0, 0.0, 0.0))
			pips += 1
	# Only the drawn slices are handed over: a longer buffer than the instance count would
	# leave the engine reading stale transforms for men who are no longer standing.
	var discs := bodies if not _sprite_ok else 0
	_packed_body = _packed_body.slice(0, discs * stride)
	_packed_bars = _packed_bars.slice(0, bars * stride)
	_packed_pips = _packed_pips.slice(0, pips * stride)
	if _sprite_ok:
		_packed_sprites = _packed_sprites.slice(0, sprites * _sprite_stride)
	_counts = {"body": discs, "bars": bars, "pips": pips, "sprites": sprites}
	return {
		"mode": "packed",
		"count": bodies,
		"discs": discs,
		"usec": Time.get_ticks_usec() - started,
	}


## Hand the buffers built by [method pack] to the engine: three assignments, whatever the army
## size. This is the whole per-frame cost of drawing the army.
func apply() -> Dictionary:
	var started := Time.get_ticks_usec()
	_assign(_body, _packed_body, int(_counts["body"]))
	_assign(_bars, _packed_bars, int(_counts["bars"]))
	_assign(_pips, _packed_pips, int(_counts["pips"]))
	if _sprite_ok:
		_assign(_sprites, _packed_sprites, int(_counts.get("sprites", 0)))
	return {"mode": "packed", "count": int(_counts["body"]), "usec": Time.get_ticks_usec() - started}


func _assign(mm: MultiMesh, buffer: PackedFloat32Array, count: int) -> void:
	if mm == null or buffer.is_empty() or count <= 0:
		if mm != null:
			mm.visible_instance_count = 0
		return
	# The instance count has to match the buffer's length *before* the buffer is set: the
	# engine rejects a buffer of a different size than the multimesh already has, and the count
	# changes as soldiers die.
	if mm.instance_count != count:
		mm.instance_count = count
	mm.buffer = buffer
	mm.visible_instance_count = count


## Pack and apply in one call: the simple path, for a caller that rebuilds every frame and for
## the benchmark's paired comparison against [code]setters[/code] and [code]buffer[/code].
func update_from(simulator: BattleSimulator) -> Dictionary:
	if not _buffer_ok:
		return _update_from_setters(simulator)
	var packed := pack(simulator)
	var applied := apply()
	return {
		"mode": "buffer",
		"count": int(packed["count"]),
		"usec": int(packed["usec"]) + int(applied["usec"]),
	}


## The documented way, kept as the fallback and as the comparison: two engine calls per
## instance, one soldier at a time.
func _update_from_setters(simulator: BattleSimulator) -> Dictionary:
	var started := Time.get_ticks_usec()
	var body_scale := OUTLINE_RADIUS * 2.0
	var bodies := 0
	var bars := 0
	var pips := 0
	var units: Array[BattleUnit] = simulator.units
	for unit in units:
		if unit == null:
			continue
		if bodies >= _capacity:
			break
		var alive := unit.is_alive()
		var team := _team_color(unit)
		_body.set_instance_transform_2d(
			bodies, Transform2D(0.0, Vector2(body_scale, body_scale), 0.0, unit.position))
		_body.set_instance_color(bodies, _body_color(unit, team, alive))
		bodies += 1
		if alive and show_bars:
			var ratio := unit.hp_ratio()
			var origin := unit.position + Vector2(-BAR_WIDTH * 0.5, -BODY_RADIUS - BAR_LIFT)
			_bars.set_instance_transform_2d(bars, Transform2D(
				0.0, Vector2(BAR_WIDTH, BAR_HEIGHT), 0.0,
				origin + Vector2(BAR_WIDTH * 0.5, BAR_HEIGHT * 0.5)))
			_bars.set_instance_color(bars, Color(0.0, 0.0, 0.0, 0.65))
			bars += 1
			var health := BattleView.COLOR_PLAYER if ratio > 0.35 else BattleView.COLOR_ENEMY
			var filled := BAR_WIDTH * ratio
			_bars.set_instance_transform_2d(bars, Transform2D(
				0.0, Vector2(filled, BAR_HEIGHT), 0.0,
				origin + Vector2(filled * 0.5, BAR_HEIGHT * 0.5)))
			_bars.set_instance_color(bars, health.lightened(0.1))
			bars += 1
		if alive and show_facing and unit.facing.length() > 0.01:
			var facing := unit.facing.normalized()
			_pips.set_instance_transform_2d(pips, Transform2D(
				facing.angle(), Vector2(PIP_LENGTH, PIP_THICKNESS), 0.0,
				unit.position + facing * (PIP_LENGTH * 0.5)))
			_pips.set_instance_color(pips, team.lightened(0.5))
			pips += 1
	_body.visible_instance_count = bodies
	_bars.visible_instance_count = bars
	_pips.visible_instance_count = pips
	return {
		"mode": "setters",
		"count": bodies,
		"usec": Time.get_ticks_usec() - started,
	}


func _write(
	buffer: PackedFloat32Array, index: int, stride: int, x_x: int, y_y: int,
	origin_x: int, origin_y: int, color_at: int, scale_x: float, scale_y: float,
	position: Vector2, colour: Color
) -> void:
	var base := index * stride
	buffer[base + x_x] = scale_x
	buffer[base + y_y] = scale_y
	buffer[base + origin_x] = position.x
	buffer[base + origin_y] = position.y
	buffer[base + color_at] = colour.r
	buffer[base + color_at + 1] = colour.g
	buffer[base + color_at + 2] = colour.b
	buffer[base + color_at + 3] = colour.a


func _stride() -> int:
	var stride: int = int(_layout.get("stride", 12))
	return stride if stride > 0 else 12


func _pip_transform(unit: BattleUnit) -> Vector2:
	return unit.position + unit.facing.normalized() * (PIP_LENGTH * 0.5)


func _team_color(unit: BattleUnit) -> Color:
	return BattleView.COLOR_PLAYER if unit.side == BattleContext.SIDE_PLAYER else BattleView.COLOR_ENEMY


func _body_color(unit: BattleUnit, team: Color, alive: bool) -> Color:
	return team if alive else team.darkened(FALLEN_DARKEN)


## Read the buffer's own layout back out of the engine instead of assuming it: write one
## instance through the documented setters with values that cannot be confused with each other,
## then find them in [member MultiMesh.buffer]. Returns the offsets the buffer path needs, and
## [code]ok: false[/code] when the layout is not one that path understands - in which case the
## field falls back to setters rather than drawing nonsense.
##
## All three disc batches share this format, so one probe serves them all. The measuring itself
## lives in [method UnitArt.measure_layout], because the compute battlefield needs the same
## answer for the same reason.
func probe_buffer_layout() -> Dictionary:
	_layout = UnitArt.measure_layout(_body, false)
	_buffer_ok = bool(_layout.get("ok", false))
	return _layout


## The sprite batch's layout, probed the same way with the custom-data block on top: the frame
## rectangle travels per instance in custom data, and where that block sits inside
## [member MultiMesh.buffer] is measured rather than assumed. No usable layout means no sprite
## batch and the discs are drawn instead - the same graceful absence as missing art.
func probe_sprite_layout() -> Dictionary:
	_sprite_layout = UnitArt.measure_layout(_sprites, true)
	_sprite_ok = adopt_sprite_layout(_sprite_layout)
	return _sprite_layout


## Adopt a sprite buffer layout measured somewhere else, and report whether it is one the writer
## understands. The layout is the dictionary [method UnitArt.measure_layout] returns; this is the
## seam for a caller that cannot read an instance buffer back - a headless run has no buffers at
## all (measured: `buffer` is empty under the dummy driver), and the render bench takes its layout
## from its own probe - so the instance write can still be exercised and asserted.
func adopt_sprite_layout(layout: Dictionary) -> bool:
	_sprite_offsets = UnitArt.offsets_from(layout)
	_sprite_stride = int(layout.get("stride", 0)) if _sprite_offsets.size() == 6 else 0
	_sprite_ok = _sprite_stride > 0 and _sprite_offsets.size() == 6 and _rebuild_sprite_tables()
	return _sprite_ok


## How many sprite instances the last [method pack] wrote.
func sprite_count() -> int:
	return int(_counts.get("sprites", 0))


## How many disc instances the last [method pack] wrote. Zero while the sprites are drawn: the
## discs are the fallback army, not a base under the men (the owner: "they aren't attachments").
func disc_count() -> int:
	return int(_counts.get("body", 0))


## The drawn rectangle (origin and size, in world units) of one packed sprite instance - read out
## of the buffer the renderer built, so a caller can assert what was written without a GPU.
func sprite_instance_rect(index: int) -> Rect2:
	var base := index * _sprite_stride
	if _sprite_offsets.size() < 6 or base + _sprite_stride > _packed_sprites.size():
		return Rect2()
	return Rect2(
		Vector2(_packed_sprites[base + _sprite_offsets[2]], _packed_sprites[base + _sprite_offsets[3]]),
		Vector2(_packed_sprites[base + _sprite_offsets[0]], _packed_sprites[base + _sprite_offsets[1]]))


## The frame rectangle one packed sprite instance carries, as the shader will read it.
func sprite_instance_custom(index: int) -> Vector4:
	var base := index * _sprite_stride
	if _sprite_offsets.size() < 6 or base + _sprite_stride > _packed_sprites.size():
		return Vector4.ZERO
	var at := _sprite_offsets[5]
	return Vector4(_packed_sprites[base + at], _packed_sprites[base + at + 1],
		_packed_sprites[base + at + 2], _packed_sprites[base + at + 3])


## The colour one packed sprite instance carries, as the shader will read it: the side's tint, or
## a corpse's darkened tint.
func sprite_instance_colour(index: int) -> Color:
	var base := index * _sprite_stride
	if _sprite_offsets.size() < 6 or base + _sprite_stride > _packed_sprites.size():
		return Color(0.0, 0.0, 0.0, 0.0)
	var at := _sprite_offsets[4]
	return Color(_packed_sprites[base + at], _packed_sprites[base + at + 1],
		_packed_sprites[base + at + 2], _packed_sprites[base + at + 3])


## ---------- the sprite batch -------------------------------------------------


## Build the sprite batch: one multimesh over the whole atlas, an instance per soldier, the
## frame chosen per instance in custom data and the flip carried by a mirrored UV rect. Called
## from [method build]; does nothing when the art is absent or the switch is off, and the field
## then draws exactly what it drew before the sprites existed.
func _build_sprite_batch(capacity: int) -> void:
	if not sprites_enabled:
		return
	if art == null:
		art = UnitArt.load_if_present()
	if art == null or not art.has_character(UnitArt.CHARACTER_PLAYER) \
			or not art.has_character(UnitArt.CHARACTER_ENEMY):
		art = null
		return
	var shader := load(UnitArt.SHADER_PATH) as Shader
	if shader == null:
		art = null
		return
	var material := ShaderMaterial.new()
	material.shader = shader
	_sprites_node = MultiMeshInstance2D.new()
	_sprites_node.texture = art.texture()
	# Pixel art: one texel stays one texel. The disc batch beside it is antialiased and wants
	# the linear filter; a sprite with a hard pixel edge does not.
	_sprites_node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprites_node.material = material
	add_child(_sprites_node)
	_sprites = UnitArt.build_batch(art.texture(), capacity)
	_sprites_node.multimesh = _sprites
	# The writer's tables need the measured layout, so they are rebuilt when one is adopted
	# ([method adopt_sprite_layout]), not here.
	_reset_animation_state(capacity)


## Hand the writer both renderers share what it needs: the per-side tables this atlas produces at
## this battle's rate, the buffer layout the probe measured, and the two placements that belong to
## the look rather than the maths. False means there is no sprite batch to write - a run without
## the art, or with a layout this writer does not understand, draws the discs instead.
func _rebuild_sprite_tables() -> bool:
	if art == null or _sprite_offsets.size() != 6 or _sprite_stride <= 0:
		return false
	# Player first: index 0 is the player's side in every side-indexed table the writer holds.
	if not _sprite_writer.setup(art, [UnitArt.CHARACTER_PLAYER, UnitArt.CHARACTER_ENEMY],
			anim_rate, _sprite_offsets, _sprite_stride, FOOT_LIFT, FALLEN_DARKEN):
		return false
	_sprite_writer.reserve(_capacity)
	return true


## Per-unit animation state, sized for [param capacity] id-addressed slots and reset to the
## "has never happened" stamps.
func _reset_animation_state(capacity: int) -> void:
	_anim_last_position.resize(capacity)
	_anim_last_position.fill(Vector2.ZERO)
	_anim_last_cooldown.resize(capacity)
	_anim_last_cooldown.fill(-1.0)
	_anim_strike_tick.resize(capacity)
	_anim_strike_tick.fill(UnitArt.NEVER)
	_anim_hurt_tick.resize(capacity)
	_anim_hurt_tick.fill(UnitArt.NEVER)
	_anim_last_attacked.resize(capacity)
	_anim_last_attacked.fill(-1)
	_anim_died_tick.resize(capacity)
	_anim_died_tick.fill(-1)
	_anim_seen.resize(capacity)
	_anim_seen.fill(0)


## Whether the sprite batch is drawing the army. False means the discs are - which is what a
## run without the art, without the switch, or with an unreadable buffer produces, and what the
## battle logs.
func has_sprites() -> bool:
	return _sprite_ok


## The lift the health bars are drawn with, derived rather than hand-tuned: the men stand
## [constant FOOT_LIFT] below the point the bar is placed from, they stand
## [method UnitSpriteWriter.sprite_head] tall, and the bar hangs [constant BAR_HEIGHT] tall off a
## [constant BODY_RADIUS] lift - so this puts the bar just above a head. (The discs only needed
## [constant BAR_LIFT].) Public because the suite pins the geometry against the art.
func bar_lift() -> float:
	if not _sprite_ok:
		return BAR_LIFT
	return _sprite_writer.sprite_head() + BAR_HEIGHT - BODY_RADIUS - FOOT_LIFT + SPRITE_BAR_MARGIN


## One soldier's sprite: his animation and frame chosen from his own state, written into the
## packed buffer at [param index] as one instance. Nothing else about him changes.
func _write_sprite(index: int, unit: BattleUnit, position: Vector2, alive: bool, tick: int) -> void:
	var id := unit.id
	var known := id >= 0 and id < _capacity
	var moved := false
	if known:
		# First sighting is neither a step nor a blow: the army is deployed standing still with
		# a fresh cooldown, and against the "never" sentinel that reads as a jump.
		var first := _anim_seen[id] == 0
		moved = not first \
			and position.distance_squared_to(_anim_last_position[id]) > UnitArt.MOVE_EPSILON
		_anim_seen[id] = 1
		_anim_last_position[id] = position
		# A cooldown that jumped between packs is the blow landing: it is the only trace a
		# strike leaves on the unit itself.
		# A bowman looses, he does not swing: the pack's attack strips are all sword, so the pose
		# is left to the idle and the arrow is the tell (the battle view flies it from the
		# simulator's own events). The clock stamp still runs for everyone else.
		if not first and not unit.ranged 				and unit.cooldown_left > _anim_last_cooldown[id] + STRIKE_COOLDOWN_JUMP:
			_anim_strike_tick[id] = tick
		_anim_last_cooldown[id] = unit.cooldown_left
		if unit.last_attacked_tick > _anim_last_attacked[id]:
			_anim_last_attacked[id] = unit.last_attacked_tick
			_anim_hurt_tick[id] = tick
		if not alive and _anim_died_tick[id] < 0:
			_anim_died_tick[id] = tick
	var hurt_age := UnitArt.NEVER
	var strike_age := UnitArt.NEVER
	var death_age := 0
	if known:
		hurt_age = tick - _anim_hurt_tick[id]
		strike_age = tick - _anim_strike_tick[id]
		if _anim_died_tick[id] >= 0:
			death_age = tick - _anim_died_tick[id]
	var side := 0 if unit.side == BattleContext.SIDE_PLAYER else 1
	# One call: the animation, the frame, the placement, the tint and the writes. The writer is
	# shared with the compute battlefield's soldier loop, which knows the same things about a man
	# a different way - [param index] is this pack's slot, [param id] is who he is.
	_sprite_writer.write(_packed_sprites, index, id if known else index, position, side, alive,
		moved, hurt_age, strike_age, death_age, unit.facing.x < 0.0, tick)
