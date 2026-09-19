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
## Where each link's curve crosses water, [start, end] index pairs per link - the bridges the map
## draws and the walk crosses by.
var _spans: Array = []
## The links the last [method review] changed tier, so the map can re-price just their ground
## instead of rebuilding the whole grid (D-129). Cleared when a review starts.
var changed_links: Array[int] = []
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
	_spans.clear()
	if state == null:
		return
	var terrain := _terrain()
	var water_height := _water_height()
	var bridge_max := _bridge_max_span()
	for raw in state.roads:
		if typeof(raw) != TYPE_DICTIONARY:
			_paths.append(PackedVector2Array())
			_spans.append([])
			continue
		var link := raw as Dictionary
		var a := state.settlement(str(link.get("a", "")))
		var b := state.settlement(str(link.get("b", "")))
		if a == null or b == null:
			_paths.append(PackedVector2Array())
			_spans.append([])
			continue
		var path := RoadPath.between(a.position, b.position, terrain, water_height, bridge_max)
		_paths.append(path)
		_spans.append(RoadPath.water_spans(path, terrain, water_height))
	_log_bridges()


## One line of the road waters at load: how many links cross a river by bridge and the widest such
## crossing - the owner's first road rule, visible in a run without a debugger.
func _log_bridges() -> void:
	var bridged := 0
	var longest := 0.0
	for i in _spans.size():
		var spans: Array = _spans[i]
		if spans.is_empty():
			continue
		bridged += 1
		var path: PackedVector2Array = _paths[i]
		for span in spans:
			longest = maxf(longest, _span_length(path, int(span.x), int(span.y)))
	if bridged > 0:
		DebugLogger.info("roads: %d of %d links cross water by bridge (widest %d u)" % [
			bridged, _paths.size(), int(round(longest)),
		], CATEGORY)


static func _span_length(path: PackedVector2Array, from: int, to: int) -> float:
	var length := 0.0
	for i in range(from + 1, mini(to + 1, path.size())):
		length += path[i - 1].distance_to(path[i])
	return length


## The terrain the roads are shaped against. Built from the campaign seed and shared with every
## other reader of the same field; a test may set it to a stand-in before refreshing the paths.
var world: Object = null


func _terrain() -> Object:
	if world == null and state != null:
		world = WorldChunks.build(state.campaign_seed)
	return world


func _water_height() -> float:
	if config == null:
		return RoadPath.WATER_HEIGHT
	return config.get_float("travel.water_height", RoadPath.WATER_HEIGHT)


func _bridge_max_span() -> float:
	if config == null:
		return RoadPath.BRIDGE_MAX_SPAN
	return config.get_float("roads.bridge_max_span", RoadPath.BRIDGE_MAX_SPAN)


## Where a link's curve crosses water, as [start, end] index pairs - what the map draws as a bridge.
func bridge_spans(index: int) -> Array:
	if index < 0 or index >= _spans.size():
		return []
	return _spans[index]


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
	var path := RoadPath.between(settlement.position, nearest.position, _terrain(), _water_height(), _bridge_max_span())
	_paths.append(path)
	_spans.append(RoadPath.water_spans(path, _terrain(), _water_height()))
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


## Whether a point lies on some link's road, in the sense the pace counts it: within the drawn
## line's own width, so the on/off log narrates the flip the player can see.
func on_road(point: Vector2) -> bool:
	return nearest_link(point, pace_radius()) >= 0


## The speed bonus the drawn roads give a walker standing here: the best bonus among the links whose
## corridor holds the point, or 0.0 on open ground. The line the map draws is the truth for the
## walk - the grid only ever prices the route - so the pace changes exactly at a road's visible
## edge, and a march crossing one gets a blip in its own footprint (D-124, D-126: the corridor is
## the drawn width, not the wider wear shoulder). [param radius] overrides the width: the eta asks
## at the route scale instead, because it samples a straight line that cannot see the curve
## underfoot (D-130).
func bonus_at(point: Vector2, radius := -1.0) -> float:
	if state == null:
		return 0.0
	var limit := pace_radius() if radius < 0.0 else radius
	var best := 0.0
	var links := mini(_paths.size(), state.roads.size())
	for i in links:
		if _distance_to_path(_paths[i], point) > limit:
			continue
		var raw: Variant = state.roads[i]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		best = maxf(best, bonus_of(str((raw as Dictionary).get("kind", "none"))))
	return best


## The width within which the pace counts the party as ON the road: the drawn line's own scale, so
## the speed flips where the eye sees the road begin and end. The wear credit and the snap still use
## the wider traffic radius - their question ("did this walking wear this road?") wants a shoulder.
func pace_radius() -> float:
	return maxf(1.0, config.get_float("roads.pace_radius", 10.0))


## The width within which walking counts as using a road: the wear scan's corridor, and the width
## inside which a route is snapped onto the drawn line.
func road_radius() -> float:
	return _traffic_radius()


## The link's own curve - the one the map draws and the grid stamps. A route running along this
## link is spliced with these very points, so the walk and the drawing are one line.
func link_curve(index: int) -> PackedVector2Array:
	if index < 0 or index >= _paths.size():
		return PackedVector2Array()
	return _paths[index]


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
	changed_links.clear()
	var ladder := tiers()
	var changed := false
	for i in state.roads.size():
		var raw: Variant = state.roads[i]
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
			changed_links.append(i)
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
			changed_links.append(i)
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
