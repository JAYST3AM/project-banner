extends TestCase
## The company banner (D-167): the painted grid, its serialisation, the campaign's
## ownership of it, and the New Game path that puts it in the player's hands.
##
## The banner screen is driven through its own public methods - paint_cell, set_detail,
## confirm, back - the same ones its buttons call, so these tests prove the screen's real
## path rather than a parallel test-only one.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	await _test_the_cloth_shape()
	await _test_default_and_starters()
	await _test_painting_is_guarded()
	await _test_runs_round_trip()
	await _test_serialisation_degrades_to_default()
	await _test_wind_is_pinned_and_bounded()
	await _test_the_banner_renders_to_an_image()
	await _test_the_campaign_carries_the_banner()
	await _test_saving_and_loading_keeps_the_banner()
	await _test_the_new_game_screen_path()
	await _test_every_pixel_icon_is_well_formed()
	greater(float(checks), 80.0, "the suite ran its assertions")
	SaveManager.delete_all_saves()
	GameManager.end_campaign()
	_complete()


## ---------- the cloth --------------------------------------------------------------

func _test_the_cloth_shape() -> void:
	section("the cloth: one silhouette at every detail")
	# Pinned allowed counts. The notch is proportional - it scales with the grid - so
	# these numbers move only when the shape rule itself moves.
	var expected := {
		Vector2i(8, 10): 72,
		Vector2i(16, 20): 292,
		Vector2i(32, 40): 1176,
	}
	for size in BannerData.detail_sizes():
		var w := size.x
		var h := size.y
		var label := "%dx%d" % [w, h]
		check(BannerData.allowed_cell(w, h, 0, 0), "%s: a corner is cloth" % label)
		check(BannerData.allowed_cell(w, h, w - 1, h - 1), "%s: a hem tail is cloth" % label)
		check(not BannerData.allowed_cell(w, h, int(w / 2.0), h - 1), "%s: the notch centre is not" % label)
		check(not BannerData.allowed_cell(w, h, -1, 0), "%s: off-grid is not cloth" % label)
		check(not BannerData.allowed_cell(w, h, 0, h), "%s: below the hem is not cloth" % label)
		var banner := BannerData.new(w, h)
		equal(banner.allowed_count(), int(expected[size]), "%s: allowed cells pinned" % label)
	check(_cut_width(16, 20, 19) > _cut_width(16, 20, 16), "the notch widens towards the hem")
	check(_cut_width(32, 40, 39) > _cut_width(8, 10, 9), "and scales with the grid")


func _cut_width(w: int, h: int, row: int) -> int:
	var cut := 0
	for x in w:
		if not BannerData.allowed_cell(w, h, x, row):
			cut += 1
	return cut


## ---------- the default and the starters -------------------------------------------

func _test_default_and_starters() -> void:
	section("the default banner and the starters")
	var banner := BannerData.create_default()
	equal(banner.width, 16, "the default is 16 wide")
	equal(banner.height, 20, "and 20 tall")
	check(banner.is_legal(), "the default is palette-legal")
	equal(banner.painted_count(), banner.allowed_count(), "the default fills its cloth")
	var twin := BannerData.create_default()
	equal(twin.to_rle(), banner.to_rle(), "two defaults are identical")
	check(banner.to_rle().contains("A"), "and the notch serialises as a hole")
	for kind in ["pale", "chev", "cross", "quart", "blank"]:
		var design := BannerData.new(32, 40)
		design.fill_starter(kind)
		check(design.is_legal(), "starter '%s' is palette-legal at 32x40" % kind)
		check(design.painted_count() <= design.allowed_count(), "starter '%s' paints only cloth" % kind)
	var blank := BannerData.new(16, 20)
	blank.fill_starter("blank")
	equal(blank.painted_count(), 0, "'blank' paints nothing")
	var unknown := BannerData.new(16, 20)
	unknown.fill_starter("nonsense")
	equal(unknown.painted_count(), 0, "an unknown starter paints nothing rather than erroring")


## ---------- painting is guarded ----------------------------------------------------

