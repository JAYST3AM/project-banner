class_name RoadNetwork
extends RefCounted
## The roads as a living thing: a tier per link, traffic that wears them in, and time that wears
## them down.
##
## A link between two settlements carries a tier - none, dirt, track, road - stored in the same
## "kind" field the drawing and the priced grid already read, so every reader sees one number and
## every save from before this system loads as roads. The world opens with real roads between the
## elder towns; a settlement founded later links itself to its nearest neighbour as a dirt road,
## good for very little, and becomes more only when traffic - whoever walks it - wears it in.
## Neglect falls one tier per long span of game years, all the way back to roadless, which the
## owner expects will almost never happen: "roadless, it takes years though, so I doubt it will
## ever happen."
##
## The network owns the traffic ledger and the tier ladder; it does not own the grid. When a tier
## changes, the map re-prices the ground (see world_map._rebuild_costs) - an event, not a per-frame
## cost.

const CATEGORY := "Roads"

var state: CampaignState
var config: GameConfig

## The curve of each link, cached: endpoints never move, so a link's shape is constant even as its
## tier changes. Indexed exactly like [member CampaignState.roads].
var _paths: Array[PackedVector2Array] = []
## The stretch of walking not yet attributed to a link, held until a scan window fills.
var _window_open := false
var _window_from := Vector2.ZERO
var _window_distance := 0.0
var _window_hours := 0.0
## When the last upgrade/decay review ran, in total game hours. Negative means never.
var _last_review_hours := -1.0


func _init(p_state: CampaignState, p_config: GameConfig) -> void:
	state = p_state
	config = p_config
	normalize()


## The ladder, roadless to best. From the config, so a save and a session cannot disagree on the
## order a tier sits in.
func tiers() -> Array:
	var listed := config.get_array("roads.tiers", []) if config != null else []
	if listed.is_empty():
		return ["none", "dirt", "track", "road"]
	return listed


## What a tier is worth to the pace. The old single road bonus stays as the fallback for the top
## tier, so a config from before this system still builds the road it always did.
func bonus_of(tier: String) -> float:
	var fallback := 1.0
	if tier == "road" and config != null:
		fallback = config.get_float("travel.road_speed_bonus", 1.4)
	if config == null:
		return fallback
	return maxf(1.0, config.get_float("roads.speed_bonus." + tier, fallback))


## Bring every link up to the shape this system stores: a known tier, a traffic figure, and a
## last-used stamp. A link from an old save has no stamp - reading that as year zero would decay
## the whole network the moment it loads, so "never used" is stamped now and ages from here.
func normalize() -> void:
	if state == null:
		return
	var ladder := tiers()
	var now := 0.0
	if state.clock != null:
		now = state.clock.total_hours()
	for raw in state.roads:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var link := raw as Dictionary
		var tier := str(link.get("kind", "road"))
		if not ladder.has(tier):
			link["kind"] = "road"
		link["traffic"] = maxf(0.0, float(link.get("traffic", 0.0)))
		if float(link.get("used_hours", -1.0)) < 0.0:
			link["used_hours"] = now
	refresh_paths()


## Re-derive the cached curves from the links. Only for links added or replaced after the network
## was built - the curve of an existing link never changes.
func refresh_paths() -> void:
	_paths.clear()
	if state == null:
		return
	for raw in state.roads:
		if typeof(raw) != TYPE_DICTIONARY:
			_paths.append(PackedVector2Array())
			continue
		var link := raw as Dictionary
		var a := state.settlement(str(link.get("a", "")))
		var b := state.settlement(str(link.get("b", "")))
		if a == null or b == null:
			_paths.append(PackedVector2Array())
			continue
		_paths.append(RoadPath.between(a.position, b.position))


## A settlement founded into the world links itself to its nearest neighbour as a dirt road:
## reachable at once, good for very little, and only a real road once people walk it. Returns the
## link, or {} when there is nobody to link to. This is the road side of settlements being built
## by the world later.
func connect_settlement(settlement: Settlement) -> Dictionary:
	if state == null or settlement == null:
		return {}
	var nearest: Settlement = null
	var best := INF
	for raw in state.settlements.values():
		var other := raw as Settlement
		if other == null or other.id == settlement.id:
			continue
		var span := settlement.position.distance_to(other.position)
		if span < best:
			best = span
			nearest = other
	if nearest == null:
		return {}
	var now := 0.0
	if state.clock != null:
		now = state.clock.total_hours()
	var link := {
		"a": settlement.id,
		"b": nearest.id,
		"kind": "dirt",
		"traffic": 0.0,
		"used_hours": now,
	}
	state.roads.append(link)
	_paths.append(RoadPath.between(settlement.position, nearest.position))
	DebugLogger.info("%s is founded, linked to %s by a dirt road" % [
		settlement.name, nearest.name,
	], CATEGORY)
	return link


## Where the party's walking is handed over. The network holds the stretch until a scan window of
## game hours has filled, then attributes every unit walked in it to the link nearest the window's
## path - the road the walker was actually on. "Traffic" counts world units walked.
func charge_move(from_point: Vector2, to_point: Vector2, distance: float, game_hours: float) -> void:
	if state == null or distance <= 0.0:
		return
	if not _window_open:
		_window_open = true
		_window_from = from_point
	_window_distance += distance
	_window_hours += game_hours
	if _window_hours >= _scan_hours():
		_flush_window(to_point)


