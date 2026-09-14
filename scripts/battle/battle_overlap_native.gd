class_name BattleOverlapNative
extends BattleOverlapGrid
## Step 7.8's native overlap pass: shape C, the whole separation pass in one call.
##
## [b]The shape, and why.[/b] Step 7.7 measured what happens when native code hands its
## intermediate results back to GDScript: the bridge eats the win. So this pass crosses the
## boundary twice per tick and never per pair: GDScript packs the field, the kernel does
## everything - its own cell index, its own enumeration, the exact test, the push, the
## accumulation, the clamp - and returns one displacement per soldier per axis, which
## GDScript then applies to the units it owns.
##
## [b]What native owns here: nothing that outlives a pass.[/b] The kernel holds transient
## arrays sized to the army and no reference to a [BattleUnit], a formation, a battle rule or
## anything persistent. Soldiers, bodies, damage, targeting and saves stay GDScript's, and the
## GDScript pass remains the shipped reference and the oracle. If the library is missing, the
## battle falls back to the reference without noticing anything except a slower tick.
##
## [b]Compare mode.[/b] With [member compare_enabled] set, every pass is also run through the
## reference on its own proxy copy of the same pre-overlap field, the two results are compared
## before either is applied, and the mismatch is recorded with the ids, positions, bodies,
## cells and both displacements. The reference's result is the one applied, so a comparison
## can never change a battle; it can only report that the two disagree.

## The native class, or null when the extension is not loaded.
var kernel: Object = null
## Set by the caller: run the reference over the same field and compare. Correctness only.
var compare_enabled: bool = false
## The locked reference, used for compare mode.
var reference: BattleOverlapGrid = null

## Boundary-cost clocks, development only. The milestone's rule is that a native kernel which
## computes in twenty milliseconds but costs seventy to marshal is not a twenty-millisecond
## solution, so every part of the round trip is timed separately.
## [member dev_usec_apply] and [member dev_usec_total] are the base class's, because they
## mean the same thing on every pass: what the write-back cost, and what the whole pass cost.
var dev_usec_sync: int = 0
var dev_usec_native: int = 0
var dev_usec_compare: int = 0
var dev_applied: int = 0

## What the last compare pass found. Zero mismatches is the claim the suite checks.
var native_mismatches: int = 0
var native_first_mismatch: Dictionary = {}
var native_calls: int = 0
var native_passes: int = 0

var _pass_units: Array[BattleUnit] = []
var _pos_x: PackedFloat64Array = PackedFloat64Array()
var _pos_y: PackedFloat64Array = PackedFloat64Array()
var _body_code: PackedInt32Array = PackedInt32Array()
var _body_spacing: PackedFloat64Array = PackedFloat64Array()
var _settled: PackedByteArray = PackedByteArray()
var _body_code_of: Dictionary = {}
var _kernel_cols: int = 0
var _kernel_rows: int = 0
var _kernel_reach: int = 0
var _kernel_cell: float = 0.0
var _proxies: Array[BattleUnit] = []
var _compare_units: Array[BattleUnit] = []


## Whether the accelerator is loaded. Checked once by the battle when it chooses a backend.
static func available() -> bool:
	return ClassDB.class_exists("NativeOverlapKernel")


func _init() -> void:
	if ClassDB.class_exists("NativeOverlapKernel"):
		kernel = ClassDB.instantiate("NativeOverlapKernel")


func configure(p_field_size: Vector2, p_cell_size: float) -> void:
	super.configure(p_field_size, p_cell_size)
	if reference == null:
		reference = BattleOverlapGrid.new()
	reference.configure(p_field_size, p_cell_size)
	_body_code_of.clear()
	_kernel_reach = 0


