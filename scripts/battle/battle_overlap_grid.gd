class_name BattleOverlapGrid
extends RefCounted
## The separation pass's own proximity index, sized for bodies rather than for eyesight.
##
## [b]Why this is not the targeting grid.[/b] [BattleSpatialGrid] answers "who is near
## me" for target selection, where the question is asked a handful of cells wide and the
## answer wants to be generous. The separation pass asks a different question - "who is
## standing inside me" - about a much smaller distance: separation happens at
## [code]separation_radius * SEPARATION_FACTOR[/code], currently 1.35 world units, where
## a target search starts at 8. Reusing one grid for both meant the pass searched a box
## several times larger than the distance it cared about and threw almost all of the
## answer away.
##
## Measured before this existed, on the fixed-area torture benchmark at five thousand
## soldiers: the pass was handed [b]95.6 candidates per soldier[/b] and found 226 pairs
## army-wide that were actually touching. A twenty-one-hundred-to-one ratio is not a
## tuning problem, it is the wrong structure for the job.
##
## [b]What it is.[/b] A uniform grid, one cell per [code]battle.overlap_cell_size[/code]
## world units, built from the same pieces as the targeting grid - packed arrays, no
## allocation after [method configure], rebuilt from scratch each pass. What differs is
## how pairs are produced: instead of every soldier asking for its neighbours, each
## occupied cell pairs itself with the half-neighbourhood of cells in front of it, so
## every physical pair is generated exactly once and the per-soldier query - and its
## result array - disappears entirely.
##
## [b]Pushes are accumulated rather than applied.[/b] Step 7.2 pushed each overlapping
## pair apart the moment it was found, which makes the outcome depend on the order pairs
## are visited in: the second pair of a cluster is measured against positions the first
## pair already moved. Here every push is summed into a per-soldier displacement and the
## whole field is moved once, at the end. Order dependence does not have to be preserved
## because it does not exist - any enumeration order produces the same positions - which
## is a stronger guarantee than carefully reproducing one. See D-074.
##
## [b]What changed as a result, stated plainly.[/b] This is not the same relaxation as
## Step 7.2's. A sequential pass resolves a cluster harder in one tick than a simultaneous
## one, because each soldier sees corrections already made to its neighbours; a
## simultaneous pass has everyone react to where everyone stood. Over several ticks the
## two reach the same separated arrangement, and soldiers are separated at least as fast
## as they can walk into each other, which is the rate that matters. The physical
## invariants are tested directly against a brute-force reference instead of the
## positions being compared, and the intentional difference is documented in Part 9's
## terms.

## Cell size in world units. Set from [code]battle.overlap_cell_size[/code].
var cell_size: float = 0.9
var cols: int = 1
var rows: int = 1
var field_size: Vector2 = Vector2(100.0, 60.0)

## How many cells in each direction a cell is paired with. Derived rather than
## configured, because it is a consequence of the geometry: a pair closer than the
## separation distance cannot be more than [code]ceil(minimum / cell_size)[/code] cells
## apart on either axis. Deriving it means a change to either number cannot silently
## produce a search that misses pairs.
var reach_cells: int = 2

## The furthest one pass may displace a soldier. A soldier buried in a crowd accumulates
## a push from every body it is inside, and without a ceiling that sum grows with the
## crowd until a pile flings somebody across the field. One separation distance per tick
## is more than a single separation needs, so the cap cannot slow an ordinary push down,
## and it turns the pass from "usually stable" into "bounded by construction".
var max_push: float = 1.35

## Development-only counters, off by default and free when off.
var stats_enabled: bool = false
var stat_cell_pairs: int = 0         ## cell pairs considered
var stat_cell_pairs_skipped: int = 0 ## cell pairs a formation's own spacing already covers
var stat_pairs: int = 0              ## soldier pairs measured
var stat_touching: int = 0           ## pairs inside the separation distance
var stat_clamped: int = 0            ## soldiers whose displacement hit the ceiling
var stat_displacement_max: float = 0.0
var _settled_units: int = 0     ## soldiers standing on their assigned place
var _interior_cells: int = 0    ## cells whose occupants are one settled body

