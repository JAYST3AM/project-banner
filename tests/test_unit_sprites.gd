extends TestCase
## The battle's unit sprites: the atlas table, the animation plan, and the placement maths.
##
## [b]What this guards.[/b] The sprites themselves need a window, a GPU and an imported atlas -
## none of which a headless run has, which is why the field's instance-buffer layout is measured
## at runtime and the batch simply does not exist without it. What a headless run [i]can[/i] pin
## is the arithmetic every frame of every soldier is drawn from: which animation a soldier is in,
## which frame of it, and where that frame lands. Those are static and pure here, so they are
## tested against hand-worked numbers rather than against the code that calls them.
##
## The atlas table itself is checked only if the pack is on this machine. The art is git-ignored
## third-party work (Zerie's Tiny RPG pack - see assets/art_source/units/tiny_rpg/README.md), so
## a fresh clone passes without it and the field draws its discs, exactly as before.

const SEED := 51501
const PER_SIDE := 4


func run() -> void:
	await _tick()
	_test_the_priority_order_of_the_animations()
	_test_a_frame_is_held_for_whole_ticks()
	_test_the_death_animation_stops_on_its_last_frame()
	_test_the_placement_puts_the_anchor_at_the_soldiers_feet()
	_test_a_flip_mirrors_the_frame_without_moving_it()
	_test_the_fields_own_geometry_clears_the_sprite()
	_test_both_sides_are_the_soldier_and_read_from_the_tint()
	_test_the_precomputed_tables_hold_together_when_the_art_is_present()
	_test_the_instance_write_follows_the_layout()
	_test_the_writer_matches_the_pure_functions()
	_test_the_atlas_table_holds_together_when_the_art_is_present()
	# A runtime error inside a test function aborts that function without recording a failure -
	# GDScript has no try/catch - so a suite whose static calls all failed would still reach
	# _complete with a handful of assertions and report PASS. The floor is the guard: the full
	# suite makes well over thirty assertions even with the art absent.
	greater(float(checks), 25.0, "the suite ran its assertions rather than aborting before them")
	_complete()


func _test_the_priority_order_of_the_animations() -> void:
	section("death outranks a wound, a wound outranks a blow, a blow outranks a step")
	var hurt := 12
	var attack := 12
	equal(UnitArt.plan(false, true, 0, 0, hurt, attack), UnitArt.DEATH,
		"a fallen soldier holds his death animation however recently he fought")
	equal(UnitArt.plan(true, true, 3, 3, hurt, attack), UnitArt.HURT,
		"struck three ticks ago: he is showing the wound, not mid-swing")
	equal(UnitArt.plan(true, true, 40, 3, hurt, attack), UnitArt.ATTACK,
		"the wound has expired and the blow has not: he is swinging")
	equal(UnitArt.plan(true, true, 40, 40, hurt, attack), UnitArt.WALK,
		"both windows have expired: a soldier who has moved is walking")
	equal(UnitArt.plan(true, false, 40, 40, hurt, attack), UnitArt.IDLE,
		"and a soldier who has not moved is standing")
	equal(UnitArt.plan(true, true, -1, -1, hurt, attack), UnitArt.WALK,
		"an age of -1 means it never happened, and never triggers")


func _test_a_frame_is_held_for_whole_ticks() -> void:
	section("a frame is held for whole ticks, and the loops wrap")
	equal(UnitArt.ticks_per_frame(140.0, 30.0), 4, "an idle frame at 140 ms and 30 ticks a second")
	equal(UnitArt.ticks_per_frame(140.0, 60.0), 8, "and the same frame at 60")
	equal(UnitArt.ticks_per_frame(65.0, 30.0), 2, "an attack frame at 65 ms is two ticks")
	equal(UnitArt.ticks_per_frame(95.0, 30.0), 3, "a walk frame at 95 ms is three")
	equal(UnitArt.ticks_per_frame(1.0, 30.0), 1, "nothing rounds down to zero ticks")
	equal(UnitArt.frame(UnitArt.IDLE, 0, 4, 6), 0, "tick zero is the first idle frame")
	equal(UnitArt.frame(UnitArt.IDLE, 11, 4, 6), 2, "eleven ticks in is frame two")
	equal(UnitArt.frame(UnitArt.WALK, 12, 3, 8), 4, "the walk cycle advances")
	equal(UnitArt.frame(UnitArt.WALK, 24, 3, 8), 0, "and wraps to the start")