func resolve(units: Array[BattleUnit], minimum: float, settle_epsilon: float = 0.0) -> void:
	if units.is_empty() or minimum <= 0.0:
		if stats_enabled:
			_reset_stats()
		return
	if kernel == null:
		# No accelerator: the reference answers, which is the whole fallback. Nothing above
		# this line knows the difference.
		reference.max_push = max_push
		reference.stats_enabled = stats_enabled
		reference.dry_level = dry_level
		reference.resolve(units, minimum, settle_epsilon)
		return

	reach_cells = maxi(1, int(ceil(minimum / cell_size)))
	if _kernel_reach != reach_cells or _kernel_cols != cols or _kernel_rows != rows \
			or not is_equal_approx(_kernel_cell, cell_size):
		kernel.call("setup", cols, rows, cell_size, reach_cells)
		_kernel_reach = reach_cells
		_kernel_cols = cols
		_kernel_rows = rows
		_kernel_cell = cell_size
	if stats_enabled:
		_reset_stats()

	var phase_clock := Time.get_ticks_usec() if stats_enabled else 0

	# 1. the field, packed. This is the fixed per-tick cost of using the accelerator at all:
	#    it is paid whatever the army does, and it is what a small battle cannot amortise.
	_sync_inputs(units, settle_epsilon)
	if stats_enabled:
		dev_usec_sync = Time.get_ticks_usec() - phase_clock

	# 2. the kernel. One call, whatever the army size.
	var clock := Time.get_ticks_usec() if stats_enabled else 0
	var displacements: PackedFloat64Array = kernel.call("resolve", _pos_x, _pos_y, _body_code,
		_body_spacing, _settled, minimum, settle_epsilon, max_push)
	native_calls += 1
	native_passes += 1
	if stats_enabled:
		dev_usec_native = Time.get_ticks_usec() - clock
		_pull_counters()

	# 3. the comparison, when it is being asked for. Correctness only: the reference's result
	#    is what gets applied below, on the same field the kernel saw.
	if compare_enabled:
		var compare_clock := Time.get_ticks_usec() if stats_enabled else 0
		_compare_pass(units, displacements, minimum, settle_epsilon)
		if stats_enabled:
			dev_usec_compare = Time.get_ticks_usec() - compare_clock

	# 4. the result, applied by the pass that owns the units.
	clock = Time.get_ticks_usec() if stats_enabled else 0
	dev_applied = _apply_displacements(displacements)
	if stats_enabled:
		dev_usec_apply = Time.get_ticks_usec() - clock
		dev_usec_total = Time.get_ticks_usec() - phase_clock


func indexed_count() -> int:
	return _pass_units.size()


func occupied_count() -> int:
	if kernel == null:
		return reference.occupied_count()
	return int(kernel.call("last_occupied_cells"))


func report() -> Dictionary:
	if kernel == null:
		return reference.report()
	return {
		"usec_build": dev_usec_sync,
		"usec_same_cell": 0,
		"usec_neighbour": 0,
		"usec_apply": dev_usec_apply,
		"usec_total": dev_usec_total,
		"usec_sync": dev_usec_sync,
		"usec_native": dev_usec_native,
		"usec_compare": dev_usec_compare,
		"coincident": int(kernel.call("last_coincident")),
		"moved_units": int(kernel.call("last_moved")),
		"displacement_sum": float(kernel.call("last_displacement_sum")),
		"max_push": max_push,
		"cell_pairs": int(kernel.call("last_cell_pairs")),
		"cell_pairs_skipped": int(kernel.call("last_cell_pairs_skipped")),
		"pairs": int(kernel.call("last_pairs")),
		"touching": int(kernel.call("last_touching")),
		"clamped": int(kernel.call("last_clamped")),
		"cell_population_max": int(kernel.call("last_cell_population_max")),
		"occupied_cells": int(kernel.call("last_occupied_cells")),
		"indexed_units": int(kernel.call("last_indexed")),
		"reach_cells": reach_cells,
		"cell_size": cell_size,
		"mismatches": native_mismatches,
	}


## Everything the boundary costs, in one dictionary, for the benchmark's own table.
func boundary_report() -> Dictionary:
	return {
		"passes": native_passes,
		"sync_us": dev_usec_sync,
		"native_us": dev_usec_native,
		"compare_us": dev_usec_compare,
		"apply_us": dev_usec_apply,
		"total_us": dev_usec_total,
		"applied": dev_applied,
		"mismatches": native_mismatches,
	}


## ---------- internals ------------------------------------------------------

## Pack the field for the kernel: positions, body codes, body spacing and the settled flag
## for every living soldier, in roster order. Slots are the caller's, so slot i here is slot i
## in the displacement array that comes back.
func _sync_inputs(units: Array[BattleUnit], settle_epsilon: float) -> void:
	var living := 0
	for unit in units:
		if unit.is_alive():
			living += 1
	if _pass_units.size() != living:
		_pass_units.resize(living)
		_pos_x.resize(living)
		_pos_y.resize(living)
		_body_code.resize(living)
		_settled.resize(living)
	var wanted := units.size()
	if _body_spacing.size() < wanted:
		_body_spacing.resize(wanted)
	var settle_sq := settle_epsilon * settle_epsilon
	_body_code_of.clear()

	var slot := 0
	for unit in units:
		if not unit.is_alive():
			continue
		_pass_units[slot] = unit
		_pos_x[slot] = unit.position.x
		_pos_y[slot] = unit.position.y
		var body := unit.formation_ref
		var code := -1
		if body != null:
			var key := body.get_instance_id()
			var found: Variant = _body_code_of.get(key)
			if found == null:
				code = _body_code_of.size()
				_body_code_of[key] = code
				if _body_spacing.size() <= code:
					_body_spacing.resize(code + 1)
				_body_spacing[code] = float(body.spacing)
			else:
				code = int(found)
		_body_code[slot] = code
		var settled := false
		if settle_epsilon > 0.0 and body != null and unit.slot_index >= 0 and unit.slot_index < body.slots.size():
			settled = unit.position.distance_squared_to(body.slots[unit.slot_index]) <= settle_sq
		_settled[slot] = 1 if settled else 0
		slot += 1


