extends Node
## The ground forge: placeholder pixel art for the battlefield, written from the catalogue.
##
## This is not an art pipeline and it is not trying to be. It exists so that the terrain system has
## something to draw *now*: four ground variants per biome, four detail overlays, the three type looks
## and a sprite for every prop kind, all generated deterministically from the biome's own palette and
## written to the paths the catalogue already names. When the owner's own art arrives it replaces
## these files one for one and nothing in the code changes.
##
## What it does care about, because the renderer depends on it:
## [br]- every ground tile [b]wraps[/b]: the noise lattice is modulo the tile, and the four
##   sub-variants are made only by rolling, turning, mirroring and re-toning - never by cropping or
##   resampling, which break the seam;
## [br]- the palette comes from [code]data/terrain/biomes.json[/code], so a tile belongs to its biome;
## [br]- props are drawn bottom-centre anchored and cropped to their own footprint, which is the
##   convention the sprite baker already uses;
## [br]- the whole run is seeded, so re-running it produces byte-identical files.
##
##   godotc --headless --path "<project>" res://scenes/dev/ground_forge.tscn
##   godotc --headless --path "<project>" res://scenes/dev/ground_forge.tscn -- --biome=plains --report

const TILE := 64
const SEED := 20260918
const BIOME_ROOT := "res://assets/terrain/biomes"
const OVERLAY_ROOT := "res://assets/terrain/overlays"
const TYPE_ROOT := "res://assets/terrain/types"
const PROP_ROOT := "res://assets/terrain/props"

var _biome_filter: String = ""
var _report_only: bool = false
var _written: int = 0
var _seams: Array[String] = []


func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		var argument := str(raw)
		if argument.begins_with("--biome="):
			_biome_filter = argument.trim_prefix("--biome=")
		elif argument == "--report":
			_report_only = true
	_make_directories()
	var biomes := BiomeCatalog.load_from()
	if not biomes.is_valid():
		push_error("ground forge: no biomes to forge")
		get_tree().quit(1)
		return
	for id in biomes.order:
		if not _biome_filter.is_empty() and id != _biome_filter:
			continue
		_forge_biome(biomes, id)
	_forge_overlays(biomes)
	_forge_types()
	_forge_props(biomes)
	print("")
	print("ground forge: %d files written, seed %d" % [_written, SEED])
	print("wrap seams (column 0 against column %d, lower is better):" % (TILE - 1))
	for line in _seams:
		print("  %s" % line)
	print("GROUND FORGE COMPLETE")
	get_tree().quit(0)


func _make_directories() -> void:
	if _report_only:
		return
	for path in [BIOME_ROOT, OVERLAY_ROOT, TYPE_ROOT, PROP_ROOT]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


## ---------- the ground -----------------------------------------------------

## One biome's four variants, four sub-variants each.
##
## The variant's own colour from the catalogue sets its palette: Lush is greener, Dry is yellower,
## Patchy is mixed and Wild is coarser, which is what the four looks are for. They share a common
## base colour deliberately - four grounds of one country, not four countries.
func _forge_biome(biomes: BiomeCatalog, biome_id: String) -> void:
	var palette := _palette_of(biomes, biome_id)
	var variant_count := biomes.variant_count(biome_id)
	for variant_index in variant_count:
		var variant := biomes.variant(biome_id, variant_index)
		var base := biomes.variant_colour(biome_id, variant_index)
		var salt := 1000 + variant_index * 131
		# How strong the variation inside the tile is: the coarser looks are given more of it, which
		# is the "slightly rougher, longer-looking vegetation" idea rather than a new texture.
		var contrast := [0.55, 0.8, 0.7, 1.0][variant_index % 4]
		var speckle := [0.05, 0.16, 0.1, 0.22][variant_index % 4]
		var tile := _fill_tile(base, palette, contrast, speckle, salt)
		var sub_count := maxi(1, biomes.variant_art(biome_id, variant_index).size())
		sub_count = maxi(sub_count, 4)
		for sub in sub_count:
			var copy := _sub_variant(tile, sub)
			var name := _variant_file_name(biomes, biome_id, variant_index, sub)
			var path := "%s/%s/base/%s" % [BIOME_ROOT, biome_id, name]
			_write_png(copy, path)
			if sub == 0:
				_measure_seam(copy, "%s/%s" % [biome_id, name])
	_report_tile_cost(biome_id, variant_count)


