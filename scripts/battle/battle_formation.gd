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

## The deepest a body's ranks may stand before it widens instead. A real line was eight to ten
## ranks; this is looser than that because a body of three thousand on a field a thousand units
## wide has to fit across as well as back, and twenty is the depth at which it does. Below this the
## definition's own frontage is kept exactly as it was.
const MAX_RANKS := 20

var id: String = ""
var side: String = BattleContext.SIDE_PLAYER
var type_id: String = "line"

## The formation's centre.
var anchor: Vector2 = Vector2.ZERO
## The step this body took this tick, when it took a straight one. The group's own arithmetic:
## its soldiers who are standing in their places go where the group goes, without each deriving the
## same displacement from a slot lookup, a distance, a normalise and a terrain lookup. Zero when the
## body is turning, reforming or standing still, in which case every soldier dresses himself exactly
## as he always did. See D-108.
var anchor_step: Vector2 = Vector2.ZERO
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

## ---------- transient battle summary (Step 7.5) ---------------------------
##
## [b]What the body knows about itself, calculated once a tick.[/b] Everything above this
## line is the body's own intent - where it is, where it is going, who is in it. Everything
## here is a reading of the battlefield: how many of its soldiers are still standing, where
## they actually are, and which hostile body this one is watching.
##
## It exists because the alternative was every soldier rediscovering it. Formation focus
## used to be one pass over the whole army per body per tick, which is quadratic once an
## army is deployed as many bodies, and the measurement said so: 881 ms a tick at twenty
## thousand soldiers (D-088). A body answering a question about itself once, and its
## soldiers reading the answer, is the same information for a fraction of the work.
##
## [b]It is battle-transient and it is not state.[/b] Nothing here is saved, nothing here
## is authoritative, and nothing outside the simulation reads it. It is recomputed from the
## soldiers themselves every tick by [BattleSimulator], so it cannot go stale: there is no
## update path to forget to call, only a rebuild that either happened this tick or did not.
## It is deliberately absent from [method to_dict] for that reason - a summary serialised
## into a save would be a second source of truth about where the soldiers are.
##
## Living members only. A body of corpses has no centre worth steering toward, and the
## nearest-enemy question is asked about bodies that can still be reached - so the dead are
## excluded as the pass accumulates rather than filtered out again by every reader.
var living_count: int = 0
## The centroid of the living members, which is where the body actually is as opposed to
## where it was told to be. Zero when nobody is left.
var centre: Vector2 = Vector2.ZERO
## An axis-aligned box around the living members. Its purpose is not display: the distance
## from a point to this box is a lower bound on the distance from that point to any soldier
## in the body, which is what lets focus selection rule a body out without looking inside
## it. A rect rather than a radius because a line is wide and shallow and a circle around
## its centre would claim ground it does not hold.
var bounds_min: Vector2 = Vector2.ZERO
var bounds_max: Vector2 = Vector2.ZERO
## Whether [member living_count], [member centre] and the bounds describe this tick.
var summary_ready: bool = false

## The hostile body this one is watching, and how far away the soldier it is watching is.
##
## [b]A body, not a soldier, is the thing that is chosen.[/b] The nearest hostile soldier to a
## body's centre belongs to the hostile body nearest to it, so choosing the body first and its
## nearest member second is the same answer for a comparison between bodies rather than
## between twenty thousand soldiers. See D-089.
##
## [b]The chosen soldier is referred to by nothing here.[/b] These are an index and two
## numbers; the reference to the soldier itself lives in [BattleSimulator], because a soldier
## already points at its own body and a body pointing back at a soldier would be a reference
## cycle. Godot's reference counting has no collector to break one, so a battle that built it
## would leak every body and every soldier in it. A body knows [i]which[/i] body it is watching
## and how far away the fighting is; the battlefield knows which soldier that is.
var focus_body_index: int = -1
## How far the watched soldier is from [member anchor], or INF when there is nobody to be
## pointed at. Read by [method BattleSimulator._focus_look_finds_nobody], which uses it to
## prove that a look could not have found anybody.
var focus_distance: float = INF
## The tick this body's focus was found to be nobody at all, which is the one repair that
## must not be repeated. Nothing comes back to life inside a tick, so a body that has already
## been told there is nobody to be pointed at is not asked again until the next one - which
## is what keeps a wiped-out enemy from becoming a focus selection per soldier (D-090).
var focus_null_tick: int = -1
## The [member membership_version] this body's focus was worked out against. A body whose
## membership has changed since holds an answer about a shape it no longer has, and this is
## what says so - one integer comparison in place of a stale-flag that somebody has to
## remember to set. See [method is_focus_current].
var focus_version: int = -1

