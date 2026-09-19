extends Node2D
## World map controller: input, camera, time advance, travel and HUD wiring.
##
## Thin by design. The view draws, the HUD reports and emits intent, the
## TravelService decides whether movement is legal, and the CampaignClock owns
## time. This script only connects them.

const SETTLEMENT_SCENE_KEY := "settlement"

@onready var _view: WorldMapView = $View
@onready var _camera: Camera2D = $Camera2D
@onready var _hud: WorldHud = $HUD

var _state: CampaignState = null
var _config: GameConfig = null
var _travel: TravelService = null
var _costs: TravelCosts = null
var _roads: RoadNetwork = null
## Kept until the ground is built, so the bar is painted until the world is whole.
var _loader: LoadingScreen = null
var _debug: DebugPanel = null
## The settlement detail card (D-136), shown on hover by _update_hover.
var _hover_card: SettlementHoverCard = null
## The traders' card (D-139), shown on hover by the same pass.
var _caravan_card: CaravanHoverCard = null
## The meeting prompt (D-139): open while the player talks to a caravan on the road.
var _caravan_dialog: CaravanDialog = null
var _caravan_meet: WorldParty = null
var _hover_candidate_id := ""
var _hover_shown_id := ""
var _hover_started_ms := 0
var _hover_mouse := Vector2.ZERO
var _overworld: OverworldService = null
var _encounters: EncounterService = null
var _caravans: CaravanService = null
var _dialog: EncounterDialog = null
var _dialog_party_id: String = ""
var _speed_before_dialog: int = CampaignClock.Speed.NORMAL

var _panning := false
## Middle-drag panning on the campaign map.
var _map_drag := false
var _hud_timer := 0.0
## The Esc menu. Owned here rather than by the HUD, because what it offers - saving, leaving the
## campaign - is the world's business, and because it has to work while the world is stopped.
var _pause: PauseMenu = null
## The map's ground, drawn as terrain rather than a flat colour.
var _terrain: Node2D = null
## Dev switch: run the map without its ground layer, to see what the ground is hiding.
var _no_ground := false
var _pause_layer: CanvasLayer = null
var _debug_timer := 0.0


## Whether data/terrain/biomes.json names any ground images that exist. Empty arrays mean the map has
## no ground to draw, which is a state the owner put it in deliberately.
func _ground_has_art() -> bool:
	var catalogue := "res://data/terrain/biomes.json"
	if not FileAccess.file_exists(catalogue):
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(catalogue))
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	for biome in (parsed.get("biomes", []) as Array):
		for ground in (biome.get("grounds", []) as Array):
			var variants: Array = ground.get("variants", [])
			for path in variants:
				if ResourceLoader.exists(str(path)):
					return true
	return false


