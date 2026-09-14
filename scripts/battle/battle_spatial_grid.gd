class_name BattleSpatialGrid
extends RefCounted
## Battlefield-local proximity queries.
##
## [b]What this exists to replace.[/b] Step 7's simulator asked, once per soldier per
## tick, "which of every soldier on the battlefield is nearest to me?" and then asked
## the question again for every pair of soldiers while separating overlaps. Both are
## quadratic in the size of the army, and the Step 7 benchmark measured what that costs:
## five thousand soldiers ran at eleven seconds a tick. The answer is not a faster scan
## - it is to stop scanning by asking a smaller question. A soldier wants to know which
## soldiers are near its position, and a grid answers that without looking at the rest
## of the field.
##
## [b]Design.[/b] A uniform grid over the battlefield, one cell every
## [code]battle.spatial_cell_size[/code] world units. Membership is a snapshot rebuilt
## once per simulation tick, which is the choice the brief asked to be made on
## measurement rather than assumption: for a few thousand lightweight data objects, one
## linear pass writing into preallocated arrays is cheaper than maintaining incremental
## state through every position write, and it cannot drift out of sync with the units it
## describes. There is no update path to get wrong because there is no update path.
##
## Buckets are a linked list held in two packed arrays - a head per cell and a next per
## slot - rather than an Array per cell. Nothing is allocated after [method configure]:
## a rebuild is a fill and a walk, and a query writes into a caller-supplied array that
## keeps its capacity between calls.
##
## [b]Determinism.[/b] Nothing here decides anything. Candidates come back in cell order
## and the caller applies its own tie-breaking, so the same units in the same places
## produce the same answers regardless of how the buckets happen to be arranged. See
## D-059 and D-061.
##
## Dead soldiers are never inserted. A casualty stays on its formation's roll so that a
## gap in a line stays a gap (D-048), but it is not a thing anybody can target or bump
## into, and spending query cost on one would be paying twice for the same mistake.

## Cells across the battlefield. Never fewer than one.
var cols: int = 1
var rows: int = 1
var cell_size: float = 4.0
var field_size: Vector2 = Vector2(100.0, 60.0)

## How far a unit may have moved since the last rebuild, in world units. Queries widen
## their cell span by this much so that a unit which has walked since the snapshot is
## still found. Set by the battlefield each tick from its own fastest soldier; without
## it a unit could cross a cell boundary between the rebuild and the query and become
## invisible to a search that should have found it - a spatial cell turning into an
## invisible wall, which is exactly the failure the boundary tests exist to catch.
var query_margin: float = 0.0

## ---------- development-only cell counters (Step 7.6) ----------------------
##
## [b]What a phase clock cannot say.[/b] Step 7.6's question is how a search costs what it
## costs, and the only honest place to count the cells a search walked is here, where they
## are walked. The counters separate the two things a widening search can waste: cells it
## read at all, and cells it read again because a rung of the ladder had already been
## through them.
##
## A single query visits each of its own cells once by construction, so nothing here counts
## repeats inside one query - the repetition the milestone asks about happens *between* the
## rungs of one ladder, and the caller derives it from the boxes it asked for (subtract the
## widest box from the sum of the rungs' reads). The grid reports what it read; the
## simulator says what that means.
##
## Every counter is incremented behind [member dev_profile], which the simulator sets from
## its own profiling flag, so a real battle pays nothing for being explained.
var dev_profile: bool = false
## Cells read by the most recent query, and by every query since the counters were cleared.
var dev_last_read: int = 0
var dev_cells_read: int = 0
## The box span of the most recent query: how many cells it would read if it walked its
## box. Nested boxes make this the size of the union across the rungs of one ladder.
var dev_last_span: int = 0
## Queries that walked their box, and queries that walked the occupied list instead.
var dev_box_walks: int = 0
var dev_occupied_walks: int = 0
## Units distance-tested by the most recent query, and by every query since the counters were
## cleared. The figure that says whether a search is paying to measure soldiers it discards.
var dev_last_candidates: int = 0
var dev_candidates: int = 0

