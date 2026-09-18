class_name ShowcaseBattle
extends RefCounted
## The 300 v 300 showcase battle, built once and shared.
##
## [b]Why this exists.[/b] The windowed showcase, the stalemate probe and the regression
## tests all need to open the same battle: three bodies a side, line formations, the
## production simulator, the production target backend and the production separation pass.
## Three copies of that setup would be three battles, and a fix verified against one of
## them would say nothing about the others. So the setup lives here, in one place, and
## every caller opens [i]this[/i] battle.
##
## [b]What it is.[/b] Deployment and nothing else: where the soldiers stand, which body
## owns whom, what orders the bodies are given. It does not run the battle, does not touch
## a clock and does not know what a stalemate is. The caller decides how it is driven.
##
## The layout is deliberately the one the showcase has always used - two armies drawn up
## forty-six units in from their own edge on a two-hundred by one-hundred-and-twenty field,
## a hundred to a body, body bands sixteen units apart - because the bug this file now
## serves was found by watching exactly that battle. Changing the layout would change the
## battle that produced the evidence.

const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY

const FIELD := Vector2(200.0, 120.0)
## The standard field is what a three-hundred-a-side showcase gets, and it grows with the army
## from there, by area, so density stays where a real battle puts it. Without this a
## twenty-thousand showcase packs ten times the soldiers into the same ground and they stand
## inside one another. Same rule as the benchmark's second family (D-077).
const FIELD_REFERENCE_SIDE := 300
## How many soldiers each body holds. Three bodies a side at this size is three hundred.
const BODY_SIZE := 100
const BODY_IDS := ["centre", "left", "right"]
const BODY_COUNT := 3
## Where each army stands, as a fraction of the field: a quarter of the way in from its own edge,
## so the two hosts face each other across the middle half of the ground with room to close. A
## fixed inset is right for the standard field and leaves a large army's hosts a thousand units
## apart on either edge of a field nobody is standing in.
const DEPLOY_FRACTION := 0.25
## The gap between one body's band and the next.
const BODY_BAND_GAP := 16.0
## The gap between one line of bodies and the line behind it.
const LINE_GAP := 24.0
const BASE_SPACING := 2.6
const FILES := 10


## The field both armies are deployed on. The constant is the standard battlefield; anything
## placing a larger army must ask for the size that army gets, or it will lay the soldiers out
## in a corner of their own ground.
static func field(per_side: int = FIELD_REFERENCE_SIDE) -> Vector2:
	return _field_for(per_side)


## Build the battle. Returns a dictionary rather than a class because the callers want
## different parts of it: the probe wants the simulator, the showcase wants the terrain for
## its camera, and both want the bodies.
##
## [param per_side] is the army size on each side. Bodies are dealt out as evenly as the
## count allows, so three hundred gives three bodies of a hundred and a smaller army gives
## smaller bodies rather than fewer of them.
## The battlefield for a given army size: the standard field at the showcase's own scale, and
## a grown one for a grown army - with a little more ground for the large battles, because a field
## that fits the men exactly leaves no room to see them as an army rather than a crowd. Below the
## standard size nothing changes at all. Static, because the builder that calls it is.
const GROUND_ROOM := 1.45


static func _field_for(per_side: int) -> Vector2:
	var ratio := maxf(1.0, float(per_side) / float(FIELD_REFERENCE_SIDE))
	var room := 1.0 if ratio <= 1.0 else GROUND_ROOM
	var scale := sqrt(ratio) * room
	return Vector2(floorf(FIELD.x * scale), floorf(FIELD.y * scale))