var _head: PackedInt32Array = PackedInt32Array()
var _next: PackedInt32Array = PackedInt32Array()
var _tails: PackedInt32Array = PackedInt32Array()
var _units: Array[BattleUnit] = []
var _count: int = 0
## Occupied cells in ascending index order, so the pass walks cells deterministically and
## never visits an empty one.
var _occupied: PackedInt32Array = PackedInt32Array()
## Displacement accumulators, indexed by slot, so the inner loop is two array writes.
var _push_x: PackedFloat32Array = PackedFloat32Array()

## ---------- development-only phase clocks (Step 7.8) ------------------------
##
## Where the overlap phase's time goes, in five coarse blocks. Deliberately not one clock per
## pair or per cell: a clock inside the hot loops would be measuring the profiler. A few
## clock reads per pass is the whole budget.
##
## [br]- [member dev_usec_build] - clearing, the roster walk, alive filtering, cell
##   calculation, insertion, and the settled test;
## [br]- [member dev_usec_same_cell] - the intra-cell pair loop;
## [br]- [member dev_usec_neighbour] - the neighbour-cell loop: the settled-skip proof, the
##   cell arithmetic and the pair loops it does take;
## [br]- [member dev_usec_apply] - the apply and clamp pass;
## [br]- [member dev_usec_total] - the whole of [method resolve] as this class measured it,
##   so the four parts can be checked against the whole instead of being the whole.
##
## The exact pair work - the squared-distance test and, for a pair that is touching, the
## push arithmetic - lives inside the two traversal clocks, because that is where it runs.
## It is separated by measurement rather than by a sixth clock: [member dry_level] runs the
## same pass over the same field with the arithmetic left out, and the difference is the
## arithmetic's cost. See the Step 7.8 report.
##
## [b]Correction.[/b] This class previously declared [code]dev_usec_pairs[/code], which
## nothing ever assigned: the pair-loop timing it was meant to hold did not exist and the
## report printed a zero that looked like "no work" rather than "not measured". It is gone,
## replaced by the five clocks above, and the report no longer has a column that can only
## be zero.
var dev_usec_build: int = 0
var dev_usec_same_cell: int = 0
var dev_usec_neighbour: int = 0
var dev_usec_apply: int = 0
var dev_usec_total: int = 0
var dev_coincident: int = 0
var dev_moved: int = 0
var dev_displacement_sum: float = 0.0
var dev_cell_pop_max: int = 0
var dev_pop_p50: int = 0
var dev_pop_p95: int = 0
var dev_pop_p99: int = 0
var _push_y: PackedFloat32Array = PackedFloat32Array()

## Why the settled-cell proof did or did not fire, counted for every neighbour-cell pair
## that reached it. The reasons are mutually exclusive by construction: the first test that
## fails is the one counted, and a pair that passes every test is counted as proved. This is
## what makes "the skip never fires" answerable with a number rather than a guess.
var dev_skip_not_settled_a: int = 0
var dev_skip_not_settled_b: int = 0
var dev_skip_no_body: int = 0
var dev_skip_other_body: int = 0
var dev_skip_spacing: int = 0
var dev_skip_proved: int = 0
## Cells whose occupants were not all one settled body. The interior count beside it is the
## other half of the same question. Development only.
var dev_mixed_cells: int = 0

## Development-only: how far each body's soldiers stood from the places it gave them,
## accumulated per body as a distance histogram in half-unit buckets, so a percentile costs
## a bucket count rather than a sort. Indexed by [member BattleFormation.index].
const DEV_BUCKETS := 24
const DEV_BUCKET_SIZE := 0.5
var dev_body_living: PackedInt32Array = PackedInt32Array()
var dev_body_settled: PackedInt32Array = PackedInt32Array()
var dev_body_distance_sum: PackedFloat64Array = PackedFloat64Array()
var dev_body_hist: PackedInt32Array = PackedInt32Array()

## Development-only: run the pass with its pair arithmetic left out, so that the arithmetic's
## own cost can be measured by subtraction against a pass over the identical field rather
## than guessed at. 0 is the real pass; 1 keeps the squared-distance test but computes no
## push; 2 enumerates pairs and computes nothing. Only reachable while [member stats_enabled]
## is on - a real battle cannot pay for it - and a dry pass never moves a soldier.
var dry_level: int = 0