var _head: PackedInt32Array = PackedInt32Array()
var _next: PackedInt32Array = PackedInt32Array()
## Bucket tails, so a rebuild appends to the back of each bucket in one pass without
## allocating anything. Sized and cleared alongside [_head], by the same fill, so there
## is no second invariant to keep true.
##
## This used to be a local array created per rebuild, which quietly contradicted the
## claim that the grid allocates nothing after [method configure] - and a claim that is
## nearly true is worse than one that is not made. See D-070.
var _tails: PackedInt32Array = PackedInt32Array()
var _slot_units: Array[BattleUnit] = []
var _count: int = 0
var _living_count: int = 0
## Every cell that holds at least one unit, in ascending index order. Queries that would
## otherwise walk more empty cells than there are occupied ones walk this instead.
##
## It is kept sorted because the order a query visits cells in is part of its contract:
## the overlap pass resolves pairs in the order it meets them, and that order is what
## makes the spatial pass produce the same positions the exhaustive loop produced. An
## optimisation that reordered the answer would not be an optimisation. See D-066.
var _occupied: PackedInt32Array = PackedInt32Array()
## One byte per cell recording which sides are present in it, so a query that only wants
## one side can skip a whole bucket with a single read rather than walking it and
## discarding every soldier in it. See D-068.
var _cell_mask: PackedByteArray = PackedByteArray()

## ---------- target-search backend selection (Step 7.7) ----------------------
##
## The walk above is the reference, the oracle and the fallback. When the native accelerator
## is built and loaded, a battle may ask it to walk the same cells instead: it returns the
## slot numbers of the candidates it found, and every decision that needs live battle state
## stays here - the exact distance test, the liveness recheck, the tie-break. The cell index
## is a snapshot taken before the soldier loop while soldiers move and die inside that same
## loop, so the native boundary stops exactly where live state begins. See D-095.
enum Backend {
	GDSCRIPT, ## the locked reference walk
	NATIVE, ## the accelerator answers the broadphase, the caller keeps the exact test
	COMPARE, ## reference and NATIVE both run, candidate sets compared
	NATIVE_FULL, ## the accelerator answers the whole query, live state mirrored into it
	COMPARE_FULL, ## reference and NATIVE_FULL both run, answers compared
}
var backend: int = Backend.GDSCRIPT
## The accelerator, or null when the project runs without it. Nothing requires it.
var native_query: Object = null
## Queries the native path answered, and - in COMPARE - how often the two backends
## disagreed. A disagreement is a correctness failure, not a tuning signal.
var native_calls: int = 0
var native_mismatches: int = 0
var native_first_mismatch: Dictionary = {}
var native_candidates: int = 0
var native_usec: int = 0
## The tick the simulator is on, stamped once a tick so a disagreement can be reported with
## the state that produced it rather than as a bare count.
var dev_tick: int = -1
var _native_cells: PackedInt32Array = PackedInt32Array()
var _native_bits: PackedInt32Array = PackedInt32Array()
var _native_ids: PackedInt32Array = PackedInt32Array()
var _native_positions: PackedVector2Array = PackedVector2Array()
## Unit id -> slot, so a soldier that moves or dies can be mirrored without a search.
var _slot_of: PackedInt32Array = PackedInt32Array()
var _synced: bool = false
var _native_capacity: int = 0
var _native_cols: int = 0
var _native_rows: int = 0
var _compare_scratch: Array[BattleUnit] = []


## [b]What Step 7.4 did not add.[/b] The brief anticipated a narrow question - "does this
## nearby region contain any hostile soldier?" - because a cheaper yes/no might have been
## what a staged target check wanted. Measurement said no: the two questions the new
## target path asks are "may I still continue with the enemy I have" and "is that enemy
## within my reach", and both are answered from data the soldier is already holding. The
## one query-shaped decision - whether a lost opponent was lost mid-swing - is a distance
## against a corpse, which costs a subtraction and needs no index at all. Adding an API
## nobody calls would be a wider surface for no gain, so this class is unchanged in
## Step 7.4. See D-083.


