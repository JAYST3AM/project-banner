extends Node
## Development-only stalemate probe for large formed battles.
##
## [b]What it is for.[/b] The 300 v 300 showcase froze at roughly half casualties: no
## soldier could reach anybody, no further casualties happened, and the battle never
## resolved. Watching that happen once is not evidence - it is an anecdote with a
## screenshot. This scene opens the same battle headlessly, drives it at a fixed
## simulation step, and writes down what the formations and the soldiers were doing at
## the moment the fighting stopped, so the failure can be reproduced, profiled and later
## re-tested without a window.
##
## [b]It is not part of the game.[/b] It is not shipped, nothing in the game reads it, and
## it changes no production value. It builds the production battle through the production
## constructors and measures it.
##
## [b]What it measures, every sample.[/b] Both sides' living counts; the tick of the last
## hit and the last death; per body: order, state (moving / turning / reforming / steady),
## contact, cohesion, anchor, where it is steering, how far its anchor is from the nearest
## hostile anchor, how far its nearest living member is from the nearest living enemy, how
## many of its soldiers have an enemy within reach, how many are allowed to press forward
## and which of the press-forward conditions is failing, and the average and worst distance
## from a soldier to its own slot. Army-wide: how many soldiers are in reach of anybody, the
## nearest-enemy distance distribution, and how many soldiers moved toward an enemy since
## the previous sample.
##
## [b]What it does when the fighting stops.[/b] A stalemate is detected from measurement
## rather than from the clock: both sides alive, no hit for a sustained number of
## [i]simulation ticks[/i], and the nearest hostile distance not closing. When that fires,
## the probe writes a full per-soldier dump of the frozen state and keeps running to the
## tick limit, so the report can say whether it ever recovered rather than only that it
## stopped once.
##
## Usage (headless):
## [codeblock]
## godotc --headless --path "<project>" res://scenes/dev/battle_stalemate_probe.tscn -- \
##     --per-side=300 --seed=780780 --ticks=24000 --out="F:/VSC Projects/pb-bench/stalemate"
## [/codeblock]
## Switches: [code]--per-side=[/code], [code]--seed=[/code], [code]--ticks=[/code],
## [code]--sample-every=[/code], [code]--stall-ticks=[/code], [code]--deep-every=[/code],
## [code]--deep-at=[/code], [code]--max-seconds=[/code], [code]--out=[/code],
## [code]--label=[/code], [code]--quiet=[/code], [code]--units=[/code],
## [code]--enemy-units=[/code], [code]--profile=[/code].

## The step the battle is driven with. Matches the showcase and the benchmark so the same
## battle is the same battle.
const TICK := 0.05

var _per_side := 300
var _seed := 780780
var _ticks := 24000
var _sample_every := 50
var _stall_ticks := 600
var _deep_every := 0
var _deep_at: Array[int] = []
var _max_seconds := 5400.0
var _out_dir := "F:/VSC Projects/pb-bench/stalemate"
var _label := "probe"
var _quiet := false
var _unit_type := "spearman"
var _enemy_unit_type := "spearman"
var _profile := false
var _trace_from := 0

var config: GameConfig = null
var catalog: FormationCatalog = null
var units_catalog: UnitCatalog = null
var simulator: BattleSimulator = null
var context: BattleContext = null
var ai_player: BattleAI = null
var ai_enemy: BattleAI = null
var checksum := ""

var _timeline: Array[Dictionary] = []
var _deep_dumps: Array[Dictionary] = []
var _last_sample_positions: Dictionary = {}
var _last_sample_nearest: Dictionary = {}
var _body_aggregate: Dictionary = {}
var _last_anchor: Dictionary = {}
var _contact_prev: Array[bool] = []
var _contact_gained := 0
var _contact_lost := 0
var _contact_events: Array[Dictionary] = []
var _first_contact_tick := -1
var _first_contact_loss_tick := -1
var _first_hit_tick := -1
var _last_hit_tick := -1
var _last_death_tick := -1
var _hits := 0
var _deaths := 0
var _deaths_player := 0
var _deaths_enemy := 0
var _longest_no_hit := 0
var _longest_no_hit_from := -1
var _longest_no_hit_to := -1
var _stall_windows: Array[Dictionary] = []
var _stall_start := -1
var _stall_min_hostile := INF
var _stall_min_hostile_tick := -1
var _dead_hole_stats: Dictionary = {}


