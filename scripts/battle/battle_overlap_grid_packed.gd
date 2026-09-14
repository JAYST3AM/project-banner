class_name BattleOverlapGridPacked
extends BattleOverlapGrid
## Step 7.8's GDScript candidate: the same separation pass, over packed numbers.
##
## [b]What this is, exactly.[/b] The same algorithm as [BattleOverlapGrid] - the same grid,
## the same cell pairing, the same visit order, the same arithmetic, the same accumulated
## push, the same clamp - with one thing changed: during the rebuild, every living soldier's
## position, body and settled flag are copied into packed arrays indexed by slot, and the hot
## pair loops read those rather than dereferencing [BattleUnit]s. Both loops also carry the
## push arithmetic inline, because in a GDScript hot loop the helper call itself is a large
## share of the cost.
##
## [b]Why it might be cheaper.[/b] Every pair in the reference does [code]_units[slot][/code]
## (an array read of a RefCounted), then [code]unit.position[/code] twice - each building a
## Vector2 out of the object - before any arithmetic happens. Here the same four numbers come
## out of two [PackedFloat64Array] reads, and no object is touched until the apply pass.
## Positions are stored as doubles because that is what [code]Vector2[/code] components
## convert to exactly, so this is not merely similar arithmetic on similar values: it is the
## same arithmetic on the same numbers.
##
## [b]What is deliberately kept.[/b] The push accumulators stay [PackedFloat32Array], as the
## reference's are, and each pair writes to them immediately, exactly as the reference does:
## batching the pushes into locals and writing once would be slightly more precise, and a
## candidate that is "more precise" is one whose numbers have to be argued about instead of
## compared. The enumeration is the reference's - occupied cells in first-occupancy order,
## intra-cell buckets in insertion order, then the forward half-neighbourhood in the same
## offset order - because that makes the floating-point sums identical too, and the oracle
## suite compares positions bit for bit on generated states rather than approximately.
##
## [b]What it is not.[/b] Not a second algorithm. It is the reference with a different memory
## layout, tested against the reference, and the reference is never deleted.

var pk_pos_x: PackedFloat64Array = PackedFloat64Array()
var pk_pos_y: PackedFloat64Array = PackedFloat64Array()
## Slot -> body code, or -1 for a soldier with no body. Codes are handed out per body during
## the rebuild, so two bodies can never share one and identity compares as an integer.
var pk_slot_body: PackedInt32Array = PackedInt32Array()
var pk_slot_settled: PackedByteArray = PackedByteArray()
## Body code -> that body's slot spacing, which is the number the settled proof tests.
var pk_spacing: PackedFloat64Array = PackedFloat64Array()
var pk_body_codes: Dictionary = {}
var pk_units: Array[BattleUnit] = []
var pk_count: int = 0

var pk_head: PackedInt32Array = PackedInt32Array()
var pk_next: PackedInt32Array = PackedInt32Array()
var pk_tails: PackedInt32Array = PackedInt32Array()
var pk_occupied: PackedInt32Array = PackedInt32Array()
var pk_cell_state: PackedByteArray = PackedByteArray()
var pk_cell_body: PackedInt32Array = PackedInt32Array()
var pk_push_x: PackedFloat32Array = PackedFloat32Array()
var pk_push_y: PackedFloat32Array = PackedFloat32Array()
var pk_offset_dx: PackedInt32Array = PackedInt32Array()
var pk_offset_dy: PackedInt32Array = PackedInt32Array()
var pk_offsets_reach: int = 0


## The geometry is the base class's - cell size, columns, rows, field - so that every caller
## that configures one of these passes configures all of them the same way.
func configure(p_field_size: Vector2, p_cell_size: float) -> void:
	super.configure(p_field_size, p_cell_size)
	var wanted := cols * rows
	if pk_head.size() != wanted:
		pk_head.resize(wanted)
		pk_head.fill(-1)
		pk_tails.resize(wanted)
		pk_tails.fill(-1)
		pk_cell_state.resize(wanted)
		pk_cell_state.fill(CELL_UNKNOWN)
		pk_cell_body.resize(wanted)
		pk_cell_body.fill(-1)
		pk_occupied.resize(0)
		pk_next.resize(0)
		pk_units.clear()
		pk_push_x.resize(0)
		pk_push_y.resize(0)
		pk_count = 0