## Size the grid for a battlefield. Cheap and idempotent: calling it again with the same
## arguments does nothing, and calling it with different ones reallocates.
func configure(p_field_size: Vector2, p_cell_size: float) -> void:
	var wanted_cell := maxf(0.25, p_cell_size)
	var wanted_cols := maxi(1, int(ceil(p_field_size.x / wanted_cell)))
	var wanted_rows := maxi(1, int(ceil(p_field_size.y / wanted_cell)))
	if wanted_cols == cols and wanted_rows == rows and is_equal_approx(wanted_cell, cell_size):
		return
	field_size = p_field_size
	cell_size = wanted_cell
	cols = wanted_cols
	rows = wanted_rows
	_head.resize(cols * rows)
	_head.fill(-1)
	_tails.resize(cols * rows)
	_tails.fill(-1)
	_cell_mask.resize(cols * rows)
	_cell_mask.fill(0)
	_next.resize(0)
	_slot_units.clear()
	_occupied.resize(0)
	_count = 0
	_living_count = 0
	# The accelerator is sized from the grid it mirrors, so a grid that resizes has to make
	# it re-size on the next rebuild rather than trust a stale shape.
	_native_capacity = 0
	_native_cols = 0
	_native_rows = 0
	# Build the accelerator if the library is loaded. Nothing here fails when it is not: the
	# backend stays GDSCRIPT and the locked walk answers every query, which is the whole
	# point of the fallback. See D-095.
	if native_query == null and ClassDB.class_exists("NativeTargetQuery"):
		native_query = ClassDB.instantiate("NativeTargetQuery")


## Rebuild membership from the living units in [param units], in the order given.
##
## Insertion appends to the back of each bucket rather than the front, so a bucket
## yields its units in the order they appear in [param units].
##
## [b]This method allocates nothing[/b] once [method configure] has been called for the
## battlefield it is being used on, and neither does anything else here. Every array it
## writes to is persistent grid storage sized on first use, and a rebuild is a sequence
## of fills and pointer writes into them. That property is asserted by a test rather
## than left as a comment, because it is the reason the cost of a rebuild is linear in
## the army and independent of how many times it has run. See D-070.
func rebuild(units: Array[BattleUnit]) -> void:
	if _head.size() != cols * rows:
		_head.resize(cols * rows)
	_head.fill(-1)
	if _tails.size() != _head.size():
		_tails.resize(_head.size())
	_tails.fill(-1)
	if _cell_mask.size() != _head.size():
		_cell_mask.resize(_head.size())
	_cell_mask.fill(0)
	_count = 0
	_living_count = 0
	_occupied.resize(0)
	if units.is_empty():
		_next.resize(0)
		_slot_units.clear()
		if _native_wanted():
			_sync_native()
		return
	if _next.size() != units.size():
		_next.resize(units.size())
	if _slot_units.size() != units.size():
		_slot_units.resize(units.size())

	for unit in units:
		if not unit.is_alive():
			continue
		var cell := _cell_index_of(unit.position)
		var slot := _count
		_slot_units[slot] = unit
		_next[slot] = -1
		if _native_wanted():
			# The accelerator is handed the cell, id, side and position of each living unit,
			# in slot order - which is the order its own slot numbers must agree with. The
			# positions are the snapshot's; the battle's own mutation points keep them true
			# afterwards, and COMPARE_FULL is what proves they do.
			if _native_cells.size() <= slot:
				_native_cells.resize(slot + 1)
				_native_bits.resize(slot + 1)
				_native_ids.resize(slot + 1)
				_native_positions.resize(slot + 1)
			_native_cells[slot] = cell
			_native_bits[slot] = _side_bit_of(unit.side)
			_native_ids[slot] = unit.id
			_native_positions[slot] = unit.position
			if _slot_of.size() <= unit.id:
				_slot_of.resize(unit.id + 1)
			_slot_of[unit.id] = slot
		_cell_mask[cell] |= _side_bit_of(unit.side)
		if _tails[cell] < 0:
			_head[cell] = slot
			_occupied.append(cell)
		else:
			_next[_tails[cell]] = slot
		_tails[cell] = slot
		_count += 1
		_living_count += 1
	if _occupied.size() > 1:
		_occupied.sort()
	if _native_wanted():
		_sync_native()


## How many living units are indexed. The grid holds nothing else.
func size() -> int:
	return _living_count


func is_empty() -> bool:
	return _living_count == 0