func _test_painting_is_guarded() -> void:
	section("painting is guarded")
	var banner := BannerData.new(16, 20)
	check(banner.set_cell(2, 2, 15), "a cloth cell accepts a palette colour")
	equal(banner.cell(2, 2), 15, "and reads it back")
	check(not banner.set_cell(7, 19, 15), "the notch refuses paint")
	equal(banner.cell(7, 19), BannerData.EMPTY, "and stays a hole")
	check(not banner.set_cell(2, 2, 99), "an off-palette index is refused")
	equal(banner.cell(2, 2), 15, "leaving the old value alone")
	check(not banner.set_cell(2, 2, -2), "a nonsense negative index is refused too")
	check(banner.set_cell(2, 2, BannerData.EMPTY), "a cell can be erased")
	equal(banner.cell(2, 2), BannerData.EMPTY, "to a hole")
	equal(banner.cell(-1, 0), BannerData.EMPTY, "off-grid reads are holes, not errors")
	check(banner.duplicate_data().to_rle() == banner.to_rle(), "duplicate_data copies exactly")


## ---------- runs -------------------------------------------------------------------

func _test_runs_round_trip() -> void:
	section("runs round trip")
	var banner := BannerData.create_default(32, 40)
	banner.fill_starter("cross")
	var rle := banner.to_rle()
	var decoded := BannerData.decode_rle(rle, 32, 40)
	equal(decoded.size(), 1280, "the decode covers every cell")
	var same := true
	for i in decoded.size():
		if decoded[i] != banner.cells[i]:
			same = false
			break
	check(same, "and matches cell for cell")
	check(BannerData.decode_rle(rle + "9B", 32, 40).is_empty(), "a wrong-length run is refused")
	check(BannerData.decode_rle("3!A", 4, 4).is_empty(), "a bad character is refused")
	check(BannerData.decode_rle("0A", 4, 4).is_empty(), "a zero run is refused")
	check(BannerData.decode_rle("9999A", 32, 40).is_empty(), "an over-long run is refused")
	check(BannerData.decode_rle("", 32, 40).is_empty(), "an empty string is not a banner")
	is_null(BannerData.from_rle("", 32, 40), "and makes no banner object")
	is_null(BannerData.from_rle("320B", 16, 20), "the constructor refuses a painted notch too")
	is_null(BannerData.from_rle("16A", 4, 4), "and a grid that is not a detail level")


## ---------- serialisation degrades to the default -----------------------------------

func _test_serialisation_degrades_to_default() -> void:
	section("serialisation degrades to the default")
	var banner := BannerData.create_default()
	var dict := banner.to_dict()
	has_key(dict, "width", "to_dict writes a width")
	has_key(dict, "height", "a height")
	has_key(dict, "rle", "and runs")
	var back := BannerData.from_dict(dict)
	equal(back.to_rle(), banner.to_rle(), "and from_dict rebuilds it exactly")
	var garbage: Array = [
		{},
		{"width": 16, "height": 20, "rle": "not runs"},
		{"width": 3, "height": 3, "rle": "9A"},
		{"width": 999, "height": 999, "rle": "1A"},
		{"width": "wide", "height": 0, "rle": 12},
	]
	for entry in garbage:
		var recovered := BannerData.from_dict(entry as Dictionary)
		check(recovered.is_legal(), "garbage recovers to a legal banner")
		equal(recovered.width, 16, "at the default size")
		equal(recovered.height, 20, "and the default shape")
	# The audit round: a save that paints the notch, a run that would expand past the
	# grid's end, and a grid that is not a configured detail level are all malformed
	# and must come back as the default banner - the load path enforces the same
	# invariants the paint path does, not just the palette.
	var painted_notch := BannerData.from_dict({"width": 16, "height": 20, "rle": "320B"})
	equal(painted_notch.to_rle(), BannerData.create_default().to_rle(),
		"a save that paints the swallowtail notch degrades to the default")
	var clock := Time.get_ticks_msec()
	var bomb := BannerData.from_dict({"width": 16, "height": 20, "rle": "999999999B"})
	equal(bomb.to_rle(), BannerData.create_default().to_rle(),
		"a run past the grid's end is refused before it expands")
	check(Time.get_ticks_msec() - clock < 500,
		"and the refusal is immediate, not after expanding the run")
	var odd_grid := BannerData.from_dict({"width": 4, "height": 4, "rle": "16A"})
	equal(odd_grid.width, 16, "a grid that is not a paintable detail level degrades")
	equal(odd_grid.height, 20, "to the default shape")
	var over_grid := BannerData.from_dict({"width": 64, "height": 64, "rle": "4096A"})
	equal(over_grid.width, 16, "and an oversized grid degrades too")
	equal(over_grid.height, 20, "to the default")
	var fine := BannerData.create_default(8, 10)
	equal(BannerData.from_dict(fine.to_dict()).to_rle(), fine.to_rle(),
		"a configured 8x10 grid still loads exactly")
	var built_askew := BannerData.new(4, 4)
	equal(built_askew.width, 16, "construction itself normalises a non-configured grid")
	equal(built_askew.height, 20, "to the default pair")
	equal(BannerData.create_default(4, 4).width, 16, "and so does the default factory")