func resolve(units: Array[BattleUnit], minimum: float, settle_epsilon: float = 0.0) -> void:
	if units.is_empty() or minimum <= 0.0:
		if stats_enabled:
			_reset_stats()
		pk_count = 0
		return
	reach_cells = maxi(1, int(ceil(minimum / cell_size)))
	pk_build_offsets()
	if stats_enabled:
		_reset_stats()
	var phase_clock := Time.get_ticks_usec() if stats_enabled else 0
	var clock := phase_clock
	pk_rebuild(units, settle_epsilon)
	if stats_enabled:
		dev_usec_build = Time.get_ticks_usec() - clock
	if pk_count == 0:
		if stats_enabled:
			dev_usec_total = Time.get_ticks_usec() - phase_clock
		return

	var minimum_sq := minimum * minimum
	var required_spacing := minimum + settle_epsilon * 2.0

	for occupied_index in pk_occupied.size():
		var cell := pk_occupied[occupied_index]

		# Inside one cell: every pair, once, in bucket order.
		if stats_enabled:
			clock = Time.get_ticks_usec()
		var slot_a := pk_head[cell]
		while slot_a >= 0:
			var ax := pk_pos_x[slot_a]
			var ay := pk_pos_y[slot_a]
			var slot_b := pk_next[slot_a]
			while slot_b >= 0:
				if stats_enabled:
					stat_pairs += 1
					if dry_level >= 2:
						slot_b = pk_next[slot_b]
						continue
				var dx := pk_pos_x[slot_b] - ax
				var dy := pk_pos_y[slot_b] - ay
				var distance_sq := dx * dx + dy * dy
				if distance_sq < minimum_sq:
					if stats_enabled:
						stat_touching += 1
						if dry_level >= 1:
							slot_b = pk_next[slot_b]
							continue
					if distance_sq <= 0.0000001:
						if stats_enabled:
							dev_coincident += 1
						var half := minimum * 0.5
						pk_push_x[slot_a] -= half
						pk_push_x[slot_b] += half
					else:
						var distance := sqrt(distance_sq)
						var scale := (minimum - distance) * 0.5 / distance
						var ox := dx * scale
						var oy := dy * scale
						pk_push_x[slot_a] -= ox
						pk_push_y[slot_a] -= oy
						pk_push_x[slot_b] += ox
						pk_push_y[slot_b] += oy
				slot_b = pk_next[slot_b]
			slot_a = pk_next[slot_a]
		if stats_enabled:
			dev_usec_same_cell += Time.get_ticks_usec() - clock
			clock = Time.get_ticks_usec()

		var cell_row := cell / cols
		var cell_col := cell - cell_row * cols
		for offset_index in pk_offset_dx.size():
			var row := cell_row + pk_offset_dy[offset_index]
			if row < 0 or row >= rows:
				continue
			var col := cell_col + pk_offset_dx[offset_index]
			if col < 0 or col >= cols:
				continue
			var neighbour := cell + pk_offset_dy[offset_index] * cols + pk_offset_dx[offset_index]
			if neighbour < 0 or neighbour >= pk_head.size() or pk_head[neighbour] < 0:
				continue
			if stats_enabled:
				stat_cell_pairs += 1
			if pk_cells_already_spaced(cell, neighbour, required_spacing):
				if stats_enabled:
					stat_cell_pairs_skipped += 1
				continue
			var other := pk_head[neighbour]
			while other >= 0:
				var bx := pk_pos_x[other]
				var by := pk_pos_y[other]
				var mine := pk_head[cell]
				while mine >= 0:
					if stats_enabled:
						stat_pairs += 1
						if dry_level >= 2:
							mine = pk_next[mine]
							continue
					var dx := bx - pk_pos_x[mine]
					var dy := by - pk_pos_y[mine]
					var distance_sq := dx * dx + dy * dy
					if distance_sq < minimum_sq:
						if stats_enabled:
							stat_touching += 1
							if dry_level >= 1:
								mine = pk_next[mine]
								continue
						if distance_sq <= 0.0000001:
							if stats_enabled:
								dev_coincident += 1
							var half := minimum * 0.5
							pk_push_x[mine] -= half
							pk_push_x[other] += half
						else:
							var distance := sqrt(distance_sq)
							var scale := (minimum - distance) * 0.5 / distance
							var ox := dx * scale
							var oy := dy * scale
							pk_push_x[mine] -= ox
							pk_push_y[mine] -= oy
							pk_push_x[other] += ox
							pk_push_y[other] += oy
					mine = pk_next[mine]
				other = pk_next[other]
		if stats_enabled:
			dev_usec_neighbour += Time.get_ticks_usec() - clock

	if dry_level == 0:
		clock = Time.get_ticks_usec() if stats_enabled else 0
		pk_apply_pushes()
		if stats_enabled:
			dev_usec_apply = Time.get_ticks_usec() - clock
	if stats_enabled:
		dev_usec_total = Time.get_ticks_usec() - phase_clock


