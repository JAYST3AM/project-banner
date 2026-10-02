class_name BannerArt
extends RefCounted
## Renders a [BannerData] as a whole banner: pole, orb finial, crossbar, tie rings and
## the cloth - which waves.
##
## The banner is painted ONCE into a small RGBA image (56 x 70 banner units, one pixel
## each) and handed out as a texture, so every consumer draws it with one
## [method CanvasItem.draw_texture_rect] call. The image is rebuilt only when the wind
## steps to a new shape (the row shifts are whole units, so that is a few times a
## second) or the paint changes - see [method signature]. Measured on the owner's
## machine, drawing the ~1,500 rectangles live every frame cost the world map about
## 2 ms/frame against the old disc marker; the cached texture is a single quad.
## [code]PB_BANNER_WIND=off[/code] stills every cloth in the same build.
##
## The layout is the one approved in the paint prototype: the cloth HANGS from the
## crossbar with a swallowtail notch on the bottom hem, and the pole carries detail -
## five-tone timber, wrap rings, a steel butt ferrule. The cloth is always 32 x 40
## units however fine its grid is, so the banner is the same size in the world at every
## detail level (D-167).

const POLE_CENTRE_X := 28.0
const BASE_Y := 70.0
const CLOTH_X := 12.0
const CLOTH_Y := 14.0
const TOTAL_W := 56
const TOTAL_H := 70

## Palette indices the furniture is drawn from (the locked 20-colour order, matching
## data/config/banner.json). These are palette-locked on purpose: the pole may not
## invent a colour the player could not paint with.
const I_OUTLINE := 0
const I_STEEL := 5
const I_STEEL_HI := 7
const I_SPARK := 10
const I_WOOD_SHADOW := 11
const I_WOOD := 12
const I_WOOD_LIGHT := 13
const I_WOOD_HI := 14
const I_GOLD := 17

static var _wind_setting := -1


## Whether wind is on for this process. [code]PB_BANNER_WIND=off[/code] stills every
## cloth in the same build, which is how a before/after screenshot pair is taken and
## how a suite can compare two frames exactly.
static func wind_enabled() -> bool:
	if _wind_setting < 0:
		var raw := OS.get_environment("PB_BANNER_WIND").to_lower()
		_wind_setting = 0 if raw == "off" or raw == "0" or raw == "false" else 1
	return _wind_setting == 1


static func total_size() -> Vector2:
	return Vector2(float(TOTAL_W), float(TOTAL_H))


## The cloth's rectangle, in banner units.
static func cloth_rect() -> Rect2:
	var cloth := BannerData.cloth_units()
	return Rect2(CLOTH_X, CLOTH_Y, cloth.x, cloth.y)


## Everything the rendered image depends on: the paint, the grid, and the wind's own
## state (each row's whole-unit shift and fold shade). Two calls with the same signature
## must produce identical pixels, which is exactly the cache's contract.
static func signature(banner: BannerData, t: float, wind: bool) -> String:
	var parts := PackedStringArray()
	parts.append("%d:%d:%d" % [banner.width, banner.height, hash(banner.cells)])
	if wind:
		for y in banner.height:
			var shade := 0
			var sway := _sway(y, t, banner.height)
			if sway < -0.55:
				shade = -1
			elif sway > 0.55:
				shade = 1
			parts.append("%d,%d" % [BannerData.wave_shift(y, t, banner.height), shade])
	return "|".join(parts)


