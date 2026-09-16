#ifndef PB_NATIVE_TARGET_QUERY_H
#define PB_NATIVE_TARGET_QUERY_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <vector>

namespace godot {

/**
 * The spatial query kernel of Project Banner's automatic target search, in native code.
 *
 * It is an accelerator and nothing else. Each tick it is handed the cell index the GDScript
 * BattleSpatialGrid builds anyway, plus the unit ids and positions behind it, and it answers
 * a search with the slot number of the opponent the same rules would pick. Two shapes are
 * implemented and measured against each other, because the boundary is as much the question
 * as the kernel:
 *
 *  - `collect()`: broadphase only. The caller keeps the exact test, so the answer is exact
 *    by construction - but every candidate crosses the boundary, which is the cost the
 *    shape A measurement exists to price.
 *  - `collect_nearest()`: broadphase and the exact test, both native. Nothing crosses per
 *    search, but the kernel must then hold positions and liveness that are true *at the
 *    moment of the query*, not at the rebuild: the caller mirrors its two mutation points -
 *    a soldier's movement and a soldier's death - into `update_position()` and
 *    `mark_dead()`, and the equivalence suite checks that the mirror is faithful.
 *
 * Slots are the caller's: unit i pushed in a rebuild owns slot i in the caller's own slot
 * array, so the kernel never holds a Godot Object pointer and nothing it stores can outlive
 * the battle that owns it.
 */
class NativeTargetQuery : public RefCounted {
	GDCLASS(NativeTargetQuery, RefCounted)

public:
	NativeTargetQuery();
	~NativeTargetQuery();

	// Configuration, once per battle.
	void setup(int cols, int rows, float cell_size, float query_margin, int capacity);
	// One tick's snapshot, in slot order: each living unit's cell, id, side bit and position.
	// Positions are the snapshot's; the caller keeps them live afterwards with
	// update_position() and mark_dead().
	void rebuild(const PackedInt32Array &cells, const PackedInt32Array &ids, const PackedInt32Array &bits, const PackedVector2Array &positions);

	// --- shape A: broadphase only. Returns how many candidates were written to the buffer.
	int collect(float px, float py, float radius, int wanted_bit);
	// Read-only view of the last search's candidates: slot numbers, zero-copy while the
	// caller does not hold on to it across the next call.
	PackedInt32Array candidates() const;

	// --- shape B: broadphase and the exact test. Returns the winning slot, or -1.
	int collect_nearest(float px, float py, float radius, int wanted_bit);

	// --- the two live-state mirrors. Called where the battle changes, not once a tick.
	void update_position(int slot, float x, float y);
	// A tick's worth of movement in one crossing: the same guard, the same write and the same order
	// as calling update_position() per soldier, for a caller that moves thousands of soldiers a tick
	// and cannot pay the bridge per soldier. The three arrays are parallel; entries past the shortest
	// are ignored. See D-118.
	void update_positions(const PackedInt32Array &slots, const PackedFloat32Array &xs, const PackedFloat32Array &ys);
	// The margin widens the *walk*; it never widens the radius the exact test promises.
	void set_margin(float margin);
	void mark_dead(int slot);

	// --- what the last search did, for the simulator's own counters.
	int last_count() const;
	int last_candidates() const;
	int last_cells_read() const;
	int last_walked_occupied() const;

	// --- bridge-cost probes. Benchmark 0 measures the boundary itself: these do nothing
	// but cross it, so the milestone can price a call before designing around one.
	int bench_ping() const;
	int bench_add(int a, int b) const;
	Vector2 bench_echo(Vector2 v) const;
	int bench_fill(int count);
	int bench_sum(const PackedInt32Array &values) const;

protected:
	static void _bind_methods();

private:
	int _cols = 0;
	int _rows = 0;
	int _capacity = 0;
	float _cell_size = 4.0f;
	float _margin = 0.0f;

	std::vector<int32_t> _head; // per cell: first slot, -1 when empty
	std::vector<int32_t> _tails; // per cell: last slot, for O(1) append
	std::vector<int32_t> _next; // per slot: next slot in the same cell
	std::vector<int32_t> _bits; // per cell: which sides are present
	std::vector<int32_t> _occupied; // cells in order of first occupancy, kept sorted
	std::vector<int32_t> _slot_ids; // per slot: the unit id, for the tie-break
	std::vector<int32_t> _slot_bits; // per slot: its side, so a mixed cell can be filtered
	std::vector<Vector2> _positions; // per slot: live position, mirrored by the caller
	std::vector<uint8_t> _alive; // per slot: live liveness, mirrored by the caller

	PackedInt32Array _out; // reused candidate buffer, never reallocated per search
	int _count = 0;
	int _candidates = 0;
	int _cells_read = 0;
	int _walked_occupied = 0;

	int _clamp_col(int col) const;
	int _clamp_row(int row) const;
	void _walk(float px, float py, float radius, int wanted_bit);
};

} // namespace godot

#endif // PB_NATIVE_TARGET_QUERY_H
