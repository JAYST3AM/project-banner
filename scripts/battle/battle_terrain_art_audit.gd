class_name BattleTerrainArtAudit
extends RefCounted
## Inspect only art paths declared by data/terrain/biomes.json.
## Empty entries for unfinished biomes are valid, not missing assets.
## A shared 64px contract is important because the shader stitches
## source images into a four-subtile atlas without resampling.
const TILE_PIXELS := 64


## Pure image inspection can be run with synthetic pixels in headless tests.
## Seam checks compare the exact opposite edges, as Hermes' pipeline does.
static func inspect_image(image: Image, opaque: bool) -> Array[String]:
	var problems: Array[String] = []
	if image == null:
		problems.append("could not read image")
		return problems
	if image.get_width() != TILE_PIXELS or image.get_height() != TILE_PIXELS:
		problems.append("image is %dx%d, expected 64x64" % [
			image.get_width(), image.get_height()])
		return problems
	var x_seams := 0
	var y_seams := 0
	var translucent := 0
	for n in TILE_PIXELS:
		if image.get_pixel(0, n) != image.get_pixel(TILE_PIXELS - 1, n):
			x_seams += 1
		if image.get_pixel(n, 0) != image.get_pixel(n, TILE_PIXELS - 1):
			y_seams += 1
	if opaque:
		for y in TILE_PIXELS:
			for x in TILE_PIXELS:
				if image.get_pixel(x, y).a < 0.999:
					translucent += 1
	if x_seams > 0 or y_seams > 0:
		problems.append("non-matching wrap edges: %d rows, %d columns" % [
			x_seams, y_seams])
	if translucent > 0:
		problems.append("%d transparent pixels in opaque ground" % translucent)
	return problems


static func _inspect_path(path: String, ground: bool, result: Dictionary) -> void:
	result["declared"] = int(result["declared"]) + 1
	if not path.begins_with("res://"):
		(result["errors"] as Array).append("non-project art path: " + path)
		return
	if not ResourceLoader.exists(path):
		(result["missing"] as Array).append(path)
		return
	var art := load(path) as Texture2D
	if art == null:
		(result["errors"] as Array).append("asset not a Texture2D: " + path)
		return
	var problems := inspect_image(art.get_image(), ground)
	if problems.is_empty():
		(result["valid"] as Array).append(path)
	else:
		for issue in problems:
			(result["errors"] as Array).append(path + ": " + issue)


## Missing declared PNGs go into 'missing', not 'errors': unfinished art
## must never make the procedural battlefield or test runner unusable.
## Existing invalid PNGs *do* create errors so they're reviewed before
## replacing the fallback.
static func inspect_biome(catalog: BiomeCatalog, biome_id: String) -> Dictionary:
	var report := {
		"biome": biome_id,
		"declared": 0,
		"valid": [],
		"missing": [],
		"errors": [],
	}
	if catalog == null or not catalog.has(biome_id):
		(report["errors"] as Array).append("unknown biome: " + biome_id)
		return report
	for entry in catalog.variants(biome_id):
		var variant := entry as Dictionary
		for raw in variant.get("art", []) as Array:
			_inspect_path(str(raw), true, report)
	for entry in catalog.overlays(biome_id):
		var overlay := entry as Dictionary
		for raw in overlay.get("art", []) as Array:
			# Overlay pixel opacity may be intentional, depending on mask art.
			_inspect_path(str(raw), false, report)
	return report