func _ready() -> void:
	_no_ground = OS.get_cmdline_user_args().has("--no-ground")
	# And no ground if the catalogue has no art for it. The art was deleted on the owner's instruction
	# and the shader drew white without it; skipping the ground entirely is the honest picture of a map
	# that has none, and it costs nothing when art comes back - the check passes and the ground returns.
	# Missing art is not the same as asking for no ground: one means "draw what we have", the other
	# means "draw nothing". Conflating them is why the flat-colour fallback never ran.
	var art_missing := not _ground_has_art()
	DebugLogger.info("world map loading", "WorldMap")

	if not GameManager.is_campaign_active():
		DebugLogger.warn("world map opened with no campaign; returning to the menu", "WorldMap")
		SceneManager.change_scene("main_menu")
		return

	_state = GameManager.campaign
	var _mark := Time.get_ticks_msec()
	var _stage_name := "start"
	_config = GameManager.config()

	# A fresh campaign has no world yet; a loaded save already does. Building it takes about five
	# seconds - ninety settlements, their names, their trade and the roads between them - and it used
	# to happen right here on the main thread, so the game could not draw a frame of it and the owner
	# felt a load spike. Now it runs on a thread behind a loading screen that can actually animate,
	# and this function waits for it while the frames keep coming.
	_stage_name = "world"
	var builder := WorldBuilder.new(_state, _config)
	# The loading screen is only made when there is real work behind it (D-132): a fresh world, or
	# the first entry of the session. The ground's field is cached on the campaign after that, so a
	# return from a town used to build the ground again with NO screen at all, and the owner watched
	# a bare map over it: "I see the map in its first state, just a grid, then it loads the campaign
	# map we are on now."
	var cached_ground: Image = _state.ground_field
	if builder.needs_build() or cached_ground == null:
		_loader = LoadingScreen.new()
		var loader := _loader
		add_child(loader)
		loader.set_progress(0.02)
		if builder.needs_build():
			loader.set_status("Generating the world")
			loader.watch(builder)
			var thread := Thread.new()
			thread.start(builder.build_if_needed)
			while thread.is_alive():
				await get_tree().process_frame
			thread.wait_to_finish()
		else:
			# The world is already on the campaign; only the ground below still costs anything.
			builder.build_if_needed()
			loader.set_progress(0.7)
		loader.set_status("Laying the ground under it")
		await get_tree().process_frame
	else:
		builder.build_if_needed()

	DebugLogger.info("  map entry: world done at %d ms" % (Time.get_ticks_msec() - _mark), "WorldMap")
	# Old saves carry no settlement detail - or one generated by older rules: fill() checks its own
	# version and regenerates when needed (D-136), so a save written before the trade/buildings rule
	# gains a consistent town without a migration.
	for key in _state.settlements.keys():
		var st := _state.settlements[key] as Settlement
		if st != null:
			SettlementDetails.fill(st, _state.campaign_seed)
	# Coverage (D-140): a town that wants nothing anybody makes - or that nobody buys from - is a
	# dead end on the road.
	SettlementDetails.repair_world_wants(_state.settlements, _state.roads)
	_stage_name = "travel service"
	_mark = Time.get_ticks_msec()
	_travel = TravelService.new(_state, _config)
	# The roads are a living thing: the network normalises every link (saves from before the tiers
	# carry plain kinds) and the travel service wears the ones the party walks. Cached on the campaign
	# with the grid (D-129): re-shaping its curves is fifty milliseconds of every map visit.
	_roads = _state.road_network
	if _roads == null:
		_roads = RoadNetwork.new(_state, _config)
		_state.road_network = _roads
	_travel.roads = _roads
	# One pathfinder for the campaign: 16,384 cells at 32 units each (it was 4,096 at 64, until the
	# owner asked for finer debug blocks), and every order after this is an A* over a grid that is
	# already priced.
	# The priced grid is cached on the campaign (D-129): it changes only when a road changes tier, and
	# a fresh build on every visit to the map froze it for a fifth of a second each time.
	_costs = _state.travel_costs
	if _costs == null or not _costs.is_ready():
		_costs = TravelCosts.new()
		_costs.build(_state.campaign_seed, _config, _state.roads, _state.settlements)
		_state.travel_costs = _costs
	_travel.costs = _costs
	_view.costs = _costs
	DebugLogger.info("  map entry: costs done at %d ms" % (Time.get_ticks_msec() - _mark), "WorldMap")
	_stage_name = "view bind"
	_mark = Time.get_ticks_msec()
	_view.bind(_state, _config, _travel)
	_view.roads = _roads
	# The ground goes in before the map view and behind it: the view draws roads, settlements and
	# parties on top of terrain it no longer has to paint itself.
	var ground_from_cache := false
	if not _no_ground and not art_missing:
		_terrain = WorldTerrain.new()
		# Under the map view, which draws at -10. The first version of this sat at -1 - above the
		# view rather than below it - so the ground was painted over the roads, the settlement
		# rings and the labels, and the map looked like empty terrain with a working UI on top.
		_terrain.z_index = -20
		add_child(_terrain)
		# The ground reports row by row, owns the last third of the bar, and yields frames while it
		# builds so the bar keeps moving instead of freezing solid. It used to be built after the
		# screen was dismissed, which is the second half of why the bar stalled: the terrain is two
		# seconds of work nobody could see.
		await _terrain.setup(_state.campaign_seed, _view.land_rect(), _config, func(part: float) -> void:
			if _loader != null:
				_loader.set_progress(0.7 + 0.3 * part)
		, _state.settlements.values())
		_view.ground_art = true
	elif not _no_ground:
		# No art, but a map the owner can still read: flat colours per terrain kind, from the same
		# field. The terrain session's files are untouched; this is a sibling that stands in.
		_terrain = WorldFlat.new()
		_terrain.z_index = -20
		add_child(_terrain)
		# Awaited, and reporting, exactly like the painted ground: without the await the map finished
		# _ready while these rows were still yielding, and without the callback the bar sat at 0.70 -
		# the figure the owner kept seeing: "it gets to 90ish % then stops".
		await _terrain.setup(_state.campaign_seed, _view.land_rect(), _config, func(part: float) -> void:
			if _loader != null:
				_loader.set_progress(0.7 + 0.3 * part)
		, cached_ground, _state.settlements.values())
		# Kept on the campaign so the next entry - every return from a town - is instant (D-132).
		_state.ground_field = _terrain.field_image
		ground_from_cache = cached_ground != null
		_view.ground_art = true
	else:
		# The one-look test for "the towns and roads are gone": with the ground off, are the features
		# missing, or merely drawn in ink that was chosen for a flat dark slab and cannot read on
		# painted grass? A switch rather than an edit, so the same build answers both halves.
		print("world terrain: disabled by --no-ground")
	_view.queue_redraw()

	DebugLogger.info("  map entry: ground done at %d ms%s" % [
		Time.get_ticks_msec() - _mark,
		" (cached)" if ground_from_cache else "",
	], "WorldMap")
	_stage_name = "map ready"
	_mark = Time.get_ticks_msec()

	_overworld = OverworldService.build(_state, _config)
	_overworld.spawn_if_needed()
	_encounters = EncounterService.build(_state, _config)
	# The roads' own life (D-139): caravans trade between the towns on the clock, below. They walk
	# the network's own link curves, so the roads below are theirs too.
	_caravans = CaravanService.build(_state, _config, _roads)
	_caravans.spawn_if_needed()

	_build_hud_and_overlays()
	_build_pause_menu()

	# A committed UI-scale change rebuilds the map's screens at the new size (D-137 follow-up).
	GameSettings.ui_scale_committed.connect(_rebuild_hud)

	# Dev-only: "--debug-panel" opens with the developer's furniture showing, priced grid included.
	# A scripted run cannot press F1, and "show me the grid" arrives as a screenshot request.
	if DevFlags.debug_panel():
		_debug.visible = _debug.is_available()
		_toggle_perf_overlay()

	_focus_camera_on_party()
	_restore_selection_from_payload()
	_refresh()
	_hud.set_hint("Click a settlement to inspect it, then Enter goes in. F1 opens debug tools.")

	_apply_dev_autoengage()
	_apply_dev_autotravel()
	_apply_dev_hover_card()

	# The map is whole - the world, its roads and the ground are all in - so the screen can go. It used
	# to be dismissed right after the world build (before the ground existed), and when the bar took the
	# ground build into its window that call was dropped and never re-added: the bar reached 0.70, said
	# it was laying the ground, and stayed there for good. The owner, watching it: "still stalling out".
	DebugLogger.info("  map entry: map ready at %d ms" % (Time.get_ticks_msec() - _mark), "WorldMap")
	if _loader != null:
		await _loader.finish()


