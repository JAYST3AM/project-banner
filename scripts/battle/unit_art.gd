class_name UnitArt
extends RefCounted
## The battle's unit sprites: one atlas, a frame table, and the arithmetic that turns a
## soldier's state into the rectangle the renderer hands the GPU.
##
## [b]Loaded only if it is there.[/b] The pack is third-party art under a licence that allows
## use but forbids re-upload, so it lives in the git-ignored [code]assets/art_source/[/code]
## tree and a fresh clone does not have it. [method load_if_present] therefore returns
## [code]null[/code] rather than failing, and [SoldierField] draws its instance discs exactly
## as it did before - the same graceful-absence rule the campaign ground follows when the
## painted terrain art is missing.
##
## [b]All arithmetic, no engine state.[/b] Everything here is a pure function of the table
## and the arguments - which frame of which animation a soldier is on, and where that frame
## sits in the atlas - so the suite can pin it without a battle, a window or a GPU.
##
## Rebuild the atlas with [code]tools/build_unit_atlas.py[/code] after changing the source
## strips; the frame counts and durations live in the JSON, never in code.

const ATLAS_PATH := "res://assets/art_source/units/tiny_rpg/unit_atlas.png"
const TABLE_PATH := "res://assets/art_source/units/tiny_rpg/unit_atlas.json"
## The shader both renderers draw their sprite batch with: custom data carries the frame rect,
## the shader maps the quad's UV onto it. Committed code - only the art is git-ignored.
const SHADER_PATH := "res://shaders/battle/unit_sprite.gdshader"

## Animation indices. Order is the atlas table's order and the renderer's vocabulary.
const IDLE := 0
const WALK := 1
const ATTACK := 2
const HURT := 3
const DEATH := 4
const ANIMATIONS: Array[String] = ["idle", "walk", "attack", "hurt", "death"]

## Which character a side is drawn as. [b]Both sides are the soldier[/b] - the owner: "dont use the
## orks" - so the orc rows stay in the atlas unused for now (a monster, or an enemy character
## whose silhouette reads apart from a soldier). Because both sides are the same character, the
## side has to read from the tint below, not the art.
const CHARACTER_PLAYER := "soldier"
const CHARACTER_ENEMY := CHARACTER_PLAYER

## The per-side tint every sprite instance is drawn with. The player's soldier is left natural -
## his own blue steel already reads as "ours" - and the enemy is multiplied warm: verified against
## the art at battle scale, it separates the lines at a glance while the helmet, face, shield and
## sword stay legible, where a stronger tint muddies the small sprite.
const TINT_PLAYER := Color(1.0, 1.0, 1.0, 1.0)
const TINT_ENEMY := Color(1.0, 0.62, 0.55, 1.0)

## Half a texel, in texels: the UV rect is inset by this at every edge so the outermost
## texel's centre lands on the quad's edge and nearest sampling cannot pick up the padding.
const TEXEL_INSET := 0.5

## The ticks between one soldier's animation phase and his neighbour's - derived from the unit
## id, so a rank does not step in lockstep. Odd on purpose: it does not divide any of the frame
## counts, which is what keeps two adjacent soldiers off the same frame.
const PHASE_STRIDE := 7
## A move smaller than this between ticks is the separation pass breathing, not a step.
const MOVE_EPSILON := 0.0004
## A tick stamp that cannot be reached, for "this has never happened to this soldier" - the
## hurt and strike stamps both renderers keep per soldier start here.
const NEVER := -1000000

var _texture: Texture2D = null
var _size := Vector2.ZERO
## World units one atlas pixel draws as. Owned by the atlas (JSON) so scale is a data edit.
var _units_per_pixel := 0.16
## character key -> {"cell": Vector2, "anchor": Vector2, "animations": {name: {y, frames, ms}}}
var _characters: Dictionary = {}


