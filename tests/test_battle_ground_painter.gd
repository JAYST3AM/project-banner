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
	_test_type_motifs_fire_and_plain_types_do_not()
	_test_output_is_a_valid_opaque_rgba_image()
	_test_seed_changes_the_grain_not_the_geometry()
	_test_raised_ground_is_lit_and_hollows_are_shaded()
	_test_altitude_alone_lights_higher_ground()
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
	# Two INDEPENDENTLY generated terrains from the same seed, not the same object baked twice: that is what
	# proves the painter is a function of the terrain data rather than of object identity or call order.
	var terrain := _terrain()
	var twin := _terrain()
	check(terrain.is_valid(), "terrain exists")
	check(twin.is_valid(), "and so does an independently generated twin")
	equal(terrain.signature(), twin.signature(), "the twin really is an equivalent terrain")
	var a := BattleGroundPainter.bake(terrain)
	var b := BattleGroundPainter.bake(terrain)
	var c := BattleGroundPainter.bake(twin)
	not_null(a, "first fallback image generated")
	not_null(b, "second fallback image generated")
	not_null(c, "and the twin's image generated")
	if a == null or b == null or c == null:
		return
	equal(a.get_size(), b.get_size(), "repeated bakes have identical bounds")
	equal(a.get_data(), b.get_data(), "repeated bakes have byte-identical pixels")
	equal(a.get_data(), c.get_data(), "an independently generated equivalent terrain bakes identically")
	check(a.get_width() > terrain.cols and a.get_height() > terrain.rows,
		"the rendered pixel grid has more detail than the simulation cells")
	equal(c.get_size(), a.get_size(), "and the twin's image is the same size")


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
	var signature_before := terrain.signature()
	var image := BattleGroundPainter.bake(terrain)
	check(image != null, "the ground renders")
	equal(terrain.to_dict(), before, "simulation terrain is unchanged by rendering")
	equal(terrain.signature(), signature_before,
		"and its signature is unchanged too, so no map was silently refreshed")


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


## The four terrain types whose motifs override the plain brush pattern.
const MOTIF_TYPES := ["water", "rough", "cliff", "woods"]


## A field that genuinely straddles BOTH thresholds, found by searching seeds. The default field tops out at
## 0.240 wetness, just under the painter's 0.25, so on it the wetness term never fires and the guard below
## would be asserting about a branch that never ran. Returns null rather than a field that only half qualifies,
## so the caller can fail closed.
func _straddling_terrain() -> BattlefieldTerrain:
	for offset in 12:
		var candidate := _terrain(SEED + offset)
		var veg_low := 2.0
		var veg_high := -1.0
		var wet_low := 2.0
		var wet_high := -1.0
		for index in candidate.cell_count():
			veg_low = minf(veg_low, candidate.vegetation_of_cell(index))
			veg_high = maxf(veg_high, candidate.vegetation_of_cell(index))
			wet_low = minf(wet_low, candidate.wetness_of_cell(index))
			wet_high = maxf(wet_high, candidate.wetness_of_cell(index))
		if veg_low <= 0.3 and veg_high > 0.3 and wet_low <= 0.25 and wet_high > 0.25:
			return candidate
	return null


func _test_vegetation_and_wetness_apply_only_when_present() -> void:
	section("vegetation and wetness change the painter's OWN output, on both sides of each threshold")
	# Anchored on BattleGroundPainter._paint_colour - the production function - compared against a model of
	# the same cell with and without the term in question. Comparing one test helper to another would only
	# demonstrate that the helpers agree with each other, which is not evidence about the painter.
	var terrain := _straddling_terrain()
	# No found-check here on purpose: if the search fails, this returns early with cases still 0 and the
	# equal(cases, 4) guard below fails, so the test fails closed without spending an extra assertion.
	if terrain == null:
		return
	var low := terrain.min_height()
	var span := maxf(0.001, terrain.max_height() - low)
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
		var up := _painted(terrain, veg_high, low, span)
		check(up.is_equal_approx(_expected_paint(terrain, veg_high, low, span, true, true)),
			"a vegetated cell (%.3f) matches the model that includes the vegetation term" % veg_top)
		check(not up.is_equal_approx(_expected_paint(terrain, veg_high, low, span, false, true)),
			"and departs from the model without it, so the term really fires in the painter")
		cases += 1
	var veg_bottom := terrain.vegetation_of_cell(veg_low)
	if veg_bottom <= 0.3:
		var down := _painted(terrain, veg_low, low, span)
		check(down.is_equal_approx(_expected_paint(terrain, veg_low, low, span, true, true)),
			"a cell at or below the vegetation threshold (%.3f) matches the model without it" % veg_bottom)
		# The discrimination for this side comes from the PAIR above: the over-threshold witness departs from
		# the model without the term, and this one matches it. Asserting that the term would move this cell
		# would be wrong - below the threshold the term deliberately does nothing.
		check(veg_bottom <= 0.3, "and this witness really is on the far side of the threshold")
		cases += 1
	var wet_top := terrain.wetness_of_cell(wet_high)
	if wet_top > 0.25:
		var wet_up := _painted(terrain, wet_high, low, span)
		check(wet_up.is_equal_approx(_expected_paint(terrain, wet_high, low, span, true, true)),
			"a wet cell (%.3f) matches the model that includes the wetness term" % wet_top)
		check(not wet_up.is_equal_approx(_expected_paint(terrain, wet_high, low, span, true, false)),
			"and departs from the model without it, so the term really fires in the painter")
		cases += 1
	var wet_bottom := terrain.wetness_of_cell(wet_low)
	if wet_bottom <= 0.25:
		var wet_down := _painted(terrain, wet_low, low, span)
		check(wet_down.is_equal_approx(_expected_paint(terrain, wet_low, low, span, true, true)),
			"a cell at or below the wetness threshold (%.3f) matches the model without it" % wet_bottom)
		check(wet_bottom <= 0.25, "and this witness really is on the far side of the threshold")
		cases += 1
	equal(cases, 4, "all four vegetation/wetness threshold cases were exercised - veg %.3f..%.3f, wet %.3f..%.3f" % [veg_top, veg_bottom, wet_top, wet_bottom])