func _test_the_death_animation_stops_on_its_last_frame() -> void:
	section("a corpse holds its pose")
	equal(UnitArt.frame(UnitArt.DEATH, 0, 3, 4), 0, "the first frame of the fall")
	equal(UnitArt.frame(UnitArt.DEATH, 10, 3, 4), 3, "once fallen, the last frame")
	equal(UnitArt.frame(UnitArt.DEATH, 100000, 3, 4), 3, "and it stays there")


func _test_the_placement_puts_the_anchor_at_the_soldiers_feet() -> void:
	section("the frame's anchor lands on the soldier's feet")
	# Hand-worked: a 38x31 cell at 0.16 units a pixel, anchor 15.5 px from the cell's left edge,
	# feet at (10, 20). The quad is centred on its own origin, so the body's centre column lands
	# at 10 + 38*0.16/2 - 15.5*0.16 = 10.56 and the cell's bottom edge at 20 - 31*0.16/2 = 17.52.
	var origin := UnitArt.origin(
		Vector2(10.0, 20.0), Vector2(38.0, 31.0), Vector2(15.5, 0.0), 0.16)
	approx(origin.x, 10.56, 0.001, "the body's centre column is placed on the soldier's x")
	approx(origin.y, 17.52, 0.001, "and the cell's bottom edge on his feet")
	# An anchor at the dead centre of the cell is the plain centred case.
	var centred := UnitArt.origin(
		Vector2(10.0, 20.0), Vector2(38.0, 31.0), Vector2(19.0, 0.0), 0.16)
	approx(centred.x, 10.0, 0.001, "an anchor in the middle of the cell draws the cell centred")


func _test_a_flip_mirrors_the_frame_without_moving_it() -> void:
	section("a flip mirrors the sampling and nothing else")
	var uv := Rect2(0.25, 0.125, 0.0625, 0.0625)
	var normal := UnitArt.custom(uv, false)
	equal(normal, Vector4(0.25, 0.125, 0.0625, 0.0625), "unflipped, the frame is itself")
	var flipped := UnitArt.custom(uv, true)
	approx(flipped.x, 0.3125, 0.0001, "flipped, the rect starts at the frame's right edge")
	approx(flipped.z, -0.0625, 0.0001, "and runs backwards")
	approx(flipped.y, normal.y, 0.0001, "the row is untouched")
	approx(flipped.w, normal.w, 0.0001, "and so is the height")
	# A uv rect's own end, so the assertion reads as the mirror it is: the flipped rect samples
	# the frame's last column exactly where the unflipped one samples its first.
	approx(normal.x, 0.25, 0.0001, "the unflipped frame samples its left edge at the quad's left")
	approx(flipped.x + flipped.z, 0.25, 0.0001, "the flipped frame samples its right edge there")


## The field's own numbers, not the art's: where a man stands on his disc, and a bar that clears
## the tallest frame. They live on [SoldierField] because they belong to that renderer's
## geometry - and referencing the class here means a field that does not compile fails this
## suite rather than passing it by never being mentioned.
func _test_the_fields_own_geometry_clears_the_sprite() -> void:
	section("the field's bar clears the tallest sprite frame")
	greater(SoldierField.FOOT_LIFT, 0.0, "the sprite's feet are lifted above the soldier's position")
	greater(SoldierField.SPRITE_BAR_LIFT, SoldierField.BAR_LIFT,
		"the bar is lifted higher for the sprites than it was for the discs")
	greater(SoldierField.SPRITE_BAR_LIFT, SoldierField.FOOT_LIFT,
		"and higher than the foot lift, or it would be drawn across his chest")


func _test_both_sides_are_the_soldier_and_read_from_the_tint() -> void:
	section("both sides are the soldier, separated by the tint")
	equal(UnitArt.key_for_side(BattleContext.SIDE_PLAYER), UnitArt.CHARACTER_PLAYER,
		"the player's side is the soldier")
	equal(UnitArt.key_for_side(BattleContext.SIDE_ENEMY), UnitArt.CHARACTER_PLAYER,
		"and so is the enemy's - the owner's call, the orc is not used")
	not_equal(UnitArt.side_tint(true), UnitArt.side_tint(false),
		"the two sides are tinted apart, or nobody could tell them apart")
	equal(UnitArt.side_tint(true), UnitArt.TINT_PLAYER, "the player's soldier is left natural")