func indexed_count() -> int:
	return pk_count


func occupied_count() -> int:
	return pk_occupied.size()


func cell_state_of(cell: int) -> int:
	if cell < 0 or cell >= pk_cell_state.size():
		return CELL_UNKNOWN
	return pk_cell_state[cell]


## The same report as the reference's, from this pass's own state. The keys are deliberately
## identical: a caller comparing two passes' work should not have to know which one it is.
func report() -> Dictionary:
	var cells := maxi(1, pk_occupied.size())
	return {
		"usec_build": dev_usec_build,
		"usec_same_cell": dev_usec_same_cell,
		"usec_neighbour": dev_usec_neighbour,
		"usec_apply": dev_usec_apply,
		"usec_total": dev_usec_total,
		"coincident": dev_coincident,
		"moved_units": dev_moved,
		"displacement_sum": dev_displacement_sum,
		"max_push": max_push,
		"cell_pairs": stat_cell_pairs,
		"cell_pairs_skipped": stat_cell_pairs_skipped,
		"pairs": stat_pairs,
		"touching": stat_touching,
		"clamped": stat_clamped,
		"displacement_max": stat_displacement_max,
		"occupied_cells": pk_occupied.size(),
		"indexed_units": pk_count,
		"cell_population_avg": float(pk_count) / float(cells),
		"reach_cells": reach_cells,
		"cell_size": cell_size,
		"cell_population_max": pk_cell_pop_max,
		"settled_units": pk_settled_units,
		"interior_cells": pk_interior_cells,
		"mixed_cells": pk_mixed_cells,
	}


## ---------- internals ------------------------------------------------------

var pk_settled_units: int = 0
var pk_interior_cells: int = 0
var pk_mixed_cells: int = 0
## The busiest single cell in the last rebuild, and how many cells it walked. Development
## only: the same figure the reference's report carries, from this pass's own buckets.
var pk_cell_pop_max: int = 0


func pk_build_offsets() -> void:
	if pk_offsets_reach == reach_cells and pk_offset_dx.size() > 0:
		return
	pk_offsets_reach = reach_cells
	pk_offset_dx.clear()
	pk_offset_dy.clear()
	for dy in range(0, reach_cells + 1):
		var min_dx := -reach_cells if dy > 0 else 1
		for dx in range(min_dx, reach_cells + 1):
			pk_offset_dx.append(dx)
			pk_offset_dy.append(dy)


