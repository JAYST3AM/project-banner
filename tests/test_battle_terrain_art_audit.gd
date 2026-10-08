extends TestCase
## Asset QA follows the biome catalogue, never speculative filenames.
## Missing art is intentionally allowed while Hermes' factory runs.


func run() -> void:
	await _tick()
	_test_exact_64px_wrap_contract()
	_test_ground_opacity_and_overlay_alpha()
	_test_catalogue_audit_does_not_invent_paths()
	_complete()


func _solid_tile(ink: Color) -> Image:
	var image := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(ink)
	return image


func _test_exact_64px_wrap_contract() -> void:
	section("an installed ground image is exactly 64px and seamless")
	var solid := _solid_tile(Color("516438"))
	equal(BattleTerrainArtAudit.inspect_image(solid, true).size(), 0,
		"opaque 64px texture with matching edges passes")
	solid.set_pixel(0, 20, Color("1a2d12"))
	check(not BattleTerrainArtAudit.inspect_image(solid, true).is_empty(),
		"a visible opposite-edge mismatch is rejected")
	var large := Image.create_empty(128, 128, false, Image.FORMAT_RGBA8)
	large.fill(Color.WHITE)
	check(not BattleTerrainArtAudit.inspect_image(large, true).is_empty(),
		"128px output cannot silently enter the 64px atlas")


func _test_ground_opacity_and_overlay_alpha() -> void:
	section("ground must be opaque; overlays can use meaningful alpha")
	var glass := _solid_tile(Color(0.4, 0.5, 0.3, 0.5))
	check(not BattleTerrainArtAudit.inspect_image(glass, true).is_empty(),
		"ground with transparent pixels is rejected")
	equal(BattleTerrainArtAudit.inspect_image(glass, false).size(), 0,
		"transparent overlay is permitted when its edges wrap")


func _test_catalogue_audit_does_not_invent_paths() -> void:
	section("factory audit follows the existing seven biome declarations")
	var catalog := BiomeCatalog.load_from()
	check(catalog.is_valid(), "terrain catalogue loaded")
	var plains := BattleTerrainArtAudit.inspect_biome(catalog, "plains")
	equal(int(plains["declared"]), 24,
		"plains declares precisely 16 ground and 8 overlay PNGs")
	for biome_id in catalog.order:
		var report := BattleTerrainArtAudit.inspect_biome(catalog, biome_id)
		check((report["errors"] as Array).is_empty(),
			"existing assets for %s match the published tile contract" % biome_id)
		var declared := int(report["declared"])
		var accounted := (report["valid"] as Array).size() + 			(report["missing"] as Array).size()
		equal(accounted, declared,
			"every declared %s tile is present or awaiting import" % biome_id)