## Dev-only: drop the player next to a hostile party so the encounter path runs
## without waiting for one to wander into them. Chooses the smallest band by
## default - the fight a careful player would pick.
func _apply_dev_autoengage() -> void:
	if not DevFlags.autoengage() or _overworld == null:
		return
	var parties := _overworld.available_parties()
	if parties.is_empty():
		DebugLogger.warn("dev flag: no hostile parties to engage", "WorldMap")
		return
	var target := parties[0]
	for candidate in parties:
		var size := _state.active_members(_state.party_of(candidate)).size()
		if size < _state.active_members(_state.party_of(target)).size():
			target = candidate
	_state.world_position = target.position
	DebugLogger.info("dev flag: moved the party onto %s (%d soldiers)" % [
		target.display_name, _state.active_members(_state.party_of(target)).size(),
	], "WorldMap")


## The HUD and the screens that hang off it: the hover card, the encounter dialog, the developer's
## panel. Extracted so a UI-scale change can build all of them again - a control keeps the text size
## it was born with, and the owner's report was exactly that: "ui slider doesn't affect the rest of
## the ui. ie the ui on the campaign map."
func _build_hud_and_overlays() -> void:
	_hud.setup(_state, _config, _travel)
	_hover_card = SettlementHoverCard.new()
	_hud.add_child(_hover_card)
	_caravan_card = CaravanHoverCard.new()
	_hud.add_child(_caravan_card)
	_hud.speed_requested.connect(_on_speed_requested)
	_hud.travel_requested.connect(_on_travel_requested)
	_hud.enter_settlement_requested.connect(_on_enter_settlement)

	_dialog = EncounterDialog.new()
	_hud.add_child(_dialog)
	_dialog.attack_requested.connect(_on_encounter_attack)
	_dialog.retreat_requested.connect(_on_encounter_retreat)

	_caravan_dialog = CaravanDialog.new()
	_hud.add_child(_caravan_dialog)
	_caravan_dialog.trade_requested.connect(_on_caravan_trade)
	_caravan_dialog.ask_requested.connect(_on_caravan_ask)
	_caravan_dialog.farewell_requested.connect(_on_caravan_farewell)

	_debug = DebugPanel.new()
	_hud.add_child(_debug)
	_debug.setup(_state, _config, _travel)
	_debug.teleport_requested.connect(_on_teleport_requested)
	_debug.gold_requested.connect(_on_gold_requested)
	_debug.speed_requested.connect(_on_speed_requested)
	_debug.state_requested.connect(_refresh)


## Build the map's screens again at the new scale, and put the player's inspection back: rebuilding
## must not quietly close the settlement they were reading. The pause menu is deliberately NOT
## rebuilt - the player is inside it, holding the slider that asked for this.
func _rebuild_hud() -> void:
	var inspected := _hud.shown_settlement_id()
	for node in [_hud, _hover_card, _caravan_card, _dialog, _caravan_dialog, _debug]:
		if node != null:
			node.free()
	_hud = WorldHud.new()
	_hud.name = "HUD"
	add_child(_hud)
	_build_hud_and_overlays()
	if DevFlags.debug_panel():
		_debug.visible = _debug.is_available()
	_hover_shown_id = ""
	_hover_candidate_id = ""
	_refresh()
	_hud.set_hint("Click a settlement to inspect it, then Enter goes in. F1 opens debug tools.")
	if not inspected.is_empty():
		var settlement := _state.settlement(inspected)
		if settlement != null:
			_hud.show_settlement(settlement)
	DebugLogger.info("ui scale committed: screens rebuilt at %d%%" % int(round(GameSettings.ui_scale * 100.0)),
		"WorldMap")