func _ready() -> void:
	_parse_args()
	DirAccess.make_dir_recursive_absolute(_out_dir)
	config = GameManager.config()
	catalog = FormationCatalog.load_from()
	units_catalog = UnitCatalog.load_from()
	_run()
	_write_report()
	get_tree().quit(0)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--per-side="):
			_per_side = maxi(2, int(arg.substr(11)))
		elif arg.begins_with("--seed="):
			_seed = int(arg.substr(7))
		elif arg.begins_with("--ticks="):
			_ticks = maxi(1, int(arg.substr(8)))
		elif arg.begins_with("--sample-every="):
			_sample_every = maxi(1, int(arg.substr(15)))
		elif arg.begins_with("--stall-ticks="):
			_stall_ticks = maxi(10, int(arg.substr(14)))
		elif arg.begins_with("--deep-every="):
			_deep_every = maxi(0, int(arg.substr(13)))
		elif arg.begins_with("--deep-at="):
			var list := arg.substr(10).split(",")
			for value in list:
				var parsed := str(value).strip_edges()
				if parsed.is_valid_int():
					_deep_at.append(int(parsed))
		elif arg.begins_with("--max-seconds="):
			_max_seconds = maxf(1.0, float(arg.substr(14)))
		elif arg.begins_with("--out="):
			_out_dir = arg.substr(6)
		elif arg.begins_with("--label="):
			_label = arg.substr(8)
		elif arg.begins_with("--units="):
			_unit_type = arg.substr(8)
		elif arg.begins_with("--enemy-units="):
			_enemy_unit_type = arg.substr(14)
		elif arg.begins_with("--quiet="):
			_quiet = arg.substr(8).to_int() != 0
		elif arg.begins_with("--profile="):
			_profile = arg.substr(10).to_int() != 0
		elif arg.begins_with("--trace-from="):
			_trace_from = maxi(0, int(arg.substr(13)))


## One line per tick, for the last stretch of a battle. Everything the formation's own
## movement rule reads: where the body is, where it has been told to go, how fast it may
## walk there, and what it says about itself. Used to see a suspected equilibrium one tick
## at a time rather than every fiftieth.
func _trace(tick: int) -> void:
	var parts := PackedStringArray()
	for body in simulator.formations:
		parts.append("%s a=(%.9f,%.9f) t=(%.9f,%.9f) d=%.9f arrive=%.6f speed=%.6f move=%s contact=%s" % [
			body.id, body.anchor.x, body.anchor.y, body.target_anchor.x, body.target_anchor.y,
			body.anchor.distance_to(body.target_anchor), body.call("_arrive_radius"),
			simulator.call("_formation_speed", body), str(body.is_moving()), str(body.in_contact)])
	print("t%d %s" % [tick, "  |  ".join(parts)])


## ---------- setup ---------------------------------------------------------

