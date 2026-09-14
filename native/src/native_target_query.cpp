#include "native_target_query.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

NativeTargetQuery::NativeTargetQuery() {}
NativeTargetQuery::~NativeTargetQuery() {}

void NativeTargetQuery::setup(int p_cols, int p_rows, float p_cell_size, float p_query_margin, int p_capacity) {
	_cols = p_cols > 0 ? p_cols : 1;
	_rows = p_rows > 0 ? p_rows : 1;
	_cell_size = p_cell_size > 0.0f ? p_cell_size : 1.0f;
	_margin = p_query_margin;
	_capacity = p_capacity > 0 ? p_capacity : 1;

	const size_t cells = (size_t)_cols * (size_t)_rows;
	_head.assign(cells, -1);
	_tails.assign(cells, -1);
	_bits.assign(cells, 0);
	_next.assign((size_t)_capacity, -1);
	_slot_ids.assign((size_t)_capacity, 0);
	_slot_bits.assign((size_t)_capacity, 0);
	_positions.assign((size_t)_capacity, Vector2());
	_alive.assign((size_t)_capacity, 1);
	_occupied.clear();
	_occupied.reserve(cells < 4096 ? cells : 4096);
	_out.resize(_capacity);
	_count = 0;
	_candidates = 0;
	_cells_read = 0;
	_walked_occupied = 0;
}

void NativeTargetQuery::rebuild(const PackedInt32Array &p_cells, const PackedInt32Array &p_ids, const PackedInt32Array &p_bits, const PackedVector2Array &p_positions) {
	const int32_t *cells = p_cells.ptr();
	const int32_t *ids = p_ids.ptr();
	const int32_t *bits = p_bits.ptr();
	const Vector2 *positions = p_positions.ptr();
	const int n = p_cells.size();

	// The same reset and the same append order the GDScript grid uses, so the two indexes
	// hold the same chains and the same occupancy order. Slot i is the i-th living unit the
	// caller pushed, which is the slot it will index its own unit array with.
	std::fill(_head.begin(), _head.end(), -1);
	std::fill(_tails.begin(), _tails.end(), -1);
	std::fill(_bits.begin(), _bits.end(), 0);
	_occupied.clear();
	if (n > _capacity) {
		_capacity = n;
		_next.assign((size_t)_capacity, -1);
		_slot_ids.assign((size_t)_capacity, 0);
		_slot_bits.assign((size_t)_capacity, 0);
		_positions.assign((size_t)_capacity, Vector2());
		_alive.assign((size_t)_capacity, 1);
		_out.resize(_capacity);
	}
	std::fill(_next.begin(), _next.end(), -1);

	for (int i = 0; i < n; i++) {
		const int32_t cell = cells[i];
		_slot_ids[i] = ids[i];
		_slot_bits[i] = bits[i];
		_positions[i] = positions[i];
		_alive[i] = 1;
		if (cell < 0 || (size_t)cell >= _head.size()) {
			continue;
		}
		_bits[cell] |= bits[i];
		if (_tails[cell] < 0) {
			_head[cell] = i;
			_occupied.push_back(cell);
		} else {
			_next[_tails[cell]] = i;
		}
		_tails[cell] = i;
	}
	// The GDScript grid keeps its occupied list sorted, and the accelerator mirrors the index
	// rather than merely approximating it. Sorting once per rebuild is what makes the two
	// walks visit the same cells in the same order, so a disagreement between the backends
	// can only ever be about the answers.
	if (_occupied.size() > 1) {
		std::sort(_occupied.begin(), _occupied.end());
	}
}

void NativeTargetQuery::update_position(int slot, float x, float y) {
	if (slot >= 0 && (size_t)slot < _positions.size()) {
		_positions[slot] = Vector2(x, y);
	}
}

void NativeTargetQuery::set_margin(float p_margin) {
	_margin = p_margin;
}

