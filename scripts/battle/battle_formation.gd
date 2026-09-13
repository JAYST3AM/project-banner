class_name BattleFormation
extends RefCounted
## A body of soldiers fighting as one shape.
##
## [b]A formation is not a preset and not a buff.[/b] It is a physical object on the
## battlefield: it has a centre, a facing, a width and a depth, and it hands each of
## its soldiers a place to stand. A soldier's job is to be in its place; it is the
## formation, not the individual, that decides where the body is going. That inversion
## is the entire point of the milestone - it is what lets thousands of soldiers be
## cheap, because most of them are doing arithmetic rather than thinking.
##
## [b]Reformation is physical.[/b] Changing shape or facing rewrites the slots and
## stops there. Nothing teleports: each soldier keeps its slot index, notices its slot
## has moved, and walks to the new one. Cohesion is the measure of how far through that
## process the formation is.
##
## [b]Facing is part of the geometry, not a decoration.[/b] Slots are generated in
## formation-local space (forward/right) and transformed into the world, so any angle
## works - not just the two the deployment code happens to use. Directional shields,
## phalanx frontage and flanking all need exactly this, so it is worth getting right
## before there is anything leaning on it.

const ORDER_ENGAGE := "engage"
const ORDER_HOLD := "hold"
const ORDER_MOVE := "move"

## How close an engaged body tries to bring its centre to the enemy's. Effectively
## "on top of", because it is closing on a body of men rather than on a map pin.
const ENGAGE_EPSILON := 0.05

## Turn tolerance, in radians. Below this the formation is considered to be facing
## where it was told to face.
const FACING_EPSILON := 0.02

var id: String = ""
var side: String = BattleContext.SIDE_PLAYER
var type_id: String = "line"

## The formation's centre.
var anchor: Vector2 = Vector2.ZERO
## Current facing, in radians. The direction the front rank looks along.
var facing: float = 0.0
## Where it has been told to face. Kept separate from [member facing] so a turn is
## something that happens over time rather than instantly.
var desired_facing: float = 0.0
## Where the body is heading, if it is heading anywhere.
var target_anchor: Vector2 = Vector2.ZERO
var order: String = ORDER_ENGAGE

## Assigned soldiers, in slot order: unit_ids[i] owns slots[i]. Battle-unit ids, not
## persistent soldier ids - a formation is battle state and never reaches the campaign.
var unit_ids: Array[int] = []
## World-space places to stand, one per assigned soldier.
var slots: Array[Vector2] = []

var file_count: int = 0
var rank_count: int = 0
var spacing: float = 2.6

## How closely the body is holding its shape: 1.0 dressed and steady, 0.0 scattered.
var cohesion: float = 1.0

var move_factor: float = 1.0
var turn_rate_deg: float = 120.0

var _max_files: int = 10
var _spacing_multiplier: float = 1.0
var _catalog: FormationCatalog = null
var _config: GameConfig = null
var _slots_dirty: bool = true
var _reforming: bool = false
var _reforming_gate: float = 0.8


## ---------- construction -------------------------------------------------

static func create(
	p_id: String,
	p_side: String,
	p_anchor: Vector2,
	p_facing: float,
	p_type_id: String,
	catalog: FormationCatalog,
	config: GameConfig
) -> BattleFormation:
	var formation := BattleFormation.new()
	formation.id = p_id
	formation.side = p_side
	formation._catalog = catalog
	formation._config = config
	if config != null:
		formation.spacing = maxf(0.2, config.get_float("formation.base_spacing", 2.6))
		formation._reforming_gate = config.get_float("formation.settled_cohesion", 0.8)
	formation.anchor = p_anchor
	formation.facing = p_facing
	formation.desired_facing = p_facing
	formation.target_anchor = p_anchor
	formation.set_type(p_type_id)
	formation._reforming = false
	return formation


## Change shape. Deliberately does [b]not[/b] move anybody: the slots are rewritten,
## every soldier keeps its slot index, and the walk to the new place is the
## reformation. Clears itself once cohesion has recovered.
func set_type(p_type_id: String) -> bool:
	var chosen := p_type_id
	if _catalog != null and not _catalog.has(chosen):
		chosen = FormationCatalog.FALLBACK_ID
	if _catalog != null:
		_max_files = _catalog.max_files(chosen)
		_spacing_multiplier = _catalog.spacing_multiplier(chosen)
		turn_rate_deg = _catalog.turn_rate_deg(chosen)
		move_factor = _catalog.move_factor(chosen)
	var base_spacing := 2.6
	if _config != null:
		base_spacing = maxf(0.2, _config.get_float("formation.base_spacing", 2.6))
	spacing = base_spacing * _spacing_multiplier
	var changed := chosen != type_id
	type_id = chosen
	_slots_dirty = true
	if changed:
		# A shape change puts the body out of order until it has dressed again.
		_reforming = true
	return changed