func _run() -> void:
	var built := ShowcaseBattle.build(
		config, units_catalog, catalog, _per_side, _seed,
		_unit_type, _enemy_unit_type, _max_seconds)
	context = built["context"]
	simulator = built["simulator"]
	checksum = ShowcaseBattle.setup_checksum(simulator.units)
	ai_player = BattleAI.create(config, BattleContext.SIDE_PLAYER)
	ai_enemy = BattleAI.create(config, BattleContext.SIDE_ENEMY)

	print("probe: %s  %d v %d deployed, %d bodies, seed %d, battle clock %.0fs, setup %s" % [
		_label, simulator.side_count(BattleContext.SIDE_PLAYER),
		simulator.side_count(BattleContext.SIDE_ENEMY), simulator.formations.size(),
		_seed, simulator.max_duration, checksum])

	simulator.reset_profile()
	simulator.profile_enabled = _profile
	simulator.start()

	for body in simulator.formations:
		_contact_prev.append(body.in_contact)

	var start_usec := Time.get_ticks_usec()
	var tick := 0
	while tick < _ticks:
		if simulator.is_finished():
			break
		ai_player.update(simulator, TICK)
		ai_enemy.update(simulator, TICK)
		var events := simulator.step(TICK)
		_consume(events)
		_contact_scan()
		tick = simulator.tick_index
		if tick % _sample_every == 0:
			_sample(tick)
			# The stall test costs an exhaustive nearest-enemy pass, so it runs on the
			# sampling cadence rather than every tick. At fifty-tick samples that is a
			# detection resolution of two and a half seconds of battle time, which is
			# finer than any stalemate this milestone is about.
			_check_stall(tick)
		if _trace_from > 0 and tick >= _trace_from:
			_trace(tick)
		if _deep_every > 0 and tick % _deep_every == 0 and tick > 0:
			_deep_dump(tick, "periodic")
		if _deep_at.has(tick):
			_deep_dump(tick, "requested")
		if tick % 2000 == 0:
			if not _quiet:
				print("  tick %6d  battle %7.1fs  wall %6.1fs  alive %d v %d  last hit %d  %s" % [
					tick, simulator.elapsed,
					float(Time.get_ticks_usec() - start_usec) / 1000000.0,
					simulator.side_count(BattleContext.SIDE_PLAYER),
					simulator.side_count(BattleContext.SIDE_ENEMY),
					_last_hit_tick, _body_state_line()])

	var wall := float(Time.get_ticks_usec() - start_usec) / 1000000.0
	print("probe: finished at tick %d (%.1fs battle, %.1fs wall), %d hits, %d deaths, winner '%s'" % [
		simulator.tick_index, simulator.elapsed, wall, _hits, _deaths, simulator.winner])
	print("probe: longest no-hit window while both sides lived: %d ticks (from %d to %d); stall windows: %d" % [
		_longest_no_hit, _longest_no_hit_from, _longest_no_hit_to, _stall_windows.size()])
	print("probe: report -> %s/stalemate_%s.txt" % [_out_dir, _label])


func _consume(events: Array[Dictionary]) -> void:
	for event in events:
		var kind := str(event.get("type", ""))
		if kind == "hit":
			_hits += 1
			_last_hit_tick = simulator.tick_index
			if _first_hit_tick < 0:
				_first_hit_tick = simulator.tick_index
			# A stall ends the moment somebody is struck: the window is closed here
			# rather than sampled, so its length is exact.
			_close_stall(simulator.tick_index)
		elif kind == "death":
			_deaths += 1
			_last_death_tick = simulator.tick_index
			if str(event.get("side", "")) == BattleContext.SIDE_PLAYER:
				_deaths_player += 1
			else:
				_deaths_enemy += 1


## Contact, per body, every tick. The transitions are the interesting part: a body that
## gained contact is a body that started fighting, and one that lost it is the case this
## milestone exists for.
func _contact_scan() -> void:
	var both_alive := simulator.side_count(BattleContext.SIDE_PLAYER) > 0 \
		and simulator.side_count(BattleContext.SIDE_ENEMY) > 0
	for i in simulator.formations.size():
		var body := simulator.formations[i]
		var now := body.in_contact
		if i >= _contact_prev.size():
			_contact_prev.append(now)
			continue
		var before := _contact_prev[i]
		if now != before:
			if now:
				_contact_gained += 1
				if _first_contact_tick < 0:
					_first_contact_tick = simulator.tick_index
			else:
				_contact_lost += 1
				if _first_contact_loss_tick < 0:
					_first_contact_loss_tick = simulator.tick_index
			if both_alive:
				_contact_events.append({
					"tick": simulator.tick_index,
					"body": body.id,
					"gained": now,
				})
		_contact_prev[i] = now
	# A body that has never been in contact: the hit tick is the honest fallback for the
	# moment the two armies met.
	if _first_contact_tick < 0 and _first_hit_tick >= 0:
		_first_contact_tick = _first_hit_tick


## ---------- sampling ------------------------------------------------------

