#include "native_soldier_batch.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>

using namespace godot;

namespace {
// One block per worker plus one for the caller, and never a block smaller than this: a batch of
// forty soldiers has no business waking eight threads to test forty distances.
constexpr int MIN_BLOCK = 1024;
// The most blocks a batch is ever cut into. Fixed, so the partitioning cannot depend on the pool.
constexpr int MAX_BLOCKS = 32;
} // namespace

NativeSoldierBatch::NativeSoldierBatch() {}

NativeSoldierBatch::~NativeSoldierBatch() {
	_stop_workers();
}

void NativeSoldierBatch::setup(int capacity, int workers, float retention_radius) {
	_stop_workers();
	_capacity = std::max(0, capacity);
	_retention_radius_sq = retention_radius * retention_radius;
	_decisions.resize(_capacity);
	_retained.resize(_capacity);
	_start_workers(workers);
}

// ---------------------------------------------------------------- the pool

void NativeSoldierBatch::_start_workers(int count) {
	int wanted = count;
	if (wanted <= 0) {
		const unsigned hw = std::thread::hardware_concurrency();
		wanted = (int)(hw == 0 ? 2u : hw) - 1;
	}
	wanted = std::max(0, std::min(wanted, 32));
	if (wanted == 0) {
		return;
	}
	_workers.reserve((size_t)wanted);
	for (int i = 0; i < wanted; i++) {
		_workers.emplace_back([this]() { _worker_main(); });
	}
}

void NativeSoldierBatch::_stop_workers() {
	if (_workers.empty()) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_stopping = true;
		_generation++;
	}
	_wake.notify_all();
	for (std::thread &worker : _workers) {
		if (worker.joinable()) {
			worker.join();
		}
	}
	_workers.clear();
	std::lock_guard<std::mutex> lock(_mutex);
	_stopping = false;
	_pending = 0;
	_blocks_claimed = 0;
	_job_count = 0;
}

void NativeSoldierBatch::_worker_main() {
	int seen = 0;
	for (;;) {
		std::function<void(int, int)> job;
		int count = 0;
		{
			std::unique_lock<std::mutex> lock(_mutex);
			_wake.wait(lock, [this, &seen]() { return _generation != seen || _stopping; });
			if (_stopping) {
				return;
			}
			seen = _generation;
			job = _job;
			count = _job_count;
		}
		// Blocks are claimed rather than assigned, so a slow worker cannot leave another idle.
		// Which worker runs which block cannot change the answer: every block writes its own
		// slice of the output and nothing else.
		for (;;) {
			int block = 0;
			{
				std::lock_guard<std::mutex> lock(_mutex);
				if (_blocks_claimed >= count) {
					break;
				}
				block = _blocks_claimed++;
			}
			job(block, count);
		}
		{
			std::lock_guard<std::mutex> lock(_mutex);
			_pending--;
			if (_pending <= 0) {
				_done.notify_all();
			}
		}
	}
}

int NativeSoldierBatch::_block_count(int count) const {
	// The block count is a function of the *batch* and never of the pool. A reduction merged in
	// block order is only bit-identical at any worker count if the blocks themselves are the same
	// blocks: a pool that cut a batch into two when running alone and twenty-four when running on
	// the machine's cores would sum the same numbers in different groupings and land in different
	// last digits. This was caught by the probe rather than reasoned about - the first version
	// took the pool into account and disagreed in the eighth decimal place.
	return std::max(1, std::min(MAX_BLOCKS, (count + MIN_BLOCK - 1) / MIN_BLOCK));
}

void NativeSoldierBatch::_parallel_for(int count, const std::function<void(int, int)> &fn) {
	if (count <= 0) {
		return;
	}
	const int blocks = _block_count(count);
	_job_count = blocks;
	if (_workers.empty() || blocks <= 1) {
		// No pool, or a batch too small to be worth waking one: the caller runs the single block
		// and no thread is touched.
		fn(0, 1);
		return;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_job = fn;
		_job_count = blocks;
		_blocks_claimed = 0;
		_pending = (int)_workers.size(); // the caller runs block 0 itself, below
		_generation++;
	}
	_wake.notify_all();
	fn(0, blocks);
	// The caller does not wait for the workers to go idle; it waits until every block that was
	// handed out has been run, which is the only ordering that matters.
	std::unique_lock<std::mutex> lock(_mutex);
	_done.wait(lock, [this]() { return _pending <= 0; });
}