## The banner as pixels: transparent where nothing is painted, opaque everywhere else.
static func render_banner_image(banner: BannerData, t: float, wind: bool) -> Image:
	var image := Image.create_empty(TOTAL_W, TOTAL_H, false, Image.FORMAT_RGBA8)
	if banner == null:
		return image
	var palette := BannerData.palette()
	var outline := _ink(palette, I_OUTLINE)
	var cell := int(float(BannerData.cloth_units().x) / float(banner.width))

	# --- finial: gold orb with a spark, on a dark collar ---
	_disk(image, 28, 3, 3.4, outline)
	_disk(image, 28, 3, 2.4, _ink(palette, I_GOLD))
	_fill(image, Rect2i(29, 2, 1, 1), _ink(palette, I_SPARK))
	_fill(image, Rect2i(25, 5, 7, 3), outline)
	_fill(image, Rect2i(26, 6, 5, 1), _ink(palette, I_WOOD))

	# --- pole: five-tone timber (right-lit), wrap rings, steel butt ferrule ---
	# The cloth hides the pole's middle, so the detail that SHOWS is the run below the
	# hem - ten units of timber with a wrap ring - and the steel butt below that. The
	# ferrule sits at the foot only; sitting it higher just put a grey lump behind the hem.
	_fill(image, Rect2i(25, 8, 7, 62), outline)
	_fill(image, Rect2i(26, 9, 1, 61), _ink(palette, I_WOOD_SHADOW))
	_fill(image, Rect2i(27, 9, 2, 61), _ink(palette, I_WOOD))
	_fill(image, Rect2i(29, 9, 1, 61), _ink(palette, I_WOOD_LIGHT))
	_fill(image, Rect2i(30, 9, 1, 61), _ink(palette, I_WOOD_HI))
	for ring_y in [21, 34, 47, 58]:
		_fill(image, Rect2i(26, ring_y, 5, 1), _ink(palette, I_WOOD_SHADOW))
	_fill(image, Rect2i(25, 64, 7, 6), outline)
	_fill(image, Rect2i(26, 65, 5, 4), _ink(palette, I_STEEL))
	_fill(image, Rect2i(28, 65, 1, 4), _ink(palette, I_STEEL_HI))
	_fill(image, Rect2i(27, 69, 3, 1), _ink(palette, I_STEEL))

	# --- cloth: the painted cells, each row shifted by the wind ---
	for y in banner.height:
		var shift := BannerData.wave_shift(y, t, banner.height) if wind else 0
		var sway := _sway(y, t, banner.height)
		for x in banner.width:
			if not banner.allowed(x, y):
				continue
			var value := banner.cell(x, y)
			if value == BannerData.EMPTY:
				continue
			var left := int(CLOTH_X) + x * cell + shift
			var top := int(CLOTH_Y) + y * cell
			_fill(image, Rect2i(left, top, cell, cell), _ink(palette, value))
			if wind:
				if sway < -0.55:
					_blend(image, Rect2i(left, top, cell, cell), _ink(palette, I_OUTLINE), 0.20)
				elif sway > 0.55:
					_blend(image, Rect2i(left, top, cell, cell), _ink(palette, I_SPARK), 0.08)

	# --- cloth outline: the silhouette edges only, following each row's shift ---
	for y in banner.height:
		var shift := BannerData.wave_shift(y, t, banner.height) if wind else 0
		for x in banner.width:
			if not banner.allowed(x, y):
				continue
			var left := int(CLOTH_X) + x * cell + shift
			var top := int(CLOTH_Y) + y * cell
			if not banner.allowed(x, y - 1):
				_fill(image, Rect2i(left, top - 1, cell, 1), outline)
			if not banner.allowed(x, y + 1):
				_fill(image, Rect2i(left, top + cell, cell, 1), outline)
			if not banner.allowed(x - 1, y):
				_fill(image, Rect2i(left - 1, top, 1, cell), outline)
			if not banner.allowed(x + 1, y):
				_fill(image, Rect2i(left + cell, top, 1, cell), outline)

	# --- crossbar over the cloth's top edge, with capped ends and tie rings ---
	_fill(image, Rect2i(9, 8, 39, 5), outline)
	_fill(image, Rect2i(10, 9, 37, 3), _ink(palette, I_WOOD))
	_fill(image, Rect2i(10, 9, 37, 1), _ink(palette, I_WOOD_LIGHT))
	_fill(image, Rect2i(10, 11, 37, 1), _ink(palette, I_WOOD_SHADOW))
	_fill(image, Rect2i(7, 9, 3, 3), outline)
	_fill(image, Rect2i(46, 9, 3, 3), outline)
	_fill(image, Rect2i(8, 10, 1, 1), _ink(palette, I_GOLD))
	_fill(image, Rect2i(47, 10, 1, 1), _ink(palette, I_GOLD))
	for tie_x in [16, 28, 40]:
		_fill(image, Rect2i(tie_x - 1, 12, 3, 3), outline)
		_fill(image, Rect2i(tie_x, 13, 1, 1), _ink(palette, I_GOLD))
	return image


## The cached texture for this banner and wind state. Rebuilt only when the signature
## moves; the cache dictionary belongs to the drawing node.
static func texture_for(cache: Dictionary, banner: BannerData, t: float, wind: bool) -> ImageTexture:
	var sig := signature(banner, t, wind)
	var cached: Variant = cache.get("tex", null)
	if cached is ImageTexture and str(cache.get("sig", "")) == sig:
		return cached as ImageTexture
	var texture := ImageTexture.create_from_image(render_banner_image(banner, t, wind))
	cache["sig"] = sig
	cache["tex"] = texture
	return texture


## Draws the banner with its pole base at [param anchor], through the cache.
##
## [param scale] converts banner units to the caller's drawing units: the map passes
## 1.0 (its drawing space IS world units), the editor's previews pass their zoom.
static func draw_marker(ci: CanvasItem, cache: Dictionary, banner: BannerData, anchor: Vector2,
		t: float, wind: bool = true, scale: float = 1.0) -> void:
	if ci == null or banner == null:
		return
	var texture := texture_for(cache, banner, t, wind)
	var origin := anchor - Vector2(POLE_CENTRE_X, BASE_Y) * scale
	ci.draw_texture_rect(texture, Rect2(origin, total_size() * scale), false)


static func _ink(palette: PackedColorArray, index: int) -> Color:
	if palette.is_empty():
		return Color.WHITE
	return palette[clampi(index, 0, palette.size() - 1)]


static func _sway(cell_y: int, t: float, height: int) -> float:
	return sin(t * BannerData.wind_speed() + ((float(cell_y) + 0.5) / float(height)) * 10.0)


static func _fill(image: Image, rect: Rect2i, colour: Color) -> void:
	var clipped := rect.intersection(Rect2i(0, 0, image.get_width(), image.get_height()))
	if clipped.size.x > 0 and clipped.size.y > 0:
		image.fill_rect(clipped, colour)


## A translucent fold shade, composited the way the canvas renderer composited it: the
## painted pixel under it, lerped towards the shade colour.
static func _blend(image: Image, rect: Rect2i, colour: Color, alpha: float) -> void:
	for py in range(rect.position.y, rect.position.y + rect.size.y):
		for px in range(rect.position.x, rect.position.x + rect.size.x):
			if px < 0 or py < 0 or px >= image.get_width() or py >= image.get_height():
				continue
			var base := image.get_pixel(px, py)
			if base.a <= 0.0:
				continue
			image.set_pixel(px, py, base.lerp(colour, alpha))


static func _disk(image: Image, cx: int, cy: int, radius: float, colour: Color) -> void:
	var reach := int(ceil(radius))
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			if float(dx * dx + dy * dy) <= radius * radius:
				if cx + dx >= 0 and cy + dy >= 0 and cx + dx < image.get_width() and cy + dy < image.get_height():
					image.set_pixel(cx + dx, cy + dy, colour)