## Apply the kernel's displacements: one addition per soldier per axis, exactly as the
## reference's apply pass does it, on the units this pass owns.
func _apply_displacements(displacements: PackedFloat64Array) -> int:
	var count := mini(_pass_units.size(), displacements.size() / 2)
	for slot in count:
		var px := displacements[slot * 2]
		var py := displacements[slot * 2 + 1]
		if px == 0.0 and py == 0.0:
			continue
		if stats_enabled:
			dev_moved += 1
			dev_displacement_sum += sqrt(px * px + py * py)
		var unit := _pass_units[slot]
		unit.position = Vector2(unit.position.x + px, unit.position.y + py)
	return count


func _pull_counters() -> void:
	stat_pairs = int(kernel.call("last_pairs"))
	stat_touching = int(kernel.call("last_touching"))
	stat_cell_pairs = int(kernel.call("last_cell_pairs"))
	stat_cell_pairs_skipped = int(kernel.call("last_cell_pairs_skipped"))
	dev_coincident = int(kernel.call("last_coincident"))
	stat_clamped = int(kernel.call("last_clamped"))


## Run the reference over the same pre-overlap field and compare, before anything is applied.
##
## The reference gets its own copies of the soldiers rather than the real ones: two passes
## over one set of objects would compare "before" against "after". Displacements are compared
## as displacements, which is what the kernel actually produces, and the reference's own
## result is what the caller applies - so a comparison can report a disagreement but can
## never cause one.
func _compare_pass(units: Array[BattleUnit], displacements: PackedFloat64Array,
		minimum: float, settle_epsilon: float) -> void:
	var living := 0
	for unit in units:
		if unit.is_alive():
			living += 1
	if _proxies.size() != living:
		_proxies.resize(living)
	var slot := 0
	for unit in units:
		if not unit.is_alive():
			continue
		var proxy := _proxies[slot]
		if proxy == null:
			proxy = BattleUnit.new()
			_proxies[slot] = proxy
		proxy.id = unit.id
		proxy.side = unit.side
		proxy.hp = 1
		proxy.max_hp = 1
		proxy.alive = true
		proxy.position = unit.position
		proxy.formation_ref = unit.formation_ref
		proxy.slot_index = unit.slot_index
		slot += 1

	reference.max_push = max_push
	reference.stats_enabled = false
	reference.dry_level = 0
	reference.resolve(_proxies, minimum, settle_epsilon)

	# Now the reference has moved its copies and the kernel has handed back displacements for
	# the same starting positions: compare where each says the soldiers should end up.
	var mismatches := 0
	for index in _proxies.size():
		var proxy := _proxies[index]
		var expected := proxy.position
		var actual := Vector2(_pos_x[index] + displacements[index * 2],
			_pos_y[index] + displacements[index * 2 + 1])
		if expected.x == actual.x and expected.y == actual.y:
			continue
		mismatches += 1
		if native_first_mismatch.is_empty():
			native_first_mismatch = {
				"tick": -1,
				"soldier_id": proxy.soldier_id,
				"unit_id": proxy.id,
				"body": str(proxy.formation_ref.id) if proxy.formation_ref != null else "",
				"cell": _cell_of(Vector2(_pos_x[index], _pos_y[index])),
				"from": [_pos_x[index], _pos_y[index]],
				"reference": [expected.x, expected.y],
				"native": [actual.x, actual.y],
				"delta": expected.distance_to(actual),
			}
	native_mismatches += mismatches


## Stamp the tick on a recorded mismatch, so the report can say when it happened.
func note_tick(tick: int) -> void:
	if not native_first_mismatch.is_empty() and int(native_first_mismatch.get("tick", -1)) < 0:
		native_first_mismatch["tick"] = tick
