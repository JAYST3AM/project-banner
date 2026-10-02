class_name BannerData
extends RefCounted
## A company banner: a small grid of palette indices, painted by the player.
##
## The banner is one fixed-size piece of cloth - [code]32 x 40[/code] banner units,
## which are world units on the map - and the grid only says how [b]finely[/b] it is
## painted: 8x10, 16x20 or 32x40 cells, one art pixel each. Choosing a finer grid
## never changes the banner's size in the world (D-167).
##
## Cells hold an index into the locked 20-colour palette, or [constant EMPTY] for a
## hole in the cloth. The palette, the detail levels and the wind constants live in
## [code]data/config/banner.json[/code]; everything here degrades to working fallbacks
## when that file (or a field of it) is missing.
##
## Serialisation is deliberately boring, like the campaign's: [method to_dict] writes
## [code]{width, height, rle}[/code] and [method from_dict] rebuilds it, falling back
## to [method create_default] for anything malformed - so an old save simply gains a
## default banner rather than failing to load.

const EMPTY := -1
const DATA_PATH := "res://data/config/banner.json"
const DEFAULT_WIDTH := 16
const DEFAULT_HEIGHT := 20
const MIN_SIZE := 4
const MAX_SIZE := 64
const MAX_CELLS := 4096
## The starter the default banner wears: the split field the paint prototype opened on.
const DEFAULT_KIND := "pale"

static var _document_cache: Dictionary = {}


## The raw banner.json, loaded once. Empty when the file is missing; every reader
## below treats that as "use the fallback".
static func _document() -> Dictionary:
	if _document_cache.is_empty():
		_document_cache = GameData.load_json(DATA_PATH)
	return _document_cache


## The locked palette. Parsed from banner.json; the hard-coded fallback carries the
## same twenty colours in the same order, so indices mean the same thing either way.
static func palette() -> PackedColorArray:
	var out := PackedColorArray()
	var raw: Variant = _document().get("palette", [])
	if typeof(raw) == TYPE_ARRAY:
		for entry in (raw as Array):
			var text := str(entry).strip_edges()
			if text.is_empty():
				continue
			if not text.begins_with("#"):
				text = "#" + text
			out.append(Color.from_string(text, Color.MAGENTA))
	if out.is_empty():
		out = fallback_palette()
	return out


static func fallback_palette() -> PackedColorArray:
	var out := PackedColorArray()
	var hexes: Array = [
		"#1a1620", "#2b2b33", "#3a3d47", "#4a4f5a", "#5c6270", "#6f7686", "#8b93a3",
		"#a9b1bf", "#c8cfd9", "#e6e9ef", "#f2f0e6", "#3c2f23", "#5a4432", "#7a5c3e",
		"#9c7b52", "#7a2f35", "#4a6f8f", "#d9a441", "#3f5a35", "#6b8f52",
	]
	for hex in hexes:
		out.append(Color(str(hex)))
	return out


static func palette_size() -> int:
	return palette().size()


## The paintable detail levels, as (width, height) pairs.
static func detail_sizes() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var raw: Variant = _document().get("details", [])
	if typeof(raw) == TYPE_ARRAY:
		for entry in (raw as Array):
			if typeof(entry) == TYPE_ARRAY and (entry as Array).size() >= 2:
				var pair: Array = entry
				out.append(Vector2i(int(pair[0]), int(pair[1])))
	if out.is_empty():
		out.append(Vector2i(8, 10))
		out.append(Vector2i(16, 20))
		out.append(Vector2i(32, 40))
	return out


static func default_detail() -> Vector2i:
	var raw: Variant = _document().get("default_detail", [])
	if typeof(raw) == TYPE_ARRAY and (raw as Array).size() >= 2:
		var pair: Array = raw
		return Vector2i(int(pair[0]), int(pair[1]))
	return Vector2i(DEFAULT_WIDTH, DEFAULT_HEIGHT)