## ---------- the wind ----------------------------------------------------------------

func _test_wind_is_pinned_and_bounded() -> void:
	section("the wind: pinned at the bar, bounded at the hem")
	var height := 20
	var ceiling := int(BannerData.wind_amplitude()) + 2
	for stamp in [0.0, 0.7, 1.31, 2.9, 5.2, 11.0]:
		var t := float(stamp)
		equal(BannerData.wave_shift(0, t, height), 0, "the top row is pinned at t=%.2f" % t)
		for y in height:
			var shift := BannerData.wave_shift(y, t, height)
			check(absi(shift) <= ceiling, "row %d stays bounded at t=%.2f" % [y, t])
	equal(BannerData.wave_shift(19, 3.25, height), BannerData.wave_shift(19, 3.25, height),
		"the same time gives the same swing")
	equal(BannerData.wave_shift(5, 1.0, 0), 0, "a zero-height cloth cannot swing")


## ---------- the renderer -------------------------------------------------------------

func _test_the_banner_renders_to_an_image() -> void:
	section("the renderer: an image the map draws with one quad")
	var banner := BannerData.create_default()
	var still := BannerArt.render_banner_image(banner, 0.0, false)
	equal(still.get_width(), 56, "the banner image is 56 wide")
	equal(still.get_height(), 70, "and 70 tall")
	var palette := BannerData.palette()
	equal(still.get_pixel(28, 3), palette[17], "the finial orb is painted gold")
	equal(still.get_pixel(13, 15), palette[10], "the cloth's first cell is painted (bone border)")
	equal(still.get_pixel(29, 51), palette[13], "and the pole shows through the notch")
	equal(still.get_pixel(2, 2).a, 0.0, "nothing is painted outside the banner")
	# Wind: at a stamp where the hem swings, the image must differ from the stilled one.
	check(BannerData.wave_shift(19, 1.0, 20) != 0, "t=1.0 swings the hem")
	var waved := BannerArt.render_banner_image(banner, 1.0, true)
	var still_at_t := BannerArt.render_banner_image(banner, 1.0, false)
	greater(float(_image_difference(waved, still_at_t)), 0.0, "wind changes the painted pixels")
	# The cache: same state -> the same texture; a different state -> a rebuild.
	var cache := {}
	var first := BannerArt.texture_for(cache, banner, 1.0, true)
	var again := BannerArt.texture_for(cache, banner, 1.0, true)
	check(first == again, "the same state is served from the cache")
	var rebuilt := BannerArt.texture_for(cache, banner, 1.0, false)
	check(rebuilt != first, "a stilled banner is a different texture")
	equal(rebuilt.get_width(), 56, "and the texture matches the image")