## Every indexed unit within [param radius] of [param position], written into
## [param out] which is cleared first and keeps its capacity between calls.
##
## [param side] filters by side when it is a real side string; pass an empty string for
## every unit. Units are considered from their position at the last rebuild, widened by
## [member query_margin], but the caller is expected to apply its own exact distance
## test - this decides only who is worth asking about.
##
## [b]The liveness check is not redundant with the rebuild.[/b] The index is a snapshot
## taken at the start of a tick, and soldiers die during that same tick's soldier loop.
## A soldier processed late in the loop would otherwise be handed a comrade who fell
## earlier in the same tick and could target, chase or bump into a corpse - which is
## both a behavioural change against the scan this replaced, which checked liveness on
## every candidate, and a violation of the standing rule that dead soldiers take no part
## in proximity queries. Indexing the living is not the same as answering about the
## living; this is the second half. See D-063.
func collect_within(position: Vector2, radius: float, side: String, out: Array[BattleUnit]) -> void:
	out.clear()
	if _living_count == 0 or radius <= 0.0:
		return
	if _native_wanted():
		if backend == Backend.NATIVE:
			_collect_native(position, radius, side, out)
		else:
			_collect_compare(position, radius, side, out)
		return
	_collect_reference(position, radius, side, out)


## The locked walk. Kept whole and callable on its own, because it is the reference the
## native path is measured against and the fallback the project runs on when the
## accelerator is not there.
func _collect_reference(position: Vector2, radius: float, side: String, out: Array[BattleUnit]) -> void:
	var reach := radius + query_margin
	var min_col := _clamp_col(int(floor((position.x - reach) / cell_size)))
	var max_col := _clamp_col(int(floor((position.x + reach) / cell_size)))
	var min_row := _clamp_row(int(floor((position.y - reach) / cell_size)))
	var max_row := _clamp_row(int(floor((position.y + reach) / cell_size)))
	var span := (max_col - min_col + 1) * (max_row - min_row + 1)
	var wanted := _side_bit_of(side) if not side.is_empty() else 0
	if dev_profile:
		dev_last_span = span
		dev_last_read = 0

	# Two ways to walk the same set of cells, and whichever visits fewer of them wins.
	# When a search covers most of a battlefield that is mostly empty - which is exactly
	# what the widest rung of a target search does on a sparse field - stepping through
	# every cell in the box means reading hundreds of empty bucket heads to find a
	# handful of soldiers. Walking the occupied cells instead costs one pass over the
	# soldiers who exist. Both visit the same cells, in the same order, so this changes
	# the cost and nothing else.
	if span > _occupied.size():
		if dev_profile:
			dev_occupied_walks += 1
		for cell in _occupied:
			if wanted != 0 and (_cell_mask[cell] & wanted) == 0:
				continue
			var row := cell / cols
			var col := cell - row * cols
			if col < min_col or col > max_col or row < min_row or row > max_row:
				continue
			if dev_profile:
				dev_last_read += 1
				dev_cells_read += 1
			var slot := _head[cell]
			while slot >= 0:
				var unit := _slot_units[slot]
				if unit.alive and (side.is_empty() or unit.side == side):
					out.append(unit)
				slot = _next[slot]
		return

	if dev_profile:
		# The box branch reads every cell in the box, including the ones its own side
		# mask skips: the mask is a read. Counted arithmetically rather than per cell,
		# because a counter inside this loop would cost as much as the loop.
		dev_box_walks += 1
		dev_last_read = span
		dev_cells_read += span
	for row in range(min_row, max_row + 1):
		var base := row * cols
		for col in range(min_col, max_col + 1):
			if wanted != 0 and (_cell_mask[base + col] & wanted) == 0:
				continue
			var slot := _head[base + col]
			while slot >= 0:
				var unit := _slot_units[slot]
				if unit.alive and (side.is_empty() or unit.side == side):
					out.append(unit)
				slot = _next[slot]


## The same query restricted to units of the other side from [param side]. A separate
## method rather than a parameter so the common case reads as what it is.
func collect_enemies_within(position: Vector2, radius: float, side: String, out: Array[BattleUnit]) -> void:
	collect_within(position, radius, enemy_side_of(side), out)


static func enemy_side_of(side: String) -> String:
	return BattleContext.SIDE_ENEMY if side == BattleContext.SIDE_PLAYER else BattleContext.SIDE_PLAYER


## Is the accelerator to be consulted at all? False for the locked backend, and false when
## no library is loaded - so a build without the accelerator pays one boolean per rebuild
## and nothing per query.
func _native_wanted() -> bool:
	return native_query != null and backend != Backend.GDSCRIPT