func set_catalog_and_config(catalog: FormationCatalog, config: GameConfig) -> void:
	_catalog = catalog
	_config = config


func display_name() -> String:
	return _catalog.display_name(type_id) if _catalog != null else type_id


## ---------- membership ---------------------------------------------------

## Add a soldier to the body. Slot order is assignment order, which keeps a
## reformation stable: nobody is reshuffled, they simply walk to the new place their
## index now points at.
func add_unit(unit_id: int) -> bool:
	if unit_ids.has(unit_id):
		return false
	unit_ids.append(unit_id)
	_slots_dirty = true
	return true


## Remove a soldier - a casualty, or a transfer. The remaining ranks close up, which
## is a reformation like any other and shows up in the cohesion.
func remove_unit(unit_id: int) -> bool:
	var index := unit_ids.find(unit_id)
	if index < 0:
		return false
	unit_ids.remove_at(index)
	_reforming = true
	_slots_dirty = true
	return true


func has_unit(unit_id: int) -> bool:
	return unit_ids.has(unit_id)


## Where in the body this soldier stands, or -1. Linear in the size of the formation;
## soldiers carry their own index so this is only ever used by tooling and tests.
func slot_index_of(unit_id: int) -> int:
	return unit_ids.find(unit_id)


func size() -> int:
	return unit_ids.size()


## Whether anybody in this body is still standing. A formation of corpses is not a
## formation, and the battlefield should not steer toward one.
func has_living_units(units_by_id: Dictionary) -> bool:
	for unit_id in unit_ids:
		var unit: BattleUnit = units_by_id.get(unit_id)
		if unit != null and unit.is_alive():
			return true
	return false


func is_empty() -> bool:
	return unit_ids.is_empty()


## ---------- geometry -----------------------------------------------------

## Unit vector the front rank looks along.
func forward() -> Vector2:
	return Vector2(cos(facing), sin(facing))


## Unit vector along the formation's width, from its own point of view.
func right_vector() -> Vector2:
	return Vector2(-sin(facing), cos(facing))


func set_anchor(point: Vector2) -> void:
	anchor = point
	_slots_dirty = true


func set_facing(angle: float) -> void:
	facing = angle
	_slots_dirty = true


## Total width of the dressed shape. A one-file column has no frontage at all.
func frontage() -> float:
	return float(maxi(0, file_count - 1)) * spacing


## How far the body reaches from front rank to rear.
func depth() -> float:
	return float(maxi(0, rank_count - 1)) * spacing


## The corners of the dressed shape, for debug drawing and bounds tests.
func bounds() -> Rect2:
	if slots.is_empty():
		return Rect2(anchor, Vector2.ZERO)
	var half := Vector2(frontage(), depth()) * 0.5
	return Rect2(anchor - half, half * 2.0)


## Recompute the places to stand. Cheap and linear, and only runs when something has
## actually moved: a formation standing still costs nothing.
func ensure_slots() -> void:
	if not _slots_dirty:
		return
	_rebuild_slots()


func _rebuild_slots() -> void:
	_slots_dirty = false
	var count := unit_ids.size()
	if count == 0:
		file_count = 0
		rank_count = 0
		slots.clear()
		return
	file_count = mini(count, _max_files)
	rank_count = int(ceil(float(count) / float(file_count)))

	var fwd := forward()
	var right := right_vector()
	# Assign into the existing array where possible: a formation that is merely
	# marching should not be allocating a fresh slot list every step.
	slots.resize(count)
	var half_files := float(file_count - 1) * 0.5
	var half_ranks := float(rank_count - 1) * 0.5
	for i in count:
		var file := i % file_count
		var rank := i / file_count
		var lateral := (float(file) - half_files) * spacing
		# Rank 0 is the front rank, so it stands furthest along the facing direction.
		var forward_offset := (half_ranks - float(rank)) * spacing
		slots[i] = anchor + right * lateral + fwd * forward_offset


## The place soldier [param index] should be standing, or the anchor if there is none.
func slot_at(index: int) -> Vector2:
	ensure_slots()
	if index < 0 or index >= slots.size():
		return anchor
	return slots[index]


## ---------- orders -------------------------------------------------------

func order_move_to(point: Vector2) -> void:
	target_anchor = point
	order = ORDER_MOVE


func order_hold() -> void:
	order = ORDER_HOLD
	target_anchor = anchor


## Close with the enemy, and keep closing until the fighting starts.
##
## This is the standing order rather than a move order: nothing is decided here about
## where the enemy is, only that this body intends to find out. The battlefield works
## out what that means each step, because it is the only thing that knows where anyone
## is standing.
func order_engage() -> void:
	order = ORDER_ENGAGE


