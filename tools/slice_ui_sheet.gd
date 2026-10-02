extends SceneTree
## Slice the custom Project Banner medieval UI sheet into individual prepared assets.
##
## The sheet (assets/ui/source/medieval_ui_sheet.png) is a generated atlas, not a grid: the
## elements sit at arbitrary positions with anti-aliased (feathered) edges. This tool:
##
##   1. hardens the alpha (a >= 128 keeps the pixel, below goes clear) so the soft
##      generation halo cannot smear against the game's dark UI;
##   2. finds each element by connected-component analysis on the alpha channel - the rects
##      come from the pixels themselves, not from eyeballed coordinates;
##   3. writes every component at or above MIN_SIZE into the staging folder with its id and
##      a manifest line, so the pieces can be reviewed and named;
##   4. with --bake, additionally writes the NAMED production set into
##      assets/ui/project_banner/<category>/ using the mapping below (component id ->
##      name), after the same per-element cleanup.
##
## Every automatic edit is listed in this file's header and recorded in
## assets/ui/project_banner/README.md - the sheet is the source, these files are the
## production assets.
##
## Usage:
##   godotc --headless --script tools/slice_ui_sheet.gd -- --report   # components + manifest
##   godotc --headless --script tools/slice_ui_sheet.gd -- --bake     # named production set

const SHEET := "res://assets/ui/source/medieval_ui_sheet.png"
const STAGE := "res://assets/ui/project_banner/_stage/"
const OUT := "res://assets/ui/project_banner/"
const ALPHA_CUT := 128
const MIN_SIZE := 24

## After the named pieces are written, a few need a patch: where a crest sat mid-piece, it
## would smear when the piece stretches, so a neighbouring slice of the same artwork is
## copied over it and the crest is re-placed as a separate overlay at runtime. Rects are in
## the written piece's pixels.
const PATCHES: Array = [
	["frames/frame_large", Rect2i(278, 0, 104, 130), Rect2i(150, 0, 104, 130)],
	["frames/header_bar", Rect2i(278, 0, 104, 139), Rect2i(150, 0, 104, 139)],
	["frames/footer_bar", Rect2i(516, 0, 84, 52), Rect2i(320, 0, 84, 52)],
]

## Production output table: component id -> one or more named pieces. A null rect takes the
## whole component; a rect sub-splits it (ornaments that grew together with their frame).
## A fill colour closes a hollow ring's interior (the frames and the input are drawn as
## rings with transparent middles - the fill is the panel surface the content sits on).
## Sub-rects for the ornament splits are estimated from 2x zooms of the staged pieces; the
## verification contact sheet follows the bake.
const OUTPUTS: Array = [
	[0, null, "frames/frame_large", Color("161a21"), null],
	[0, Rect2i(300, 0, 66, 76), "ornaments/crest_shield", null, Rect2i(0, 0, 66, 64)],
	[1, null, "frames/frame_medium", Color("161a21"), null],
	[1, Rect2i(183, 0, 62, 42), "ornaments/diamond_top", null, Rect2i(0, 0, 62, 26)],
	[2, null, "frames/frame_small", Color("161a21"), null],
	[2, Rect2i(102, 0, 62, 42), "ornaments/diamond_top_small", null, Rect2i(0, 0, 62, 26)],
	[3, null, "panels/inset_panel", null, null],
	[4, null, "panels/tile_parchment", null, null],
	[5, null, "panels/tile_dark", null, null],
	[6, null, "frames/header_bar", null, null],
	[6, Rect2i(300, 0, 66, 76), "ornaments/crest_header", null, Rect2i(0, 0, 66, 64)],
	[7, null, "buttons/primary_green", null, null],
	[8, null, "inputs/input_frame", Color("12161d"), null],
	[8, Rect2i(354, 12, 42, 50), "ornaments/button_diamond", null, Rect2i(2, 2, 38, 44)],
	[9, null, "buttons/secondary_dark", null, null],
	[10, null, "dividers/divider_wide", null, null],
	[11, null, "ornaments/diamond_ornate", null, null],
	[12, null, "ornaments/square_crest", null, null],
	[13, null, "ornaments/bracket_tl", null, null],
	[14, null, "ornaments/bracket_tr", null, null],
	[16, null, "ornaments/bracket_bl", null, null],
	[17, null, "ornaments/bracket_br", null, null],
	[15, null, "frames/footer_bar", null, null],
	[18, null, "ornaments/ring_plain", null, null],
	[19, null, "ornaments/cross_gold", null, null],
	[20, null, "ornaments/ring_crest", null, null],
]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := "bake" if "--bake" in args else "report"
	var sheet := Image.load_from_file(SHEET)
	if sheet == null:
		print("SHEET MISSING: ", SHEET)
		quit(1)
		return
	sheet.convert(Image.FORMAT_RGBA8)
	_harden_alpha(sheet)
	var components := _find_components(sheet)
	components.sort_custom(_rect_before_yx)
	if mode == "report":
		DirAccess.make_dir_recursive_absolute(STAGE)
		var index := 0
		for rect in components:
			var r: Rect2i = rect
			var piece := _crop(sheet, r)
			piece.save_png("%sc%03d_%dx%d.png" % [STAGE, index, r.size.x, r.size.y])
			print("c%03d  x=%4d y=%4d  %4d x %4d" % [index, r.position.x, r.position.y, r.size.x, r.size.y])
			index += 1
		print("components: ", components.size())
	else:
		var made := 0
		for entry in OUTPUTS:
			var row: Array = entry
			var r: Rect2i = components[int(row[0])]
			var sub: Variant = row[1]
			if sub is Rect2i:
				var s: Rect2i = sub
				r = Rect2i(r.position + s.position, s.size)
			var piece := _crop(sheet, r)
			var fill: Variant = row[3]
			if fill is Color:
				_close_ring(piece, fill)
			var keep: Variant = row[4]
			if keep is Rect2i:
				_erase_outside(piece, keep)
			var rel: String = str(row[2])
			DirAccess.make_dir_recursive_absolute(OUT + rel.get_base_dir())
			piece.save_png(OUT + rel + ".png")
			made += 1
		for entry in PATCHES:
			var row: Array = entry
			var path := OUT + str(row[0]) + ".png"
			var piece := Image.load_from_file(path)
			if piece == null:
				print("PATCH MISSING ", path)
				continue
			piece.convert(Image.FORMAT_RGBA8)
			var dest: Rect2i = row[1]
			var src: Rect2i = row[2]
			var block := Image.create_empty(dest.size.x, dest.size.y, false, Image.FORMAT_RGBA8)
			block.blit_rect(piece, src, Vector2i.ZERO)
			piece.blit_rect(block, Rect2i(Vector2i.ZERO, dest.size), dest.position)
			piece.save_png(path)
		print("named pieces: ", made, " -> ", OUT)
	quit(0)


