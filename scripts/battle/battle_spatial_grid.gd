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