static func build(
	config: GameConfig,
	units_catalog: UnitCatalog,
	formations_catalog: FormationCatalog,
	per_side: int,
	seed_value: int,
	unit_type: String = "spearman",
	enemy_unit_type: String = "spearman",
	max_seconds: float = 0.0,
	with_terrain: bool = true
) -> Dictionary:
	var context := BattleContext.new()
	context.battle_id = "showcase_%d" % per_side
	context.battle_seed = seed_value
	context.terrain_seed = seed_value
	context.enemy_display_name = "Bandits"

	var bodies := BODY_COUNT
	var per_body := int(ceil(float(per_side) / float(bodies)))

	# The field, decided before anything is placed on it, and used for every index built on it as
	# well: a scaled field with a grid still sized for the old one would answer out of bounds, and
	# a deployment laid out for the old one would put a large army in a corner of its own ground.
	var battlefield := _field_for(per_side)

	var units: Array[BattleUnit] = []
	var next_id := 0
	for side_value in [SIDE_PLAYER, SIDE_ENEMY]:
		var side := str(side_value)
		var type_id := unit_type if side == SIDE_PLAYER else enemy_unit_type
		var on_left := side == SIDE_PLAYER
		for i in per_side:
			var body_index := mini(bodies - 1, i / per_body)
			var within := i % per_body
			var snapshot := make_snapshot(units_catalog, config, type_id, side, i)
			var unit := BattleUnit.from_snapshot(snapshot, side, next_id)
			next_id += 1
			units.append(unit)
			place_in_block(unit, battlefield, body_index, within, per_body, on_left)

	var simulator := BattleSimulator.new(config, seed_value)
	if max_seconds > 0.0:
		simulator.max_duration = max_seconds
	simulator.field_size = battlefield
	simulator.grid.configure(battlefield, simulator.cell_size)
	simulator.overlap_grid.configure(battlefield, simulator.overlap_cell_size)
	simulator.add_units(units)
	# The ground, unless the run is the before-half of a before-and-after: the same battle on no
	# terrain at all is the baseline the terrain has to be measured against, and asking for it here
	# is cheaper and more honest than keeping an old build around to compare with.
	if with_terrain:
		simulator.set_terrain_from_context(context, config)
	var terrain := simulator.terrain

	build_formations(simulator, formations_catalog, bodies, per_body, per_side, units)

	# Open on the army in its own order. Every soldier starts on the slot it will fight from, which
	# is the layout the formation layer would dress the loose deployment blocks into over the first
	# seconds of the battle - reached before the first frame instead of after it. The bodies have
	# already set their anchors, so the slots are built around where the army stands.
	var by_id := {}
	for unit in units:
		by_id[unit.id] = unit
	for body in simulator.formations:
		body.ensure_slots()
		for i in body.unit_ids.size():
			var member: BattleUnit = by_id.get(body.unit_ids[i])
			if member == null:
				continue
			member.formation_ref = body
			member.slot_index = i
			member.position = member.formation_slot()

	return {
		"context": context,
		"simulator": simulator,
		"terrain": terrain,
		"per_side": per_side,
		"per_body": per_body,
		"bodies": bodies,
	}


## One soldier's snapshot, out of the real unit catalog. Level one, full health: this is a
## deployed army, not a battle already in progress.
static func make_snapshot(
	units_catalog: UnitCatalog,
	config: GameConfig,
	type_id: String,
	side: String,
	index: int
) -> Dictionary:
	var definition := units_catalog.get_definition(type_id)
	if definition == null:
		definition = units_catalog.get_definition("spearman")
	var level := 1
	var max_hp := definition.max_hp_at(level, config)
	return {
		"soldier_id": "show_%s_%d" % [side, index],
		"name": "%s %d" % [definition.display_name, index],
		"unit_type_id": definition.id,
		"unit_name": definition.display_name,
		"level": level,
		"max_hp": max_hp,
		"hp": max_hp,
		"attack": definition.attack_at(level, config),
		"defence": definition.defence,
		"move_speed": definition.move_speed,
		"attack_range": definition.attack_range,
		"attack_cooldown": definition.attack_cooldown,
		"ranged": definition.ranged,
		"traits": [],
	}