void NativeTargetQuery::mark_dead(int slot) {
	if (slot >= 0 && (size_t)slot < _alive.size()) {
		_alive[slot] = 0;
	}
}

void NativeTargetQuery::_walk(float p_x, float p_y, float p_radius, int p_wanted_bit) {
	_count = 0;
	_candidates = 0;
	_cells_read = 0;
	_walked_occupied = 0;
	if (_occupied.empty() || p_radius <= 0.0f) {
		return;
	}

	const float reach = p_radius + _margin;
	const int min_col = _clamp_col((int)std::floor((p_x - reach) / _cell_size));
	const int max_col = _clamp_col((int)std::floor((p_x + reach) / _cell_size));
	const int min_row = _clamp_row((int)std::floor((p_y - reach) / _cell_size));
	const int max_row = _clamp_row((int)std::floor((p_y + reach) / _cell_size));
	const int span = (max_col - min_col + 1) * (max_row - min_row + 1);

	int32_t *out = _out.ptrw();
	int count = 0;

	// The same two ways to walk the same cells as the reference, chosen by the same rule, so
	// that a comparison of the two backends compares answers and not strategies.
	if (span > (int)_occupied.size()) {
		_walked_occupied = 1;
		for (const int32_t cell : _occupied) {
			if (p_wanted_bit != 0 && (_bits[cell] & p_wanted_bit) == 0) {
				continue;
			}
			const int row = cell / _cols;
			const int col = cell - row * _cols;
			if (col < min_col || col > max_col || row < min_row || row > max_row) {
				continue;
			}
			_cells_read++;
			for (int32_t slot = _head[cell]; slot >= 0; slot = _next[slot]) {
				if (count < _capacity) {
					out[count++] = slot;
				}
			}
		}
	} else {
		for (int row = min_row; row <= max_row; row++) {
			const int base = row * _cols;
			for (int col = min_col; col <= max_col; col++) {
				const int32_t cell = base + col;
				if (p_wanted_bit != 0 && (_bits[cell] & p_wanted_bit) == 0) {
					continue;
				}
				for (int32_t slot = _head[cell]; slot >= 0; slot = _next[slot]) {
					if (count < _capacity) {
						out[count++] = slot;
					}
				}
			}
		}
		_cells_read = span;
	}
	_count = count;
}

int NativeTargetQuery::collect(float p_x, float p_y, float p_radius, int p_wanted_bit) {
	// Broadphase only: the caller filters. The cell mask has already decided which cells
	// were worth opening; nothing here decides who is.
	_walk(p_x, p_y, p_radius, p_wanted_bit);
	return _count;
}

int NativeTargetQuery::collect_nearest(float p_x, float p_y, float p_radius, int p_wanted_bit) {
	_walk(p_x, p_y, p_radius, p_wanted_bit);
	const int32_t *out = _out.ptr();
	const float limit = p_radius * p_radius;
	int best_slot = -1;
	int best_id = 0;
	float best_distance = 0.0f;
	const Vector2 point(p_x, p_y);
	for (int i = 0; i < _count; i++) {
		const int32_t slot = out[i];
		_candidates++;
		if (p_wanted_bit != 0 && (_slot_bits[slot] & p_wanted_bit) == 0) {
			// The cell mask says a cell holds somebody of the wanted side, not that every
			// soldier in it does: a mixed cell has to be filtered per soldier, exactly as
			// the reference filters while it walks.
			continue;
		}
		if (!_alive[slot]) {
			// A soldier can die after the index was built and before its own turn comes
			// round; the reference rechecks this while it walks, so the kernel does too.
			continue;
		}
		const Vector2 &candidate = _positions[slot];
		const float dx = candidate.x - point.x;
		const float dy = candidate.y - point.y;
		const float distance = dx * dx + dy * dy;
		// The radius is a promise, not a hint: the walk returns a box, and a candidate half
		// a cell beyond the radius would end the escalation early. See D-065.
		if (distance > limit) {
			continue;
		}
		if (best_slot < 0 || distance < best_distance || (distance == best_distance && _slot_ids[slot] < best_id)) {
			best_slot = slot;
			best_id = _slot_ids[slot];
			best_distance = distance;
		}
	}
	return best_slot;
}