## Aim the body at a point without changing what it has been told to do. Used by the
## battlefield to steer a body that is already engaged.
func steer_toward(point: Vector2) -> void:
	target_anchor = point


func order_face(angle: float) -> void:
	desired_facing = angle


func order_face_toward(point: Vector2) -> void:
	var to_point := point - anchor
	if to_point.length() > 0.0001:
		desired_facing = to_point.angle()


## ---------- per-step update ----------------------------------------------

## How close the centre has to get before it counts as having got there.
##
## A body making for a waypoint stops a comfortable distance short of it - nobody needs
## a formation to grind to a halt on an exact coordinate. A body closing on an enemy is
## not making for a waypoint at all: it stops when the enemy is there, so it aims to be
## on top of it.
func _arrive_radius() -> float:
	if order == ORDER_ENGAGE:
		return ENGAGE_EPSILON
	if _config != null:
		return maxf(0.05, _config.get_float("formation.arrive_radius", 0.6))
	return 0.6


## Advance the body itself by one step. Individual soldiers are not touched here -
## they walk to their slots themselves, which is what keeps this cheap.
##
## [param speed] is the pace the whole body may move at; the caller derives it from
## its slowest soldier so that nobody is left behind by their own formation.
func advance(delta: float, speed: float) -> void:
	if order != ORDER_HOLD:
		var to_target := target_anchor - anchor
		var distance := to_target.length()
		var arrive := _arrive_radius()
		if distance > arrive:
			var step := minf(distance - arrive, maxf(0.0, speed) * delta)
			anchor += to_target.normalized() * step
			_slots_dirty = true
		else:
			anchor = target_anchor
			if order == ORDER_MOVE:
				# A move order is finished when the body arrives. It does not silently
				# become a standing order to keep going somewhere.
				order = ORDER_HOLD
			_slots_dirty = true

	var difference := angle_difference(facing, desired_facing)
	if absf(difference) > 0.0001:
		var rate := turn_rate_deg
		if _config != null:
			rate *= maxf(0.05, _config.get_float("formation.rotate_speed_factor", 0.75))
		var max_step := deg_to_rad(rate) * delta
		facing = wrapf(facing + clampf(difference, -max_step, max_step), -PI, PI)
		_slots_dirty = true


## How closely the body is holding its shape, measured against the slots it was given.
## Written back to [member cohesion] and returned.
func update_cohesion(units_by_id: Dictionary, reference_distance: float) -> float:
	if unit_ids.is_empty():
		cohesion = 1.0
		return cohesion
	ensure_slots()
	var reference := maxf(0.01, reference_distance)
	var total := 0.0
	var counted := 0
	for i in unit_ids.size():
		var unit: BattleUnit = units_by_id.get(unit_ids[i])
		if unit == null or not unit.is_alive():
			continue
		total += minf(1.0, unit.position.distance_to(slots[i]) / reference)
		counted += 1
	if counted == 0:
		cohesion = 0.0
		return cohesion
	cohesion = clampf(1.0 - total / float(counted), 0.0, 1.0)
	if _reforming and cohesion >= _reforming_gate:
		_reforming = false
	return cohesion


## ---------- derived state ------------------------------------------------
## Deliberately derived rather than stored: there is no state machine here, just
## questions asked of the geometry.

func is_moving() -> bool:
	if order == ORDER_HOLD:
		return false
	return anchor.distance_to(target_anchor) > _arrive_radius()


func is_turning() -> bool:
	return absf(angle_difference(facing, desired_facing)) > FACING_EPSILON


## True while the body is still dressing into a shape it was recently told to take.
func is_reforming() -> bool:
	return _reforming


func is_stable() -> bool:
	return not is_moving() and not is_turning() and not is_reforming()


func state_name() -> String:
	if is_reforming():
		return "reforming"
	if is_moving():
		return "moving"
	if is_turning():
		return "turning"
	return "steady"


func facing_degrees() -> float:
	return rad_to_deg(facing)


func to_dict() -> Dictionary:
	return {
		"id": id,
		"side": side,
		"type": type_id,
		"anchor": DataUtils.vec2_to(anchor),
		"target_anchor": DataUtils.vec2_to(target_anchor),
		"facing_deg": facing_degrees(),
		"desired_facing_deg": rad_to_deg(desired_facing),
		"files": file_count,
		"ranks": rank_count,
		"spacing": spacing,
		"frontage": frontage(),
		"depth": depth(),
		"units": unit_ids.duplicate(),
		"cohesion": cohesion,
		"state": state_name(),
		"order": order,
	}
