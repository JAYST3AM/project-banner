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


## Build a field for [param simulator] and attach it to [param parent], or return null if the
## battle should keep drawing its soldiers the way it always has. The caller keeps the field and
## drives [method pack] and [method apply]; nothing about the simulation changes either way.
static func attach(parent: Node2D, view: BattleView, simulator: BattleSimulator) -> SoldierField:
	var node := SoldierField.new()
	parent.add_child(node)
	node.build(simulator.units.size())
	node.probe_buffer_layout()
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
		var position := unit.position
		# The soldier himself.
		_write(_packed_body, bodies, stride, x_x, y_y, origin_x, origin_y, color_at,
			body_scale, body_scale, position, _body_color(unit, team, alive))
		bodies += 1
		if alive and show_bars:
			# The bar's background and its fill, in that order: instance order is draw order
			# inside one multimesh, so the fill lands on top of its own background.
			var ratio := unit.hp_ratio()
			var origin := position + Vector2(-BAR_WIDTH * 0.5, -BODY_RADIUS - BAR_LIFT)
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
	_packed_body = _packed_body.slice(0, bodies * stride)
	_packed_bars = _packed_bars.slice(0, bars * stride)
	_packed_pips = _packed_pips.slice(0, pips * stride)
	_counts = {"body": bodies, "bars": bars, "pips": pips}
	return {
		"mode": "packed",
		"count": bodies,
		"usec": Time.get_ticks_usec() - started,
	}


## Hand the buffers built by [method pack] to the engine: three assignments, whatever the army
## size. This is the whole per-frame cost of drawing the army.
func apply() -> Dictionary:
	var started := Time.get_ticks_usec()
	_assign(_body, _packed_body, int(_counts["body"]))
	_assign(_bars, _packed_bars, int(_counts["bars"]))
	_assign(_pips, _packed_pips, int(_counts["pips"]))
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
## All three batches share this format, so one probe serves them all.
func probe_buffer_layout() -> Dictionary:
	_layout = {"ok": false, "stride": 0}
	_buffer_ok = false
	if _body == null or _body.instance_count < 1:
		return _layout
	var probe_position := Vector2(12345.0, 6789.0)
	var probe_scale := 3.0
	var probe_colour := Color(0.25, 0.5, 0.75, 1.0)
	_body.set_instance_transform_2d(
		0, Transform2D(0.0, Vector2(probe_scale, probe_scale), 0.0, probe_position))
	_body.set_instance_color(0, probe_colour)
	var raw: PackedFloat32Array = _body.buffer
	if raw.is_empty():
		return _layout
	var origin_x := -1
	for i in raw.size():
		if absf(raw[i] - probe_position.x) < 0.5:
			origin_x = i
			break
	if origin_x < 0:
		return _layout
	var origin_y := -1
	for i in raw.size():
		if absf(raw[i] - probe_position.y) < 0.5 and i != origin_x:
			origin_y = i
			break
	var color_at := -1
	for i in raw.size():
		if absf(raw[i] - float(probe_colour.r)) < 0.01:
			color_at = i
			break
	var x_x := -1
	var y_y := -1
	for i in raw.size():
		if absf(raw[i] - probe_scale) < 0.001 and i != origin_x:
			if x_x < 0:
				x_x = i
			elif y_y < 0:
				y_y = i
	if origin_y < 0 or color_at < 0 or x_x < 0 or y_y < 0:
		return _layout
	# Slice size: written into a second instance and found again, because one instance's origin
	# slot says nothing about how far the next one starts.
	_body.set_instance_transform_2d(
		1, Transform2D(0.0, Vector2(probe_scale, probe_scale), 0.0, Vector2(111.0, 222.0)))
	var second: PackedFloat32Array = _body.buffer
	var second_origin := -1
	for i in range(origin_x + 1, second.size()):
		if absf(second[i] - 111.0) < 0.5:
			second_origin = i
			break
	if second_origin < 0:
		return _layout
	_layout = {
		"ok": true,
		"stride": second_origin - origin_x,
		"origin_x": origin_x,
		"origin_y": origin_y,
		"color": color_at,
		"x_x": x_x,
		"y_y": y_y,
	}
	_buffer_ok = true
	# The probe's own values are not soldiers: clear the instances it wrote to.
	_body.visible_instance_count = 0
	return _layout