func _variant_file_name(biomes: BiomeCatalog, biome_id: String, variant_index: int, sub: int) -> String:
	var wanted := biomes.variant_art(biome_id, variant_index)
	if sub < wanted.size():
		var path := str(wanted[sub])
		return path.get_file()
	var variant_name := biomes.variant_name(biome_id, variant_index).to_lower().replace(" ", "_")
	return "%s_%s_%d.png" % [biome_id, variant_name, sub + 1]


## A tile of wrap-safe value noise in the variant's colour, quantised to a small palette.
##
## Quantised on purpose: pixel art reads because its tones are few and its edges are hard, and a
## continuous gradient at this size reads as mush. Four tones plus two speckle passes is what gives
## the ground something to look at without giving it anything to read.
func _fill_tile(base: Color, palette: PackedColorArray, contrast: float, speckle: float, salt: int) -> Image:
	var image := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	var tones := _tones_from(base, palette)
	for y in TILE:
		for x in TILE:
			var u := float(x) / float(TILE)
			var v := float(y) / float(TILE)
			var value := _fbm(u, v, salt, 3, 6.0)
			var shade := clampf((value - 0.5) * contrast + 0.5, 0.0, 1.0)
			var colour := tones[clampi(int(shade * float(tones.size())), 0, tones.size() - 1)]
			var roll := _hash01(x, y, salt + 991)
			if roll < speckle * 0.5:
				colour = colour.lightened(0.14)
			elif roll > 1.0 - speckle * 0.5:
				colour = colour.darkened(0.14)
			image.set_pixel(x, y, colour)
	return image


## The four to six tones a tile is drawn in, from the biome's palette and the variant's colour.
func _tones_from(base: Color, palette: PackedColorArray) -> PackedColorArray:
	var tones := PackedColorArray()
	var dark := base.darkened(0.3)
	if not palette.is_empty():
		dark = palette[0]
	tones.append(dark)
	tones.append(base.darkened(0.12))
	tones.append(base)
	tones.append(base.lightened(0.1))
	if palette.size() > 2:
		tones.append(palette[palette.size() - 2])
		tones.append(base.lightened(0.22))
	return tones


## One of the four sub-variants of a tile: the same art, moved, turned, mirrored or re-toned.
##
## Every one of these keeps the tile seamless, which is the whole constraint. Cropping, resampling or
## overlaying a non-wrapping noise breaks the seam and is what turns "four variants" into "four
## visible tile edges".
func _sub_variant(tile: Image, sub: int) -> Image:
	var out := tile.duplicate() as Image
	match sub:
		0:
			out = _rolled(tile, 0, 0)
			out = _toned(out, 1.0)
		1:
			out = _rolled(tile, 23, 11)
			out = _toned(out, 0.97)
		2:
			out = _rolled(tile, 5, 31)
			out = _rotated(out)
			out = _toned(out, 1.03)
		3:
			out = _rolled(tile, 37, 3)
			out = _mirrored(out)
			out = _toned(out, 0.94)
	return out


func _rolled(tile: Image, dx: int, dy: int) -> Image:
	var out := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	for y in TILE:
		for x in TILE:
			out.set_pixel(x, y, tile.get_pixel((x + dx) % TILE, (y + dy) % TILE))
	return out


func _rotated(tile: Image) -> Image:
	var out := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	for y in TILE:
		for x in TILE:
			out.set_pixel(y, TILE - 1 - x, tile.get_pixel(x, y))
	return out


func _mirrored(tile: Image) -> Image:
	var out := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	for y in TILE:
		for x in TILE:
			out.set_pixel(TILE - 1 - x, y, tile.get_pixel(x, y))
	return out


