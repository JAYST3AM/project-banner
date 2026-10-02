class_name PixelIcons
extends RefCounted
## Tiny pixel-art icons for the interface, drawn from string grids.
##
## The mockup's creation screen leans on small silhouette icons - a barrel for the company
## step, swords for the class step, a pencil for the pencil - and this project has no icon
## assets. Rather than ship a font or a sprite sheet, each icon here is a 10x10 grid of
## characters ("#" ink, "." paper) turned into an [ImageTexture] once and cached. Nearest
## filtering everywhere, so they scale as art, and the caller picks the ink colour so the
## same pencil can be cream on a dark tile or brown on parchment.
##
## These are furniture, not a system: nothing here is interactive or stateful.

const ICONS := {
	# --- the creation rail -------------------------------------------------------------
	"company": [
		"..######..",
		".########.",
		"##.####.##",
		"##.####.##",
		".########.",
		".########.",
		"##.####.##",
		"##.####.##",
		".########.",
		"..######..",
	],
	"founder": [
		"...####...",
		"..######..",
		"..######..",
		"..######..",
		"...####...",
		"....##....",
		"..######..",
		".########.",
		".########.",
		".#......#.",
	],
	"appearance": [
		"...####...",
		"..######..",
		".########.",
		".##....##.",
		".##.##.##.",
		".##....##.",
		"..##..##..",
		"...####...",
		"....##....",
		"...####...",
	],
	"backstory": [
		".########.",
		".#......#.",
		".#.####.#.",
		".#......#.",
		".#.####.#.",
		".#......#.",
		".#.####.#.",
		".#......#.",
		".########.",
		"..........",
	],
	"culture": [
		"....##....",
		"...####...",
		"..#.##.#..",
		".#..##..#.",
		".#..##..#.",
		".#..##..#.",
		"..#.##.#..",
		"..####....",
		"...##.....",
		"..........",
	],
	"class": [
		".########.",
		"##########",
		"##########",
		"##.####.##",
		"##.####.##",
		".########.",
		"..######..",
		"...####...",
		"....##....",
		"..........",
	],
	"subclass": [
		"..######..",
		"..######..",
		"..######..",
		"..######..",
		"..##..##..",
		"..##..##..",
		"..######..",
		"...####...",
		"....##....",
		"..........",
	],
	"starting": [
		"...####...",
		"..######..",
		"...####...",
		"..######..",
		"...####...",
		"..######..",
		"...####...",
		"..######..",
		"...####...",
		"..........",
	],
	"rules": [
		"...#..#...",
		"..######..",
		".########.",
		"##.####.##",
		"##.####.##",
		".########.",
		"..######..",
		"...#..#...",
		"..........",
		"..........",
	],
	# --- the paint tools ----------------------------------------------------------------
	"pencil": [
		"........##",
		".......###",
		"......###.",
		".....###..",
		"....###...",
		"...###....",
		"..###.....",
		".###......",
		".##.......",
		"..........",
	],
	"eraser": [
		".#####....",
		"########..",
		"########..",
		"#######...",
		"######....",
		"#####.....",
		"####......",
		"###.......",
		"..........",
		"..........",
	],
	"fill": [
		"....#.....",
		"...#.#....",
		"..#...#...",
		".#.....#..",
		".#.....#..",
		"..#...#...",
		"...#.#....",
		"....#.....",
		".....#....",
		"......#...",
	],
	"mirror": [
		"##...|..##",
		".##..|.##.",
		"..##.|.##.",
		"...##|##..",
		"....#|#...",
		"...##|##..",
		"..##.|.##.",
		".##..|.##.",
		"##...|..##",
		"..........",
	],
	"wind": [
		"...#####..",
		"..#.....#.",
		"........#.",
		"......##..",
		"..........",
		"..######..",
		".......#..",
		".....##...",
		"..........",
		"########..",
	],
	"grid": [
		"##.##.##..",
		"##.##.##..",
		"..........",
		"##.##.##..",
		"##.##.##..",
		"..........",
		"##.##.##..",
		"##.##.##..",
		"..........",
		"..........",
	],
	"undo": [
		"....##....",
		"...##.....",
		"..#####...",
		".##...##..",
		"##.....##.",
		"##.....##.",
		".#######..",
		"..........",
		"..........",
		"..........",
	],
	"clear": [
		"...####...",
		"..........",
		".########.",
		".#.#.#.#..",
		".#.#.#.#..",
		".########.",
		"..######..",
		"..........",
		"..........",
		"..........",
	],
	# --- starters, one per real starter kind -------------------------------------------
	"st_pale": [
		"..........",
		".#########",
		".#...#####",
		".#...#####",
		".#...#####",
		".#...#####",
		".#...#####",
		".#...#####",
		".#########",
		"..........",
	],
	"st_chev": [
		"..........",
		"..##......",
		"..###.....",
		"..####....",
		"..#####...",
		"..####....",
		"..###.....",
		"..##......",
		"..........",
		"..........",
	],
	"st_cross": [
		"..........",
		"....##....",
		"....##....",
		".########.",
		".########.",
		"....##....",
		"....##....",
		"..........",
		"..........",
		"..........",
	],
	"st_quart": [
		"..........",
		".####.####",
		".####.####",
		".####.####",
		".####.####",
		"..........",
		".####.####",
		".####.####",
		".####.####",
		".####.####",
	],
	"st_blank": [
		"..........",
		".########.",
		".########.",
		".########.",
		".########.",
		".########.",
		".########.",
		".########.",
		".########.",
		"..........",
	],
	# --- furniture ---------------------------------------------------------------------
	"dice": [
		"..........",
		".########.",
		".#......#.",
		".#.##...#.",
		".#......#.",
		".#...##.#.",
		".#......#.",
		".########.",
		"..........",
		"..........",
	],
	"arrow_left": [
		"....#.....",
		"...##.....",
		"..###.....",
		".####.....",
		"#####.....",
		".####.....",
		"..###.....",
		"...##.....",
		"....#.....",
		"..........",
	],
	"diamond": [
		"....##....",
		"...####...",
		"..######..",
		".########.",
		"..######..",
		"...####...",
		"....##....",
		"..........",
		"..........",
		"..........",
	],
}

static var _cache: Dictionary = {}


## The icon as a texture, in one ink colour. Cached per name+colour, so a screen that asks
## for the same pencil every rebuild still builds one image.
static func texture(name: String, colour: Color = Color.WHITE) -> ImageTexture:
	var key := "%s|%s" % [name, colour.to_html(false)]
	if _cache.has(key):
		return _cache[key] as ImageTexture
	var grid: Array = ICONS.get(name, [])
	if grid.is_empty():
		return null
	var height := grid.size()
	var width := str(grid[0]).length()
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		var row := str(grid[y])
		for x in mini(width, row.length()):
			if row[x] == "#":
				image.set_pixel(x, y, colour)
	var texture := ImageTexture.create_from_image(image)
	_cache[key] = texture
	return texture


## An icon in a square, sized in interface points: a TextureRect already set to nearest
## filtering, ready to drop into a row.
static func icon(name: String, size: int = 20, colour: Color = Color.WHITE) -> TextureRect:
	var node := TextureRect.new()
	node.texture = texture(name, colour)
	node.custom_minimum_size = Vector2(float(size), float(size))
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node
