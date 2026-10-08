extends TestCase
## The battlefield fallback is presentational only and must be deterministic.


func run() -> void:
	await _tick()
	_test_ground_is_deterministic_and_scaled()
	_test_ground_has_visual_detail()
	_test_ground_does_not_mutate_terrain()
	_test_renderer_has_safe_fallback_without_art_or_shader()
	_complete()


func _terrain() -> BattlefieldTerrain:
	return BattlefieldTerrain.generate(70717, Vector2(100.0, 60.0), GameManager.config())


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


func _test_renderer_has_safe_fallback_without_art_or_shader() -> void:
	section("authored ground renderer parses and yields to fallback when unavailable")
	var terrain := _terrain()
	var biomes := BiomeCatalog.load_from()
	var config := GameManager.config()
	var painter := TerrainGround.new()
	not_null(painter, "authored renderer script can be instantiated after revert")
	var shader_available := ResourceLoader.exists(TerrainGround.SHADER_PATH)
	var art_available := TerrainGround.has_art(terrain, biomes)
	var displayed := painter.show_field(terrain, biomes, config)
	if not art_available or not shader_available:
		check(not displayed, "missing assets never claim a successful ground render")
		check(not painter.visible, "the authored layer stays hidden while fallback draws")
		var fallback := BattleGroundPainter.bake(terrain)
		check(fallback != null, "fallback stays available without authored resources")
	else:
		check(displayed, "complete authored ground assets can render")
	painter.free()