## Per cell: whether everyone in it is standing where its formation put it, and if so
## which formation. A cell that is a settled body's interior can be left alone against
## another cell of the same settled body, because the two soldiers closest across those
## cells are one slot apart and a slot is a formation spacing wide. See
## [method _cells_already_spaced].
const CELL_UNKNOWN := 0
const CELL_SETTLED := 1
const CELL_MIXED := 2
var _cell_state: PackedByteArray = PackedByteArray()
var _cell_body: Array = []

## The forward half of the square neighbourhood, as the row and column steps it is made
## of. Half, because the other half is this half seen from the other cell, which is what
## makes every physical pair fall out exactly once with no id comparison.
##
## Two arrays of small numbers rather than one array of encoded pairs: the inner loop runs
## once per occupied cell per offset, and decoding a packed pair there cost four integer
## divisions for every one of them. That was most of the pass.
var _offset_dx: PackedInt32Array = PackedInt32Array()
var _offset_dy: PackedInt32Array = PackedInt32Array()
var _offsets_reach: int = 0


func configure(p_field_size: Vector2, p_cell_size: float) -> void:
	var wanted_cell := maxf(0.05, p_cell_size)
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
	_cell_state.resize(cols * rows)
	_cell_state.fill(CELL_UNKNOWN)
	_cell_body.resize(cols * rows)
	_cell_body.fill(null)
	_next.resize(0)
	_units.clear()
	_occupied.resize(0)
	_push_x.resize(0)
	_push_y.resize(0)
	_count = 0


## Separate every pair of soldiers standing closer together than [param minimum].
##
## [param settle_epsilon] is how close to its assigned place a soldier has to be before
## the formation that placed it is trusted to be keeping it off its own neighbours. Pass
## zero or less to switch that optimisation off.
func resolve(units: Array[BattleUnit], minimum: float, settle_epsilon: float = 0.0) -> void:
	if units.is_empty() or minimum <= 0.0:
		# A pass with nothing to do still reports having done nothing: a report left holding
		# the previous pass's numbers would be read as this pass's work, and the grid is
		# holding nobody rather than the army it held last time.
		if stats_enabled:
			_reset_stats()
		_count = 0
		return
	reach_cells = maxi(1, int(ceil(minimum / cell_size)))
	_build_offsets()
	if stats_enabled:
		_reset_stats()
	var phase_clock := Time.get_ticks_usec() if stats_enabled else 0
	var clock := phase_clock
	_rebuild(units, settle_epsilon)
	if stats_enabled:
		dev_usec_build = Time.get_ticks_usec() - clock
		_measure_population()
	if _count == 0:
		if stats_enabled:
			dev_usec_total = Time.get_ticks_usec() - phase_clock
		return

	var minimum_sq := minimum * minimum
	var required_spacing := minimum + settle_epsilon * 2.0

	for occupied_index in _occupied.size():
		var cell := _occupied[occupied_index]

		# Inside one cell: every pair, once, walking the bucket as a linked list rather
		# than copying it out.
		if stats_enabled:
			clock = Time.get_ticks_usec()
		var slot_a := _head[cell]
		while slot_a >= 0:
			var slot_b := _next[slot_a]
			while slot_b >= 0:
				if stats_enabled:
					stat_pairs += 1
				_consider(slot_a, slot_b, minimum, minimum_sq)
				slot_b = _next[slot_b]
			slot_a = _next[slot_a]
		if stats_enabled:
			dev_usec_same_cell += Time.get_ticks_usec() - clock

		# Against the half-neighbourhood in front, so each pair of cells is visited once.
		# The cell's row and column are worked out once for all the offsets rather than
		# per offset, and the neighbour is an index step from the delta rather than a
		# second set of divisions.
		if stats_enabled:
			clock = Time.get_ticks_usec()
		var cell_row := cell / cols
		var cell_col := cell - cell_row * cols
		for offset_index in _offset_dx.size():
			var row := cell_row + _offset_dy[offset_index]
			if row < 0 or row >= rows:
				continue
			var col := cell_col + _offset_dx[offset_index]
			if col < 0 or col >= cols:
				continue
			var neighbour := cell + _offset_dy[offset_index] * cols + _offset_dx[offset_index]
			if neighbour < 0 or neighbour >= _head.size() or _head[neighbour] < 0:
				continue
			if stats_enabled:
				stat_cell_pairs += 1
			if _cells_already_spaced(cell, neighbour, required_spacing):
				if stats_enabled:
					stat_cell_pairs_skipped += 1
				continue
			var other := _head[neighbour]
			while other >= 0:
				var mine := _head[cell]
				while mine >= 0:
					if stats_enabled:
						stat_pairs += 1
					_consider(mine, other, minimum, minimum_sq)
					mine = _next[mine]
				other = _next[other]
		if stats_enabled:
			dev_usec_neighbour += Time.get_ticks_usec() - clock

	# A dry pass exists to measure the enumeration itself, so it must not move anybody:
	# that is what makes the three passes comparable, because they all read the same field.
	if dry_level == 0:
		clock = Time.get_ticks_usec() if stats_enabled else 0
		_apply_pushes()
		if stats_enabled:
			dev_usec_apply = Time.get_ticks_usec() - clock
	if stats_enabled:
		dev_usec_total = Time.get_ticks_usec() - phase_clock