## The art, or [code]null[/code] when the pack is not present or unreadable. Never throws:
## an absent file, broken JSON or an unimported PNG all mean "draw the discs".
static func load_if_present() -> UnitArt:
	if not ResourceLoader.exists(ATLAS_PATH) or not FileAccess.file_exists(TABLE_PATH):
		return null
	var art := UnitArt.new()
	if not art._read():
		return null
	return art


func _read() -> bool:
	var file := FileAccess.open(TABLE_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var table: Dictionary = parsed
	var raw_characters: Dictionary = table.get("characters", {})
	if raw_characters.is_empty():
		return false
	var loaded := load(ATLAS_PATH) as Texture2D
	if loaded == null:
		return false

	var characters := {}
	for key in raw_characters.keys():
		var entry: Dictionary = raw_characters[key]
		var cell: Array = entry.get("cell", [])
		var anchor: Array = entry.get("anchor", [])
		if cell.size() < 2 or anchor.size() < 2:
			return false
		var animations := {}
		var raw_animations: Dictionary = entry.get("animations", {})
		for anim in ANIMATIONS:
			var data: Dictionary = raw_animations.get(anim, {})
			if data.is_empty():
				return false
			animations[anim] = {
				"y": float(data.get("y", 0)),
				"frames": maxi(1, int(data.get("frames", 1))),
				"ms": maxf(1.0, float(data.get("ms", 100))),
			}
		characters[str(key)] = {
			"cell": Vector2(float(cell[0]), float(cell[1])),
			"anchor": Vector2(float(anchor[0]), float(anchor[1])),
			# The idle pose's height in atlas pixels, as the builder measured it. Optional: a
			# table built before the field existed falls back to the cell in [method head_units].
			"head": float(entry.get("head", 0.0)),
			"animations": animations,
		}

	_texture = loaded
	_size = Vector2(float(loaded.get_width()), float(loaded.get_height()))
	_units_per_pixel = maxf(0.001, float(table.get("units_per_pixel", 0.16)))
	_characters = characters
	return true


## The key of the character the given side is drawn as.
static func key_for_side(side: String) -> String:
	return CHARACTER_PLAYER if side == BattleContext.SIDE_PLAYER else CHARACTER_ENEMY


## The tint the given side's sprites are drawn with.
static func side_tint(is_player: bool) -> Color:
	return TINT_PLAYER if is_player else TINT_ENEMY


func texture() -> Texture2D:
	return _texture


func atlas_size() -> Vector2:
	return _size


func units_per_pixel() -> float:
	return _units_per_pixel


func characters() -> Array[String]:
	var keys: Array[String] = []
	for key in _characters.keys():
		keys.append(str(key))
	return keys


func has_character(key: String) -> bool:
	return _characters.has(key)


## The drawn size of one frame of [param key], in world units.
func cell_size(key: String) -> Vector2:
	return _cell(key)


## Where a soldier's world position sits inside the frame, in atlas pixels from the cell's
## left edge and from its bottom edge.
func anchor(key: String) -> Vector2:
	var entry: Dictionary = _characters.get(key, {})
	return entry.get("anchor", Vector2.ZERO)


## How tall a soldier of [param key] stands in his idle pose, in world units. What a health bar
## hangs off, so it is public: the renderers place their bars from it and the suite pins them.
func head(key: String) -> float:
	return head_units(_characters.get(key, {}), cell_size(key), _units_per_pixel)


func frames_of(key: String, animation: int) -> int:
	var data: Dictionary = _animation(key, animation)
	return int(data.get("frames", 1))


## Milliseconds a frame of this animation is held for.
func frame_ms(key: String, animation: int) -> float:
	var data: Dictionary = _animation(key, animation)
	return float(data.get("ms", 100.0))


## How many whole simulation ticks a frame is held for at [param rate] ticks a second.
static func ticks_per_frame(ms: float, rate: float) -> int:
	return maxi(1, int(round(ms * maxf(0.001, rate) / 1000.0)))


## The frame's rectangle in the atlas, in normalised UV coordinates, inset by half a texel
## at every edge.
func uv_rect(key: String, animation: int, frame: int) -> Rect2:
	var entry: Dictionary = _characters.get(key, {})
	if entry.is_empty():
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var cell: Vector2 = entry["cell"]
	var data: Dictionary = _animation(key, animation)
	var frames := int(data.get("frames", 1))
	var index := clampi(frame, 0, frames - 1)
	var x := float(index) * cell.x + TEXEL_INSET
	var y := float(data.get("y", 0.0)) + TEXEL_INSET
	var width := maxf(1.0, cell.x - TEXEL_INSET * 2.0)
	var height := maxf(1.0, cell.y - TEXEL_INSET * 2.0)
	return Rect2(x / _size.x, y / _size.y, width / _size.x, height / _size.y)


func _animation(key: String, animation: int) -> Dictionary:
	var entry: Dictionary = _characters.get(key, {})
	if entry.is_empty():
		return {"frames": 1, "ms": 100.0, "y": 0.0}
	var animations: Dictionary = entry["animations"]
	var name := ANIMATIONS[clampi(animation, 0, ANIMATIONS.size() - 1)]
	return animations.get(name, {"frames": 1, "ms": 100.0, "y": 0.0})


func _cell(key: String) -> Vector2:
	var entry: Dictionary = _characters.get(key, {})
	return entry.get("cell", Vector2.ONE)


## ---------- the animation clock and the plan (renderer-agnostic) -------------
##
## Both renderers - the canvas battle's [SoldierField] and the compute battlefield - draw the
## same atlas the same way, so the arithmetic lives here and neither owns it: which animation a
## soldier is in, which frame of it, where the quad goes and what the shader is handed.
##
## [b]Everything a per-soldier loop needs is precomputed.[/b] Asking this class once per soldier
## per pack means string-keyed dictionary walks inside the hottest loop a renderer has - measured
## at 7.5 us a soldier on the compute field, against 0.4 for the precomputed tables this returns.
## A renderer calls [method renderer_data] once per character and reads arrays afterwards.

## Everything one renderer needs for one character, precomputed: the animation clock - the ticks
## a frame of each animation is held for, the frame counts, how long the hurt and attack poses
## last - the cell size, the anchor, the world units one pixel draws as, and the UV rectangle of
## every frame laid out as [code][animation * uv_stride + frame][/code].
func renderer_data(key: String, rate: float) -> Dictionary:
	var ticks: PackedInt32Array = PackedInt32Array()
	var frames: PackedInt32Array = PackedInt32Array()
	var stride := 1
	for animation in ANIMATIONS.size():
		ticks.append(ticks_per_frame(frame_ms(key, animation), rate))
		frames.append(frames_of(key, animation))
		stride = maxi(stride, frames[animation])
	var uv: PackedVector4Array = PackedVector4Array()
	uv.resize(ANIMATIONS.size() * stride)
	for animation in ANIMATIONS.size():
		for index in frames[animation]:
			var rect := uv_rect(key, animation, index)
			uv[animation * stride + index] = Vector4(
				rect.position.x, rect.position.y, rect.size.x, rect.size.y)
	var cell := cell_size(key)
	var anchor_point := anchor(key)
	var entry: Dictionary = _characters.get(key, {})
	var hurt_at := int(ANIMATIONS.find("hurt"))
	var attack_at := int(ANIMATIONS.find("attack"))
	return {
		"ticks": ticks,
		"frames": frames,
		"uv": uv,
		"uv_stride": stride,
		# cell.xy, anchor.xy, units a pixel, hurt ticks, attack ticks, how tall he stands - one
		# typed block so the per-soldier path never has to touch a dictionary. The last one is
		# what a health bar hangs off: the idle pose's height, not the cell's, or the bar floats
		# above his head whatever pose he is in (a sword reaches higher than a head - see the
		# atlas builder's `head`).
		"common": PackedFloat32Array([
			cell.x, cell.y, anchor_point.x, anchor_point.y, _units_per_pixel,
			float(int(frames[hurt_at]) * int(ticks[hurt_at])),
			float(int(frames[attack_at]) * int(ticks[attack_at])),
			head_units(entry, cell, _units_per_pixel),
		]),
	}


## How tall a soldier of this character stands in the idle pose, in world units: the atlas's own
## `head` (pixels from the cell's bottom edge) at the units a pixel the art declares. Falls back
## to the whole cell for a table built before the field existed - the bar then clears a raised
## sword but floats a gap above the head, which is what this replaced.
static func head_units(entry: Dictionary, cell: Vector2, units: float) -> float:
	var head := float(entry.get("head", 0.0))
	if head <= 0.0 or units <= 0.0:
		return cell.y
	return head * units


## Which animation a soldier is in, from the things a renderer knows about him. Pure and static
## so the priority order can be pinned by a suite without a battle: a fallen soldier holds his
## death animation, a blow struck plays over a blow taken, either plays out over its own length, a
## soldier who has moved since the last pack walks, and everyone else stands.
static func plan(
	alive: bool, moved: bool, hurt_age: int, strike_age: int,
	hurt_window: int, attack_window: int
) -> int:
	if not alive:
		return DEATH
	# A blow struck outranks a blow taken. In a press every man is hit while he swings, so the
	# flinch checked first hid every attack in a melee while the archers - seldom hit - showed
	# theirs: the swing has to be the man's own act, or a scrum looks like men standing being hit.
	if strike_age >= 0 and strike_age < attack_window:
		return ATTACK
	if hurt_age >= 0 and hurt_age < hurt_window:
		return HURT
	if moved:
		return WALK
	return IDLE


## The frame within an animation, for a whole number of ticks into it: the loops wrap, and the
## death animation stops on its last frame - a corpse holds its pose. Whole ticks rather than
## seconds because the animation rides the simulation, and a battle that is paused or running at
## half rate must not blend between two poses.
static func frame(animation: int, ticks_into: int, ticks_per_frame_count: int, frames: int) -> int:
	var per := maxi(1, ticks_per_frame_count)
	var count := maxi(1, frames)
	var index := int(ticks_into / per)
	if animation == DEATH:
		return clampi(index, 0, count - 1)
	return posmod(index, count)


## Where a sprite instance's quad origin goes. The frame's anchor - the body's centre column on
## the cell's bottom edge, from the atlas table - is placed at [param foot], and a quad is
## centred on its own origin, so the origin is offset by half the drawn size. Pure, so the
## placement can be pinned by a suite without a GPU.
static func origin(foot: Vector2, cell: Vector2, anchor: Vector2, units_per_pixel: float) -> Vector2:
	return Vector2(
		foot.x + cell.x * units_per_pixel * 0.5 - anchor.x * units_per_pixel,
		foot.y - cell.y * units_per_pixel * 0.5
	)


## The custom data one sprite instance carries: the frame's rectangle in the atlas, and the
## flip as a mirrored UV - the pack's characters are single-direction, so a mirrored frame is
## the whole of "left-facing", and no second copy of the art is needed. The shader does the
## rest; this is a pure function of the rectangle.
static func custom(uv: Rect2, flip: bool) -> Vector4:
	return custom_from(Vector4(uv.position.x, uv.position.y, uv.size.x, uv.size.y), flip)


## [method custom] from the packed form a precomputed table stores: xy the frame's corner, zw its
## size, in normalised atlas coordinates. One function so the tables and the direct path cannot
## disagree about a mirror.
static func custom_from(uv: Vector4, flip: bool) -> Vector4:
	if flip:
		return Vector4(uv.x + uv.z, uv.y, -uv.z, uv.w)
	return uv


## ---------- reading a multimesh's buffer layout ------------------------------
##
## The frame rectangle travels in per-instance custom data, which means a second [MultiMesh] and
## a different buffer stride from the disc batches - so the layout is measured, never assumed:
## write one instance through the documented setters with values that cannot be confused with
## each other, then find them in [member MultiMesh.buffer]. Returns the offsets a writer needs,
## and [code]ok: false[/code] when the layout is not one the sprite path understands - in which
## case the renderer draws what it always drew rather than soldiers at each other's coordinates.
static func measure_layout(mm: MultiMesh, with_custom: bool) -> Dictionary:
	var layout := {"ok": false, "stride": 0}
	if mm == null or mm.instance_count < 2:
		return layout
	var probe_position := Vector2(12345.0, 6789.0)
	var probe_scale := 3.0
	var probe_colour := Color(0.25, 0.5, 0.75, 1.0)
	var probe_custom := Color(0.11, 0.22, 0.33, 0.44)
	mm.set_instance_transform_2d(
		0, Transform2D(0.0, Vector2(probe_scale, probe_scale), 0.0, probe_position))
	mm.set_instance_color(0, probe_colour)
	if with_custom:
		mm.set_instance_custom_data(0, probe_custom)
	var raw: PackedFloat32Array = mm.buffer
	if raw.is_empty():
		return layout
	var origin_x := -1
	for i in raw.size():
		if absf(raw[i] - probe_position.x) < 0.5:
			origin_x = i
			break
	if origin_x < 0:
		return layout
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
	var custom_at := -1
	if with_custom:
		for i in raw.size():
			if absf(raw[i] - float(probe_custom.r)) < 0.001:
				custom_at = i
				break
		# The block is four consecutive floats in the order they were written; a layout where
		# it is not is a layout the sprite path does not understand.
		if custom_at < 0 or custom_at + 3 >= raw.size():
			return layout
		var expected: PackedFloat32Array = PackedFloat32Array([
			probe_custom.g, probe_custom.b, probe_custom.a])
		for k in expected.size():
			if absf(raw[custom_at + 1 + k] - expected[k]) > 0.001:
				return layout
	if origin_y < 0 or color_at < 0 or x_x < 0 or y_y < 0:
		return layout
	# Slice size: written into a second instance and found again, because one instance's origin
	# slot says nothing about how far the next one starts.
	mm.set_instance_transform_2d(
		1, Transform2D(0.0, Vector2(probe_scale, probe_scale), 0.0, Vector2(111.0, 222.0)))
	var second: PackedFloat32Array = mm.buffer
	var second_origin := -1
	for i in range(origin_x + 1, second.size()):
		if absf(second[i] - 111.0) < 0.5:
			second_origin = i
			break
	if second_origin < 0:
		return layout
	layout = {
		"ok": true,
		"stride": second_origin - origin_x,
		"origin_x": origin_x,
		"origin_y": origin_y,
		"color": color_at,
		"x_x": x_x,
		"y_y": y_y,
		"custom": custom_at,
	}
	# The probe's own values are not soldiers: clear the instances it wrote to.
	mm.visible_instance_count = 0
	return layout


## The six buffer offsets a sprite writer needs, from a measured layout, or an empty array when
## the layout is not understood. Flat and typed because it is read once per soldier per pack.
static func offsets_from(layout: Dictionary) -> PackedInt32Array:
	if not bool(layout.get("ok", false)):
		return PackedInt32Array()
	var offsets := PackedInt32Array([
		int(layout.get("x_x", -1)), int(layout.get("y_y", -1)),
		int(layout.get("origin_x", -1)), int(layout.get("origin_y", -1)),
		int(layout.get("color", -1)), int(layout.get("custom", -1)),
	])
	var understood := int(layout.get("stride", 0)) > 0 and offsets.size() == 6
	for offset in offsets:
		understood = understood and offset >= 0
	return offsets if understood else PackedInt32Array()


## The multimesh every renderer's sprite batch is built from: one quad, per-instance colour for
## the tint and per-instance custom data for the frame, NEAREST filtered because the art is
## pixel art and a hard pixel edge is the point.
static func build_batch(texture: Texture2D, capacity: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	mm.instance_count = maxi(1, capacity)
	mm.visible_instance_count = 0
	return mm
