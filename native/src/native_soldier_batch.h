#ifndef PB_NATIVE_SOLDIER_BATCH_H
#define PB_NATIVE_SOLDIER_BATCH_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace godot {

/**
 * The per-soldier loop's data-only slices, in native code, over a struct-of-arrays layout.
 *
 * [b]What it is for.[/b] At twenty thousand soldiers the update loop is the largest phase of a
 * tick - 211.7 ms of 408.3 ms, measured in Step 7.8C - and inside it the largest single slice is
 * awareness: twenty thousand soldiers a tick, each probing an opponent it already has (a map
 * lookup and two distance checks) to discover that almost all of them should keep doing exactly
 * what they were doing. That is arithmetic over contiguous arrays, which is the shape this kernel
 * is built for and the shape the GDScript loop cannot have.
 *
 * [b]Struct of arrays, not array of structs.[/b] Positions are two parallel float arrays rather
 * than a `Vector2` per soldier, liveness, side, remembered target, cadence and body are parallel
 * integer arrays, and every hot loop walks one platform for the whole batch. Nothing is loaded
 * that a lane does not need, no pointer is chased, and the distance test is the same instruction
 * over eight lanes of the same array - which is what lets the compiler vectorise it without
 * anybody writing intrinsics. Whether it did is not asserted here; what the pass cost is reported
 * (`stats()["usec"]`), and the shapes are measured against each other by the caller.
 *
 * [b]The pool is persistent and the partitioning is fixed.[/b] Workers start once at `setup()` and
 * stay; a pass hands them contiguous blocks of the batch. Every pass here is [i]element-wise[/i]:
 * a soldier writes its own decision slot and nothing else, reads arrays nobody writes, and so
 * cannot race and cannot depend on how many workers exist. The counters are accumulated per block
 * and summed in block order - the only cross-soldier reduction in the kernel, and the reason the
 * answer is bit-identical at one worker and at sixteen. `probe_parallel_sum()` exists so the
 * suite can assert that directly rather than trust it.
 *
 * [b]The boundary is paid once a tick.[/b] Six arrays in, one decision array out. Nothing is
 * called per soldier: Step 7.7 measured that the boundary, not the arithmetic, is what makes a
 * native accelerator slow, and a per-soldier method call is the boundary at its worst.
 */
class NativeSoldierBatch : public RefCounted {
	GDCLASS(NativeSoldierBatch, RefCounted)

public:
	NativeSoldierBatch();
	~NativeSoldierBatch();

	// --- configuration, once per battle -----------------------------------------------
	//
	// `workers`: 0 means one less than the machine's cores, 1 means the calling thread runs every
	// block and no threads are started at all. Any value is legal: the partitioning is fixed and
	// the results do not depend on it.
	void setup(int capacity, int workers, float retention_radius);

	int worker_count() const { return (int)_workers.size(); }
	int capacity() const { return _capacity; }

	// --- one tick's awareness pass ----------------------------------------------------
	//
	// Every array is in slot order and all of them are the caller's own, so nothing here holds a
	// Godot object and nothing can outlive the battle that owns it:
	//
	//   positions    slot*2 = x, slot*2+1 = y
	//   alive        1 living, 0 dead
	//   sides        the soldier's side bit
	//   targets      the slot of the opponent the soldier remembers, or -1
	//   reach        the soldier's own attack reach: the distance at which a remembered
	//                opponent is one it can strike now rather than one it is walking to
	//   due          1 when this soldier's awareness tick has come round
	//   struck       1 when the soldier was struck recently enough that the sim's gate lets it
	//                retaliate, which is one of the ways a look is allowed besides the band
	//   bodies       the body the soldier stands in, or -1 for a soldier in no body
	//   bands        per body: the contact band's radius (squared by the kernel)
	//   boxes        flattened [min_x, min_y, max_x, max_y] per (body, nearby enemy) pair
	//   box_counts   per body: how many boxes it has
	//   box_offsets  per body: where its boxes begin in `boxes`
	//
	// It answers, per soldier, one of:
	//
	//   DECISION_KEEP    the opponent it remembers is alive, hostile and in reach
	//   DECISION_HOLD    it is alive and hostile but out of reach: the soldier walks to it
	//   DECISION_DEFER   it wants an opponent and its body is not in this fight, so it may not look
	//   DECISION_SEARCH  it wants an opponent and the hierarchy allows the look
	//   DECISION_NONE    dead, or its awareness tick has not come round (the sim answers a
	//                    soldier whose turn has not come without consulting the gate at all)
	//
	// A soldier under an explicit order never reaches this pass - the caller resolves orders
	// first, exactly as the GDScript loop does - and one with no body gets the pre-formation
	// rule, which is that a due tick looks.
	enum Decision {
		DECISION_NONE = 0,
		DECISION_KEEP = 1,
		DECISION_HOLD = 2,
		DECISION_DEFER = 3,
		DECISION_SEARCH = 4,
	};

	PackedInt32Array run_awareness(
			const PackedFloat32Array &positions,
			const PackedInt32Array &alive,
			const PackedInt32Array &sides,
			const PackedInt32Array &targets,
			const PackedFloat32Array &reach,
			const PackedInt32Array &due,
			const PackedInt32Array &look_now,
			const PackedInt32Array &bodies,
			const PackedFloat32Array &bands,
			const PackedFloat32Array &boxes,
			const PackedInt32Array &box_counts,
			const PackedInt32Array &box_offsets);

	// The decisions of the last pass, one int per soldier in slot order.
	PackedInt32Array decisions() const { return _decisions; }
	// The opponent each soldier is to be pointed at after the pass, or -1.
	PackedInt32Array retained() const { return _retained; }
	// What the pass did, in the same words the GDScript counters use, plus the microseconds spent
	// inside the pass, the number of blocks it was cut into and the number of workers it ran on.
	Dictionary stats() const;

	// A determinism probe for the suite: sums `sqrt(x^2 + y^2)` over the first `count` soldiers of
	// a generated batch through the pool, and returns [sum, blocks, workers, usec]. The same count
	// must give bit-identical sums at one worker and at sixteen, and this is the cheapest way to
	// assert that about the partitioning itself rather than about a pass that happens to use it.
	PackedFloat64Array probe_parallel_sum(int count);

private:
	PackedInt32Array _decisions;
	PackedInt32Array _retained;

	struct BlockCounts {
		int64_t keep = 0;
		int64_t hold = 0;
		int64_t defer = 0;
		int64_t search = 0;
		int64_t none = 0;
		int64_t box_tests = 0;
		int64_t tested = 0;
	};
	std::vector<BlockCounts> _counts;
	int64_t _microseconds = 0;
	int _blocks = 0;

	int _capacity = 0;
	float _retention_radius_sq = 0.0f;

	std::vector<std::thread> _workers;
	std::mutex _mutex;
	std::condition_variable _wake;
	std::condition_variable _done;
	int _generation = 0;
	int _pending = 0;
	int _job_count = 0;
	int _blocks_claimed = 0;
	std::function<void(int, int)> _job;
	bool _stopping = false;

	void _start_workers(int count);
	void _stop_workers();
	void _worker_main();
	void _parallel_for(int count, const std::function<void(int, int)> &fn);
	int _block_count(int count) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // PB_NATIVE_SOLDIER_BATCH_H