## A brightness shift that keeps the tile's own wrap: a multiplier, not an overlay.
func _toned(tile: Image, factor: float) -> Image:
	var out := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	for y in TILE:
		for x in TILE:
			var colour := tile.get_pixel(x, y)
			out.set_pixel(x, y, Color(colour.r * factor, colour.g * factor, colour.b * factor, colour.a))
	return out


## How badly a tile meets itself: the mean absolute difference between its first and last columns,
## against the same comparison taken in the middle of the tile. A seamless tile scores near zero; a
## cropped one scores high. Printed rather than asserted, because the delivered art's own score is the
## baseline to compare against.
func _measure_seam(tile: Image, label: String) -> void:
	var edge := 0.0
	var middle := 0.0
	for y in TILE:
		var first := tile.get_pixel(0, y)
		var last := tile.get_pixel(TILE - 1, y)
		edge += absf(first.r - last.r) + absf(first.g - last.g) + absf(first.b - last.b)
		var a := tile.get_pixel(TILE / 2, y)
		var b := tile.get_pixel(TILE / 2 - 1, y)
		middle += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
	var normaliser := maxf(0.001, float(TILE) * 3.0)
	_seams.append("%-34s edge %.4f, interior %.4f" % [label, edge / normaliser, middle / normaliser])


func _report_tile_cost(biome_id: String, variants: int) -> void:
	print("  %s: %d variants, %d files, %dx%d px each" % [biome_id, variants, variants * 4, TILE, TILE])


## ---------- overlays, type looks and props ---------------------------------

## Four detail overlays for the biome's list, two files each, with alpha: an overlay is painted over
## the ground rather than replacing it, so what is transparent matters as much as what is not.
func _forge_overlays(biomes: BiomeCatalog) -> void:
	var wanted := {}
	for biome_id in biomes.order:
		if not _biome_filter.is_empty() and biome_id != _biome_filter:
			continue
		for entry in biomes.overlays(biome_id):
			var record := entry as Dictionary
			var id := str(record.get("id", ""))
			if id.is_empty():
				continue
			wanted[id] = _overlay_colour(id)
	for id in wanted.keys():
		var colour := wanted[id] as Color
		for sub in 2:
			var image := _overlay_tile(colour, id, sub)
			_write_png(image, "%s/%s_%d.png" % [OVERLAY_ROOT, str(id), sub + 1])


func _overlay_colour(id: String) -> Color:
	match id:
		"dirt", "trampled":
			return Color("6b5a3a")
		"dry_grass":
			return Color("a08f45")
		"dark_grass":
			return Color("3a4a1c")
		"stones", "scree":
			return Color("7c776c")
		"moss":
			return Color("4f6b33")
		"flowers":
			return Color("c9b06a")
		"dead_vegetation":
			return Color("6d5f42")
		"mud":
			return Color("4a3f2c")
		"sand":
			return Color("a89653")
		"snow_drift":
			return Color("cfd6dd")
		"leaf_litter":
			return Color("6a4f2c")
		"frost":
			return Color("c2d2dc")
		"silt":
			return Color("8a7a55")
	return Color("6b6350")


## An overlay is a mask, not a colour: it covers part of the ground and lets the rest through.
func _overlay_tile(colour: Color, id: String, sub: int) -> Image:
	var image := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	var salt := 5000 + sub * 277 + absi(id.hash()) % 1000
	for y in TILE:
		for x in TILE:
			var value := _fbm(float(x) / float(TILE), float(y) / float(TILE), salt, 3, 5.0)
			# A soft-edged mask: solid in the middle of a patch, transparent at its edge, so a cell's
			# coverage reads as a region rather than as a stencil.
			var coverage := smoothstep(0.45, 0.7, value)
			var tone := colour.darkened(_hash01(x, y, salt + 31) * 0.2)
			image.set_pixel(x, y, Color(tone.r, tone.g, tone.b, coverage * 0.85))
	return image


