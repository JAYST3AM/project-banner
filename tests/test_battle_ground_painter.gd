extends TestCase
## Slice C: the battlefield ground painter - a deterministic, renderer-free image generator.
##
## The boundary this suite holds to: BattlefieldTerrain supplies the data, BattleGroundPainter converts it
## into an image, and the views decide whether and how to display it. Nothing here touches the authored atlas
## renderer, the GPU field, shaders or LOD. The two cases in the original worktree suite that exercised
## TerrainGround - the authored renderer and its type map - are deliberately NOT carried over: they belong to
## the scenery work, and this slice is the generator alone.
##
## Where a property cannot be set directly, the fixture uses data the generator actually produced and asserts
## a relationship, rather than reaching into private arrays or restating the formula under test.


func run() -> void:
	await _tick()
	_test_ground_is_deterministic_and_scaled()
	_test_ground_has_visual_detail()
	_test_ground_does_not_mutate_terrain()
	_test_image_geometry_and_the_texel_clamp()
	_test_soil_colours_cover_every_type_and_fall_back()
	_test_vegetation_and_wetness_apply_only_when_present()
	_test_each_type_motif_paints_a_distinct_block()
	_test_output_is_a_valid_opaque_rgba_image()
	_test_seed_changes_the_grain_not_the_geometry()
	_test_raised_ground_is_lit_and_hollows_are_shaded()
	_test_a_flat_field_is_lit_only_by_altitude()
	_test_type_motifs_are_local_and_type_driven()
	_test_invalid_or_missing_terrain_yields_no_image()
	_complete()


const SEED := 70717
const FIELD := Vector2(100.0, 60.0)
## Mirrors the ceiling inside the painter's own clamp call.
const TEXEL_CEILING := 6
## The green the painter's vegetation pass lerps toward, named here so the assertion reads as intent.
const VEGETATION_GREEN := Color("475a39")


func _terrain(seed_value: int = SEED, field: Vector2 = FIELD) -> BattlefieldTerrain:
	return BattlefieldTerrain.generate(seed_value, field, GameManager.config())


## The colour a cell would be painted before the illumination term is applied: base, then the soil tint, then
## the vegetation and wetness passes. Built from composable helpers so an assertion about ONE pass can hold
## the others constant and cannot be satisfied by a different pass moving the colour.
func _pre_shade_colour(terrain: BattlefieldTerrain, index: int) -> Color:
	return _with_wetness(_with_vegetation(_soil_only_colour(terrain, index), terrain, index),
		terrain, index)


func _test_ground_is_deterministic_and_scaled() -> void:
	section("battlefield pixel ground is reproducible")
	var terrain := _terrain()
	check(terrain.is_valid(), "terrain exists")
	var a := BattleGroundPainter.bake(terrain)
	var b := BattleGroundPainter.bake(terrain)
	not_null(a, "first fallback image generated")
	not_null(b, "second fallback image generated")
	if a == null or b == null:
		return
	equal(a.get_size(), b.get_size(), "repeated bakes have identical bounds")
	equal(a.get_data(), b.get_data(), "repeated bakes have byte-identical pixels")
	check(a.get_width() > terrain.cols and a.get_height() > terrain.rows,
		"the rendered pixel grid has more detail than the simulation cells")


func _test_ground_has_visual_detail() -> void:
	section("ground is legible beyond a single block colour per cell")
	var image := BattleGroundPainter.bake(_terrain())
	if image == null:
		check(false, "image exists")
		return
	var unique: Dictionary = {}
	for y in mini(image.get_height(), 32):
		for x in mini(image.get_width(), 32):
			unique[image.get_pixel(x, y).to_html()] = true
	greater(float(unique.size()), 4.0, "a small area contains multiple muted pixel tones")


