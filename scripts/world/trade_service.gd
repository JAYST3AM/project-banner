class_name TradeService
extends RefCounted
## The trade layer's foundations (D-139): what goods are worth, who wants them, and which journeys
## are worth making. Caravans read this to pick their routes; the settlement card already shows the
## produces/wants this prices (D-136).
##
## Deliberately simple: a good is worth a base value everywhere, and more where a town wants it.
## Prices that move with supply and demand are the market layer's business later - this layer only
## has to answer "is that trip worth the road", because that is the question a caravan asks.

const GOODS_PATH := "res://data/config/goods.json"

## How much a town's wanting a good multiplies its worth there, by the town's own pocket.
const WANT_MULTIPLIER := {"poor": 1.0, "modest": 1.15, "wealthy": 1.3}

static var _goods: Dictionary = {}


## id -> {"name", "value", "category"}. Loaded once per run.
static func goods() -> Dictionary:
	if _goods.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(GOODS_PATH))
		if typeof(parsed) != TYPE_DICTIONARY:
			DebugLogger.warn("trade: could not read %s" % GOODS_PATH, "TradeService")
			_goods = {"__missing__": {"name": "Unknown", "value": 0, "category": "?"}}
		else:
			for entry in ((parsed as Dictionary).get("goods", []) as Array):
				var row: Dictionary = entry as Dictionary
				_goods[str(row.get("id", ""))] = row
	return _goods


## What a good is worth as a base figure. An unpriced good is worth 1, not 0: the road is the same
## length either way, and silently ignoring it would hide the catalogue gap.
static func value_of(good: String) -> int:
	var row: Dictionary = goods().get(good, {}) as Dictionary
	return int(row.get("value", 1))


static func name_of(good: String) -> String:
	var row: Dictionary = goods().get(good, {}) as Dictionary
	return str(row.get("name", good))


## What one trip from [param from] to [param to] is worth carrying: the goods the destination wants
## that the origin sells, priced at the destination. Empty when the two towns trade nothing.
static func route_gain(from: Settlement, to: Settlement) -> Dictionary:
	if from == null or to == null or from.id == to.id:
		return {"goods": [], "value": 0}
	var multiplier := float(WANT_MULTIPLIER.get(to.wealth, 1.0))
	var carried: Array[String] = []
	var value := 0
	for good in from.produces:
		if not to.wants.has(good):
			continue
		carried.append(good)
		value += int(round(float(value_of(good)) * multiplier))
	return {"goods": carried, "value": value}


## The journeys worth leaving [param from] for, best first, limited. Only towns another kind of
## place trades with: a village does not caravan to itself, and distance is a cost, not a detail.
##
## Roads are drawn from [method RoadPath.between] between any two settlements, and a caravan walks
## that same curve - so "on a road" is not a filter here, it is how the movement works.
static func best_routes(from: Settlement, settlements: Dictionary, limit: int = 3,
		max_units: float = 1500.0) -> Array:
	var routes: Array = []
	for key in settlements.keys():
		var to := settlements[key] as Settlement
		if to == null or to.id == from.id:
			continue
		var distance := from.position.distance_to(to.position)
		if distance > max_units:
			continue
		var gain := route_gain(from, to)
		var goods: Array = gain.get("goods", []) as Array
		if goods.is_empty():
			continue
		# Value pays the road: a rich haul a long way off can still beat a thin haul next door.
		var score := float(gain.get("value", 0)) - distance * 0.012
		if score <= 0.0:
			continue
		routes.append({
			"id": to.id,
			"name": to.name,
			"goods": goods,
			"value": int(gain.get("value", 0)),
			"distance": distance,
			"score": score,
		})
	routes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))
	return routes.slice(0, limit)


## A one-line cargo description for logs and cards: "ale, wool cloth (58 coin)".
static func describe_cargo(cargo: Array, value: int) -> String:
	if cargo.is_empty():
		return "nothing"
	var names: Array[String] = []
	for good_any in cargo:
		names.append(name_of(str(good_any)).to_lower())
	return "%s (%d coin)" % [", ".join(names), value]