## Which body this is in [member BattleSimulator.formations], and the only way the focus
## layer addresses one: a position in a list rather than a name, because a summary is looked
## up per soldier and per body and a string key would be hashed every time. Set once, by
## [method BattleSimulator.add_formation], and never changed - bodies are added to a battle
## and never removed from it.
var index: int = -1
## Bumped whenever membership changes. The summary and the focus are both readings of a
## particular set of soldiers, so both are invalidated by the same event, in the same place.
var membership_version: int = 0

## Whether any soldier of this body is currently within reach of an enemy.
##
## Contact belongs to a body, not to a side. A wing that has not reached the enemy is
## not "in contact" merely because the centre is fighting, and a body's own orders are
## judged against its own state. Maintained by the battlefield inside the per-soldier
## reach test it already performs, so it costs a boolean rather than a search, and
## cleared at the end of each step. See D-056.
var in_contact: bool = false

## ---------- formation-driven engagement (D-105) ---------------------------
##
## A body knows which enemy body it is fighting, and its soldiers only look for opponents of
## their own where a fight is actually happening. Everything below is derived from geometry the
## battle already computes: the body's own box, its own reach, and the enemy's. No new queries.

## Nowhere to go: no living enemy body left to face.
const ENGAGEMENT_NONE := 0
## A target exists and the two bodies have not met.
const ENGAGEMENT_APPROACHING := 1
## A target exists and the two bodies are within a weapon's reach of each other, but nobody on
## either side has actually struck yet.
const ENGAGEMENT_NEAR_CONTACT := 2
## Fighting: at least one soldier of this body is in reach of an enemy this tick.
const ENGAGEMENT_IN_CONTACT := 3
## Was fighting, and the enemy is still alive and nearby, but the two bodies have come apart
## again. Soldiers keep whatever opponent they had; nobody looks for a new one until the fight
## returns or the state lapses back to APPROACHING.
const ENGAGEMENT_DISENGAGING := 4

## The enemy body this one is facing. Chosen once per body per cadence, deterministically, and
## overridable only by an explicit order. Empty when there is nobody left to fight.
var target_formation_id: String = ""
## Set when the target above came from an explicit order rather than from choosing, so the
## automatic choice leaves it alone until the body it names is gone. See [method
## BattleSimulator.set_engagement_target].
var target_explicit: bool = false
## One of the ENGAGEMENT_* states. Never read by a soldier's movement; it is what the gate and
## the development view ask.
var engagement: int = ENGAGEMENT_NONE
## Tick this body's target and state were last worked out, so the work happens on a cadence
## rather than every tick. See [constant BattleSimulator.ENGAGEMENT_RECHECK_TICKS].
var engagement_tick: int = -1000000
## The furthest reach any living soldier in this body has, accumulated by the summary pass. The
## contact band is derived from this rather than from a hardcoded sword: a body of archers
## promotes its soldiers from further off than a body of spearmen. See D-105.
var max_range: float = 0.0
## How far a soldier of this body may stand from the *enemy* body's box and still be allowed to
## look for its own opponent: this body's furthest reach, plus the enemy's, plus slack for one
## rank and a step of movement. A soldier inside it is in the fight or about to be.
var contact_band: float = 0.0
## The enemy bodies close enough that soldiers of this body may need to look at them - normally
## one, more when this body is being taken in the flank or from behind. Rebuilt with the state
## above, and iterated by the gate, so the gate is a handful of box distances rather than a
## walk of the battlefield.
var nearby_enemy_ids: Array[String] = []
## Tick this body was last in contact, for the DISENGAGING hysteresis.
var last_contact_tick: int = -1000000

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
	# A body whose membership has just changed has no defensible reading of the
	# battlefield: its living count, its centre, its bounds and its focus all described the
	# body it was. Bumping the version is what discards them - the summary reports itself
	# not ready and the focus stops matching, in one integer, so a caller cannot forget to
	# invalidate one of the two. It is the same principle as routing membership through
	# this method in the first place: the invariant is not "remember to call it" but "there
	# is no way to change membership without doing so" (D-054).
	membership_version += 1
	summary_ready = false
	living_count = 0
	centre = Vector2.ZERO
	bounds_min = Vector2.ZERO
	bounds_max = Vector2.ZERO
	focus_body_index = -1
	focus_distance = INF
	focus_null_tick = -1
	ensure_slots()