## The painter's own colour for a cell, through its production entry point rather than a test helper.
func _painted(terrain: BattlefieldTerrain, index: int, low: float, span: float) -> Color:
	return BattleGroundPainter._paint_colour(terrain, index, index % terrain.cols, index / terrain.cols,
		low, span)


## The whole pipeline modelled in one place - the pre-shade stages with each conditional term switchable, then
## the painter's own shade formula - so an assertion can hold one term out and compare production against it.
func _expected_paint(terrain: BattlefieldTerrain, index: int, low: float, span: float,
		with_vegetation: bool, with_wetness: bool) -> Color:
	var col := index % terrain.cols
	var row := index / terrain.cols
	var base := _soil_only_colour(terrain, index)
	if with_vegetation:
		base = _with_vegetation(base, terrain, index)
	if with_wetness:
		base = _with_wetness(base, terrain, index)
	var here := terrain.height_of_cell(index)
	var left := terrain.height_of_cell(row * terrain.cols + maxi(0, col - 1))
	var above := terrain.height_of_cell(maxi(0, row - 1) * terrain.cols + col)
	var illumination := clampf((here - (left + above) * 0.5) * 0.085, -0.14, 0.14)
	var altitude := clampf((here - low) / span, 0.0, 1.0)
	var shade := illumination + (altitude - 0.5) * 0.13
	return base.lightened(shade) if shade >= 0.0 else base.darkened(-shade)


func _test_type_motifs_fire_and_plain_types_do_not() -> void:
	section("a motif type departs from the plain brush pattern; a plain type obeys it exactly")
	# The brush pattern alone paints only three colours inside a cell - the base, a 0.095-darkened shadow and a
	# 0.11-lightened highlight - chosen by a hash of the cell and the texel. Water, rough, cliff and woods then
	# OVERRIDE that. So the honest test of a motif is that the block DIVERGES from the brush rule, and the
	# honest test of a plain type is that it matches it exactly. Merely showing the four blocks differ would be
	# satisfied by the base colour changing with the type, which is not the motif at work at all.
	var terrain := _terrain()
	# One cell, chosen so that ONLY its type can move the brush pattern: a type with no motif, and vegetation
	# below the threshold that triggers the tuft overlay. The first two attempts at this control used the
	# middle of the field and then any non-motif type, and both were caught by the assertion below - woods is
	# a motif type, and a plain type with tall vegetation still departs from the rule.
	var target := -1
	var plain := ""
	for cell in terrain.cell_count():
		var candidate := terrain.type_id_of_cell(cell)
		if not candidate in MOTIF_TYPES and terrain.vegetation_of_cell(cell) <= 0.35:
			target = cell
			plain = candidate
			break
	check(target >= 0, "the field contains a plain, low-vegetation cell to test (%s)" % plain)
	if target < 0:
		return
	check(not plain in MOTIF_TYPES, "and its type carries no motif")
	check(terrain.vegetation_of_cell(target) <= 0.35,
		"and its vegetation is below the tuft threshold (%.3f)" % terrain.vegetation_of_cell(target))
	var centre := terrain.cell_centre(target)
	var col := target % terrain.cols
	var row := target / terrain.cols
	var per_cell := mini(TEXEL_CEILING,
		maxi(1, BattleGroundPainter.TARGET_WIDTH / maxi(terrain.cols, terrain.rows)))
	for kind in ["water", "rough", "cliff", "woods", plain]:
		check(terrain.set_type_at(centre, kind), "the fixture can set the cell to %s" % kind)
		var image := BattleGroundPainter.bake(terrain)
		if image == null:
			check(false, "the ground renders with a %s cell" % kind)
			return
		var block: Array[Color] = []
		for py in per_cell:
			for px in per_cell:
				block.append(image.get_pixel(col * per_cell + px, row * per_cell + py))
		var off_rule := _texels_off_the_brush_rule(block, per_cell, col, row, terrain.terrain_seed)
		if kind == plain:
			equal(off_rule, 0, "a plain %s cell obeys the brush pattern exactly" % kind)
		else:
			greater(float(off_rule), 0.0,
				"a %s cell departs from the brush pattern, so its motif fired" % kind)


