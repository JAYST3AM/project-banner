class_name BattleSetup
extends RefCounted
## Builds the fighting units for a battle and lays them out on the field.
##
## Pure data: given a [BattleContext] it produces positioned [BattleUnit]s. No
## nodes, no rendering, no input - which is what lets the deployment be tested
## headlessly and reused unchanged when battlefields become terrain-aware.

const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY


## Fallback spacing for a body whose shape cannot be read from the formation catalog - the same
## number the catalog and the config carry. The deployment normally takes both its files and its
## spacing from the shape it is about to give the body, so men start on their marks rather than
## walking sideways to find them.
const FILE_SPACING := 2.6


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


## The rectangles an army is drawn up in: the player on the left, the enemy on the right, each
## [code]battle.deploy_depth[/code] deep and the full height of the field.
##
## This is the ground terrain props must leave alone. The deployment above is a formula rather than a
## recorded decision, so the zones are derived from the same numbers - if the deployment ever changes
## shape, this changes with it rather than falling out of step with it.
static func deployment_zones(config: GameConfig) -> Array[Rect2]:
	var field := field_size(config)
	var depth := config.get_float("battle.deploy_depth", 20.0)
	var margin := config.get_float("battle.deploy_margin", 8.0)
	var zones: Array[Rect2] = []
	var width := minf(field.x * 0.5, depth + margin)
	zones.append(Rect2(Vector2.ZERO, Vector2(width, field.y)))
	zones.append(Rect2(Vector2(field.x - width, 0.0), Vector2(width, field.y)))
	return zones


## Place both armies facing each other: player on the left, enemy on the right,
## melee to the front and ranged behind, in ranks that fit the deployment depth.
##
## Men are placed on the lattice of the shape they are about to be given (see
## [method assign_default_formations]: a line for the melee, a loose body for the missiles), because
## the formations lay their slots out from each body's centroid and its own geometry. A deployment
## that used some other lattice had every man walk sideways to find his place, which the formation
## suite measured as ranks more than four units out of order after six seconds of dressing.
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

	var types := FormationCatalog.load_from()
	var line := _lattice(types, config, "line", 10)
	var loose := _lattice(types, config, "loose", 6)
	_deploy_side(players, field, depth, margin, true, line, loose)
	_deploy_side(enemies, field, depth, margin, false, line, loose)



## The lattice one of the deployment's shapes asks its men to stand on, as (files, spacing). Read
## from the same catalog the formations are built from, so the two cannot drift apart; the fallbacks
## are the catalog's own defaults for a shape it cannot supply.
static func _lattice(types: FormationCatalog, config: GameConfig, id: String, fallback_files: int) -> Vector2:
	if types != null and types.is_valid() and types.has(id):
		var base := config.get_float("formation.base_spacing", 2.6)
		return Vector2(float(types.max_files(id)), maxf(0.2, base * types.spacing_multiplier(id)))
	return Vector2(float(fallback_files), FILE_SPACING)


static func _deploy_side(units: Array[BattleUnit], field: Vector2, depth: float, margin: float, on_left: bool, line: Vector2, loose: Vector2) -> void:
	if units.is_empty():
		return
	# Missiles behind, melee in front: the deployment is laid out in depth by role, not as one
	# block. It was one block - a square grid of columns and rows - so the front rank and the
	# archers ended up side by side in separate lanes at the same distance from the enemy, and
	# both armies' archers met each other head-on with no line in between. The journal of a
	# 15-archer-and-30-spearman test battle caught exactly that: our archers at (75, 42) and
	# theirs at (76, 42) after both had crossed the field.
	#
	# The zone is split in depth: missiles stand in the back third of it, the line in the front
	# two thirds, and each body is laid out in ranks of at most nine files across the field.
	var melee: Array[BattleUnit] = []
	var ranged: Array[BattleUnit] = []
	for unit in units:
		if unit.ranged:
			ranged.append(unit)
		else:
			melee.append(unit)
	_place_in_ranks(ranged, field, depth * 0.34, margin, 0.0, on_left, loose)
	_place_in_ranks(melee, field, depth * 0.66, margin, depth * 0.34, on_left, line)