## ---------- transient battle summary -------------------------------------

## Start rebuilding the summary. One of these per body per tick, from the simulator.
func begin_summary() -> void:
	living_count = 0
	centre = Vector2.ZERO
	bounds_min = Vector2.ZERO
	bounds_max = Vector2.ZERO
	max_range = 0.0
	summary_ready = false


## Write down the summary the simulator has just accumulated.
##
## [b]One write per body per tick rather than one per soldier.[/b] The pass that counts a
## body's soldiers keeps its running total in local variables and hands the answer over once,
## because writing a [Vector2]'s components onto an object is a read, a modify and a write
## each time in GDScript - and the pass does it once per soldier, which on the fixed-area
## torture test is ten thousand times a body per tick. Measured, moving the accumulation out
## of here and into the caller was worth a fifth of the focus phase at twenty thousand
## soldiers.
func write_summary(
	count: int,
	sum: Vector2,
	low: Vector2,
	high: Vector2,
	reach: float = 0.0
) -> void:
	living_count = count
	centre = Vector2.ZERO if count == 0 else sum / float(count)
	bounds_min = low
	bounds_max = high
	max_range = reach
	summary_ready = true


## Whether this body has anybody left to steer. The same question
## [method has_living_units] answers by walking the roll, answered from the summary that has
## already been built - which is what lets focus selection rule a body out without looking
## inside it. False before the first summary is built, and false for a body of corpses.
func is_living() -> bool:
	return summary_ready and living_count > 0


## Whether the focus this body holds describes the body it is now. False after a membership
## change and true again once the next tick has worked out a fresh answer, which is what
## makes "no stale focus" a question with an answer rather than a hope.
func is_focus_current() -> bool:
	return focus_version == membership_version


## Squared distance from a point to this body's box, which is a lower bound on the squared
## distance from that point to any living soldier in it.
##
## Zero when the point is inside the box, and exact when it is outside: the nearest member
## is at least as far away as the nearest edge, because every member is inside the box. A
## bound, not an estimate - focus selection uses it to prove a body cannot hold the nearest
## enemy rather than to guess where that enemy is.
func bounds_distance_squared(point: Vector2) -> float:
	var dx := maxf(maxf(bounds_min.x - point.x, point.x - bounds_max.x), 0.0)
	var dy := maxf(maxf(bounds_min.y - point.y, point.y - bounds_max.y), 0.0)
	return dx * dx + dy * dy


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


## Whether this body's soldiers may press forward this step, decided once for the body rather than once
## per soldier. The three things it rests on - the order, and the moving, turning and reforming
## predicates - cannot change while the soldiers dress, because the only call the per-soldier loop makes
## into a body is [method mark_in_contact]. Contact itself is deliberately [b]not[/b] folded in here: it
## is set by soldiers part way through their own loop, so it is read live, per soldier, exactly as it
## always was. Set by the battlefield once a step, after the bodies move and before the soldiers dress.
var press_forward_open: bool = false


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
	# The definition's frontage is the shape a body wants, not a cap on how many men it may hold.
	# Ten files is square for a hundred men and a thread for three thousand - a body of three
	# thousand laid out that way is a column eight hundred units long standing where a formation
	# should be, which is what put soldiers outside their own battlefield. Depth is what stays
	# bounded, so a body too deep for its file count widens until it is not.
	if count > _max_files and rank_count > MAX_RANKS:
		file_count = int(ceil(float(count) / float(MAX_RANKS)))
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
			if step > 0.0:
				var before := anchor
				anchor += to_target.normalized() * step
				if anchor == before:
					# [b]A step too fine for the centre to express is an arrival.[/b] The
					# centre is stored in single precision, so near a coordinate of a hundred
					# the smallest change it can hold is about a hundred-thousandth of a unit -
					# and a body asked to close the last few millionths of a unit onto its
					# station cannot move at all. Left alone it then reports itself [i]moving[/i]
					# for the rest of the battle while standing perfectly still, and
					# [method is_moving] is what decides whether its soldiers may press
					# forward to restart a fight that has stopped: a body stuck one rounding
					# error short of its station can never let them. Measured: a 300 v 300
					# battle froze for fifteen thousand ticks with every body reporting
					# `moving` at a distance of 0.050003 units. Arriving moves the centre by
					# less than the arrive radius, so nothing is teleported. See D-102.
					anchor = target_anchor
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