## Dev-only: begin travelling immediately (see DevFlags). Used by automated runs
## to exercise the real rendered world map without a mouse.
func _apply_dev_autotravel() -> void:
	var town := DevFlags.consume_autostart_town()
	if not town.is_empty():
		DebugLogger.info("dev flag: entering %s directly" % town, "WorldMap")
		_travel.teleport_to(town)
		_on_enter_settlement(town)
		return
	var destination := DevFlags.autotravel_destination()
	if destination.is_empty():
		return
	var settlement := _state.settlement(destination)
	if settlement == null:
		DebugLogger.warn("dev flag: unknown autotravel destination '%s'" % destination, "WorldMap")
		return
	DebugLogger.info("dev flag: autotravelling to %s" % settlement.name, "WorldMap")
	_on_travel_requested(destination)


## ---------- per-frame ----------------------------------------------------

## One simulation step, in real seconds: the same 30 Hz the battle clock runs at, read from the config
## so the two cannot drift apart.
const SIM_STEP := 1.0 / 30.0
## Real seconds banked since the last simulation step. Frame time varies; the step does not.
var _accumulator := 0.0


func _process(delta: float) -> void:
	# The world is built behind the loading screen, on a thread, while this map's frames are already
	# running. Until the build lands there is no clock to step and no travel to advance, and calling
	# into either produced 327 errors of "Nonexistent function 'step' in base 'Nil'" in one run.
	if _state == null or _travel == null:
		return
	if _state == null:
		return

	_update_camera_pan(delta)

	# The world runs on the simulation clock, not on however fast the renderer draws. Stepping travel
	# once per frame made it both too fast (360 steps a second, each capped at 24 units) and jittery
	# (uneven frame times, so uneven strides) - the owner: "is jittery and sped up". A fixed 30 Hz
	# accumulator gives every step the same slice of time, so the world advances evenly and at the rate
	# the config names, and a dropped frame costs frame rate rather than running the world faster.
	_accumulator += delta
	while _accumulator >= SIM_STEP:
		_accumulator -= SIM_STEP
		var game_hours := _state.clock.advance_real_seconds(SIM_STEP)
		if game_hours > 0.0:
			# Remembered so the map can draw the party *between* steps rather than only on them.
			_state.previous_world_position = _state.world_position
			var report := _travel.step(game_hours)
			if report.get("arrived", false):
				_on_arrived(str(report.get("settlement_id", "")))
			if _overworld != null:
				_overworld.step(game_hours)
			if _caravans != null:
				_caravans.step(game_hours)
				_check_caravan_meeting()
	# The roads age and grow on the same clock: a link worn by traffic rises a tier, one nobody has
	# used for years falls one, and the map re-prices the ground when either happens - an event of
	# about a seventh of a second, not a per-frame cost.
	if _roads != null and _roads.review(_state.clock.total_hours()):
		_rebuild_costs()
	# How far the renderer is through the step it is waiting on, for the same reason.
	_state.render_alpha = clampf(_accumulator / SIM_STEP, 0.0, 1.0)

	# The cost grid is drawn while debug mode is open, so what the pathfinder prices and what the
	# owner can see are the same thing on the same screen.
	if _view != null and _debug != null:
		_view.show_costs = _debug.visible

	_check_for_encounter()

	_view.queue_redraw()

	_update_hover()

	# HUD text does not need to run at frame rate.
	_hud_timer += delta
	if _hud_timer >= 0.1:
		_hud_timer = 0.0
		_refresh()


func _refresh() -> void:
	_hud.refresh()
	if _debug != null:
		_debug.refresh()


## A road changed tier: its ground is re-priced in place, and handed back to the same readers. A
## journey already under way keeps its route; the next order is planned on the new prices. The full
## rebuild is only for when there is no link ledger to trust - it used to run for every tier change
## and every map entry, a fifth of a second of frozen map each time (D-129).
func _rebuild_costs() -> void:
	if _costs != null and _costs.is_ready() and _roads != null and not _roads.changed_links.is_empty():
		var restamped := _roads.changed_links.size()
		for index in _roads.changed_links:
			_costs.apply_tier(index)
		_roads.changed_links.clear()
		DebugLogger.info("  costs: re-stamped %d changed link(s) in place" % restamped, "WorldMap")
	else:
		_costs.build(_state.campaign_seed, _config, _state.roads, _state.settlements)
		_state.travel_costs = _costs
	_travel.costs = _costs
	_view.costs = _costs
	_view.queue_redraw()