## The cloth, in banner units (world units on the map). Fixed for every detail level.
static func cloth_units() -> Vector2:
	var raw: Variant = _document().get("cloth_units", [])
	if typeof(raw) == TYPE_ARRAY and (raw as Array).size() >= 2:
		var pair: Array = raw
		return Vector2(float(pair[0]), float(pair[1]))
	return Vector2(32.0, 40.0)


static func max_cells() -> int:
	return int(_document().get("max_cells", MAX_CELLS))


static func wind_amplitude() -> float:
	var wind: Variant = _document().get("wind", {})
	if typeof(wind) == TYPE_DICTIONARY:
		return float((wind as Dictionary).get("amplitude", 3.0))
	return 3.0


static func wind_speed() -> float:
	var wind: Variant = _document().get("wind", {})
	if typeof(wind) == TYPE_DICTIONARY:
		return float((wind as Dictionary).get("speed", 2.1))
	return 2.1


## How far a cloth row has swung, in whole banner units, at time [param t].
##
## The top row is pinned to the crossbar and the swing grows towards the hem; whole
## units, because the cloth is pixel art and a half-pixel shift is a blur. A gust
## term moves the whole banner between calm and brisk. Pure maths, so the suites can
## pin it and the renderers can stay dumb.
static func wave_shift(cell_y: int, t: float, height: int) -> int:
	if height <= 0:
		return 0
	var progress := (float(cell_y) + 0.5) / float(height)
	var gust := 0.78 + 0.22 * sin(t * 0.31) + 0.12 * sin(t * 0.83 + 1.7)
	var swing := wind_amplitude() * pow(progress, 1.7) * gust * sin(t * wind_speed() + progress * 10.0)
	return int(round(swing))