## The precomputed tables are what a renderer's per-soldier loop reads, so they are the part of
## this pipeline most worth pinning: a table that disagreed with [method UnitArt.uv_rect] would
## draw the wrong frames at speed instead of failing.
func _test_the_precomputed_tables_hold_together_when_the_art_is_present() -> void:
	section("the precomputed per-character tables, when the pack is on this machine")
	var art := UnitArt.load_if_present()
	if art == null:
		check(true, "absent art is a legitimate outcome, not a failure")
		return
	for key in [UnitArt.CHARACTER_PLAYER, UnitArt.CHARACTER_ENEMY]:
		var data := art.renderer_data(key, 30.0)
		var ticks: PackedInt32Array = data["ticks"]
		var frames: PackedInt32Array = data["frames"]
		var uv: PackedVector4Array = data["uv"]
		var stride := int(data["uv_stride"])
		var widest := 1
		for animation in UnitArt.ANIMATIONS.size():
			widest = maxi(widest, frames[animation])
		equal(stride, widest, "%s: the uv table's stride is the widest animation" % key)
		equal(uv.size(), UnitArt.ANIMATIONS.size() * stride, "%s: the table is animations x stride" % key)
		for animation in UnitArt.ANIMATIONS.size():
			var rect := art.uv_rect(key, animation, 0)
			var packed_rect: Vector4 = uv[animation * stride]
			approx(packed_rect.x, rect.position.x, 0.000001, "%s %s: uv x agrees" % [key, UnitArt.ANIMATIONS[animation]])
			approx(packed_rect.z, rect.size.x, 0.000001, "%s %s: uv width agrees" % [key, UnitArt.ANIMATIONS[animation]])
		var common: PackedFloat32Array = data["common"]
		var cell := art.cell_size(key)
		var anchor := art.anchor(key)
		approx(common[0], cell.x, 0.000001, "%s: the cell width is in the block" % key)
		approx(common[1], cell.y, 0.000001, "%s: and its height" % key)
		approx(common[2], anchor.x, 0.000001, "%s: the anchor is in it" % key)
		approx(common[4], art.units_per_pixel(), 0.000001, "%s: and the scale" % key)
		var hurt_at := UnitArt.ANIMATIONS.find("hurt")
		equal(common[5], float(int(frames[hurt_at]) * int(ticks[hurt_at])),
			"%s: the hurt window is its own animation's length" % key)
		var attack_at := UnitArt.ANIMATIONS.find("attack")
		equal(common[6], float(int(frames[attack_at]) * int(ticks[attack_at])),
			"%s: and so is the attack window" % key)
		# The packed form and the direct one must not disagree about a mirror.
		var packed: Vector4 = UnitArt.custom_from(uv[0], true)
		var direct: Vector4 = UnitArt.custom(art.uv_rect(key, 0, 0), true)
		approx(packed.x, direct.x, 0.000001, "%s: the packed flip matches the direct one" % key)
		approx(packed.z, direct.z, 0.000001, "%s: including its direction" % key)


## The instance write itself. A headless run has no instance buffers to read back - the engine's
## own [member MultiMesh.buffer] comes back empty under the dummy driver - but the buffer the
## renderer builds is its own [PackedFloat32Array], and the layout it writes into can be injected.
## So the write can be pinned after all: the origin lands where the anchor maths says, the size is
## the character's cell scaled, and the frame rect is a real rectangle of the atlas.
func _test_the_instance_write_follows_the_layout() -> void:
	section("what one packed sprite instance actually contains")
	var art := UnitArt.load_if_present()
	if art == null:
		check(true, "absent art is a legitimate outcome, not a failure")
		return
	var field := SoldierField.new()
	field.art = art
	field.build(8)
	check(not field.has_sprites(), "with no measured layout the batch is not drawn")
	# The engine's own layout for a 2D transform plus colour plus custom data - the shape the
	# render bench probes on this build, injected here because a headless run cannot probe it.
	check(field.adopt_sprite_layout({
		"ok": true, "stride": 16, "x_x": 0, "y_y": 5,
		"origin_x": 3, "origin_y": 7, "color": 8, "custom": 12,
	}), "an injected layout turns the write on")
	var built := ShowcaseBattle.build(
		GameManager.config(), UnitCatalog.load_from(), FormationCatalog.load_from(), 2, SEED)
	var simulator: BattleSimulator = built["simulator"]
	var packed := field.pack(simulator)
	equal(field.sprite_count(), simulator.units.size(), "one instance a soldier")
	equal(field.disc_count(), 0, "and no discs: the sprite is the unit, not a marker on a base")
	equal(int(packed.get("discs", -1)), 0, "the pack says so too, for the bench's report")
	for i in simulator.units.size():
		var unit: BattleUnit = simulator.units[i]
		var key := UnitArt.key_for_side(unit.side)
		var cell := art.cell_size(key)
		var scale := art.units_per_pixel()
		var rect := field.sprite_instance_rect(i)
		approx(rect.size.x, cell.x * scale, 0.001, "the drawn width is the character's cell")
		approx(rect.size.y, cell.y * scale, 0.001, "and its height")
		var expected := UnitArt.origin(
			unit.position + Vector2(0.0, SoldierField.FOOT_LIFT), cell, art.anchor(key), scale)
		approx(rect.position.x, expected.x, 0.001, "the frame's anchor lands on his x")
		approx(rect.position.y, expected.y, 0.001, "and its bottom edge on his feet")
		var custom := field.sprite_instance_custom(i)
		check(custom.x >= 0.0 and custom.x <= 1.0 and custom.y >= 0.0 and custom.y <= 1.0,
			"the frame rect starts inside the atlas")
		check(custom.z != 0.0 and custom.w != 0.0, "and has a size")
	field.free()