func indexed_count() -> int:
	return _count


func occupied_count() -> int:
	return _occupied.size()


func reset_stats() -> void:
	_reset_stats()


## Everything the last pass did, as one dictionary, for the benchmark and for tests.
## Development-only data; nothing in the game reads it.
func _measure_population() -> void:
	# Population percentiles across occupied cells, built once per rebuild from the same
	# buckets the pairs come from. Workload shape, not timing: it is what says whether the
	# pass is walking a few fat cells or many thin ones.
	var hist: PackedInt32Array = PackedInt32Array()
	for cell in _occupied:
		var population := 0
		var slot := _head[cell]
		while slot >= 0:
			population += 1
			slot = _next[slot]
		if population > dev_cell_pop_max:
			dev_cell_pop_max = population
		if hist.size() <= population:
			hist.resize(population + 1)
		hist[population] += 1
	var total := 0
	for value in hist:
		total += value
	if total == 0:
		return
	var cumulative := 0
	var half := int(ceil(float(total) * 0.5))
	var ninety_five := int(ceil(float(total) * 0.95))
	var ninety_nine := int(ceil(float(total) * 0.99))
	for population in hist.size():
		cumulative += hist[population]
		if dev_pop_p50 == 0 and cumulative >= half:
			dev_pop_p50 = population
		if dev_pop_p95 == 0 and cumulative >= ninety_five:
			dev_pop_p95 = population
		if dev_pop_p99 == 0 and cumulative >= ninety_nine:
			dev_pop_p99 = population
			break


func report() -> Dictionary:
	var cells := maxi(1, _occupied.size())
	return {
		"usec_build": dev_usec_build,
		"usec_same_cell": dev_usec_same_cell,
		"usec_neighbour": dev_usec_neighbour,
		"usec_apply": dev_usec_apply,
		"usec_total": dev_usec_total,
		"coincident": dev_coincident,
		"moved_units": dev_moved,
		"displacement_sum": dev_displacement_sum,
		"cell_population_max": dev_cell_pop_max,
		"cell_population_p50": dev_pop_p50,
		"cell_population_p95": dev_pop_p95,
		"cell_population_p99": dev_pop_p99,
		"max_push": max_push,
		"cell_pairs": stat_cell_pairs,
		"cell_pairs_skipped": stat_cell_pairs_skipped,
		"pairs": stat_pairs,
		"touching": stat_touching,
		"displacements": stat_touching * 2,
		"clamped": stat_clamped,
		"displacement_max": stat_displacement_max,
		"occupied_cells": _occupied.size(),
		"indexed_units": _count,
		"cell_population_avg": float(_count) / float(cells),
		"settled_units": _settled_units,
		"interior_cells": _interior_cells,
		"mixed_cells": dev_mixed_cells,
		"reach_cells": reach_cells,
		"cell_size": cell_size,
		"skip_not_settled_a": dev_skip_not_settled_a,
		"skip_not_settled_b": dev_skip_not_settled_b,
		"skip_no_body": dev_skip_no_body,
		"skip_other_body": dev_skip_other_body,
		"skip_spacing": dev_skip_spacing,
		"skip_proved": dev_skip_proved,
		"bodies": _body_report(),
	}