func _on_arrived(settlement_id: String) -> void:
	var settlement := _state.settlement(settlement_id)
	if settlement == null:
		return
	_hud.set_hint("Arrived at %s on %s." % [settlement.name, _state.clock.full_string()])
	_select(settlement)
	_refresh()


## ---------- encounters ---------------------------------------------------

## The world pauses the moment two parties touch, exactly as the brief specifies.
func _check_for_encounter() -> void:
	if _dialog_party_id != "" or _encounters == null:
		return
	var world_party := _encounters.detect()
	if world_party == null:
		return
	if world_party.kind != Party.KIND_BANDIT:
		return
	_show_encounter(world_party)
	if DevFlags.autoattack():
		DebugLogger.info("dev flag: auto-attacking", "WorldMap")
		_on_encounter_attack()


func _show_encounter(world_party: WorldParty) -> void:
	_dialog_party_id = world_party.id
	_speed_before_dialog = int(_state.clock.speed)
	_state.clock.set_speed(CampaignClock.Speed.PAUSED)

	var party := _state.party_of(world_party)
	var enemy_count := _state.active_members(party).size()
	_dialog.show_encounter(
		world_party.display_name,
		_encounters.enemy_strength(world_party),
		enemy_count,
		_encounters.player_strength(),
		_state.active_members(_state.player_party).size()
	)
	_hud.set_hint("The world is paused while you decide.")
	DebugLogger.info("encounter with %s (%d soldiers) at %s" % [
		world_party.display_name, enemy_count, _state.clock.full_string(),
	], "WorldMap")
	_refresh()


func _close_encounter_dialog() -> void:
	_dialog_party_id = ""
	_dialog.hide_dialog()
	_state.clock.set_speed(_speed_before_dialog as CampaignClock.Speed)


## ---------- caravans (D-139) ---------------------------------------------

## Meeting a caravan on the road: close enough and off cooldown, the traders have their say. The
## world pauses while the meeting is open, like an encounter - but nobody here is drawing steel.
func _check_caravan_meeting() -> void:
	if DevFlags.no_meetings():
		return
	if _caravans == null or _caravan_dialog == null or _caravan_dialog.visible:
		return
	if _dialog != null and _dialog.visible:
		return
	if _state == null or _state.clock == null:
		return
	var caravan := _caravans.nearest_meetable(_state.world_position,
		_config.get_float("trade.meeting_radius", 42.0))
	if caravan == null:
		return
	_caravan_meet = caravan
	_speed_before_dialog = _state.clock.speed
	_state.clock.set_speed(CampaignClock.Speed.PAUSED)
	_caravan_dialog.show_meeting(caravan, _caravans, _state)
	_hud.set_hint("Traders on the road. The world waits while you talk.")
	DebugLogger.info("met %s on the road (%s)" % [caravan.display_name,
		_state.clock.full_string()], "Trade")


func _on_caravan_trade() -> void:
	if _caravan_meet == null or _caravans == null:
		return
	var sale := _caravans.sell_one_crate(_caravan_meet)
	if bool(sale.get("ok", false)):
		_caravan_dialog.set_note("You buy a crate of %s for %d coin." % [
			TradeService.name_of(str(sale.get("good", ""))).to_lower(), int(sale.get("price", 0))])
		_caravan_dialog.refresh_after_trade(_caravan_meet)
		_refresh()
	else:
		_caravan_dialog.set_note("No sale: %s." % str(sale.get("reason", "no reason given")))


func _on_caravan_ask() -> void:
	if _caravan_meet != null and _caravans != null:
		_caravan_dialog.set_note(_caravans.road_report(_caravan_meet))


func _on_caravan_farewell() -> void:
	if _caravan_meet != null:
		_caravan_meet.encounter_cooldown_until_hours = _state.clock.total_hours() \
			+ _config.get_float("trade.meeting_cooldown_hours", 20.0)
		_caravan_meet = null
	if _caravan_dialog != null:
		_caravan_dialog.hide_dialog()
	_state.clock.set_speed(_speed_before_dialog as CampaignClock.Speed)
	_hud.set_hint("Click a settlement to inspect it, then Enter goes in. F1 opens debug tools.")


func _on_encounter_attack() -> void:
	var world_party := _state.world_party(_dialog_party_id)
	var party_id := _dialog_party_id
	if world_party == null or _encounters == null:
		_close_encounter_dialog()
		return
	var context := _encounters.build_context(world_party, true)
	if context == null:
		_hud.set_hint("That fight could not be started - see the log.")
		_close_encounter_dialog()
		return
	DebugLogger.info("attacking %s (battle %s)" % [world_party.display_name, context.battle_id], "WorldMap")
	_close_encounter_dialog()
	_hud.set_hint("Loading the battlefield against %s..." % party_id)
	SceneManager.change_scene("battle_field", {"context": context})