func pk_rebuild(units: Array[BattleUnit], settle_epsilon: float) -> void:
	if pk_head.size() != cols * rows:
		pk_head.resize(cols * rows)
		pk_tails.resize(cols * rows)
		pk_cell_state.resize(cols * rows)
		pk_cell_body.resize(cols * rows)
	for cell in pk_occupied:
		pk_head[cell] = -1
		pk_tails[cell] = -1
		pk_cell_state[cell] = CELL_UNKNOWN
		pk_cell_body[cell] = -1
	pk_count = 0
	pk_settled_units = 0
	pk_interior_cells = 0
	pk_mixed_cells = 0
	pk_occupied.resize(0)
	var wanted := units.size()
	if pk_units.size() != wanted:
		pk_units.resize(wanted)
		pk_push_x.resize(wanted)
		pk_push_y.resize(wanted)
		pk_pos_x.resize(wanted)
		pk_pos_y.resize(wanted)
		pk_slot_body.resize(wanted)
		pk_slot_settled.resize(wanted)
	if pk_next.size() != wanted:
		pk_next.resize(wanted)
	var settle_sq := settle_epsilon * settle_epsilon
	pk_body_codes.clear()

	for unit in units:
		if not unit.is_alive():
			continue
		var cell := _cell_of(unit.position)
		var slot := pk_count
		pk_units[slot] = unit
		pk_next[slot] = -1
		pk_pos_x[slot] = unit.position.x
		pk_pos_y[slot] = unit.position.y

		var body := unit.formation_ref
		var code := -1
		if body != null:
			var key := body.get_instance_id()
			var found: Variant = pk_body_codes.get(key)
			if found == null:
				code = pk_body_codes.size()
				pk_body_codes[key] = code
				if pk_spacing.size() <= code:
					pk_spacing.resize(code + 1)
				pk_spacing[code] = float(body.spacing)
			else:
				code = int(found)
		pk_slot_body[slot] = code

		var settled := false
		if settle_epsilon > 0.0 and body != null and unit.slot_index >= 0 and unit.slot_index < body.slots.size():
			settled = unit.position.distance_squared_to(body.slots[unit.slot_index]) <= settle_sq
		pk_slot_settled[slot] = 1 if settled else 0
		if settled:
			pk_settled_units += 1

		var state := pk_cell_state[cell]
		if state == CELL_UNKNOWN:
			pk_cell_state[cell] = CELL_SETTLED if settled else CELL_MIXED
			pk_cell_body[cell] = code
		elif state == CELL_SETTLED and (not settled or pk_cell_body[cell] != code):
			pk_cell_state[cell] = CELL_MIXED
			pk_cell_body[cell] = -1

		if pk_tails[cell] < 0:
			pk_head[cell] = slot
			pk_occupied.append(cell)
		else:
			pk_next[pk_tails[cell]] = slot
		pk_tails[cell] = slot
		pk_push_x[slot] = 0.0
		pk_push_y[slot] = 0.0
		pk_count += 1

	if stats_enabled:
		pk_cell_pop_max = 0
		for cell in pk_occupied:
			match pk_cell_state[cell]:
				CELL_SETTLED:
					pk_interior_cells += 1
				CELL_MIXED:
					pk_mixed_cells += 1
			var population := 0
			var slot := pk_head[cell]
			while slot >= 0:
				population += 1
				slot = pk_next[slot]
			pk_cell_pop_max = maxi(pk_cell_pop_max, population)


## The same proof as the reference's, over body codes rather than body references.
func pk_cells_already_spaced(a: int, b: int, required_spacing: float) -> bool:
	if pk_cell_state[a] != CELL_SETTLED or pk_cell_state[b] != CELL_SETTLED:
		return false
	var code := pk_cell_body[a]
	if code < 0 or code != pk_cell_body[b]:
		return false
	return pk_spacing[code] > required_spacing


func pk_apply_pushes() -> void:
	var ceiling_sq := max_push * max_push
	for slot in pk_count:
		var px := pk_push_x[slot]
		var py := pk_push_y[slot]
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
		var unit := pk_units[slot]
		unit.position = Vector2(unit.position.x + px, unit.position.y + py)