## Lay one body of men out in ranks within a band of the deployment zone, on the lattice of the
## shape it is about to be given. [param start] is how far into the zone the band begins, measured
## inward from this army's own end of the field.
##
## The maths mirrors [method BattleFormation.rebuild_slots]: files across the width at the shape's
## spacing, ranks from the anchor back, rank zero at the front. Placement is symmetric about the
## band's centre, so the centroid the formation anchors itself on is exactly where the body was
## drawn up.
static func _place_in_ranks(units: Array[BattleUnit], field: Vector2, band: float, margin: float, start: float, on_left: bool, lattice: Vector2) -> void:
	var count := units.size()
	if count == 0:
		return
	var files := mini(count, maxi(1, int(lattice.x)))
	var ranks := int(ceil(float(count) / float(files)))
	var spacing := maxf(0.2, lattice.y)
	var half_files := float(files - 1) * 0.5
	var half_ranks := float(ranks - 1) * 0.5
	var centre_y := margin + (maxf(1.0, field.y - (margin * 2.0)) * 0.5)
	var centre_inward := start + (band * 0.5)
	for index in count:
		var lateral := (float(index % files) - half_files) * spacing
		# A body's right is -y when it faces -x, so the enemy's files run the other way down the
		# field. Getting this sign wrong mirrors the whole body: every man in the enemy's line had
		# to walk across his own ranks to find his place, which is what the formation suite was
		# measuring as ranks seven units out of order six seconds after deployment.
		if not on_left:
			lateral = -lateral
		var forward_offset := (half_ranks - float(index / files)) * spacing
		var inward := centre_inward + forward_offset
		var x := margin + inward if on_left else field.x - margin - inward
		var y := clampf(centre_y + lateral, margin, field.y - margin)
		units[index].position = Vector2(x, y)
		units[index].facing = Vector2.RIGHT if on_left else Vector2.LEFT


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


## ---------- formations ---------------------------------------------------

## Put both armies into formations: melee as the line, ranged as a looser body behind.
##
## This is the same arrangement the deployment above already used - front rank to the
## enemy, missiles behind - but expressed as formations, so from here on the shape of
## an army is something a formation decides rather than something a loop of
## coordinates decides. Both sides go through the identical call: the enemy is not a
## special case, it is an army that happens to be given orders by [BattleAI].
##
## Units are only [i]told[/i] where their place is. They walk there when the battle
## starts, so a freshly deployed battle opens with the ranks dressing rather than with
## everyone already standing on their marks - which is the honest version, and it
## gives the cohesion measure something real to report from the first second.
static func assign_default_formations(
	simulator: BattleSimulator,
	config: GameConfig,
	catalog: FormationCatalog = null
) -> Array[BattleFormation]:
	var created: Array[BattleFormation] = []
	if simulator == null:
		return created
	var types := catalog if catalog != null else FormationCatalog.load_from()
	if not types.is_valid():
		DebugLogger.error("no formation types available; armies stay unformed", "BattleSetup")
		return created

	var line_anchors := {}
	for side in [SIDE_PLAYER, SIDE_ENEMY]:
		var melee: Array[int] = []
		var ranged: Array[int] = []
		for unit in simulator.units:
			if unit.side != side:
				continue
			if unit.ranged:
				ranged.append(unit.id)
			else:
				melee.append(unit.id)

		var facing := 0.0 if side == SIDE_PLAYER else PI
		var anchor := _centroid(simulator, melee)
		if melee.is_empty():
			anchor = _centroid(simulator, ranged)
		line_anchors[side] = anchor

		if not melee.is_empty():
			var body := BattleFormation.create("%s_line" % side, side, anchor, facing, "line", types, config)
			simulator.add_formation(body)
			simulator.assign_formation(body, melee)
			created.append(body)
		if not ranged.is_empty():
			var skirmishers := BattleFormation.create(
				"%s_ranged" % side, side, _centroid(simulator, ranged), facing, "loose", types, config
			)
			simulator.add_formation(skirmishers)
			simulator.assign_formation(skirmishers, ranged)
			created.append(skirmishers)

	# Face each body at the other army rather than at a direction chosen in advance, so
	# this works whatever way round the deployment happened to put them. Engagement is
	# the battle's default stance, but it is stated here anyway: a freshly deployed army
	# is an army that intends to fight, and the fighting has to start whether or not
	# anyone gives another order.
	for body in created:
		var opposing: Vector2 = line_anchors.get(_other_side(body.side), body.anchor)
		body.order_face_toward(opposing)
		body.set_facing(body.desired_facing)
		body.order_engage()
		body.ensure_slots()
	return created


static func _other_side(side: String) -> String:
	return SIDE_ENEMY if side == SIDE_PLAYER else SIDE_PLAYER


static func _centroid(simulator: BattleSimulator, unit_ids: Array[int]) -> Vector2:
	if unit_ids.is_empty():
		return Vector2.ZERO
	var total := Vector2.ZERO
	var counted := 0
	for unit_id in unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null:
			continue
		total += unit.position
		counted += 1
	if counted == 0:
		return Vector2.ZERO
	return total / float(counted)