func _sample(tick: int) -> void:
	var reach := _reach_profile()
	var row := {
		"tick": tick,
		"elapsed": simulator.elapsed,
		"living_player": simulator.side_count(BattleContext.SIDE_PLAYER),
		"living_enemy": simulator.side_count(BattleContext.SIDE_ENEMY),
		"last_hit_tick": _last_hit_tick,
		"last_death_tick": _last_death_tick,
		"since_last_hit": tick - _last_hit_tick if _last_hit_tick >= 0 else tick,
		"in_reach": reach["in_reach"],
		"nearest_average": reach["nearest_average"],
		"nearest_max": reach["nearest_max"],
		"nearest_beyond_scan": reach["beyond"],
		"press_forward_allowed": reach["press_allowed"],
		"press_blocked_order": reach["press_blocked_order"],
		"press_blocked_moving": reach["press_blocked_moving"],
		"press_blocked_turning": reach["press_blocked_turning"],
		"press_blocked_reforming": reach["press_blocked_reforming"],
		"press_blocked_contact": reach["press_blocked_contact"],
		"press_blocked_unformed": reach["press_blocked_unformed"],
		"moving_toward_enemy": reach["closing"],
		"dressing": reach["dressing"],
		"bodies": _body_rows(),
	}
	_timeline.append(row)
	# Bookkeeping for the longest quiet stretch while both sides were alive.
	if _last_hit_tick >= 0:
		var quiet := tick - _last_hit_tick
		if quiet > _longest_no_hit:
			_longest_no_hit = quiet
			_longest_no_hit_from = _last_hit_tick
			_longest_no_hit_to = tick


