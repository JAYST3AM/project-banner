#ifndef PB_NATIVE_OVERLAP_KERNEL_H
#define PB_NATIVE_OVERLAP_KERNEL_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <vector>

namespace godot {

/**
 * The separation pass, in native code: shape C.
 *
 * Step 7.7's lesson was that a native kernel which hands its intermediate results back to
 * GDScript is measuring the bridge rather than the work. So this kernel does the whole pass
 * internally - its own cell index, its own pair enumeration, the exact test, the push
 * arithmetic, the accumulation and the clamp - and hands back one number per soldier per
 * axis: the displacement to apply. Nothing per pair crosses the boundary, and the boundary
 * is crossed once per tick rather than once per candidate.
 *
 * What it does NOT own: soldiers. It holds transient arrays sized to the army and no Godot
 * Object pointer at all, so nothing here can reach a BattleUnit, a formation, a battle rule
 * or a save file. GDScript remains authoritative: it builds the inputs, calls once, and
 * applies the displacements to the units it owns. The GDScript pass remains the oracle.
 *
 * The enumeration is deliberately the GDScript pass's, case for case:
 *  - occupied cells in order of first occupancy (the roster's order, not sorted), because
 *    that is the order BattleOverlapGrid walks them in;
 *  - inside a cell, slots in ascending order, which is the order the grid's linked list is
 *    built in;
 *  - then the same forward half-neighbourhood, in the same offset order.
 *
 * The pass is Jacobi - every push follows from where everyone stood - so any order produces
 * the same arrangement in exact arithmetic. The order is kept anyway, because it is what
 * makes the floating-point *sums* identical as well, and a candidate whose numbers can be
 * compared bit for bit is a candidate that does not have to be argued about.
 *
 * Accumulators are `float`, matching the PackedFloat32Array the GDScript pass accumulates
 * into: that rounding is part of the shipped result and is reproduced rather than improved.
 */
class NativeOverlapKernel : public RefCounted {
	GDCLASS(NativeOverlapKernel, RefCounted)

public:
	NativeOverlapKernel();
	~NativeOverlapKernel();

	/**
	 * Geometry, once per battle. `reach` is how many cells in each direction a cell is paired
	 * with, which is the caller's derivation from the separation distance and the cell size.
	 */
	void setup(int cols, int rows, double cell_size, int reach);

	/**
	 * One pass. Inputs are the caller's packed snapshot of its living soldiers in slot order:
	 * position, body code (-1 for none), the spacing of the body that code names, and whether
	 * the soldier stands on its assigned place. Returns 2 * count doubles: dx, dy per slot.
	 */
	PackedFloat64Array resolve(
			const PackedFloat64Array &pos_x,
			const PackedFloat64Array &pos_y,
			const PackedInt32Array &body_code,
			const PackedFloat64Array &body_spacing,
			const PackedByteArray &settled,
			double minimum,
			double settle_epsilon,
			double max_push);

	// What the last pass did, for the caller's own report. Counters only; no state.
	int last_indexed() const;
	int last_occupied_cells() const;
	int last_pairs() const;
	int last_touching() const;
	int last_cell_pairs() const;
	int last_cell_pairs_skipped() const;
	int last_coincident() const;
	int last_cell_population_max() const;
	int last_moved() const;
	int last_clamped() const;
	double last_displacement_sum() const;

protected:
	static void _bind_methods();

private:
	int _cols = 1;
	int _rows = 1;
	int _reach = 1;
	double _cell_size = 1.35;

	std::vector<int32_t> _head; // per cell: first slot, -1 when empty
	std::vector<int32_t> _tails; // per cell: last slot, for an O(1) append
	std::vector<int32_t> _next; // per slot: next slot in the same cell
	std::vector<int32_t> _occupied; // cells in order of first occupancy
	std::vector<uint8_t> _cell_settled; // per cell: 1 when every occupant is settled
	std::vector<int32_t> _cell_body; // per cell: the settled body code, or -1
	std::vector<float> _push_x;
	std::vector<float> _push_y;
	std::vector<int32_t> _offset_dx;
	std::vector<int32_t> _offset_dy;
	PackedFloat64Array _out;

	int _count = 0;
	int _occupied_cells = 0;
	int _pairs = 0;
	int _touching = 0;
	int _cell_pairs = 0;
	int _cell_pairs_skipped = 0;
	int _coincident = 0;
	int _cell_population_max = 0;
	int _moved = 0;
	int _clamped = 0;
	double _displacement_sum = 0.0;

	int _cell_of(double x, double y) const;
	void _build_offsets();
	void _consider(const double *px, const double *py, int slot_a, int slot_b,
			double minimum, double minimum_sq);
	void _apply(double max_push);
};

} // namespace godot

#endif // PB_NATIVE_OVERLAP_KERNEL_H