func _flush_window(to_point: Vector2) -> void:
	var probes: Array[Vector2] = [_window_from, _window_from.lerp(to_point, 0.5), to_point]
	var matched: Array[int] = []
	for probe in probes:
		var index := _nearest_link(probe)
		if index >= 0 and not matched.has(index):
			matched.append(index)
	var now := 0.0
	if state.clock != null:
		now = state.clock.total_hours()
	for index in matched:
		var link: Dictionary = state.roads[index]
		link["traffic"] = float(link.get("traffic", 0.0)) + _window_distance
		link["used_hours"] = now
	_window_open = false
	_window_hours = 0.0
	_window_distance = 0.0


## The link nearest a point, or -1 when none lies within [param within] (a negative value means
## anywhere). The wear scan, the travel log and the probes all read the same curves the map draws.
func nearest_link(point: Vector2, within := -1.0) -> int:
	var limit := INF if within < 0.0 else within
	var best := limit
	var found := -1
	for i in _paths.size():
		var distance := _distance_to_path(_paths[i], point)
		if distance < best:
			best = distance
			found = i
	return found


## The wear scan's own question: the nearest link, but only inside the traffic radius - the width
## within which walking counts as using the road.
func _nearest_link(point: Vector2) -> int:
	return nearest_link(point, _traffic_radius())


## Whether a point lies on some link's road, by the same radius the wear scan uses.
func on_road(point: Vector2) -> bool:
	return _nearest_link(point) >= 0


## A link's name for the log: both ends, as a sentence reads them. Empty when the index names
## nothing.
func link_label(index: int) -> String:
	if state == null or index < 0 or index >= state.roads.size():
		return ""
	var raw: Variant = state.roads[index]
	if typeof(raw) != TYPE_DICTIONARY:
		return ""
	var link := raw as Dictionary
	var a := state.settlement(str(link.get("a", "")))
	var b := state.settlement(str(link.get("b", "")))
	var left := a.name if a != null else str(link.get("a", ""))
	var right := b.name if b != null else str(link.get("b", ""))
	return "%s to %s" % [left, right]


## How far the nearest link's curve runs from a point; INF when there are none. Public because
## suites and probes ask the same question the wear scan does.
func distance_to_nearest_link(point: Vector2) -> float:
	var best := INF
	for path in _paths:
		best = minf(best, _distance_to_path(path, point))
	return best


func _distance_to_path(path: PackedVector2Array, point: Vector2) -> float:
	var best := INF
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		var span := b - a
		var length_squared := span.length_squared()
		var t := 0.0
		if length_squared > 0.0001:
			t = clampf((point - a).dot(span) / length_squared, 0.0, 1.0)
		best = minf(best, point.distance_to(a + span * t))
	return best


## The world's slow clock on the network, run once a frame by the map. Throttled to a review every
## review_hours of game time; returns true when a link changed tier, which is the map's cue to
## re-price the ground and repaint. Upgrades come from traffic, decay from idle game years, and a
## roadless link can be worn back into a dirt path by traffic again.
func review(total_hours: float) -> bool:
	if state == null:
		return false
	if _last_review_hours >= 0.0 and total_hours - _last_review_hours < _review_hours():
		return false
	_last_review_hours = total_hours
	var ladder := tiers()
	var changed := false
	for raw in state.roads:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var link := raw as Dictionary
		var tier := str(link.get("kind", "road"))
		var rung := ladder.find(tier)
		if rung < 0:
			continue
		var traffic := float(link.get("traffic", 0.0))
		var threshold := _upgrade_threshold(tier)
		if threshold > 0.0 and traffic >= threshold and rung < ladder.size() - 1:
			# Worn enough to rise. The spill carries, so a very busy link keeps its momentum.
			link["kind"] = str(ladder[rung + 1])
			link["traffic"] = traffic - threshold
			changed = true
			DebugLogger.info("road %s-%s wears up to %s" % [
				str(link.get("a", "")), str(link.get("b", "")), str(ladder[rung + 1]),
			], CATEGORY)
			continue
		if tier == "none":
			continue
		var idle_days := (total_hours - float(link.get("used_hours", total_hours))) / 24.0
		if idle_days >= _decay_days():
			link["kind"] = str(ladder[rung - 1])
			link["used_hours"] = total_hours
			changed = true
			DebugLogger.info("road %s-%s falls to %s after %.0f idle days" % [
				str(link.get("a", "")), str(link.get("b", "")), str(ladder[rung - 1]), idle_days,
			], CATEGORY)
	return changed


func _scan_hours() -> float:
	return maxf(0.01, config.get_float("roads.traffic_scan_hours", 0.1))


func _review_hours() -> float:
	return maxf(0.01, config.get_float("roads.review_hours", 6.0))


func _decay_days() -> float:
	return maxf(1.0, config.get_float("roads.decay_days_per_tier", 3650.0))


func _traffic_radius() -> float:
	var fallback := config.get_float("travel.road_width", 26.0)
	return maxf(1.0, config.get_float("roads.traffic_radius", fallback))


func _upgrade_threshold(tier: String) -> float:
	return maxf(0.0, config.get_float("roads.upgrade_traffic." + tier, 0.0))