func _test_ground_does_not_mutate_terrain() -> void:
	section("painting ground never modifies combat terrain")
	var terrain := _terrain()
	var before := terrain.to_dict()
	var image := BattleGroundPainter.bake(terrain)
	check(image != null, "the ground renders")
	equal(terrain.to_dict(), before, "simulation terrain is unchanged by rendering")


func _test_image_geometry_and_the_texel_clamp() -> void:
	section("the image is sized from the cell grid, with texels-per-cell clamped at both ends")
	var normal := _terrain()
	var image := BattleGroundPainter.bake(normal)
	if image == null:
		check(false, "a normal field renders")
		return
	var per_cell := mini(TEXEL_CEILING, maxi(1, BattleGroundPainter.TARGET_WIDTH / maxi(normal.cols, normal.rows)))
	equal(image.get_size(), Vector2i(normal.cols * per_cell, normal.rows * per_cell),
		"the image is the cell grid scaled by its texels per cell")
	# A tiny field: the oversampling is capped, so it never explodes the image.
	var tiny := _terrain(SEED, Vector2(12.0, 12.0))
	check(tiny.cols <= 3 and tiny.rows <= 3, "the tiny fixture really is tiny")
	var tiny_image := BattleGroundPainter.bake(tiny)
	if tiny_image == null:
		check(false, "a tiny field renders")
		return
	equal(tiny_image.get_width(), tiny.cols * TEXEL_CEILING, "oversampling stops at the ceiling")
	# The floor, without paying for a square field. The clamp depends on max(cols, rows), so a long, narrow
	# battlefield reaches the same boundary for a fraction of the cells: 4100 x 8 world units at the default
	# four-unit cell size is a 1025 x 2 grid, past the 1024 target, so each cell gets exactly one texel.
	var narrow := _terrain(SEED, Vector2(4100.0, 8.0))
	check(maxi(narrow.cols, narrow.rows) > BattleGroundPainter.TARGET_WIDTH,
		"the narrow fixture really does exceed the target width")
	check(narrow.cols * narrow.rows < 4000,
		"and it reaches that boundary with a few thousand cells, not over a million")
	var narrow_image := BattleGroundPainter.bake(narrow)
	if narrow_image == null:
		check(false, "a narrow field renders"); return
	equal(narrow_image.get_size(), Vector2i(narrow.cols, narrow.rows),
		"at the floor the image is exactly one texel per cell")
	check(narrow_image.get_width() > 0 and narrow_image.get_height() > 0,
		"the floor cannot produce a zero-sized image")


func _test_soil_colours_cover_every_type_and_fall_back() -> void:
	section("every soil the terrain can report has a colour, and unknown soils fall back")
	var fallback := Color("123456")
	equal(BattleGroundPainter._soil_colour("grass", fallback), Color("68704a"), "grass")
	equal(BattleGroundPainter._soil_colour("dirt", fallback), Color("7b6547"), "dirt")
	equal(BattleGroundPainter._soil_colour("silt", fallback), Color("796e54"), "silt")
	equal(BattleGroundPainter._soil_colour("sand", fallback), Color("867655"), "sand")
	equal(BattleGroundPainter._soil_colour("rock", fallback), Color("73716a"), "rock")
	equal(BattleGroundPainter._soil_colour("gravel", fallback), Color("7a7665"), "gravel")
	equal(BattleGroundPainter._soil_colour("mudflat", fallback), Color("514a38"), "mudflat")
	equal(BattleGroundPainter._soil_colour("something-else", fallback), fallback,
		"an unknown soil keeps the caller's colour rather than inventing one")