## Hand the accelerator this tick's snapshot. The cell index it mirrors is the one already
## built above, so a synced battle does the cell arithmetic once, not twice.
func _sync_native() -> void:
	if _native_cols != cols or _native_rows != rows or _native_capacity < _count:
		var capacity := maxi(_count, 64)
		native_query.call("setup", cols, rows, cell_size, 0.0, capacity)
		_native_cols = cols
		_native_rows = rows
		_native_capacity = capacity
	_native_cells.resize(_count)
	_native_bits.resize(_count)
	_native_ids.resize(_count)
	_native_positions.resize(_count)
	native_query.call("rebuild", _native_cells, _native_ids, _native_bits, _native_positions)
	# The margin widens the walk; the radius stays the promise the exact test keeps. The
	# kernel applies it itself so both walkers reach the same ground. See D-065.
	native_query.call("set_margin", query_margin)
	_synced = true


## Is the accelerator holding this tick's index, and is a query allowed to reach it?
func can_answer_natively() -> bool:
	return native_query != null and _synced and backend != Backend.GDSCRIPT


## A soldier moved. Its cell is deliberately *not* updated: the index is a snapshot of where
## everyone stood at the rebuild, and only the position the exact test reads is live.
func native_moved(unit: BattleUnit) -> void:
	if not can_answer_natively() or unit.id >= _slot_of.size():
		return
	native_query.call("update_position", _slot_of[unit.id], unit.position.x, unit.position.y)


## A soldier died. The reference rechecks liveness on every candidate it walks, so the mirror
## has to as well - a death that is not mirrored here is a wrong answer later in the tick.
func native_died(unit: BattleUnit) -> void:
	if not can_answer_natively() or unit.id >= _slot_of.size():
		return
	native_query.call("mark_dead", _slot_of[unit.id])


## The whole query, answered in the accelerator: cells, side, liveness, the exact distance and
## the tie-break, with the live state mirrored in by the two hooks above.
func native_nearest(unit: BattleUnit, side: String, radius: float) -> BattleUnit:
	var wanted := _side_bit_of(side) if not side.is_empty() else 0
	var started := Time.get_ticks_usec() if dev_profile else 0
	var slot: int = native_query.call("collect_nearest", unit.position.x, unit.position.y, radius, wanted)
	native_calls += 1
	if dev_profile:
		native_usec += Time.get_ticks_usec() - started
		# The shape counters are read from the same fields the reference walk writes, so the
		# SEARCH SHAPE table means the same thing whichever backend answered.
		dev_last_read = native_query.call("last_cells_read")
		dev_last_span = dev_last_read
		native_candidates += native_query.call("last_candidates")
	if slot < 0:
		return null
	return _slot_units[slot]


## How many candidates the accelerator measured in its last search, for the simulator's own
## shape counters.
func native_last_candidates() -> int:
	if native_query == null:
		return 0
	return native_query.call("last_candidates")


## Record one ladder rung where the two full implementations disagreed. The reference stays
## authoritative; this only counts and keeps the first disagreement whole.
func note_answer(unit: BattleUnit, radius: float, reference: BattleUnit, native: BattleUnit) -> void:
	var reference_id := -1 if reference == null else reference.id
	var native_id := -1 if native == null else native.id
	if reference_id == native_id:
		return
	native_mismatches += 1
	if native_first_mismatch.is_empty():
		native_first_mismatch = {
			"tick": dev_tick,
			"asker": unit.id,
			"position": unit.position,
			"radius": radius,
			"reference_id": reference_id,
			"native_id": native_id,
			"candidates": native_candidates,
		}


## The accelerator's answer, filtered exactly as the reference filters while it walks.
##
## The accelerator returns candidate slot numbers, not units, and it cannot know that a
## soldier died after the index was built and before its own turn came round. The reference
## rechecks liveness and side per candidate, so this does too - which is what makes the
## collected set identical rather than merely similar, and why the order it arrives in
## cannot matter: the exact test below keeps the nearest and breaks ties by unit id.
func _collect_native(position: Vector2, radius: float, side: String, out: Array[BattleUnit]) -> void:
	var wanted := _side_bit_of(side) if not side.is_empty() else 0
	var started := Time.get_ticks_usec() if dev_profile else 0
	# The margin the reference adds is added here, so the accelerator needs no margin of its
	# own and the reach it walks is the same reach.
	var count: int = native_query.call("collect", position.x, position.y, radius, wanted)
	native_calls += 1
	var buffer: PackedInt32Array = native_query.call("candidates")
	for i in count:
		var unit := _slot_units[buffer[i]]
		if unit.alive and (side.is_empty() or unit.side == side):
			out.append(unit)
	if dev_profile:
		native_usec += Time.get_ticks_usec() - started
		native_candidates += out.size()