PackedInt32Array NativeTargetQuery::candidates() const {
	// A view of the whole buffer; the caller reads only the first last_count() entries.
	return _out;
}

int NativeTargetQuery::last_count() const { return _count; }
int NativeTargetQuery::last_candidates() const { return _candidates; }
int NativeTargetQuery::last_cells_read() const { return _cells_read; }
int NativeTargetQuery::last_walked_occupied() const { return _walked_occupied; }

int NativeTargetQuery::_clamp_col(int col) const {
	if (col < 0) {
		return 0;
	}
	if (col >= _cols) {
		return _cols - 1;
	}
	return col;
}

int NativeTargetQuery::_clamp_row(int row) const {
	if (row < 0) {
		return 0;
	}
	if (row >= _rows) {
		return _rows - 1;
	}
	return row;
}

// ---------------------------------------------------------------- bridge probes

int NativeTargetQuery::bench_ping() const { return 1; }
int NativeTargetQuery::bench_add(int a, int b) const { return a + b; }
Vector2 NativeTargetQuery::bench_echo(Vector2 v) const { return v; }

int NativeTargetQuery::bench_fill(int count) {
	int32_t *out = _out.ptrw();
	const int n = count < _capacity ? count : _capacity;
	for (int i = 0; i < n; i++) {
		out[i] = i;
	}
	_count = n;
	return n;
}

int NativeTargetQuery::bench_sum(const PackedInt32Array &values) const {
	const int32_t *v = values.ptr();
	const int n = values.size();
	int64_t sum = 0;
	for (int i = 0; i < n; i++) {
		sum += v[i];
	}
	return (int)sum;
}

void NativeTargetQuery::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "cols", "rows", "cell_size", "query_margin", "capacity"), &NativeTargetQuery::setup);
	ClassDB::bind_method(D_METHOD("rebuild", "cells", "ids", "bits", "positions"), &NativeTargetQuery::rebuild);
	ClassDB::bind_method(D_METHOD("collect", "px", "py", "radius", "wanted_bit"), &NativeTargetQuery::collect);
	ClassDB::bind_method(D_METHOD("collect_nearest", "px", "py", "radius", "wanted_bit"), &NativeTargetQuery::collect_nearest);
	ClassDB::bind_method(D_METHOD("update_position", "slot", "x", "y"), &NativeTargetQuery::update_position);
	ClassDB::bind_method(D_METHOD("mark_dead", "slot"), &NativeTargetQuery::mark_dead);
	ClassDB::bind_method(D_METHOD("set_margin", "margin"), &NativeTargetQuery::set_margin);
	ClassDB::bind_method(D_METHOD("candidates"), &NativeTargetQuery::candidates);
	ClassDB::bind_method(D_METHOD("last_count"), &NativeTargetQuery::last_count);
	ClassDB::bind_method(D_METHOD("last_candidates"), &NativeTargetQuery::last_candidates);
	ClassDB::bind_method(D_METHOD("last_cells_read"), &NativeTargetQuery::last_cells_read);
	ClassDB::bind_method(D_METHOD("last_walked_occupied"), &NativeTargetQuery::last_walked_occupied);

	ClassDB::bind_method(D_METHOD("bench_ping"), &NativeTargetQuery::bench_ping);
	ClassDB::bind_method(D_METHOD("bench_add", "a", "b"), &NativeTargetQuery::bench_add);
	ClassDB::bind_method(D_METHOD("bench_echo", "v"), &NativeTargetQuery::bench_echo);
	ClassDB::bind_method(D_METHOD("bench_fill", "count"), &NativeTargetQuery::bench_fill);
	ClassDB::bind_method(D_METHOD("bench_sum", "values"), &NativeTargetQuery::bench_sum);
}