func _test_vegetation_and_wetness_apply_only_when_present() -> void:
	section("vegetation and wetness change the ground only on the cells that carry them")
	# The painter applies vegetation only above 0.3 and wetness only above 0.25. Whether a given generated
	# field contains cells on BOTH sides of those thresholds is the generator's business, so this asserts the
	# behaviour on whichever side is actually present, and names the value it used in every message. That way
	# the test cannot pass by finding nothing, and it reports the real ranges when it runs.
	var terrain := _terrain()
	var veg_high := 0
	var veg_low := 0
	var wet_high := 0
	var wet_low := 0
	for index in terrain.cell_count():
		if terrain.vegetation_of_cell(index) > terrain.vegetation_of_cell(veg_high):
			veg_high = index
		if terrain.vegetation_of_cell(index) < terrain.vegetation_of_cell(veg_low):
			veg_low = index
		if terrain.wetness_of_cell(index) > terrain.wetness_of_cell(wet_high):
			wet_high = index
		if terrain.wetness_of_cell(index) < terrain.wetness_of_cell(wet_low):
			wet_low = index
	var cases := 0
	var veg_top := terrain.vegetation_of_cell(veg_high)
	if veg_top > 0.3:
		check(_pre_shade_colour(terrain, veg_high) != _soil_only_colour(terrain, veg_high),
			"a vegetated cell (%.3f) is changed by the vegetation pass" % veg_top)
		check(_colour_distance(_pre_shade_colour(terrain, veg_high), VEGETATION_GREEN)
			< _colour_distance(_soil_only_colour(terrain, veg_high), VEGETATION_GREEN),
			"and pulled toward the vegetation green")
		cases += 1
	var veg_bottom := terrain.vegetation_of_cell(veg_low)
	if veg_bottom <= 0.3:
		check(_pre_shade_colour(terrain, veg_low)
			== _with_wetness(_soil_only_colour(terrain, veg_low), terrain, veg_low),
			"a cell at or below the vegetation threshold (%.3f) gets no vegetation, wetness aside"
				% veg_bottom)
		cases += 1
	var wet_top := terrain.wetness_of_cell(wet_high)
	if wet_top > 0.25:
		check(_pre_shade_colour(terrain, wet_high).v <= _soil_only_colour(terrain, wet_high).v,
			"a wet cell (%.3f) is never brightened by the wetness pass" % wet_top)
		cases += 1
	var wet_bottom := terrain.wetness_of_cell(wet_low)
	if wet_bottom <= 0.25:
		check(_pre_shade_colour(terrain, wet_low)
			== _with_vegetation(_soil_only_colour(terrain, wet_low), terrain, wet_low),
			"a cell at or below the wetness threshold (%.3f) gets no wetness, vegetation aside"
				% wet_bottom)
		cases += 1
	check(cases >= 2, "the field exercised at least two threshold cases (%d of 4)" % cases)


func _test_each_type_motif_paints_a_distinct_block() -> void:
	section("water, rough, cliff and woods each paint their own block")
	var terrain := _terrain()
	var index := terrain.cell_count() / 2
	var centre := terrain.cell_centre(index)
	var blocks: Dictionary = {}
	for kind in ["water", "rough", "cliff", "woods"]:
		check(terrain.set_type_at(centre, kind), "the fixture can set the cell to %s" % kind)
		var image := BattleGroundPainter.bake(terrain)
		if image == null:
			check(false, "the ground renders with a %s cell" % kind)
			return
		var per_cell := maxi(1, image.get_width() / maxi(1, terrain.cols))
		var col := index % terrain.cols
		var row := index / terrain.cols
		var signature := ""
		for py in per_cell:
			for px in per_cell:
				signature += image.get_pixel(col * per_cell + px, row * per_cell + py).to_html()
		blocks[kind] = signature
		check(signature.length() > 0, "the %s cell has texels of its own" % kind)
	equal(blocks.size(), 4, "all four types were baked")
	var distinct: Dictionary = {}
	for kind in blocks:
		distinct[blocks[kind]] = true
	equal(distinct.size(), 4, "and no two types paint an identical block")