## Whether a cell is part of the cloth at this detail level. The shape is the one the
## owner approved in the paint prototype: a straight top edge and a swallowtail notch
## cut into the bottom hem, both of which scale with the grid so every level wears the
## same silhouette.
static func allowed_cell(w: int, h: int, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= w or y >= h:
		return false
	var rows := maxi(2, int(round(float(h) / 5.0)))
	if y >= h - rows:
		var depth := float(y - (h - rows) + 1)
		var tail := float(maxi(1, int(round(float(w) / 8.0))))
		var half := depth / float(rows) * (float(w) / 2.0 - tail)
		if absf(float(x) - float(w - 1) / 2.0) < half:
			return false
	return true


## A fresh banner in the default design: legal, fully painted, deterministic.
static func create_default(w: int = DEFAULT_WIDTH, h: int = DEFAULT_HEIGHT) -> BannerData:
	var banner := BannerData.new(w, h)
	banner.fill_starter(DEFAULT_KIND)
	return banner


static func from_rle(text: String, w: int, h: int) -> BannerData:
	var decoded := decode_rle(text, w, h)
	if decoded.is_empty():
		return null
	var banner := BannerData.new(w, h)
	banner.cells = decoded
	return banner


## Rebuilds from [method to_dict]'s shape. Anything malformed - bad sizes, undecodable
## or wrong-length runs, an oversized grid - quietly becomes the default banner: an old
## or corrupt save must open with a legal banner, not fail to open at all.
static func from_dict(data: Dictionary) -> BannerData:
	var w := int(data.get("width", 0))
	var h := int(data.get("height", 0))
	var rle := str(data.get("rle", ""))
	if w < MIN_SIZE or w > MAX_SIZE or h < MIN_SIZE or h > MAX_SIZE or w * h > max_cells():
		if not data.is_empty():
			DebugLogger.warn("banner shape %dx%d is not paintable; using the default" % [w, h], "BannerData")
		return create_default()
	var banner := from_rle(rle, w, h)
	if banner == null:
		if not data.is_empty():
			DebugLogger.warn("banner runs did not decode (%dx%d); using the default" % [w, h], "BannerData")
		return create_default()
	return banner


static func decode_rle(text: String, w: int, h: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if text.is_empty() or w <= 0 or h <= 0:
		return out
	var size := palette_size()
	for token in text.split("."):
		if token.length() < 2:
			return PackedInt32Array()
		var letter := token.substr(token.length() - 1, 1)
		var digits := token.substr(0, token.length() - 1)
		if not digits.is_valid_int():
			return PackedInt32Array()
		var count := int(digits)
		if count <= 0:
			return PackedInt32Array()
		var value := EMPTY
		if letter != "A":
			var code := letter.unicode_at(0)
			if code < 66 or code >= 66 + size:
				return PackedInt32Array()
			value = code - 66
		for i in count:
			out.append(value)
	if out.size() != w * h:
		return PackedInt32Array()
	return out


var width: int = DEFAULT_WIDTH
var height: int = DEFAULT_HEIGHT
## Palette indices, row-major. [constant EMPTY] is a hole in the cloth.
var cells: PackedInt32Array = PackedInt32Array()


func _init(w: int = DEFAULT_WIDTH, h: int = DEFAULT_HEIGHT) -> void:
	width = w
	height = h
	cells = PackedInt32Array()
	cells.resize(w * h)
	cells.fill(EMPTY)


func allowed(x: int, y: int) -> bool:
	return allowed_cell(width, height, x, y)


func cell(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= width or y >= height:
		return EMPTY
	return cells[y * width + x]


## Paints one cell. Refuses cells outside the cloth and indices outside the palette,
## so no renderer ever has to defend itself against a saved banner.
func set_cell(x: int, y: int, value: int) -> bool:
	if not allowed(x, y):
		return false
	if value != EMPTY and (value < 0 or value >= palette_size()):
		return false
	cells[y * width + x] = value
	return true


func allowed_count() -> int:
	var count := 0
	for y in height:
		for x in width:
			if allowed(x, y):
				count += 1
	return count


func painted_count() -> int:
	var count := 0
	for value in cells:
		if value != EMPTY:
			count += 1
	return count


func is_legal() -> bool:
	var size := palette_size()
	for value in cells:
		if value < EMPTY:
			return false
		if value != EMPTY and value >= size:
			return false
	return true


func duplicate_data() -> BannerData:
	var copy := BannerData.new(width, height)
	copy.cells = cells.duplicate()
	return copy


## Fills the cloth with a starter pattern. Only cloth cells are touched; the notch
## stays a hole. Unknown kinds leave the cloth blank rather than erroring.
func fill_starter(kind: String) -> void:
	var size := palette_size()
	for y in height:
		for x in width:
			if not allowed(x, y):
				cells[y * width + x] = EMPTY
				continue
			var cx := float(width - 1) / 2.0
			var cy := float(height - 1) / 2.0
			var value := EMPTY
			match kind:
				"pale":
					value = 15 if x * 2 < width else 16
					if x == 0 or x == width - 1 or y == 0 or y == height - 1:
						value = 10
				"chev":
					value = 10 if absf(float(y) - (absf(float(x) - cx) * 1.15 + 3.0)) < 1.6 else 18
				"cross":
					value = 10 if (absf(float(x) - cx) < 1.2 or absf(float(y) - cy) < 1.2) else 15
				"quart":
					value = 15 if (float(x) < cx) == (float(y) < cy) else 10
					if x == 0 or x == width - 1 or y == 0 or y == height - 1:
						value = 17
				_:
					value = EMPTY
			if value != EMPTY:
				value = clampi(value, 0, maxi(0, size - 1))
			cells[y * width + x] = value


func to_rle() -> String:
	var out := ""
	var i := 0
	while i < cells.size():
		var j := i
		while j < cells.size() and cells[j] == cells[i]:
			j += 1
		out += str(j - i) + String.chr(65 + (cells[i] + 1))
		if j < cells.size():
			out += "."
		i = j
	return out


func to_dict() -> Dictionary:
	return {"width": width, "height": height, "rle": to_rle()}