func _on_encounter_retreat() -> void:
	var world_party := _state.world_party(_dialog_party_id)
	if world_party != null and _encounters != null:
		_encounters.apply_retreat(world_party)
		_hud.set_hint("You pulled away from %s." % world_party.display_name)
	_close_encounter_dialog()
	_refresh()


## ---------- camera -------------------------------------------------------

func _focus_camera_on_party() -> void:
	_camera.position = _state.world_position
	# Pulled back from 1.0, which showed a 1600-unit slice of a 4096-unit world: the owner's words were
	# "everything is way too close". 0.55 shows about 2900 units, so a settlement, its neighbours and
	# the road between them are on screen at once.
	_camera.zoom = Vector2(0.75, 0.75)


func _update_camera_pan(delta: float) -> void:
	var direction := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		direction.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		direction.y += 1.0
	if direction == Vector2.ZERO:
		return
	var speed := _config.get_float("world.camera_pan_speed", 700.0) / maxf(0.2, _camera.zoom.x)
	_camera.position += direction.normalized() * speed * delta
	_clamp_camera()


## Keep the camera over the world. It used to be clamped to the campaign's old 1600x900 map
## rectangle, so a party standing at y 4060 of a 4096-unit world could pan to the edge of the map and
## no further - the owner felt that as "camera felt weird like I was limited by the area I can move
## around". The limit is the world's own size now, with a margin so the edge of the land can sit in
## the middle of the screen rather than pinned to a corner.
func _clamp_camera() -> void:
	var margin := 160.0
	var whole := Vector2(WorldChunks.WORLD_SIZE, WorldChunks.WORLD_SIZE)
	_camera.position = Vector2(
		clampf(_camera.position.x, -margin, whole.x + margin),
		clampf(_camera.position.y, -margin, whole.y + margin)
	)


func _zoom_by(factor: float) -> void:
	var min_zoom := _config.get_float("world.camera_min_zoom", 0.45)
	var max_zoom := _config.get_float("world.camera_max_zoom", 2.2)
	var next := clampf(_camera.zoom.x * factor, min_zoom, max_zoom)
	_camera.zoom = Vector2(next, next)


## ---------- input --------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _state == null:
		return
	# Middle-drag pans, and Home returns to the party. The keyboard pan was always there, but the
	# camera was clamped to the campaign's old 1600x900 rectangle on a 4096-unit world, so a party
	# outside it could not be followed: every pan was clamped straight back and the map felt stuck.
	# The clamp is the world now, and a mouse is what a hand reaches for on a map.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		_map_drag = event.pressed
		return
	if event is InputEventMouseMotion and _map_drag:
		_camera.position -= event.relative / maxf(0.05, _camera.zoom.x)
		_clamp_camera()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_HOME:
		_focus_camera_on_party()
		_hud.set_hint("Back over the party.")
		return

	# Esc opens the menu. Closing is the menu's own business: while it is open the tree is paused,
	# and a paused screen does not receive input at all - so the menu, which is set to keep running,
	# hears the second Esc itself.
	if event.is_action_pressed("ui_cancel") and _pause != null and not _pause.is_open():
		_pause.open()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(1.12)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(1.0 / 1.12)
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_handle_left_click(_view.get_global_mouse_position())
		elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
			_handle_right_click(_view.get_global_mouse_position())
		return

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			_camera.position -= motion.relative / _camera.zoom
			_clamp_camera()
			return
		# Hovering the map: remember the cursor and the place under it (D-136). The card itself is
		# shown by _process after a short rest, so sweeping the mouse across the map never flickers a
		# card into being.
		if not _map_drag:
			_hover_mouse = motion.position
			_update_hover_candidate()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)


func _handle_left_click(world_point: Vector2) -> void:
	var settlement := _view.settlement_at(world_point)
	if settlement == null:
		_deselect()
		return
	_select(settlement)


## Right click is the move button: anywhere on the map, with or without a settlement under it.
## A place that can be entered is travelled to by its own order, so arriving there opens it; every
## other spot - a hamlet, a ruin, a crossroads, open ground - is simply somewhere to march to. This
## is a real march either way: travel costs game hours and the clock runs while it happens.
func _handle_right_click(world_point: Vector2) -> void:
	var settlement := _view.settlement_at(world_point)
	if settlement != null and settlement.is_enterable():
		if _travel.set_destination(settlement.id):
			_hud.set_hint("Marching to %s." % settlement.name)
		return
	var point := settlement.position if settlement != null else world_point
	if _travel.set_destination_point(point):
		_hud.set_hint("Marching to open ground (%.1f h)." % _travel.hours_to_reach(point))
	else:
		_hud.set_hint("Already here.")


## F1 shows the developer's furniture: the debug panel and the frame-rate overlay together, because
## the owner asked for them as one thing - "move the fps one and all that to the right of the screen
## and toggles on/off with f1 (should initially be toggled off)". Both start hidden; frame counting
## and the hitch warnings in the log run regardless.
func _toggle_perf_overlay() -> void:
	for node in get_tree().get_nodes_in_group("perf_overlay"):
		if node.has_method("toggle"):
			node.call("toggle")