## Per body: how many of its soldiers are standing on the places it gave them, and how far
## from those places the rest are. Development only; empty unless the pass was measured.
##
## The percentages and percentiles are computed here rather than stored, so the arrays stay
## counters and this stays the only place that decides what they mean.
func _body_report() -> Array:
	var out: Array = []
	for index in dev_body_living.size():
		var living := dev_body_living[index]
		if living <= 0:
			continue
		var sampled := 0
		for bucket in DEV_BUCKETS:
			sampled += dev_body_hist[index * DEV_BUCKETS + bucket]
		var average := 0.0
		if sampled > 0:
			average = dev_body_distance_sum[index] / float(sampled)
		out.append({
			"index": index,
			"living": living,
			"settled": dev_body_settled[index],
			"settled_fraction": float(dev_body_settled[index]) / float(living),
			"sampled": sampled,
			"distance_average": average,
			"distance_p50": _hist_percentile(index, sampled, 0.5),
			"distance_p95": _hist_percentile(index, sampled, 0.95),
		})
	return out


## The bucket a percentile falls in, reported as the bucket's upper edge. Coarse by design:
## the question is "are these soldiers on their marks or metres off them", not a number to
## three decimals.
func _hist_percentile(index: int, sampled: int, fraction: float) -> float:
	if sampled <= 0:
		return 0.0
	var target := int(ceil(float(sampled) * fraction))
	var cumulative := 0
	for bucket in DEV_BUCKETS:
		cumulative += dev_body_hist[index * DEV_BUCKETS + bucket]
		if cumulative >= target:
			return float(bucket + 1) * DEV_BUCKET_SIZE
	return float(DEV_BUCKETS) * DEV_BUCKET_SIZE


## Which cell a position falls in. Exposed for tests and tooling; the pass itself has no
## reason to care which cell anything is in, only that its neighbour is the right one.
func cell_index_of(position: Vector2) -> int:
	return _cell_of(position)


## Whether a soldier was treated as standing on its assigned place during the last
## rebuild. Development and test use only.
func cell_state_of(cell: int) -> int:
	if cell < 0 or cell >= _cell_state.size():
		return CELL_UNKNOWN
	return _cell_state[cell]


## ---------- internals ------------------------------------------------------

func _reset_stats() -> void:
	dev_usec_build = 0
	dev_usec_same_cell = 0
	dev_usec_neighbour = 0
	dev_usec_apply = 0
	dev_usec_total = 0
	dev_coincident = 0
	dev_moved = 0
	dev_displacement_sum = 0.0
	dev_cell_pop_max = 0
	dev_pop_p50 = 0
	dev_pop_p95 = 0
	dev_pop_p99 = 0
	dev_skip_not_settled_a = 0
	dev_skip_not_settled_b = 0
	dev_skip_no_body = 0
	dev_skip_other_body = 0
	dev_skip_spacing = 0
	dev_skip_proved = 0
	dev_mixed_cells = 0
	stat_cell_pairs = 0
	stat_cell_pairs_skipped = 0
	stat_pairs = 0
	stat_touching = 0
	stat_clamped = 0
	stat_displacement_max = 0.0
	# Zeroed in place, never resized down: these are indexed by a formation's own index
	# during the rebuild that follows, and an array a reset shrank is an index error in the
	# very pass it is measuring. See D-091's note about the same mistake in the focus layer.
	var zeroed := dev_body_living.size()
	for index in zeroed:
		dev_body_living[index] = 0
		dev_body_settled[index] = 0
		dev_body_distance_sum[index] = 0.0
	for index in zeroed * DEV_BUCKETS:
		dev_body_hist[index] = 0


func _build_offsets() -> void:
	if _offsets_reach == reach_cells and _offset_dx.size() > 0:
		return
	_offsets_reach = reach_cells
	_offset_dx.clear()
	_offset_dy.clear()
	for dy in range(0, reach_cells + 1):
		var min_dx := -reach_cells if dy > 0 else 1
		for dx in range(min_dx, reach_cells + 1):
			_offset_dx.append(dx)
			_offset_dy.append(dy)