## Both backends, one query. The reference fills [param out] and remains authoritative; the
## accelerator's answer is collected beside it and the two are compared as sets of unit ids,
## because the scan above them is indifferent to the order it is handed candidates in. A
## disagreement is reported whole - tick, query, radius, both counts and the ids that
## differ - so it can be reproduced rather than merely counted.
func _collect_compare(position: Vector2, radius: float, side: String, out: Array[BattleUnit]) -> void:
	_collect_reference(position, radius, side, out)
	_compare_scratch.clear()
	_collect_native(position, radius, side, _compare_scratch)
	# Compared as sorted id lists rather than by searching one list for each member of the
	# other: a per-candidate scan would make this mode quadratic, and the mode exists to be
	# trusted, not to be slow on purpose.
	var reference_ids: PackedInt32Array = PackedInt32Array()
	for unit in out:
		reference_ids.append(unit.id)
	var native_ids: PackedInt32Array = PackedInt32Array()
	for unit in _compare_scratch:
		native_ids.append(unit.id)
	reference_ids.sort()
	native_ids.sort()
	if reference_ids == native_ids:
		return
	native_mismatches += 1
	if native_first_mismatch.is_empty():
		native_first_mismatch = {
			"tick": dev_tick,
			"position": position,
			"radius": radius,
			"side": side,
			"reference_count": reference_ids.size(),
			"native_count": native_ids.size(),
			"reference_ids": reference_ids.slice(0, 12),
			"native_ids": native_ids.slice(0, 12),
		}


## What the backend did, for the benchmark and the suite. Counters only; nothing here
## changes behaviour.
func backend_report() -> Dictionary:
	return {
		"backend": backend,
		"native_calls": native_calls,
		"native_mismatches": native_mismatches,
		"first_mismatch": native_first_mismatch.duplicate(),
		"native_candidates": native_candidates,
		"native_usec": native_usec,
	}


## Cell index for a world position. Exposed for tests and tooling; the simulation has no
## reason to care which cell anything is in.
func cell_index_of(position: Vector2) -> int:
	return _cell_index_of(position)


## Every living unit in one cell, for tooling. Allocates, so it is not for hot loops.
func units_in_cell(col: int, row: int) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	if col < 0 or col >= cols or row < 0 or row >= rows:
		return out
	var slot := _head[row * cols + col]
	while slot >= 0:
		out.append(_slot_units[slot])
		slot = _next[slot]
	return out


## The occupied cells and how many units each holds, for tooling and for the benchmark's
## density reporting. Allocates a dictionary; not for hot loops.
func occupancy() -> Dictionary:
	var counts := {}
	for cell in _head.size():
		var slot := _head[cell]
		var count := 0
		while slot >= 0:
			count += 1
			slot = _next[slot]
		if count > 0:
			counts[cell] = count
	return counts


## Units in the fullest single cell. This is the number that decides whether a uniform
## grid is still doing its job: a battlefield where every soldier stands in one cell is
## a battlefield the grid cannot subdivide, and local queries degrade toward the scan
## they replaced. Reported by the benchmark rather than assumed. See D-060.
func busiest_cell() -> int:
	var worst := 0
	for cell in _head.size():
		var slot := _head[cell]
		var count := 0
		while slot >= 0:
			count += 1
			slot = _next[slot]
		worst = maxi(worst, count)
	return worst


## Which bit of [member _cell_mask] a side owns. Anything that is not the player is the
## enemy, which is the same rule the simulator uses to decide who fights whom.
static func _side_bit_of(side: String) -> int:
	return 1 if side == BattleContext.SIDE_PLAYER else 2


func _cell_index_of(position: Vector2) -> int:
	return _clamp_row(int(floor(position.y / cell_size))) * cols + _clamp_col(int(floor(position.x / cell_size)))


func _clamp_col(col: int) -> int:
	return clampi(col, 0, cols - 1)


func _clamp_row(row: int) -> int:
	return clampi(row, 0, rows - 1)