## Lay one soldier out where its army was drawn up, in a coarse block of its own body's
## area. Deliberately not on its formation slot: a freshly deployed battle opens with the
## ranks dressing, and the showcase opens the same way rather than with everyone already
## standing on their mark.
static func place_in_block(
	unit: BattleUnit,
	battlefield: Vector2,
	body_index: int,
	within: int,
	per_body: int,
	on_left: bool
) -> void:
	# Bodies stand one behind the other in depth, not abreast across the field: a body's frontage runs
	# the width of the ground it faces along, so three bodies side by side would need three times the
	# field's height and the outer ones would stand off it. Lines in depth is how real armies stood -
	# front, main, reserve - and it keeps every soldier on the ground he was given. The frontage here
	# is the one the formation itself will lay out, from the same bound, so the blocks the army is
	# drawn up in are the ranks it then dresses into.
	var files := maxi(FILES, int(ceil(float(per_body) / float(BattleFormation.MAX_RANKS))))
	var ranks := int(ceil(float(per_body) / float(files)))
	var file := within % files
	var rank := within / files
	var body_span := float(files - 1) * BASE_SPACING
	var body_depth := float(maxi(0, ranks - 1)) * BASE_SPACING
	var centre_y := battlefield.y * 0.5
	var line_pitch := body_depth + LINE_GAP
	var base_x := battlefield.x * DEPLOY_FRACTION if on_left else battlefield.x * (1.0 - DEPLOY_FRACTION)
	var anchor_x := base_x - float(body_index) * line_pitch if on_left \
		else base_x + float(body_index) * line_pitch
	var x := anchor_x - body_depth * 0.5 + float(rank) * BASE_SPACING if on_left \
		else anchor_x + body_depth * 0.5 - float(rank) * BASE_SPACING
	var y := centre_y - body_span * 0.5 + float(file) * BASE_SPACING
	unit.position = Vector2(x, y)
	unit.facing = Vector2.RIGHT if on_left else Vector2.LEFT


## Three bodies a side: centre, left, right. Membership comes from where the army was
## drawn up - a body owns the soldiers standing in its part of the line - and every body is
## then given the orders the production AI would give it: face the enemy, engage.
static func build_formations(
	simulator: BattleSimulator,
	catalog: FormationCatalog,
	bodies: int,
	per_body: int,
	per_side: int,
	units: Array[BattleUnit]
) -> void:
	var config := simulator.config
	for side_value in [SIDE_PLAYER, SIDE_ENEMY]:
		var side := str(side_value)
		var battlefield := simulator.field_size
		var opposing_centre := Vector2(battlefield.x * (1.0 - DEPLOY_FRACTION), battlefield.y * 0.5) if side == SIDE_PLAYER \
			else Vector2(battlefield.x * DEPLOY_FRACTION, battlefield.y * 0.5)
		for body_index in bodies:
			var members: Array[int] = []
			for i in per_body:
				var unit_index := unit_index_of(side, body_index, per_body, i, per_side, units)
				if unit_index >= 0:
					members.append(units[unit_index].id)
			if members.is_empty():
				continue
			var centroid := Vector2.ZERO
			for unit_id in members:
				centroid += simulator.find_unit(unit_id).position
			centroid /= float(members.size())
			var body := BattleFormation.create(
				"%s_%s" % [side, BODY_IDS[body_index]], side, centroid,
				0.0 if side == SIDE_PLAYER else PI, "line", catalog, config)
			simulator.add_formation(body)
			simulator.assign_formation(body, members)
			body.order_face_toward(opposing_centre)
			body.set_facing(body.desired_facing)
			body.order_engage()
			body.ensure_slots()


static func unit_index_of(
	side: String,
	body_index: int,
	per_body: int,
	within: int,
	per_side: int,
	units: Array[BattleUnit]
) -> int:
	var offset := 0 if side == SIDE_PLAYER else per_side
	var index := offset + body_index * per_body + within
	if index < 0 or index >= units.size():
		return -1
	return index


## A fingerprint of the deployment: every soldier's id and position, in order. Two builds
## that agree on this are the same battle, which is what lets a refactor of the setup be
## shown to have changed nothing.
static func setup_checksum(units: Array[BattleUnit]) -> String:
	var parts := PackedStringArray()
	for unit in units:
		parts.append("%d:%.3f,%.3f" % [unit.id, unit.position.x, unit.position.y])
	var joined := "|".join(parts)
	return "%d:%08x" % [units.size(), hash(joined) & 0xFFFFFFFF]