## Every living soldier's nearest living enemy, and what it is doing about it.
##
## The nearest-enemy scan is exhaustive rather than bucketed. At six hundred soldiers that
## is one hundred and eighty thousand distances, twice a second of battle time, which is
## affordable; a bucketed answer would have to say "no enemy within the scan" exactly where
## this milestone needs an exact number - how far the nearest hostile actually is when
## nobody can reach anybody.
func _reach_profile() -> Dictionary:
	var living: Array[BattleUnit] = []
	for unit in simulator.units:
		if unit.is_alive():
			living.append(unit)

	var in_reach := 0
	var press_allowed := 0
	var blocked_order := 0
	var blocked_moving := 0
	var blocked_turning := 0
	var blocked_reforming := 0
	var blocked_contact := 0
	var blocked_unformed := 0
	var closing := 0
	var dressing := 0
	var beyond := 0
	var total := 0.0
	var worst := 0.0
	var counted := 0
	var nearest_now := {}
	var per_body := {}
	for unit in living:
		var nearest: BattleUnit = null
		var nearest_distance := INF
		for other in living:
			if other.side == unit.side:
				continue
			var distance := unit.position.distance_squared_to(other.position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = other
		if nearest == null:
			beyond += 1
			continue
		var metres := unit.position.distance_to(nearest.position)
		counted += 1
		total += metres
		worst = maxf(worst, metres)
		if metres <= unit.attack_range:
			in_reach += 1
		nearest_now[unit.id] = metres
		var previous: Variant = _last_sample_nearest.get(unit.id)
		if previous != null and metres < float(previous) - 0.005:
			closing += 1
		var body := unit.formation_ref
		var key := body.id if body != null else ""
		var row: Dictionary = per_body.get(key, {
			"living": 0, "in_reach": 0, "press_allowed": 0, "nearest": INF,
			"slot_total": 0.0, "slot_worst": 0.0, "dressing": 0, "closing": 0,
		})
		row["living"] = int(row["living"]) + 1
		if metres <= unit.attack_range:
			row["in_reach"] = int(row["in_reach"]) + 1
		row["nearest"] = minf(float(row["nearest"]), metres)
		if previous != null and metres < float(previous) - 0.005:
			row["closing"] = int(row["closing"]) + 1
		if unit.is_formed():
			var place := unit.formation_slot()
			var error := unit.position.distance_to(place)
			row["slot_total"] = float(row["slot_total"]) + error
			row["slot_worst"] = maxf(float(row["slot_worst"]), error)
			if error > 0.15:
				row["dressing"] = int(row["dressing"]) + 1
				dressing += 1
			if bool(simulator.call("_can_press_forward", unit, body)):
				press_allowed += 1
				row["press_allowed"] = int(row["press_allowed"]) + 1
			else:
				if body == null or unit.slot_index < 0:
					blocked_unformed += 1
				elif body.order != BattleFormation.ORDER_ENGAGE:
					blocked_order += 1
				elif body.is_moving():
					blocked_moving += 1
				elif body.is_turning():
					blocked_turning += 1
				elif body.is_reforming():
					blocked_reforming += 1
				elif body.in_contact:
					blocked_contact += 1
				else:
					blocked_unformed += 1
		else:
			blocked_unformed += 1
		per_body[key] = row
	_last_sample_nearest = nearest_now
	_body_aggregate = per_body
	return {
		"in_reach": in_reach,
		"nearest_average": 0.0 if counted == 0 else total / float(counted),
		"nearest_max": worst,
		"beyond": beyond,
		"press_allowed": press_allowed,
		"press_blocked_order": blocked_order,
		"press_blocked_moving": blocked_moving,
		"press_blocked_turning": blocked_turning,
		"press_blocked_reforming": blocked_reforming,
		"press_blocked_contact": blocked_contact,
		"press_blocked_unformed": blocked_unformed,
		"closing": closing,
		"dressing": dressing,
		"counted": counted,
	}


## Per-body rows for the current tick, aggregated from the same pass that measured the
## soldiers, so a body's row and the army-wide row can never disagree.
func _body_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for body in simulator.formations:
		var stats: Dictionary = _body_aggregate.get(body.id, {})
		var living := int(stats.get("living", 0))
		var target := _nearest_enemy_body(body)
		var terrain_mult := 1.0
		if simulator.terrain != null:
			terrain_mult = simulator.terrain.move_multiplier_at(body.anchor)
		var previous_anchor: Variant = _last_anchor.get(body.id)
		var anchor_moved := -1.0
		if previous_anchor != null:
			anchor_moved = (previous_anchor as Vector2).distance_to(body.anchor)
		_last_anchor[body.id] = body.anchor
		rows.append({
			"id": body.id,
			"side": body.side,
			"order": body.order,
			"state": body.state_name(),
			"in_contact": body.in_contact,
			"moving": body.is_moving(),
			"turning": body.is_turning(),
			"reforming": body.is_reforming(),
			"cohesion": body.cohesion,
			"living": living,
			"size": body.size(),
			"anchor": [body.anchor.x, body.anchor.y],
			"steering_to": [body.target_anchor.x, body.target_anchor.y],
			"anchor_to_steer": body.anchor.distance_to(body.target_anchor),
			"arrive_radius": float(body.call("_arrive_radius")),
			"formation_speed": float(simulator.call("_formation_speed", body)),
			"terrain_multiplier": terrain_mult,
			"anchor_moved_since_sample": anchor_moved,
			"anchor_to_enemy_anchor": body.anchor.distance_to(target.anchor) if target != null else -1.0,
			"enemy_body": target.id if target != null else "",
			"nearest_member_to_enemy": -1.0 if living == 0 else float(stats.get("nearest", -1.0)),
			"members_in_reach": int(stats.get("in_reach", 0)),
			"press_allowed": int(stats.get("press_allowed", 0)),
			"members_closing": int(stats.get("closing", 0)),
			"slot_error_average": 0.0 if living == 0 else float(stats.get("slot_total", 0.0)) / float(living),
			"slot_error_worst": float(stats.get("slot_worst", 0.0)),
		})
	return rows


## The nearest living enemy to a point, exhaustively. Used by the per-body rows, where a
## handful of extra walks per sample costs nothing and an exact answer is worth having.
func _nearest_enemy_to(unit: BattleUnit) -> BattleUnit:
	var best: BattleUnit = null
	var best_distance := INF
	var enemy_side := simulator.enemy_side_of(unit.side)
	for other in simulator.units:
		if not other.is_alive() or other.side != enemy_side:
			continue
		var distance := unit.position.distance_squared_to(other.position)
		if distance < best_distance:
			best_distance = distance
			best = other
	return best


## The hostile body this one is steering at, by the same rule the simulator uses - nearest
## by anchor, skipping bodies with nobody left standing.
func _nearest_enemy_body(body: BattleFormation) -> BattleFormation:
	var best: BattleFormation = null
	var best_distance := INF
	var units_by_id := simulator.units_by_id()
	for other in simulator.formations:
		if other.side == body.side or not other.has_living_units(units_by_id):
			continue
		var distance := body.anchor.distance_squared_to(other.anchor)
		if distance < best_distance:
			best_distance = distance
			best = other
	return best


func _body_state_line() -> String:
	var parts := PackedStringArray()
	for body in simulator.formations:
		parts.append("%s:%s%s coh %.2f" % [
			body.id, body.state_name(), "*" if body.in_contact else "", body.cohesion])
	return "  ".join(parts)


## ---------- stalemate detection -------------------------------------------

## A stall is a claim about the fighting, not about the clock: both sides alive, no hit for
## [member _stall_ticks] simulation ticks, and nobody in reach of anybody. The tick
## threshold is a parameter so the same probe can describe a small battle (where a few
## hundred ticks of quiet is normal) and a three-hundred-a-side one.
func _check_stall(tick: int) -> void:
	var living_player := simulator.side_count(BattleContext.SIDE_PLAYER)
	var living_enemy := simulator.side_count(BattleContext.SIDE_ENEMY)
	if living_player == 0 or living_enemy == 0:
		return
	if _last_hit_tick < 0:
		return
	var quiet := tick - _last_hit_tick
	if quiet < _stall_ticks:
		return
	var reach := _reach_profile()
	if int(reach["in_reach"]) > 0:
		return
	# Nearest hostile distance, army-wide, at the moment the stall was noticed.
	var nearest := INF
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var other := _nearest_enemy_to(unit)
		if other != null:
			nearest = minf(nearest, unit.position.distance_to(other.position))
	if _stall_start < 0:
		_stall_start = tick
		_stall_min_hostile = nearest
		_stall_min_hostile_tick = tick
		print("  STALEMATE: tick %d (%.1fs battle), %d of %d in reach, nearest hostile %.2f units, no hit for %d ticks" % [
			tick, simulator.elapsed, int(reach["in_reach"]), int(reach["counted"]), nearest, quiet])
		_deep_dump(tick, "stalemate")
	else:
		if nearest < _stall_min_hostile:
			_stall_min_hostile = nearest
			_stall_min_hostile_tick = tick


func _close_stall(tick: int) -> void:
	if _stall_start < 0:
		return
	_stall_windows.append({
		"from": _stall_start,
		"to": tick,
		"ticks": tick - _stall_start,
		"min_hostile": _stall_min_hostile,
		"min_hostile_tick": _stall_min_hostile_tick,
		"battle_seconds": float(tick - _stall_start) * TICK,
	})
	_stall_start = -1
	_stall_min_hostile = INF


## ---------- deep dump -----------------------------------------------------

## Everything, per soldier, at one tick. This is the profile of the failure state rather
## than a summary of it: where every survivor stands, where it was told to stand, what it
## is pointed at, and whether it could reach it.
func _deep_dump(tick: int, reason: String) -> void:
	var living_player := simulator.side_count(BattleContext.SIDE_PLAYER)
	var living_enemy := simulator.side_count(BattleContext.SIDE_ENEMY)
	var soldiers: Array[Dictionary] = []
	var in_reach := 0
	var no_slot := 0
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var nearest := _nearest_enemy_to(unit)
		var nearest_distance := -1.0
		if nearest != null:
			nearest_distance = unit.position.distance_to(nearest.position)
			if nearest_distance <= unit.attack_range:
				in_reach += 1
		var row := {
			"id": unit.id,
			"side": unit.side,
			"body": unit.formation_ref.id if unit.formation_ref != null else "",
			"slot": unit.slot_index,
			"position": [unit.position.x, unit.position.y],
			"nearest_enemy_distance": nearest_distance,
			"reach": unit.attack_range,
			"target_id": unit.auto_target_id,
			"order_target_id": unit.attack_order_target_id,
			"next_search_tick": unit.next_search_tick,
		}
		if unit.is_formed():
			var place := unit.formation_slot()
			row["slot_position"] = [place.x, place.y]
			row["slot_error"] = unit.position.distance_to(place)
		else:
			no_slot += 1
		soldiers.append(row)

	var target_rows: Array[Dictionary] = []
	var targets_valid := 0
	var targets_dead := 0
	var targets_missing := 0
	var targets_far := 0
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		if unit.auto_target_id < 0:
			continue
		var other := simulator.find_unit(unit.auto_target_id)
		if other == null:
			targets_missing += 1
			continue
		if not other.is_alive():
			targets_dead += 1
			continue
		targets_valid += 1
		if unit.position.distance_to(other.position) > unit.attack_range:
			targets_far += 1
		if target_rows.size() < 40:
			target_rows.append({
				"id": unit.id,
				"body": unit.formation_ref.id if unit.formation_ref != null else "",
				"target": other.id,
				"distance": unit.position.distance_to(other.position),
				"reach": unit.attack_range,
			})

	var dump := {
		"tick": tick,
		"reason": reason,
		"elapsed": simulator.elapsed,
		"living_player": living_player,
		"living_enemy": living_enemy,
		"in_reach": in_reach,
		"unformed": no_slot,
		"targets_valid": targets_valid,
		"targets_dead": targets_dead,
		"targets_missing": targets_missing,
		"targets_out_of_reach": targets_far,
		"bodies": _body_rows(),
		"soldiers": soldiers,
		"sample_targets": target_rows,
	}
	_deep_dumps.append(dump)
	print("  deep dump at tick %d (%s): %d v %d living, %d in reach, targets valid %d / dead %d / far %d" % [
		tick, reason, living_player, living_enemy, in_reach, targets_valid, targets_dead, targets_far])


## ---------- report --------------------------------------------------------

func _write_report() -> void:
	_close_stall(simulator.tick_index)
	var report := _build_report()
	var json := JSON.stringify(report, "  ")
	var text := _report_text(report)
	var json_path := "%s/stalemate_%s.json" % [_out_dir, _label]
	var text_path := "%s/stalemate_%s.txt" % [_out_dir, _label]
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if file != null:
		file.store_string(json)
		file.close()
	var text_file := FileAccess.open(text_path, FileAccess.WRITE)
	if text_file != null:
		text_file.store_string(text)
		text_file.close()
	print(text)


func _build_report() -> Dictionary:
	var out := {
		"label": _label,
		"seed": _seed,
		"per_side": _per_side,
		"unit_type": _unit_type,
		"enemy_unit_type": _enemy_unit_type,
		"setup_checksum": checksum,
		"tick_step": TICK,
		"battle_clock_limit": simulator.max_duration,
		"stall_threshold_ticks": _stall_ticks,
		"ticks": simulator.tick_index,
		"battle_seconds": simulator.elapsed,
		"resolved": simulator.is_finished(),
		"winner": simulator.winner,
		"hits": _hits,
		"deaths": _deaths,
		"deaths_player": _deaths_player,
		"deaths_enemy": _deaths_enemy,
		"living_player": simulator.side_count(BattleContext.SIDE_PLAYER),
		"living_enemy": simulator.side_count(BattleContext.SIDE_ENEMY),
		"first_hit_tick": _first_hit_tick,
		"first_contact_tick": _first_contact_tick,
		"first_contact_loss_tick": _first_contact_loss_tick,
		"last_hit_tick": _last_hit_tick,
		"last_death_tick": _last_death_tick,
		"contact_gained": _contact_gained,
		"contact_lost": _contact_lost,
		"longest_no_hit_ticks": _longest_no_hit,
		"longest_no_hit_from": _longest_no_hit_from,
		"longest_no_hit_to": _longest_no_hit_to,
		"stall_windows": _stall_windows,
		"stalled_at_end": _stall_start >= 0,
		"contact_events": _contact_events,
		"timeline": _timeline,
		"deep_dumps": _deep_dumps,
	}
	if _profile:
		out["profile"] = simulator.profile.duplicate()
		out["target_report"] = simulator.target_report()
		out["focus_report"] = simulator.focus_report()
		out["backend_report"] = simulator.backend_report()
		out["overlap_backend_report"] = simulator.overlap_backend_report()
	return out


func _report_text(report: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("PROJECT BANNER - LARGE-BATTLE STALEMATE PROBE (%s)" % _label)
	lines.append("seed %d   %d v %d   units %s/%s   step %.3fs   battle clock %.0fs   setup %s" % [
		int(report["seed"]), int(report["per_side"]), int(report["per_side"]),
		_unit_type, _enemy_unit_type, float(report["tick_step"]),
		float(report["battle_clock_limit"]), checksum])
	lines.append("")
	lines.append("outcome: %s   winner '%s'   %d sim ticks (%.1fs battle)" % [
		"resolved" if bool(report["resolved"]) else "UNRESOLVED",
		str(report["winner"]), int(report["ticks"]), float(report["battle_seconds"])])
	lines.append("casualties: %d hits, %d dead (player %d, enemy %d); %d v %d standing" % [
		int(report["hits"]), int(report["deaths"]), int(report["deaths_player"]),
		int(report["deaths_enemy"]), int(report["living_player"]), int(report["living_enemy"])])
	lines.append("contact: first contact tick %d, first loss tick %d, gains %d, losses %d" % [
		int(report["first_contact_tick"]), int(report["first_contact_loss_tick"]),
		int(report["contact_gained"]), int(report["contact_lost"])])
	lines.append("quiet: last hit tick %d, last death tick %d, longest no-hit window %d ticks (%d -> %d)" % [
		int(report["last_hit_tick"]), int(report["last_death_tick"]),
		int(report["longest_no_hit_ticks"]), int(report["longest_no_hit_from"]),
		int(report["longest_no_hit_to"])])
	lines.append("stall windows: %d%s" % [
		_stall_windows.size(), "  (STALLED AT END)" if bool(report["stalled_at_end"]) else ""])
	for window in _stall_windows:
		lines.append("  from tick %d to %d (%d ticks, %.1fs), nearest hostile %.2f units at tick %d" % [
			int(window["from"]), int(window["to"]), int(window["ticks"]),
			float(window["battle_seconds"]), float(window["min_hostile"]),
			int(window["min_hostile_tick"])])
	lines.append("")
	lines.append("TIMELINE (every %d ticks)" % _sample_every)
	lines.append("     tick   battle     alive   since  in-reach  nearest avg/max  press  closing  dressing")
	for row in _timeline:
		lines.append("  %7d  %6.1fs  %3d v %3d  %6d  %6d  %8.2f/%7.2f  %5d  %7d  %8d" % [
			int(row["tick"]), float(row["elapsed"]), int(row["living_player"]),
			int(row["living_enemy"]), int(row["since_last_hit"]), int(row["in_reach"]),
			float(row["nearest_average"]), float(row["nearest_max"]),
			int(row["press_forward_allowed"]), int(row["moving_toward_enemy"]),
			int(row["dressing"])])
	lines.append("")
	for dump in _deep_dumps:
		lines.append("DEEP DUMP at tick %d (%s): %d v %d living" % [
			int(dump["tick"]), str(dump["reason"]), int(dump["living_player"]),
			int(dump["living_enemy"])])
		lines.append("  in reach %d   unformed %d   targets: valid %d, dead %d, missing %d, out of reach %d" % [
			int(dump["in_reach"]), int(dump["unformed"]), int(dump["targets_valid"]),
			int(dump["targets_dead"]), int(dump["targets_missing"]),
			int(dump["targets_out_of_reach"])])
		for body in dump["bodies"]:
			lines.append("  %-16s %-9s%s %3d/%3d up  coh %3.0f%%  anchor->enemy %.1f  nearest member->enemy %.2f  in reach %3d  press %3d  slot err avg %.2f worst %.2f" % [
				str(body["id"]), str(body["state"]), "*" if bool(body["in_contact"]) else " ",
				int(body["living"]), int(body["size"]), float(body["cohesion"]) * 100.0,
				float(body["anchor_to_enemy_anchor"]), float(body["nearest_member_to_enemy"]),
				int(body["members_in_reach"]), int(body["press_allowed"]),
				float(body["slot_error_average"]), float(body["slot_error_worst"])])
		lines.append("")
		if dump["soldiers"].size() <= 400:
			lines.append("  SOLDIERS (id, side, body, slot, position, nearest enemy, slot error)")
			for row in dump["soldiers"]:
				lines.append("    %4d %-6s %-18s slot %3d  (%.1f, %.1f)  nearest %6.2f  reach %.1f  target %d" % [
					int(row["id"]), str(row["side"]), str(row["body"]), int(row["slot"]),
					float(row["position"][0]), float(row["position"][1]),
					float(row["nearest_enemy_distance"]), float(row["reach"]),
					int(row["target_id"])])
		lines.append("")
	return "\n".join(lines)