func _rebuild(units: Array[BattleUnit], settle_epsilon: float) -> void:
	if _head.size() != cols * rows:
		_head.resize(cols * rows)
		_tails.resize(cols * rows)
		_cell_state.resize(cols * rows)
		_cell_body.resize(cols * rows)
	# Only the cells the last pass used are cleared. Filling every cell of a battlefield
	# that is mostly empty is work proportional to the ground rather than to the army,
	# which is the shape of cost this whole milestone exists to remove - and it showed up
	# here as four whole-battlefield fills per pass on a field with hundreds of thousands
	# of cells. Everything outside [_occupied] is already in its empty state: [method
	# configure] puts it there, and nothing else ever writes to it.
	for cell in _occupied:
		_head[cell] = -1
		_tails[cell] = -1
		_cell_state[cell] = CELL_UNKNOWN
		_cell_body[cell] = null
	_count = 0
	_settled_units = 0
	_interior_cells = 0
	_occupied.resize(0)
	if _units.size() != units.size():
		_units.resize(units.size())
		_push_x.resize(units.size())
		_push_y.resize(units.size())
	if _next.size() != units.size():
		_next.resize(units.size())
	var settle_sq := settle_epsilon * settle_epsilon

	for unit in units:
		if not unit.is_alive():
			continue
		var cell := _cell_of(unit.position)
		var slot := _count
		_units[slot] = unit
		_next[slot] = -1

		# A soldier is settled when its body has given it a place and it is standing on
		# it. The slot index is checked against the body's slot count because a soldier
		# whose place no longer exists reports its own position as its place, which would
		# otherwise read as perfect obedience.
		var settled := false
		var body := unit.formation_ref
		if settle_epsilon > 0.0 and body != null and unit.slot_index >= 0 and unit.slot_index < body.slots.size():
			var to_slot_sq := unit.position.distance_squared_to(body.slots[unit.slot_index])
			settled = to_slot_sq <= settle_sq
			if stats_enabled:
				_record_body_distance(body, settled, sqrt(to_slot_sq))
		elif stats_enabled and body != null:
			# A body exists but gave this soldier no place to stand, so it cannot be
			# settled and its distance to a place is not a number worth recording.
			_record_body_distance(body, false, -1.0)

		var state := _cell_state[cell]
		if state == CELL_UNKNOWN:
			_cell_state[cell] = CELL_SETTLED if settled else CELL_MIXED
			_cell_body[cell] = body if settled else null
		elif state == CELL_SETTLED and (not settled or _cell_body[cell] != body):
			_cell_state[cell] = CELL_MIXED
			_cell_body[cell] = null

		if settled:
			_settled_units += 1
		if _tails[cell] < 0:
			_head[cell] = slot
			_occupied.append(cell)
		else:
			_next[_tails[cell]] = slot
		_tails[cell] = slot
		# Cleared as the roster is walked rather than in a pass of its own: the pushes
		# this soldier will receive are being counted from zero, and there is no reason to
		# read the whole array twice to say so.
		_push_x[slot] = 0.0
		_push_y[slot] = 0.0
		_count += 1
	# Deliberately not sorted. The pass sums every push and applies them together, so the
	# order cells are visited in does not reach the result - which is the point of D-074,
	# and means the pass does not have to pay for an ordering it does not need.
	if stats_enabled:
		_interior_cells = 0
		dev_mixed_cells = 0
		for cell in _occupied:
			match _cell_state[cell]:
				CELL_SETTLED:
					_interior_cells += 1
				CELL_MIXED:
					dev_mixed_cells += 1


## Per-body settled statistics: how many of a formation's soldiers are standing on the places
## it gave them, and how far from those places the rest are. Development only, and only
## reached while the pass is being measured. Distances are accumulated into half-unit buckets
## so that a percentile is a bucket walk rather than a sort of the whole army.
func _record_body_distance(body: BattleFormation, settled: bool, distance: float) -> void:
	var index := maxi(0, body.index)
	if dev_body_living.size() <= index:
		var wanted := index + 1
		dev_body_living.resize(wanted)
		dev_body_settled.resize(wanted)
		dev_body_distance_sum.resize(wanted)
		dev_body_hist.resize(wanted * DEV_BUCKETS)
	dev_body_living[index] += 1
	if settled:
		dev_body_settled[index] += 1
	if distance >= 0.0:
		dev_body_distance_sum[index] += float(distance)
		var bucket := mini(DEV_BUCKETS - 1, int(distance / DEV_BUCKET_SIZE))
		dev_body_hist[index * DEV_BUCKETS + bucket] += 1