func _test_output_is_a_valid_opaque_rgba_image() -> void:
	section("the baked image is usable as a texture: RGBA8, opaque, and fully filled")
	var image := BattleGroundPainter.bake(_terrain())
	if image == null:
		check(false, "the ground renders")
		return
	equal(image.get_format(), Image.FORMAT_RGBA8, "the image is RGBA8")
	check(image.get_width() > 0 and image.get_height() > 0, "it has real dimensions")
	var opaque := true
	var filled := true
	for y in mini(image.get_height(), 32):
		for x in mini(image.get_width(), 32):
			var pixel := image.get_pixel(x, y)
			if pixel.a < 0.999:
				opaque = false
			if pixel.r == 0.0 and pixel.g == 0.0 and pixel.b == 0.0:
				filled = false
	check(opaque, "every sampled pixel is fully opaque")
	check(filled, "and none is left black, which is what an unwritten texel of a fresh image is")


## Color has no distance method, so compare in RGB space explicitly.
func _colour_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## The colour as far as the soil tint. The vegetation and wetness assertions compare AGAINST this, so they
## cannot be satisfied by the soil step alone.
func _soil_only_colour(terrain: BattlefieldTerrain, index: int) -> Color:
	return terrain.colour_of_cell(index).lerp(
		BattleGroundPainter._soil_colour(terrain.soil_id_of_cell(index), terrain.colour_of_cell(index)),
		0.35)


## One pass at a time, so a test can hold the other constant. Both mirror the painter's own thresholds.
func _with_vegetation(base: Color, terrain: BattlefieldTerrain, index: int) -> Color:
	var vegetation := clampf(terrain.vegetation_of_cell(index), 0.0, 1.0)
	if vegetation > 0.3:
		return base.lerp(VEGETATION_GREEN, vegetation * 0.14)
	return base


func _with_wetness(base: Color, terrain: BattlefieldTerrain, index: int) -> Color:
	var wetness := clampf(terrain.wetness_of_cell(index), 0.0, 1.0)
	if wetness > 0.25:
		return base.darkened((wetness - 0.25) * 0.18)
	return base


func _test_seed_changes_the_grain_not_the_geometry() -> void:
	section("a different seed regrains the field without changing the terrain it describes")
	var first := BattleGroundPainter.bake(_terrain(SEED))
	var second := BattleGroundPainter.bake(_terrain(SEED + 1))
	if first == null or second == null:
		check(false, "both fields render")
		return
	equal(first.get_size(), second.get_size(), "the geometry follows the grid, not the seed")
	check(first.get_data() != second.get_data(), "a different seed produces a different image")


func _test_raised_ground_is_lit_and_hollows_are_shaded() -> void:
	section("the illumination term lights ground raised above its neighbours and shades ground below")
	var terrain := _terrain()
	var low := terrain.min_height()
	var span := maxf(0.001, terrain.max_height() - low)
	var lit := -1
	var shaded := -1
	for row in terrain.rows:
		for col in terrain.cols:
			var index := row * terrain.cols + col
			var here := terrain.height_of_cell(index)
			var left := terrain.height_of_cell(row * terrain.cols + maxi(0, col - 1))
			var above := terrain.height_of_cell(maxi(0, row - 1) * terrain.cols + col)
			var relief := here - (left + above) * 0.5
			var altitude := (here - low) / span
			# Both picks also constrain altitude, because the shade is relief PLUS an altitude term: a hollow
			# high on the map can still come out brighter than its base colour, and that is correct.
			if relief > 0.35 and altitude < 0.6 and lit < 0:
				lit = index
			elif relief < -0.35 and altitude < 0.4 and shaded < 0:
				shaded = index
			if lit >= 0 and shaded >= 0:
				break
		if lit >= 0 and shaded >= 0:
			break
	check(lit >= 0, "the generated field has a cell standing proud of its neighbours")
	check(shaded >= 0, "and one lying below them")
	if lit < 0 or shaded < 0:
		return
	var lit_colour := BattleGroundPainter._paint_colour(terrain, lit, lit % terrain.cols,
		lit / terrain.cols, low, span)
	check(lit_colour.v > _pre_shade_colour(terrain, lit).v,
		"a cell raised above its neighbours is painted brighter than the same cell shaded by nothing")
	var shaded_colour := BattleGroundPainter._paint_colour(terrain, shaded, shaded % terrain.cols,
		shaded / terrain.cols, low, span)
	check(shaded_colour.v < _pre_shade_colour(terrain, shaded).v,
		"and one lying below them is painted darker than the same cell shaded by nothing")