## The fused writer both renderers run their soldier loop through is fast because it inlines the
## maths and writes only what changed. That makes it the one place where the hot path could drift
## from the specification - [method UnitArt.plan], [method UnitArt.frame], [method UnitArt.origin],
## [method UnitArt.custom] - so every state a battle produces is staged here and the instance left
## in the buffer is compared against what those pure functions say it should be.
func _test_the_writer_matches_the_pure_functions() -> void:
	section("the fused writer against the pure functions")
	var art := UnitArt.load_if_present()
	if art == null:
		check(true, "absent art is a legitimate outcome, not a failure")
		return
	var field := SoldierField.new()
	field.art = art
	field.build(8)
	if not field.adopt_sprite_layout({
		"ok": true, "stride": 16, "x_x": 0, "y_y": 5,
		"origin_x": 3, "origin_y": 7, "color": 8, "custom": 12,
	}):
		check(false, "the injected layout was refused")
		return
	var built := ShowcaseBattle.build(
		GameManager.config(), UnitCatalog.load_from(), FormationCatalog.load_from(), 2, SEED)
	var simulator: BattleSimulator = built["simulator"]
	var unit: BattleUnit = simulator.units[0]
	var key := UnitArt.key_for_side(unit.side)
	var data := art.renderer_data(key, field.anim_rate)
	var ticks: PackedInt32Array = data["ticks"]
	var counts: PackedInt32Array = data["frames"]
	var living := UnitArt.side_tint(unit.side == BattleContext.SIDE_PLAYER)

	# The deployed army: nobody has moved yet, so the first pack has everybody standing.
	field.pack(simulator)
	_check_instance(art, field, simulator, unit, ticks, counts, UnitArt.IDLE, 0, "first pack")
	approx(field.sprite_instance_colour(0).v, living.v, 0.001, "a living soldier wears his side's tint")

	# The pack that changes nothing: it writes nothing, and what is left in the buffer is still
	# what the pure functions say - the whole point of writing only what changed.
	field.pack(simulator)
	_check_instance(art, field, simulator, unit, ticks, counts, UnitArt.IDLE, 0, "unchanged pack")

	# He walked this pack: the walk loop, and the origin where his new position puts it.
	unit.position += Vector2(0.9, 0.4)
	simulator.tick_index += 1
	field.pack(simulator)
	_check_instance(art, field, simulator, unit, ticks, counts, UnitArt.WALK, 0, "a step")
	# ...and his old position is not where he draws: the origin moved with him.
	var rect := field.sprite_instance_rect(0)
	var stale := UnitArt.origin(
		unit.position - Vector2(0.9, 0.4) + Vector2(0.0, SoldierField.FOOT_LIFT),
		art.cell_size(key), art.anchor(key), art.units_per_pixel())
	check(absf(rect.position.x - stale.x) > 0.01, "the origin followed him rather than staying put")

	# A wound: the hurt pose, from its first frame.
	unit.last_attacked_tick = simulator.tick_index + 1
	simulator.tick_index += 1
	field.pack(simulator)
	_check_instance(art, field, simulator, unit, ticks, counts, UnitArt.HURT, 0, "a wound")

	# A blow of his own: the attack pose. The canvas battle reads a strike off the cooldown
	# jumping, which is the only trace a blow leaves on the unit itself - once the wound has
	# played out, because a wound outranks a blow in the plan.
	unit.cooldown_left += SoldierField.STRIKE_COOLDOWN_JUMP + 1.0
	simulator.tick_index += int(data["common"][5]) + 1
	field.pack(simulator)
	_check_instance(art, field, simulator, unit, ticks, counts, UnitArt.ATTACK, 0, "a blow")

	# And the fall: the death pose held at its first frame, drawn darkened.
	var dying: BattleUnit = simulator.units[1]
	dying.hp = 0.0
	var death_slot := 1
	field.pack(simulator)
	_check_instance(art, field, simulator, dying, ticks, counts, UnitArt.DEATH, 0, "the fall",
		death_slot)
	approx(field.sprite_instance_colour(death_slot).v,
		UnitArt.side_tint(dying.side == BattleContext.SIDE_PLAYER).darkened(SoldierField.FALLEN_DARKEN).v,
		0.001, "and a corpse is drawn darkened")
	field.free()