## Whether two cells can be skipped because every pair across them is already held apart
## by the geometry that placed them.
##
## The claim is exact rather than a heuristic. Two soldiers standing within
## [param settle] of their assigned places are at least [code]spacing - 2 * settle[/code]
## apart, and the closest two places in a slot grid are one spacing apart. If that exceeds
## the separation distance, no pair across two settled cells of one body can be touching,
## so neither a distance nor a push needs computing. A body whose spacing is too tight for
## the claim to hold is never skipped - the test is against the body's own spacing, so a
## cramped formation simply does the work.
##
## When the pass is being measured, the first test that fails is counted, so the reasons add
## up to the number of cell pairs that reached the proof. Development-only counting; the
## decision itself is the same code either way.
func _cells_already_spaced(a: int, b: int, required_spacing: float) -> bool:
	if _cell_state[a] != CELL_SETTLED:
		if stats_enabled:
			dev_skip_not_settled_a += 1
		return false
	if _cell_state[b] != CELL_SETTLED:
		if stats_enabled:
			dev_skip_not_settled_b += 1
		return false
	var body: BattleFormation = _cell_body[a]
	if body == null:
		if stats_enabled:
			dev_skip_no_body += 1
		return false
	if body != _cell_body[b]:
		if stats_enabled:
			dev_skip_other_body += 1
		return false
	if body.spacing <= required_spacing:
		if stats_enabled:
			dev_skip_spacing += 1
		return false
	if stats_enabled:
		dev_skip_proved += 1
	return true


func _consider(slot_a: int, slot_b: int, minimum: float, minimum_sq: float) -> void:
	if stats_enabled and dry_level >= 2:
		return
	var a := _units[slot_a]
	var b := _units[slot_b]
	var dx := b.position.x - a.position.x
	var dy := b.position.y - a.position.y
	var distance_sq := dx * dx + dy * dy
	if distance_sq >= minimum_sq:
		return
	if stats_enabled:
		stat_touching += 1
		if dry_level >= 1:
			return
	if distance_sq <= 0.0000001:
		# Exactly on top of each other: there is no axis to separate along, so one is
		# chosen. Fixed rather than random, so a pair in precisely the same spot resolves
		# the same way every time it happens.
		if stats_enabled:
			dev_coincident += 1
		var half := minimum * 0.5
		_push_x[slot_a] -= half
		_push_x[slot_b] += half
		return
	var distance := sqrt(distance_sq)
	var scale := (minimum - distance) * 0.5 / distance
	var ox := dx * scale
	var oy := dy * scale
	_push_x[slot_a] -= ox
	_push_y[slot_a] -= oy
	_push_x[slot_b] += ox
	_push_y[slot_b] += oy


func _apply_pushes() -> void:
	var ceiling_sq := max_push * max_push
	for slot in _count:
		var px := _push_x[slot]
		var py := _push_y[slot]
		if px == 0.0 and py == 0.0:
			continue
		if stats_enabled:
			dev_moved += 1
		var magnitude_sq := px * px + py * py
		if magnitude_sq > ceiling_sq:
			var scale := max_push / sqrt(magnitude_sq)
			px *= scale
			py *= scale
			if stats_enabled:
				stat_clamped += 1
		elif stats_enabled:
			stat_displacement_max = maxf(stat_displacement_max, sqrt(magnitude_sq))
		if stats_enabled:
			dev_displacement_sum += sqrt(px * px + py * py)
		var unit := _units[slot]
		unit.position = Vector2(unit.position.x + px, unit.position.y + py)


func _cell_of(position: Vector2) -> int:
	return clampi(int(floor(position.y / cell_size)), 0, rows - 1) * cols \
		+ clampi(int(floor(position.x / cell_size)), 0, cols - 1)


## The cell [param steps] along from another, or -1 when that falls off the field.
func _cell_at(cell: int, dx: int, dy: int) -> int:
	var row := cell / cols + dy
	if row < 0 or row >= rows:
		return -1
	var col := cell % cols + dx
	if col < 0 or col >= cols:
		return -1
	return row * cols + col