func _test_a_flat_field_is_lit_only_by_altitude() -> void:
	section("with no relief, brightness comes only from how high the cell sits")
	var terrain := _terrain()
	var low := terrain.min_height()
	var span := maxf(0.001, terrain.max_height() - low)
	var found := -1
	for row in terrain.rows:
		for col in terrain.cols:
			var index := row * terrain.cols + col
			var here := terrain.height_of_cell(index)
			var left := terrain.height_of_cell(row * terrain.cols + maxi(0, col - 1))
			var above := terrain.height_of_cell(maxi(0, row - 1) * terrain.cols + col)
			if absf(here - (left + above) * 0.5) < 0.02 and absf((here - low) / span - 0.5) < 0.06:
				found = index
				break
		if found >= 0:
			break
	if found < 0:
		check(true, "this field has no exactly-flat cell at mid altitude to check - skipped, not failed")
		return
	var colour := BattleGroundPainter._paint_colour(terrain, found, found % terrain.cols,
		found / terrain.cols, low, span)
	check(absf(colour.v - _pre_shade_colour(terrain, found).v) < 0.02,
		"flat ground at mid altitude is left essentially unshaded")


func _test_type_motifs_are_local_and_type_driven() -> void:
	section("changing one cell's terrain type changes that cell's texels and little else")
	var terrain := _terrain()
	var before := BattleGroundPainter.bake(terrain)
	if before == null:
		check(false, "the ground renders")
		return
	var index := terrain.cell_count() / 2
	var kind := terrain.type_id_of_cell(index)
	var replacement := "water" if kind != "water" else "woods"
	check(terrain.set_type_at(terrain.cell_centre(index), replacement),
		"the fixture can set a cell's type")
	var after := BattleGroundPainter.bake(terrain)
	if after == null:
		check(false, "the ground renders after the type change")
		return
	equal(after.get_size(), before.get_size(), "the image geometry does not depend on the types")
	var per_cell := maxi(1, before.get_width() / maxi(1, terrain.cols))
	var target_col := index % terrain.cols
	var target_row := index / terrain.cols
	var inside := 0
	var outside := 0
	var total := before.get_width() * before.get_height()
	for y in before.get_height():
		for x in before.get_width():
			if before.get_pixel(x, y) == after.get_pixel(x, y):
				continue
			if x / per_cell == target_col and y / per_cell == target_row:
				inside += 1
			else:
				outside += 1
	greater(float(inside), 0.0, "the changed cell's own texels are repainted")
	check(float(outside) < float(total) * 0.06,
		"the rest of the field is left alone, relief apart")


func _test_invalid_or_missing_terrain_yields_no_image() -> void:
	section("a missing or invalid terrain returns no image rather than a broken one")
	var unbuilt := BattlefieldTerrain.new()
	check(not unbuilt.is_valid(), "a terrain that was never generated is invalid")
	equal(BattleGroundPainter.bake(unbuilt), null, "an invalid terrain bakes nothing")
	equal(BattleGroundPainter.bake(null), null, "and so does no terrain at all")
	# A zero-sized request is not the invalid path: the generator clamps it to its own minimum.
	var clamped := BattlefieldTerrain.generate(SEED, Vector2.ZERO, GameManager.config())
	check(clamped.is_valid(),
		"a zero-sized request is clamped to the generator's minimum instead of failing")
	equal(clamped.size, Vector2(8.0, 8.0), "and that minimum is eight world units a side")
	not_null(BattleGroundPainter.bake(clamped), "so it bakes a real, if tiny, image")
