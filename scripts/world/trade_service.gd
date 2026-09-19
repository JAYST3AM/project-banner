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
		# Value pays the road: a rich haul a long way off can still beat a thin haul next door. The
		# constant was 0.012 before carts had purses and quantities (D-140): at that price a crate of
		# firewood could never cover 400 u of road, so villages selling cheap goods dead-ended - the
		# live session's "no road to a buyer" warnings. A caravan now carries up to six crates, so
		# bulk goods move on volume and the road is charged per unit more gently.
		var score := float(gain.get("value", 0)) - distance * 0.004
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


## What a caravan actually loads at [param from] for the trip to [param to], paying out of its own
## purse (D-140): the most valuable of the route's goods first, one crate at a time, until the purse
## cannot cover the next crate or the cart is full. Returns {"goods": [...with repeats...], "cost": n}.
## This is where spending power is real - a noble house's purse buys jewellery, an independent's
## buys two crates of ale.
static func buy_load(from: Settlement, to: Settlement, cash: int, units_max: int) -> Dictionary:
	var gain := route_gain(from, to)
	var menu: Array = (gain.get("goods", []) as Array).duplicate()
	menu.sort_custom(func(a: Variant, b: Variant) -> bool: return value_of(str(a)) > value_of(str(b)))
	var loaded: Array[String] = []
	var spent := 0
	while loaded.size() < units_max:
		var bought := false
		for good_any in menu:
			var good := str(good_any)
			var price := value_of(good)
			if spent + price > cash:
				continue
			loaded.append(good)
			spent += price
			bought = true
			break
		if not bought:
			break
	return {"goods": loaded, "cost": spent}


## What the destination pays for a cart: each crate at its own worth, lifted by how much the town
## wants it (a town's pocket is its own wealth).
static func sale_value(cargo: Array, to: Settlement) -> int:
	if to == null:
		return 0
	var multiplier := float(WANT_MULTIPLIER.get(to.wealth, 1.0))
	var value := 0
	for good in cargo:
		value += int(round(float(value_of(str(good))) * multiplier))
	return value


## A one-line cargo description for logs and cards: "ale x2, wool cloth (58 coin)".
static func describe_cargo(cargo: Array, value: int) -> String:
	if cargo.is_empty():
		return "nothing"
	var counts := {}
	var order: Array[String] = []
	for good_any in cargo:
		var good := str(good_any)
		if not counts.has(good):
			counts[good] = 0
			order.append(good)
		counts[good] = int(counts[good]) + 1
	var names: Array[String] = []
	for good in order:
		var label := name_of(good).to_lower()
		if int(counts[good]) > 1:
			names.append("%s x%d" % [label, int(counts[good])])
		else:
			names.append(label)
	return "%s (%d coin)" % [", ".join(names), value]