PackedFloat64Array NativeSoldierBatch::probe_parallel_sum(int count) {
	PackedFloat64Array answer;
	answer.resize(4);
	if (count <= 0) {
		return answer;
	}
	_blocks = _block_count(count);
	const int blocks = _blocks;
	_counts.assign((size_t)blocks, BlockCounts());
	// One slot per block, merged in block order: the only cross-worker reduction in this kernel.
	std::vector<double> partials((size_t)blocks, 0.0);
	const auto started = std::chrono::steady_clock::now();
	_parallel_for(count, [&](int block, int block_count) {
		double sum = 0.0;
		const int begin = (int)((int64_t)count * block / block_count);
		const int end = (int)((int64_t)count * (block + 1) / block_count);
		for (int i = begin; i < end; i++) {
			const double x = (double)i * 0.5;
			const double y = (double)i * 0.25;
			sum += std::sqrt(x * x + y * y);
		}
		partials[(size_t)block] = sum;
	});
	const auto finished = std::chrono::steady_clock::now();
	double total = 0.0;
	for (int block = 0; block < blocks; block++) {
		total += partials[(size_t)block];
	}
	answer[0] = total;
	answer[1] = blocks;
	answer[2] = (int)_workers.size();
	answer[3] = (double)std::chrono::duration_cast<std::chrono::microseconds>(finished - started).count();
	return answer;
}

// ---------------------------------------------------------------- the pass

PackedInt32Array NativeSoldierBatch::run_awareness(
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
		const PackedInt32Array &box_offsets) {
	const int count = alive.size();
	if (count <= 0 || positions.size() < count * 2 || sides.size() < count ||
			targets.size() < count || reach.size() < count || due.size() < count ||
			look_now.size() < count || bodies.size() < count) {
		return PackedInt32Array();
	}
	// A battle with no bodies passes no boxes at all, which is legal: every body test below is
	// skipped for a soldier in no body, and bounded by `box_total` for one that is.
	const int box_total = (int)(boxes.size() / 4);
	const int band_count = bands.size();
	_capacity = count;
	_decisions.resize(count);
	_retained.resize(count);

	const float *pos = positions.ptr();
	const int32_t *alive_ptr = alive.ptr();
	const int32_t *side_ptr = sides.ptr();
	const int32_t *target_ptr = targets.ptr();
	const float *reach_ptr = reach.ptr();
	const int32_t *due_ptr = due.ptr();
	const int32_t *look_ptr = look_now.ptr();
	const int32_t *body_ptr = bodies.ptr();
	const float *band_ptr = bands.ptr();
	const float *box_ptr = boxes.ptr();
	const int32_t *box_count_ptr = box_counts.ptr();
	const int32_t *box_offset_ptr = box_offsets.ptr();
	int32_t *decision_ptr = _decisions.ptrw();
	int32_t *retained_ptr = _retained.ptrw();

	const float retention_sq = _retention_radius_sq;
	_blocks = _block_count(count);
	_counts.assign((size_t)_blocks, BlockCounts());

	const auto started = std::chrono::steady_clock::now();
	_parallel_for(count, [&](int block, int block_count) {
		BlockCounts &counts = _counts[(size_t)block];
		// The soldier's own slots are the only memory this writes, so a block may be interrupted,
		// reordered or run on any worker without changing a single answer.
		const int begin = (int)((int64_t)count * block / block_count);
		const int end = (int)((int64_t)count * (block + 1) / block_count);
		for (int slot = begin; slot < end; slot++) {
			if (alive_ptr[slot] == 0) {
				decision_ptr[slot] = DECISION_NONE;
				retained_ptr[slot] = -1;
				counts.none++;
				continue;
			}
			counts.tested++;
			const float x = pos[slot * 2];
			const float y = pos[slot * 2 + 1];
			const int32_t remember = target_ptr[slot];
			int32_t decision = DECISION_NONE;
			int32_t kept = -1;

			// 1. The opponent already remembered, if it is still worth having.
			if (remember >= 0 && remember < count && alive_ptr[remember] != 0 &&
					side_ptr[remember] != side_ptr[slot]) {
				const float dx = pos[remember * 2] - x;
				const float dy = pos[remember * 2 + 1] - y;
				const float d2 = dx * dx + dy * dy;
				// Two different distances, which is the distinction the sim draws: the retention
				// radius says whether the opponent is still worth remembering, and the soldier's
				// own reach says whether it can strike it now or is walking to it.
				if (d2 <= retention_sq) {
					const float soldier_reach = reach_ptr[slot];
					decision = d2 <= soldier_reach * soldier_reach ? DECISION_KEEP : DECISION_HOLD;
					kept = remember;
				}
			}

			// 2. Nothing worth keeping: this soldier's awareness tick has come round, so the
			// question is whether the hierarchy lets it look. The cadence decides whether the
			// question is asked at all (the sim answers a soldier whose turn has not come with
			// the cheap answer and never consults the gate), and `struck` is one of the ways the
			// sim's gate says yes, alongside the contact band.
			if (decision == DECISION_NONE && due_ptr[slot] != 0) {
				const int32_t body = body_ptr[slot];
				if (body < 0 || look_ptr[slot] != 0) {
					// No body: the soldier is its own formation, and the pre-formation rule is
					// that a due awareness tick looks. Struck recently: the same.
					decision = DECISION_SEARCH;
				} else if (body < band_count && body < box_counts.size() &&
						body < box_offsets.size()) {
					const float band = band_ptr[body];
					const float band_sq = band * band;
					const int first = box_offset_ptr[body];
					const int boxes_here = box_count_ptr[body];
					bool in_band = false;
					if (first >= 0 && boxes_here > 0 && first + boxes_here <= box_total) {
						for (int b = 0; b < boxes_here; b++) {
							const float *box = box_ptr + (size_t)(first + b) * 4;
							const float dx = std::max(std::max(box[0] - x, 0.0f), x - box[2]);
							const float dy = std::max(std::max(box[1] - y, 0.0f), y - box[3]);
							counts.box_tests++;
							if (dx * dx + dy * dy <= band_sq) {
								in_band = true;
								break;
							}
						}
					}
					decision = in_band ? DECISION_SEARCH : DECISION_DEFER;
				}
			}

			decision_ptr[slot] = decision;
			retained_ptr[slot] = kept;
			switch (decision) {
				case DECISION_KEEP: counts.keep++; break;
				case DECISION_HOLD: counts.hold++; break;
				case DECISION_DEFER: counts.defer++; break;
				case DECISION_SEARCH: counts.search++; break;
				default: counts.none++; break;
			}
		}
	});
	const auto finished = std::chrono::steady_clock::now();
	_microseconds = std::chrono::duration_cast<std::chrono::microseconds>(finished - started).count();

	return _decisions;
}