## One soldier's instance against the specification: his frame rectangle and his placement, both
## derived from [method UnitArt]'s pure functions rather than from the writer's own arithmetic.
func _check_instance(art: UnitArt, field: SoldierField, simulator: BattleSimulator, unit: BattleUnit,
		ticks: PackedInt32Array, counts: PackedInt32Array, animation: int, age: int, label: String,
		slot: int = 0) -> void:
	var key := UnitArt.key_for_side(unit.side)
	var cell := art.cell_size(key)
	var scale := art.units_per_pixel()
	var into := simulator.tick_index + unit.id * UnitArt.PHASE_STRIDE
	if animation != UnitArt.IDLE and animation != UnitArt.WALK:
		into = maxi(0, age)
	var frame := UnitArt.frame(animation, into, ticks[animation], counts[animation])
	var expected := UnitArt.custom(art.uv_rect(key, animation, frame), unit.facing.x < 0.0)
	var custom := field.sprite_instance_custom(slot)
	approx(custom.x, expected.x, 0.0001, "%s: the frame's left edge" % label)
	approx(custom.y, expected.y, 0.0001, "%s: its top edge" % label)
	approx(custom.z, expected.z, 0.0001, "%s: its width" % label)
	approx(custom.w, expected.w, 0.0001, "%s: its height" % label)
	var placement := UnitArt.origin(
		unit.position + Vector2(0.0, SoldierField.FOOT_LIFT), cell, art.anchor(key), scale)
	var rect := field.sprite_instance_rect(slot)
	approx(rect.position.x, placement.x, 0.001, "%s: the anchor on his x" % label)
	approx(rect.position.y, placement.y, 0.001, "%s: the bottom edge on his feet" % label)
	approx(rect.size.x, cell.x * scale, 0.001, "%s: the cell's width" % label)
	approx(rect.size.y, cell.y * scale, 0.001, "%s: and its height" % label)


func _test_the_atlas_table_holds_together_when_the_art_is_present() -> void:
	section("the atlas table, when the pack is on this machine")
	var art := UnitArt.load_if_present()
	if art == null:
		print("    (the pack is not present: the field draws its discs, and that path is unchanged)")
		check(true, "absent art is a legitimate outcome, not a failure")
		return
	greater(art.atlas_size().x, 0.0, "the atlas has a width")
	greater(art.atlas_size().y, 0.0, "and a height")
	greater(art.units_per_pixel(), 0.0, "and a scale")
	var keys: Array[String] = [UnitArt.CHARACTER_PLAYER, UnitArt.CHARACTER_ENEMY]
	for key in keys:
		check(art.has_character(key), "the table has the %s" % key)
		var cell := art.cell_size(key)
		greater(cell.x, 0.0, "%s: the cell has a width" % key)
		greater(cell.y, 0.0, "%s: and a height" % key)
		var anchor := art.anchor(key)
		check(anchor.x >= 0.0 and anchor.x <= cell.x, "%s: the anchor is inside the cell" % key)
		for animation in UnitArt.ANIMATIONS.size():
			var name := UnitArt.ANIMATIONS[animation]
			var frames := art.frames_of(key, animation)
			greater(float(frames), 0.0, "%s %s: how many frames" % [key, name])
			greater(art.frame_ms(key, animation), 0.0, "%s %s: how long a frame is held" % [key, name])
			var rect := art.uv_rect(key, animation, 0)
			check(rect.position.x >= 0.0 and rect.position.y >= 0.0,
				"%s %s: the frame starts inside the atlas" % [key, name])
			check(rect.end.x <= 1.001 and rect.end.y <= 1.001,
				"%s %s: and ends inside it" % [key, name])
			if frames > 1:
				var second := art.uv_rect(key, animation, 1)
				not_equal(second.position.x, rect.position.x,
					"%s %s: frame 1 is a different frame" % [key, name])
			var last := art.uv_rect(key, animation, frames - 1)
			var clamped := art.uv_rect(key, animation, frames + 5)
			equal(clamped.position.x, last.position.x,
				"%s %s: a frame past the end clamps to the last one" % [key, name])
