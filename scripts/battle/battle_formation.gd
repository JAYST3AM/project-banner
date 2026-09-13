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

## Whether any soldier of this body is currently within reach of an enemy.
##
## Contact belongs to a body, not to a side. A wing that has not reached the enemy is
## not "in contact" merely because the centre is fighting, and a body's own orders are
## judged against its own state. Maintained by the battlefield inside the per-soldier
## reach test it already performs, so it costs a boolean rather than a search, and
## cleared at the end of each step. See D-056.
var in_contact: bool = false

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
	# Rebuild now rather than leaving it to the next step. A shape change is a rare,
	# deliberate act, and asking a body what shape it is in should answer for the shape
	# it has just been given rather than the one it is walking out of - `file_count`,
	# `rank_count`, `frontage()` and `depth()` all read from the rebuilt geometry. The
	# per-step path deliberately stays lazy, because that one runs every tick for every
	# body and this one runs when somebody gives an order.
	ensure_slots()
	return changed


func set_catalog_and_config(catalog: FormationCatalog, config: GameConfig) -> void:
	_catalog = catalog
	_config = config


func display_name() -> String:
	return _catalog.display_name(type_id) if _catalog != null else type_id


## ---------- membership ---------------------------------------------------
##
## Membership is owned here and nowhere else.
##
## Every method below marks the slot geometry dirty before returning, and that is the
## entire reason these methods exist. A formation's files, ranks, frontage, depth and
## slot positions are all derived from how many soldiers it holds, so a membership
## change that does not invalidate the geometry leaves the body believing it is a shape
## it is no longer. Step 7 shipped with [BattleSimulator] editing [member unit_ids]
## directly, which is exactly the mistake this API makes impossible: a player could
## detach a group from a steady line and the line would keep reporting the frontage,
## the rank count and the slot positions of a body four men larger, until something
## unrelated happened to dirty it. See D-054.
##
## Callers must never edit [member unit_ids] from outside. The invariant is not
## "remember to call `_invalidate()`" but "there is no way to change membership without
## doing so".

## Add a soldier to the body. Slot order is assignment order, which keeps a reformation
## stable: nobody is reshuffled, they simply walk to the new place their index now
## points at.
func add_unit(unit_id: int) -> bool:
	if unit_ids.has(unit_id):
		return false
	unit_ids.append(unit_id)
	_invalidate()
	return true


## Remove a soldier - a casualty, or a transfer. The remaining ranks close up, which
## is a reformation like any other and shows up in the cohesion.
func remove_unit(unit_id: int) -> bool:
	var index := unit_ids.find(unit_id)
	if index < 0:
		return false
	unit_ids.remove_at(index)
	_invalidate()
	return true


## Remove several soldiers in one rebuild rather than one rebuild each. Returns how many
## were actually in the body.
func remove_units(leaving: Array[int]) -> int:
	if leaving.is_empty() or unit_ids.is_empty():
		return 0
	var going := {}
	for unit_id in leaving:
		going[unit_id] = true
	var kept: Array[int] = []
	var removed := 0
	for existing in unit_ids:
		if going.has(existing):
			removed += 1
		else:
			kept.append(existing)
	if removed > 0:
		unit_ids = kept
		_invalidate()
	return removed


## Replace the membership wholesale, in the order given, and rebuild the geometry for
## the body that results.
##
## Duplicates are dropped rather than accepted: a soldier belongs to one body, and
## holding the same id twice would give it two places and put it on the rolls twice.
##
## An unchanged list does nothing at all - not even marking the body as reforming - so
## re-issuing the same assignment is free and does not disturb a dressed formation.
func set_units(new_ids: Array[int]) -> void:
	var ordered: Array[int] = []
	var seen := {}
	for unit_id in new_ids:
		if seen.has(unit_id):
			continue
		seen[unit_id] = true
		ordered.append(unit_id)
	if _same_membership(ordered):
		return
	unit_ids = ordered
	_invalidate()


func _same_membership(candidate: Array[int]) -> bool:
	if candidate.size() != unit_ids.size():
		return false
	for i in candidate.size():
		if candidate[i] != unit_ids[i]:
			return false
	return true


## The one place a membership change becomes a geometry change.
##
## Both halves matter, and the rebuild is done here rather than left to the caller. A
## formation's files and ranks are derived from how many soldiers it holds, so slots
## that are merely marked dirty are still wrong until somebody remembers to ask - and
## the whole failure this API exists to prevent is a caller not remembering. After this
## returns, [member slots] describes the body that [member unit_ids] describes. There
## is no window in which a formation can be asked its frontage and answer with the
## frontage of a body it is no longer.
##
## The second half is the reformation flag. A body whose membership just changed has
## not yet dressed into the shape that change produced - true of a detachment, of a
## casualty, and of a body being formed for the first time. Without it a formation can
## report itself steady while standing in a shape it has not yet walked into.
func _invalidate() -> void:
	_reforming = true
	_slots_dirty = true
	ensure_slots()


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


## ---------- contact ------------------------------------------------------

## Note that one of this body's soldiers has an enemy within reach. Called from the
## battlefield's per-soldier reach test, which has already made the comparison.
func mark_in_contact() -> void:
	in_contact = true


## Forget last step's contact. Called once per step for every body, after the soldiers
## have been updated, so that the orders read at the top of the next step see the state
## the fight actually ended the previous one in.
func clear_contact() -> void:
	in_contact = false


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


## An axis-aligned box that genuinely contains the body.
##
## Derived from the slot positions rather than from frontage and depth around the
## anchor. Those two are the body's size [i]along its own axes[/i], so a formation at
## forty-five degrees has slots running diagonally and a box built from its width and
## depth would not contain them - the slots would rotate and the rectangle would not,
## which is a lie told by a debug overlay.
##
## Axis-aligned on purpose. An oriented rectangle would be a second geometry system to
## keep correct, and the only job here is to tell the truth about where the soldiers
## are. An empty body reports a zero-size box at its anchor.
func bounds() -> Rect2:
	ensure_slots()
	if slots.is_empty():
		return Rect2(anchor, Vector2.ZERO)
	var min_point := slots[0]
	var max_point := slots[0]
	for slot in slots:
		min_point.x = minf(min_point.x, slot.x)
		min_point.y = minf(min_point.y, slot.y)
		max_point.x = maxf(max_point.x, slot.x)
		max_point.y = maxf(max_point.y, slot.y)
	return Rect2(min_point, max_point - min_point)


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
		"in_contact": in_contact,
		"state": state_name(),
		"order": order,
	}