Dictionary NativeSoldierBatch::stats() const {
	// Summed in block order: the one place where several workers contribute to one number, and
	// the reason a multi-worker count is identical to a single-worker one.
	BlockCounts total;
	for (const BlockCounts &counts : _counts) {
		total.keep += counts.keep;
		total.hold += counts.hold;
		total.defer += counts.defer;
		total.search += counts.search;
		total.none += counts.none;
		total.box_tests += counts.box_tests;
		total.tested += counts.tested;
	}
	Dictionary result;
	result["keep"] = (int64_t)total.keep;
	result["hold"] = (int64_t)total.hold;
	result["defer"] = (int64_t)total.defer;
	result["search"] = (int64_t)total.search;
	result["none"] = (int64_t)total.none;
	result["box_tests"] = (int64_t)total.box_tests;
	result["tested"] = (int64_t)total.tested;
	result["blocks"] = _blocks;
	result["workers"] = (int)_workers.size();
	result["usec"] = (int64_t)_microseconds;
	return result;
}

void NativeSoldierBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "capacity", "workers", "retention_radius"), &NativeSoldierBatch::setup);
	ClassDB::bind_method(D_METHOD("worker_count"), &NativeSoldierBatch::worker_count);
	ClassDB::bind_method(D_METHOD("capacity"), &NativeSoldierBatch::capacity);
	ClassDB::bind_method(D_METHOD("run_awareness", "positions", "alive", "sides", "targets", "reach", "due", "look_now", "bodies", "bands", "boxes", "box_counts", "box_offsets"), &NativeSoldierBatch::run_awareness);
	ClassDB::bind_method(D_METHOD("decisions"), &NativeSoldierBatch::decisions);
	ClassDB::bind_method(D_METHOD("retained"), &NativeSoldierBatch::retained);
	ClassDB::bind_method(D_METHOD("stats"), &NativeSoldierBatch::stats);
	ClassDB::bind_method(D_METHOD("probe_parallel_sum", "count"), &NativeSoldierBatch::probe_parallel_sum);

	ClassDB::bind_integer_constant(get_class_static(), "", "DECISION_NONE", DECISION_NONE);
	ClassDB::bind_integer_constant(get_class_static(), "", "DECISION_KEEP", DECISION_KEEP);
	ClassDB::bind_integer_constant(get_class_static(), "", "DECISION_HOLD", DECISION_HOLD);
	ClassDB::bind_integer_constant(get_class_static(), "", "DECISION_DEFER", DECISION_DEFER);
	ClassDB::bind_integer_constant(get_class_static(), "", "DECISION_SEARCH", DECISION_SEARCH);
}