## Reading order: top to bottom, then left to right.
func _rect_before_yx(a: Rect2i, b: Rect2i) -> bool:
	if a.position.y != b.position.y:
		return a.position.y < b.position.y
	return a.position.x < b.position.x


## Snap the feathered generation edges to the pixel grid: a pixel is either part of the
## artwork or it is not.
func _harden_alpha(image: Image) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.a < float(ALPHA_CUT) / 255.0:
				image.set_pixel(x, y, Color(0, 0, 0, 0))
			elif c.a < 1.0:
				image.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))


## One pass of 8-connected flood fill over the alpha channel; returns bounding rects of
## every component at or above MIN_SIZE on the longest side.
func _find_components(image: Image) -> Array:
	var w := image.get_width()
	var h := image.get_height()
	var seen := PackedByteArray()
	seen.resize(w * h)
	var rects: Array = []
	for y in h:
		for x in w:
			var key := y * w + x
			if seen[key] == 1 or image.get_pixel(x, y).a < 0.5:
				continue
			var stack: Array[Vector2i] = [Vector2i(x, y)]
			var min_x := x
			var min_y := y
			var max_x := x
			var max_y := y
			while not stack.is_empty():
				var p: Vector2i = stack.pop_back()
				var pk := p.y * w + p.x
				if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h or seen[pk] == 1:
					continue
				if image.get_pixel(p.x, p.y).a < 0.5:
					continue
				seen[pk] = 1
				min_x = mini(min_x, p.x)
				min_y = mini(min_y, p.y)
				max_x = maxi(max_x, p.x)
				max_y = maxi(max_y, p.y)
				for dy in [-1, 0, 1]:
					for dx in [-1, 0, 1]:
						stack.append(Vector2i(p.x + dx, p.y + dy))
			var size := Vector2i(max_x - min_x + 1, max_y - min_y + 1)
			if maxi(size.x, size.y) >= MIN_SIZE:
				rects.append(Rect2i(min_x, min_y, size.x, size.y))
	return rects


func _crop(sheet: Image, rect: Rect2i) -> Image:
	var piece := Image.create_empty(rect.size.x, rect.size.y, false, Image.FORMAT_RGBA8)
	piece.blit_rect(sheet, rect, Vector2i.ZERO)
	return piece


## Keep only what is inside the box: everything else goes transparent. For ornament crops
## that unavoidably swallowed a sliver of their frame's edge, the box is the piece's
## measured keep region.
func _erase_outside(piece: Image, keep: Rect2i) -> void:
	for y in piece.get_height():
		for x in piece.get_width():
			if x < keep.position.x or y < keep.position.y \
					or x >= keep.position.x + keep.size.x or y >= keep.position.y + keep.size.y:
				piece.set_pixel(x, y, Color(0, 0, 0, 0))


## Give a hollow ring its surface: flood the piece from its centre and fill every
## transparent pixel reached. The band outside the ring (e.g. the space beside a crest
## poking above the frame) is not connected to the centre, so it stays transparent.
func _close_ring(piece: Image, fill: Color) -> void:
	var w := piece.get_width()
	var h := piece.get_height()
	var stack: Array[Vector2i] = [Vector2i(w / 2, h / 2)]
	var seen := {}
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h:
			continue
		var key := p.y * w + p.x
		if seen.has(key):
			continue
		seen[key] = true
		if piece.get_pixel(p.x, p.y).a >= 0.5:
			continue
		piece.set_pixel(p.x, p.y, fill)
		stack.append(Vector2i(p.x + 1, p.y))
		stack.append(Vector2i(p.x - 1, p.y))
		stack.append(Vector2i(p.x, p.y + 1))
		stack.append(Vector2i(p.x, p.y - 1))