## ---------- hover card (D-136) -------------------------------------------

## How long the cursor must rest on a settlement before its detail card appears. Long enough that
## sweeping the mouse across the map never flickers a card, short enough that resting feels like an
## answer rather than a wait.
const HOVER_DELAY_MS := 250


func _update_hover_candidate() -> void:
	if _view == null:
		return
	var key := ""
	var under := _view.settlement_at(_view.get_global_mouse_position())
	if under != null:
		key = "s." + under.id
	else:
		var caravan := _caravan_under(_view.get_global_mouse_position())
		if caravan != null:
			key = "c." + caravan.id
	if key != _hover_candidate_id:
		_hover_candidate_id = key
		_hover_started_ms = Time.get_ticks_msec()


## The caravan under the cursor, within a few pixels - a moving thing is harder to hit than a town,
## so the traders get a slightly larger hand.
func _caravan_under(point: Vector2) -> WorldParty:
	if _state == null:
		return null
	var best: WorldParty = null
	var best_distance := 16.0
	for key in _state.parties.keys():
		var world_party := _state.parties[key] as WorldParty
		if world_party == null or not world_party.is_available():
			continue
		if world_party.kind != Party.KIND_CARAVAN:
			continue
		var distance := point.distance_to(world_party.position)
		if distance <= best_distance:
			best_distance = distance
			best = world_party
	return best


## Once a frame: show the card for whatever has been rested on long enough, keep it near the
## cursor, and take it away the moment the cursor moves off.
func _update_hover() -> void:
	if _hover_card == null or _state == null:
		return
	if _hover_candidate_id.is_empty():
		if not _hover_shown_id.is_empty():
			_hover_shown_id = ""
			_hover_card.hide_card()
			if _caravan_card != null:
				_caravan_card.hide_card()
		return
	if _hover_shown_id == _hover_candidate_id:
		_position_hover_card()
		return
	if Time.get_ticks_msec() - _hover_started_ms >= HOVER_DELAY_MS:
		_show_hover_card(_hover_candidate_id)


func _show_hover_card(key: String) -> void:
	# Caravan keys are "c.<id>"; settlement keys are "s.<id>" (older callers pass a bare id, which
	# is a settlement - unchanged from before this pass).
	if key.begins_with("c."):
		var caravan := _state.parties.get(key.substr(2), null) as WorldParty
		if caravan == null or _caravans == null:
			return
		_hover_shown_id = key
		_hover_card.hide_card()
		_caravan_card.show_caravan(caravan, _caravans, _state)
		return
	var settlement := _state.settlement(key.substr(2) if key.begins_with("s.") else key)
	if settlement == null:
		return
	_hover_shown_id = key
	if _caravan_card != null:
		_caravan_card.hide_card()
	_hover_card.show_settlement(settlement,
		"Travel here: ~%.1f game hours" % _travel.hours_to_reach(settlement.position))
	_position_hover_card()


## Near the cursor, clamped inside the screen: never under the pointer's own corner, never hanging
## off an edge.
func _position_hover_card() -> void:
	var card: Control = _hover_card
	if _caravan_card != null and _caravan_card.visible:
		card = _caravan_card
	if card == null:
		return
	var card_size := card.size
	if card_size == Vector2.ZERO:
		card_size = card.get_combined_minimum_size()
	var screen := get_viewport().get_visible_rect().size
	var at := _hover_mouse + Vector2(22.0, 18.0)
	at.x = clampf(at.x, 8.0, maxf(8.0, screen.x - card_size.x - 8.0))
	at.y = clampf(at.y, 8.0, maxf(8.0, screen.y - card_size.y - 8.0))
	card.position = at


## Dev-only: "--hover-card" (or "--hover-card=<id>") shows the card at boot. Bare, it prefers the
## nearest VISITED settlement - the card's full form - and falls back to the nearest of any kind,
## which shows the unscouted form.
func _apply_dev_hover_card() -> void:
	var wanted := DevFlags.hover_card()
	if wanted.is_empty():
		return
	# "--hover-card=caravan_00" shows the traders' card (D-139); anything else is a settlement id or
	# "nearest", exactly as before.
	if wanted.begins_with("caravan_"):
		var caravan := _state.parties.get(wanted, null) as WorldParty
		if caravan != null and _caravans != null:
			_hover_mouse = get_viewport().get_visible_rect().size * 0.42
			_hover_candidate_id = "c." + caravan.id
			_show_hover_card(_hover_candidate_id)
		return
	var target: Settlement = null
	if wanted != "nearest":
		target = _state.settlement(wanted)
	else:
		var best_visited := INF
		var best_any := INF
		var candidate_any: Settlement = null
		for key in _state.settlements.keys():
			var st := _state.settlements[key] as Settlement
			if st == null:
				continue
			var distance := st.position.distance_to(_state.world_position)
			if st.visited and distance < best_visited:
				best_visited = distance
				target = st
			if distance < best_any:
				best_any = distance
				candidate_any = st
		if target == null:
			target = candidate_any
	if target == null:
		return
	_hover_mouse = get_viewport().get_visible_rect().size * 0.42
	_show_hover_card(target.id)


