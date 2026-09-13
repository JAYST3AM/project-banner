class_name BattleSetup
extends RefCounted
## Builds the fighting units for a battle and lays them out on the field.
##
## Pure data: given a [BattleContext] it produces positioned [BattleUnit]s. No
## nodes, no rendering, no input - which is what lets the deployment be tested
## headlessly and reused unchanged when battlefields become terrain-aware.

const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY


## Every unit in the battle, players first, enemy second.
static func build_units(context: BattleContext) -> Array[BattleUnit]:
	var units: Array[BattleUnit] = []
	if context == null:
		return units
	var next_id := 0
	for snapshot in context.player_snapshot:
		units.append(BattleUnit.from_snapshot(snapshot, SIDE_PLAYER, next_id))
		next_id += 1
	for snapshot in context.enemy_snapshot:
		units.append(BattleUnit.from_snapshot(snapshot, SIDE_ENEMY, next_id))
		next_id += 1
	return units


## Build and deploy in one call - the form almost every caller wants.
static func build_units_prepared(context: BattleContext, config: GameConfig) -> Array[BattleUnit]:
	var units := build_units(context)
	deploy(units, config)
	return units


static func field_size(config: GameConfig) -> Vector2:
	return Vector2(
		config.get_float("battle.field_width", 100.0),
		config.get_float("battle.field_height", 60.0)
	)


## Place both armies facing each other: player on the left, enemy on the right,
## melee to the front and ranged behind, in ranks that fit the deployment depth.
static func deploy(units: Array[BattleUnit], config: GameConfig) -> void:
	var field := field_size(config)
	var depth := config.get_float("battle.deploy_depth", 20.0)
	var margin := config.get_float("battle.deploy_margin", 8.0)

	var players: Array[BattleUnit] = []
	var enemies: Array[BattleUnit] = []
	for unit in units:
		if unit.side == SIDE_PLAYER:
			players.append(unit)
		else:
			enemies.append(unit)

	_deploy_side(players, field, depth, margin, true)
	_deploy_side(enemies, field, depth, margin, false)


static func _deploy_side(units: Array[BattleUnit], field: Vector2, depth: float, margin: float, on_left: bool) -> void:
	if units.is_empty():
		return
	# Melee in front (closest to the enemy), ranged behind them.
	var ordered := _front_to_back(units)

	var count := ordered.size()
	var rows := maxi(1, int(ceil(sqrt(float(count)))))
	var columns := maxi(1, int(ceil(float(count) / float(rows))))

	var usable_height := maxf(1.0, field.y - (margin * 2.0))
	var row_step := usable_height / float(rows)
	var column_step := depth / float(columns)

	for index in ordered.size():
		var unit := ordered[index]
		var column := index % columns
		var row := index / columns
		var offset := (float(column) + 0.5) * column_step
		var x := margin + offset if on_left else field.x - margin - offset
		var y := margin + (float(row) + 0.5) * row_step
		unit.position = Vector2(x, y)
		unit.facing = Vector2.RIGHT if on_left else Vector2.LEFT


static func _front_to_back(units: Array[BattleUnit]) -> Array[BattleUnit]:
	var melee: Array[BattleUnit] = []
	var ranged: Array[BattleUnit] = []
	for unit in units:
		if unit.ranged:
			ranged.append(unit)
		else:
			melee.append(unit)
	var out: Array[BattleUnit] = []
	out.append_array(melee)
	out.append_array(ranged)
	return out