## The three looks a type needs to be more than a tint: water, rock and mud.
func _forge_types() -> void:
	_write_png(_type_tile(Color("33506b"), 6100, 0.10), "%s/water_1.png" % TYPE_ROOT)
	_write_png(_type_tile(Color("3b5a77"), 6200, 0.16), "%s/water_2.png" % TYPE_ROOT)
	_write_png(_type_tile(Color("6b625a"), 6300, 0.5), "%s/rock_1.png" % TYPE_ROOT)
	_write_png(_type_tile(Color("4a3f2c"), 6400, 0.28), "%s/mud_1.png" % TYPE_ROOT)


func _type_tile(base: Color, salt: int, contrast: float) -> Image:
	var image := Image.create_empty(TILE, TILE, false, Image.FORMAT_RGBA8)
	for y in TILE:
		for x in TILE:
			var value := _fbm(float(x) / float(TILE), float(y) / float(TILE), salt, 3, 4.0)
			var shade := clampf((value - 0.5) * contrast * 2.0 + 0.5, 0.0, 1.0)
			var colour := base.darkened((1.0 - shade) * 0.4).lightened(shade * 0.18)
			image.set_pixel(x, y, colour)
	return image


## One sprite per prop kind, bottom-centre anchored on a transparent canvas.
##
## Crude on purpose: this is a placeholder that has the right size, the right silhouette in one colour
## and the right footing. The factory at F:/ProjectBanner-AI is where real art comes from.
func _forge_props(biomes: BiomeCatalog) -> void:
	for kind_id in biomes.prop_kind_ids():
		var definition := biomes.prop_kind(kind_id)
		var art := definition.get("art", []) as Array
		if art.is_empty():
			continue
		for index in art.size():
			var path := str(art[index])
			if not path.begins_with(PROP_ROOT):
				continue
			var image := _prop_sprite(kind_id, index)
			if image == null:
				continue
			_write_png(image, path)


func _prop_sprite(kind_id: String, variant: int) -> Image:
	var salt := 7000 + variant * 97
	match kind_id:
		"tree":
			return _blob_sprite(Vector2i(28, 40), Color("3f5a2a"), Color("54381f"), 0.55, salt)
		"bush":
			return _blob_sprite(Vector2i(22, 16), Color("44603a"), Color("54381f"), 0.3, salt)
		"rock":
			return _blob_sprite(Vector2i(20, 14), Color("6f6a60"), Color("4f4a42"), 0.0, salt)
		"log":
			return _log_sprite()
		"stump":
			return _blob_sprite(Vector2i(14, 12), Color("5a4026"), Color("3f2c1a"), 0.2, salt)
		"fence":
			return _fence_sprite()
		"ruin":
			return _blob_sprite(Vector2i(28, 22), Color("7a7266"), Color("4a463f"), 0.0, salt)
		"crop":
			return _crop_sprite(salt)
		"hay":
			return _blob_sprite(Vector2i(18, 14), Color("b39a4c"), Color("7a6a2c"), 0.1, salt)
		"debris":
			return _blob_sprite(Vector2i(16, 10), Color("5f5947"), Color("3f3a2c"), 0.3, salt)
		"reed":
			return _reed_sprite(salt)
		"cactus":
			return _blob_sprite(Vector2i(14, 24), Color("4a6b3a"), Color("2f4a26"), 0.2, salt)
	return null


## A rounded blob with a darker base: what most of these are, at placeholder fidelity.
func _blob_sprite(size: Vector2i, top: Color, base: Color, raggedness: float, salt: int) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var centre := Vector2(float(size.x) * 0.5, float(size.y) * 0.42)
	var radius := Vector2(float(size.x) * 0.48, float(size.y) * 0.42)
	for y in size.y:
		for x in size.x:
			var offset := Vector2(float(x), float(y)) - centre
			var reach := _hash01(x, y, salt) * raggedness
			var shape := (offset.x * offset.x) / (radius.x * radius.x) + (offset.y * offset.y) / (radius.y * radius.y)
			if shape + reach > 1.0:
				continue
			var shade := clampf(1.0 - (float(y) / float(size.y)) * 0.6 + _hash01(x, y, salt + 7) * 0.2, 0.0, 1.0)
			var colour := base.lerp(top, shade)
			image.set_pixel(x, y, colour)
	return image