func _image_difference(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				count += 1
	return count


## ---------- the campaign owns the banner --------------------------------------------

func _test_the_campaign_carries_the_banner() -> void:
	section("the campaign owns the banner")
	var state := GameManager.new_campaign("Banner Test", 4242)
	not_null(state.player_banner, "a new campaign has a banner")
	check(state.player_banner.is_legal(), "and it is legal")
	var painted := BannerData.new(32, 40)
	painted.fill_starter("cross")
	painted.set_cell(1, 1, 17)
	var carried := GameManager.new_campaign("Banner Test 2", 4243, painted)
	check(carried.player_banner == painted, "new_campaign keeps the painted banner itself")
	var data := carried.to_dict()
	not_null(data.get("player_banner"), "to_dict writes the banner")
	var rebuilt := CampaignState.from_dict(data, GameManager.config())
	not_null(rebuilt.player_banner, "from_dict rebuilds one")
	equal(rebuilt.player_banner.to_rle(), carried.player_banner.to_rle(), "exactly")
	data.erase("player_banner")
	var old := CampaignState.from_dict(data, GameManager.config())
	not_null(old.player_banner, "an old save gains a banner on load")
	check(old.player_banner.is_legal(), "a legal one")
	equal(old.player_banner.width, 16, "at the default detail")
	equal(old.player_banner.height, 20, "and shape")


## ---------- save and load -----------------------------------------------------------

func _test_saving_and_loading_keeps_the_banner() -> void:
	section("saving and loading keeps the exact cloth")
	var state := GameManager.new_campaign("Banner Save", 6060)
	state.player_banner.fill_starter("quart")
	state.player_banner.set_cell(3, 3, 16)
	var rle := state.player_banner.to_rle()
	check(GameManager.save_campaign(), "the campaign saves")
	GameManager.end_campaign()
	check(GameManager.continue_campaign(), "and continues")
	var loaded := GameManager.campaign
	not_null(loaded.player_banner, "with its banner")
	equal(loaded.player_banner.to_rle(), rle, "cell for cell")


## ---------- the New Campaign path ----------------------------------------------------

func _test_the_new_game_screen_path() -> void:
	section("the New Campaign path: menu -> creation screen -> campaign")
	# Through the real menu: New Campaign hands off to the creation screen (D-168), and
	# opening that screen founds nothing - the campaign exists only after Start Campaign.
	var menu := await SceneManager.change_scene_and_wait("main_menu")
	not_null(menu, "the main menu loads")
	if menu == null:
		return
	var campaign_before := GameManager.campaign
	menu.call("press_new_campaign")
	var screen := await SceneManager.await_scene("new_campaign")
	not_null(screen, "New Campaign opens the creation screen")
	equal(SceneManager.current_key, "new_campaign", "and it is the current scene")
	check(GameManager.campaign == campaign_before, "opening the screen created no campaign")

	# The company is named and the world seeded on this screen.
	screen.call("set_company_name", "Painted Company")
	equal(screen.call("company_name"), "Painted Company", "the name field carries the typing")
	screen.call("set_seed_text", "5150")
	equal(screen.call("seed_text"), "5150", "the seed field carries the typing")

	# Painting through the real workspace: a cell, then a finer detail on the same cloth.
	var space: BannerWorkspace = screen.call("workspace")
	not_null(space, "the screen embeds the banner workspace")
	var banner: BannerData = space.current_banner()
	not_null(banner, "which holds a banner")
	equal(banner.width, 16, "in the default detail")
	space.paint_cell(0, 0, 15)
	equal(banner.cell(0, 0), 15, "a painted corner lands")
	space.set_detail(8, 10)
	banner = space.current_banner()
	equal(banner.width, 8, "a finer detail takes")
	equal(banner.height, 10, "in both axes")
	equal(BannerData.cloth_units(), Vector2(32.0, 40.0), "the cloth itself never changes size")
	# The owner's rule: moving around the screen must not lose the setup.
	equal(screen.call("company_name"), "Painted Company", "the name survives the detail change")
	equal(screen.call("seed_text"), "5150", "and the seed survives it")
	space.paint_cell(0, 0, 17)

	# START CAMPAIGN: exactly one campaign, with the typed name, seed and cloth, then the map.
	screen.call("start")
	var world := await SceneManager.await_scene("world_map")
	not_null(world, "START CAMPAIGN reaches the world map")
	equal(SceneManager.current_key, "world_map", "which is current")
	var campaign := GameManager.campaign
	not_null(campaign, "a campaign exists")
	equal(campaign.campaign_name, "Painted Company", "with the name from the creation screen")
	equal(campaign.campaign_seed, 5150, "and the seed")
	not_null(campaign.player_banner, "carrying the painted banner")
	equal(campaign.player_banner.cell(0, 0), 17, "with the paint on it")
	equal(campaign.player_banner.width, 8, "at the chosen detail")

	# Back means nothing happened, however far the player got: no campaign, no trace.
	var menu_again := await SceneManager.change_scene_and_wait("main_menu")
	not_null(menu_again, "back at the menu")
	var before := GameManager.campaign
	var screen_again := await SceneManager.change_scene_and_wait("new_campaign")
	not_null(screen_again, "the creation screen opens again")
	screen_again.call("set_company_name", "Never Made")
	screen_again.call("back")
	var menu_third := await SceneManager.await_scene("main_menu")
	not_null(menu_third, "Back returns to the menu")
	check(GameManager.campaign == before, "and Back created nothing")

	# Escape returns to the menu too, even mid-typing: a focused line edit consumes
	# ui_cancel on its own, so the screen listens before the GUI (D-168 audit round).
	var screen_escape := await SceneManager.change_scene_and_wait("new_campaign")
	not_null(screen_escape, "the screen opens for the Escape test")
	screen_escape.call("focus_company_name")
	check(bool(screen_escape.call("name_field_has_focus")), "the name field holds the caret")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	Input.parse_input_event(escape)
	var menu_escape := await SceneManager.await_scene("main_menu")
	not_null(menu_escape, "Escape returns to the menu even while typing")
	check(GameManager.campaign == before, "and Escape created nothing")
	var release := InputEventKey.new()
	release.keycode = KEY_ESCAPE
	release.physical_keycode = KEY_ESCAPE
	release.pressed = false
	Input.parse_input_event(release)

	# Validation: a blank name resolves to the configured default and a text seed keeps
	# its stable hash - the same request, the same world, whatever was typed.
	var screen_last := await SceneManager.change_scene_and_wait("new_campaign")
	not_null(screen_last, "the screen opens once more")
	screen_last.call("set_company_name", "   ")
	screen_last.call("set_seed_text", "old oak")
	var default_name := GameManager.config().get_string("campaign.default_campaign_name", "A New Banner")
	equal(screen_last.call("resolved_name"), default_name, "a blank name resolves to the default")
	equal(screen_last.call("resolved_seed"), RngService.stable_hash("old oak"),
		"and a text seed keeps its stable hash")
	screen_last.call("start")
	await SceneManager.await_scene("world_map")
	var last_campaign := GameManager.campaign
	equal(last_campaign.campaign_name, default_name, "the default name reaches the campaign")
	equal(last_campaign.campaign_seed, RngService.stable_hash("old oak"), "and the hashed seed does too")
	GameManager.end_campaign()
	await SceneManager.change_scene_and_wait("main_menu")


## ---------- the icon set ------------------------------------------------------------

## The visual pass's icons are string grids read by [method PixelIcons.texture], which sizes
## the image from the first row. The audit caught one icon at 11 wide among 10s - it rendered
## squashed inside its square control - so the format is pinned here: every icon, every row,
## ten and ten.
func _test_every_pixel_icon_is_well_formed() -> void:
	section("every pixel icon is a well-formed 10x10 grid")
	check(PixelIcons.ICONS.size() >= 20, "the set covers the screen's furniture")
	for icon_name in PixelIcons.ICONS.keys():
		var grid: Array = PixelIcons.ICONS[icon_name]
		equal(grid.size(), 10, "icon '%s' is ten rows" % icon_name)
		for y in grid.size():
			equal(str(grid[y]).length(), 10, "icon '%s' row %d is ten wide" % [icon_name, y])
		check(not PixelIcons.texture(str(icon_name)).get_image().is_empty(),
			"icon '%s' renders to a texture" % icon_name)