## How many texels in a cell's block differ from what the plain brush pattern would have painted. The block's
## most common colour is the cell's base: eleven of the seventeen brush values leave the base untouched, so
## the mode identifies it without the test needing to know the pre-shade pipeline.
func _texels_off_the_brush_rule(block: Array[Color], per_cell: int, col: int, row: int,
		seed_value: int) -> int:
	var tally: Dictionary = {}
	var base: Color = block[0]
	var most := 0
	for pixel in block:
		var html := pixel.to_html()
		tally[html] = int(tally.get(html, 0)) + 1
		if tally[html] > most:
			most = tally[html]
			base = pixel
	var shadow := base.darkened(0.095)
	var light := base.lightened(0.11)
	var detail := BattleGroundPainter._mix_id(col, row, seed_value)
	var off_rule := 0
	var at := 0
	for py in per_cell:
		for px in per_cell:
			var brush := (detail + (px / 2) * 17 + (py / 2) * 29) % 17
			var expected := base
			if brush <= 2:
				expected = shadow
			elif brush >= 15:
				expected = light
			if block[at] != expected:
				off_rule += 1
			at += 1
	return off_rule


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
	# The WHOLE image, not a corner of it: an unwritten texel anywhere is the bug this exists to catch.
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.a < 0.999:
				opaque = false
			if pixel.r == 0.0 and pixel.g == 0.0 and pixel.b == 0.0:
				filled = false
	check(opaque, "every sampled pixel is fully opaque")
	check(filled, "and none is left black, which is what an unwritten texel of a fresh image is")


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


func _test_altitude_alone_lights_higher_ground() -> void:
	section("with relief held flat, the higher of two cells receives the brighter shade")
	# The shade is relief PLUS an altitude term. Two cells with zero relief leave altitude as the only
	# difference, and comparing the shade each RECEIVED - rather than their raw colours, which soil and
	# vegetation also move - isolates that term. There is deliberately no branch here that can pass without
	# testing the painter; a field with no flat ground fails this rather than skipping it.
	var terrain := _terrain()
	var low := terrain.min_height()
	var span := maxf(0.001, terrain.max_height() - low)
	var flat_low := -1
	var flat_high := -1
	var lowest_alt := 2.0
	var highest_alt := -1.0
	for row in terrain.rows:
		for col in terrain.cols:
			var index := row * terrain.cols + col
			var here := terrain.height_of_cell(index)
			var left := terrain.height_of_cell(row * terrain.cols + maxi(0, col - 1))
			var above := terrain.height_of_cell(maxi(0, row - 1) * terrain.cols + col)
			if absf(here - (left + above) * 0.5) > 0.01:
				continue
			var altitude := (here - low) / span
			if altitude < lowest_alt:
				lowest_alt = altitude
				flat_low = index
			if altitude > highest_alt:
				highest_alt = altitude
				flat_high = index
	check(flat_low >= 0 and flat_high >= 0, "the field contains flat ground to compare")
	if flat_low < 0 or flat_high < 0:
		return
	check(highest_alt - lowest_alt > 0.1,
		"and that flat ground spans a real altitude range (%.3f to %.3f)" % [lowest_alt, highest_alt])
	if highest_alt - lowest_alt <= 0.1:
		return
	var low_painted := BattleGroundPainter._paint_colour(terrain, flat_low, flat_low % terrain.cols,
		flat_low / terrain.cols, low, span)
	var high_painted := BattleGroundPainter._paint_colour(terrain, flat_high, flat_high % terrain.cols,
		flat_high / terrain.cols, low, span)
	var low_shade := low_painted.v - _pre_shade_colour(terrain, flat_low).v
	var high_shade := high_painted.v - _pre_shade_colour(terrain, flat_high).v
	check(high_shade > low_shade,
		"the higher flat cell takes the brighter shade (%.4f against %.4f)" % [high_shade, low_shade])


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