func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_F1:
			if _debug != null:
				_debug.toggle()
			_toggle_perf_overlay()
		KEY_SPACE:
			_state.clock.toggle_pause()
			_hud.set_hint("Time %s." % _state.clock.speed_name().to_lower())
		KEY_1:
			_on_speed_requested("paused")
		KEY_2:
			_on_speed_requested("normal")
		KEY_3:
			_on_speed_requested("fast")
		KEY_ESCAPE:
			_deselect()
		KEY_F5:
			_on_save_requested()
		KEY_R:
			_travel.clear_destination()
			_hud.set_hint("Travel cancelled.")
		_:
			return
	_refresh()


## ---------- selection ----------------------------------------------------

func _select(settlement: Settlement) -> void:
	_view.selected_id = settlement.id
	_view.queue_redraw()
	_hud.show_settlement(settlement)


func _deselect() -> void:
	_view.selected_id = ""
	_view.queue_redraw()
	_hud.hide_settlement()


func _restore_selection_from_payload() -> void:
	var payload := SceneManager.consume_payload()
	var wanted := str(payload.get("select_settlement_id", ""))
	if wanted.is_empty():
		return
	var settlement := _state.settlement(wanted)
	if settlement != null:
		_select(settlement)


## ---------- HUD actions --------------------------------------------------

func _on_speed_requested(speed_name: String) -> void:
	if not _state.clock.set_speed_by_name(speed_name):
		return
	_refresh()


func _on_travel_requested(settlement_id: String) -> void:
	var settlement := _state.settlement(settlement_id)
	if settlement == null:
		return
	if not settlement.is_enterable():
		# A place that cannot be entered is still somewhere to march to. Refusing the order taught
		# the player nothing about the map; marching there is plainly what the button means.
		if _travel.set_destination_point(settlement.position):
			_hud.set_hint("Marching to %s - about %.1f game hours." % [
				settlement.name, _travel.hours_to_reach(settlement.position),
			])
		return
	if _travel.set_destination(settlement_id):
		var hours := _travel.hours_to_reach(settlement.position)
		_hud.set_hint("Travelling to %s - %.0f units, about %.1f game hours at %s speed." % [
			settlement.name,
			_travel.distance_to(settlement.position),
			hours,
			_state.clock.speed_name().to_lower(),
		])
	else:
		_hud.set_hint("%s is right here. Choose Enter %s instead." % [settlement.name, settlement.name])
	_refresh()


func _on_enter_settlement(settlement_id: String) -> void:
	var settlement := _state.settlement(settlement_id)
	if settlement == null:
		return
	if not _travel.is_at_settlement(settlement_id):
		_hud.set_hint("Travel to %s first." % settlement.name)
		return
	DebugLogger.info("entering %s" % settlement.name, "WorldMap")
	SceneManager.change_scene(SETTLEMENT_SCENE_KEY, {"settlement_id": settlement_id})


## Built here rather than in the scene file, on its own canvas layer above the HUD: a Control added
## as a plain child would draw underneath the HUD's own layer and the menu would come up behind the
## panels it is supposed to cover.
func _build_pause_menu() -> void:
	_pause_layer = CanvasLayer.new()
	_pause_layer.layer = 40
	add_child(_pause_layer)
	_pause = PauseMenu.new()
	_pause_layer.add_child(_pause)
	_pause.save_requested.connect(_on_save_requested)
	_pause.menu_requested.connect(_on_menu_requested)
	_pause.quit_requested.connect(_on_quit_requested)


func _on_quit_requested() -> void:
	DebugLogger.info("quit requested from the pause menu", "WorldMap")
	get_tree().quit()


func _on_save_requested() -> void:
	var saved := GameManager.save_campaign()
	if saved:
		_hud.set_hint("Campaign saved.")
	else:
		_hud.set_hint("Save failed - see the log.")
	# The HUD's line is behind the menu when the menu is what asked, so the menu says it too.
	if _pause != null and _pause.is_open():
		_pause.set_status("Campaign saved." if saved else "Save failed - see the log.")


func _on_menu_requested() -> void:
	GameManager.save_campaign()
	SceneManager.change_scene("main_menu")


func _on_teleport_requested(settlement_id: String) -> void:
	if _travel.teleport_to(settlement_id):
		var settlement := _state.settlement(settlement_id)
		_focus_camera_on_party()
		_select(settlement)
		_refresh()


func _on_gold_requested(amount: int) -> void:
	_state.player_gold += amount
	DebugLogger.info("debug: gold %+d -> %d" % [amount, _state.player_gold], "Debug")
	_refresh()