func _log_sprite() -> Image:
	var image := Image.create_empty(22, 10, false, Image.FORMAT_RGBA8)
	for y in 10:
		for x in 22:
			var edge := absf(float(y) - 4.5) / 4.5
			if edge > 1.0:
				continue
			image.set_pixel(x, y, Color("54381f").lightened((1.0 - edge) * 0.25 + _hash01(x, y, 31) * 0.12))
	return image


func _fence_sprite() -> Image:
	var image := Image.create_empty(26, 14, false, Image.FORMAT_RGBA8)
	var wood := Color("5a4527")
	for post in [1, 12, 23]:
		for y in range(3, 14):
			for x in range(post, mini(26, post + 2)):
				image.set_pixel(x, y, wood)
	for x in 26:
		if x % 7 == 3:
			continue
		image.set_pixel(x, 5, wood.lightened(0.1))
		image.set_pixel(x, 9, wood.darkened(0.1))
	return image


func _crop_sprite(salt: int) -> Image:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	for y in range(4, 16):
		for x in 16:
			if (x + y) % 3 == 0:
				continue
			var colour := Color("a08f45").darkened(float(y) * 0.02 + _hash01(x, y, salt) * 0.1)
			image.set_pixel(x, y, colour)
	return image


func _reed_sprite(salt: int) -> Image:
	var image := Image.create_empty(16, 22, false, Image.FORMAT_RGBA8)
	for stalk in 5:
		var x := 1 + stalk * 3
		var height := 10 + int(_hash01(stalk, 1, salt) * 9.0)
		for y in range(22 - height, 22):
			if x >= 16:
				continue
			image.set_pixel(x, y, Color("5f6b3a").darkened(_hash01(y, stalk, salt) * 0.2))
	return image


## ---------- plumbing -------------------------------------------------------

func _palette_of(biomes: BiomeCatalog, biome_id: String) -> PackedColorArray:
	var record := biomes.define(biome_id)
	var raw: Variant = record.get("palette", [])
	var out := PackedColorArray()
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in raw as Array:
		var text := str(entry)
		if Color.html_is_valid(text):
			out.append(Color(text))
	return out


func _write_png(image: Image, path: String) -> void:
	if _report_only:
		return
	var error := image.save_png(ProjectSettings.globalize_path(path))
	if error != OK:
		push_error("ground forge: could not write %s (error %d)" % [path, error])
		return
	_written += 1


## A number in [0, 1) from three integers. The forge has its own so a re-run cannot depend on any
## other system's hashes.
func _hash01(x: int, y: int, salt: int) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 2246822519 + SEED * 2654435761) % 2147483647
	if h < 0:
		h += 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	h = h % 2147483647
	if h < 0:
		h += 2147483647
	h = h ^ (h >> 16)
	return float(h % 16777216) / 16777216.0


## Fractal value noise whose lattice is modulo the tile, so the tile meets itself exactly.
func _fbm(u: float, v: float, salt: int, octaves: int, frequency: float) -> float:
	var total := 0.0
	var weight := 0.0
	var amplitude := 1.0
	var f := frequency
	for octave in octaves:
		var period := maxi(2, int(roundf(f)))
		total += _noise(u * f, v * f, period, salt + octave * 131) * amplitude
		weight += amplitude
		amplitude *= 0.5
		f *= 2.0
	return total / maxf(0.001, weight)


func _noise(x: float, y: float, period: int, salt: int) -> float:
	var x0 := int(floorf(x))
	var y0 := int(floorf(y))
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	var a := _hash01(posmod(x0, period), posmod(y0, period), salt)
	var b := _hash01(posmod(x0 + 1, period), posmod(y0, period), salt)
	var c := _hash01(posmod(x0, period), posmod(y0 + 1, period), salt)
	var d := _hash01(posmod(x0 + 1, period), posmod(y0 + 1, period), salt)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)
