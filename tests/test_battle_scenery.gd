extends TestCase
## Scenery is original, deterministic pixel art and is strictly visual-only.


func run() -> void:
	await _tick()
	_test_fallback_art_for_all_kinds()
	_test_fallback_is_deterministic()
	_test_clipping_and_alpha()
	_complete()


func _test_fallback_art_for_all_kinds() -> void:
	section("all configured scenery kinds can draw when art files are missing")
	var biomes := BiomeCatalog.load_from()
	for kind in biomes.prop_kind_ids():
		var img := BattleScenery.fallback_image(kind)
		not_null(img, "generated fallback for %s" % kind)
		if img != null:
			equal(img.get_size(), BattleScenery.FALLBACK_IMAGE_SIZE,
				"scenery size is consistent for %s" % kind)
			check(img.get_pixel(16, 36).a > 0.0,
				"%s has a solid grounded footprint" % kind)


func _test_fallback_is_deterministic() -> void:
	section("fallback scenery is exactly repeatable")
	for kind in ["tree", "rock", "fence", "ruin", "crop"]:
		var first := BattleScenery.fallback_image(kind)
		var second := BattleScenery.fallback_image(kind)
		equal(first.get_data(), second.get_data(),
			"%s pixel pattern is stable" % kind)


func _test_clipping_and_alpha() -> void:
	section("scenery pixel sprites have transparent edges")
	var tree := BattleScenery.fallback_image("tree")
	equal(tree.get_pixel(0, 0).a, 0.0, "sprite margins are transparent")
	check(tree.get_pixel(16, 12).a > 0.0, "tree crown is opaque")
	check(tree.get_pixel(15, 31).a > 0.0, "tree trunk is opaque")
