#include "native_overlap_kernel.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

NativeOverlapKernel::NativeOverlapKernel() {}
NativeOverlapKernel::~NativeOverlapKernel() {}

void NativeOverlapKernel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "cols", "rows", "cell_size", "reach"), &NativeOverlapKernel::setup);
	ClassDB::bind_method(D_METHOD("resolve", "pos_x", "pos_y", "body_code", "body_spacing", "settled", "minimum", "settle_epsilon", "max_push"),
			&NativeOverlapKernel::resolve);
	ClassDB::bind_method(D_METHOD("last_indexed"), &NativeOverlapKernel::last_indexed);
	ClassDB::bind_method(D_METHOD("last_occupied_cells"), &NativeOverlapKernel::last_occupied_cells);
	ClassDB::bind_method(D_METHOD("last_pairs"), &NativeOverlapKernel::last_pairs);
	ClassDB::bind_method(D_METHOD("last_touching"), &NativeOverlapKernel::last_touching);
	ClassDB::bind_method(D_METHOD("last_cell_pairs"), &NativeOverlapKernel::last_cell_pairs);
	ClassDB::bind_method(D_METHOD("last_cell_pairs_skipped"), &NativeOverlapKernel::last_cell_pairs_skipped);
	ClassDB::bind_method(D_METHOD("last_coincident"), &NativeOverlapKernel::last_coincident);
	ClassDB::bind_method(D_METHOD("last_cell_population_max"), &NativeOverlapKernel::last_cell_population_max);
	ClassDB::bind_method(D_METHOD("last_moved"), &NativeOverlapKernel::last_moved);
	ClassDB::bind_method(D_METHOD("last_clamped"), &NativeOverlapKernel::last_clamped);
	ClassDB::bind_method(D_METHOD("last_displacement_sum"), &NativeOverlapKernel::last_displacement_sum);
}

void NativeOverlapKernel::setup(int cols, int rows, double cell_size, int reach) {
	_cols = cols < 1 ? 1 : cols;
	_rows = rows < 1 ? 1 : rows;
	_cell_size = cell_size < 0.05 ? 0.05 : cell_size;
	_reach = reach < 1 ? 1 : reach;
	_head.assign(static_cast<size_t>(_cols) * static_cast<size_t>(_rows), -1);
	_tails.assign(static_cast<size_t>(_cols) * static_cast<size_t>(_rows), -1);
	_cell_settled.assign(static_cast<size_t>(_cols) * static_cast<size_t>(_rows), 0);
	_cell_body.assign(static_cast<size_t>(_cols) * static_cast<size_t>(_rows), -1);
	_occupied.clear();
	_count = 0;
}

// The cell a position falls in, identical to BattleOverlapGrid._cell_of: the same clamping
// expression, so a soldier standing on a boundary lands in the same cell in both passes.
int NativeOverlapKernel::_cell_of(double x, double y) const {
	int row = static_cast<int>(std::floor(y / _cell_size));
	if (row < 0) {
		row = 0;
	} else if (row > _rows - 1) {
		row = _rows - 1;
	}
	int col = static_cast<int>(std::floor(x / _cell_size));
	if (col < 0) {
		col = 0;
	} else if (col > _cols - 1) {
		col = _cols - 1;
	}
	return row * _cols + col;
}

// The forward half of the square neighbourhood, in the caller's order: the same list the
// GDScript pass builds from the same two loops.
void NativeOverlapKernel::_build_offsets() {
	_offset_dx.clear();
	_offset_dy.clear();
	for (int dy = 0; dy <= _reach; ++dy) {
		int min_dx = dy > 0 ? -_reach : 1;
		for (int dx = min_dx; dx <= _reach; ++dx) {
			_offset_dx.push_back(dx);
			_offset_dy.push_back(dy);
		}
	}
}

PackedFloat64Array NativeOverlapKernel::resolve(
		const PackedFloat64Array &pos_x,
		const PackedFloat64Array &pos_y,
		const PackedInt32Array &body_code,
		const PackedFloat64Array &body_spacing,
		const PackedByteArray &settled,
		double minimum,
		double settle_epsilon,
		double max_push) {
	_count = static_cast<int>(pos_x.size());
	_pairs = 0;
	_touching = 0;
	_cell_pairs = 0;
	_cell_pairs_skipped = 0;
	_coincident = 0;
	_cell_population_max = 0;
	_moved = 0;
	_clamped = 0;
	_displacement_sum = 0.0;
	_occupied_cells = 0;

	if (_count <= 0 || minimum <= 0.0) {
		_out.clear();
		return _out;
	}

	// Capacity first: the caller's arrays are the roster, so the kernel's own arrays follow
	// them rather than being sized by a guess.
	if (static_cast<int>(_next.size()) < _count) {
		_next.resize(_count);
		_push_x.resize(_count);
		_push_y.resize(_count);
	}
	const size_t wanted_cells = static_cast<size_t>(_cols) * static_cast<size_t>(_rows);
	if (_head.size() < wanted_cells) {
		_head.assign(wanted_cells, -1);
		_tails.assign(wanted_cells, -1);
		_cell_settled.assign(wanted_cells, 0);
		_cell_body.assign(wanted_cells, -1);
	}

	_build_offsets();

	// Only the cells the previous pass used are cleared, the same way the GDScript pass does
	// it: work proportional to the army rather than to the ground.
	for (size_t i = 0; i < _occupied.size(); ++i) {
		int cell = _occupied[i];
		_head[cell] = -1;
		_tails[cell] = -1;
		_cell_settled[cell] = 0;
		_cell_body[cell] = -1;
	}
	_occupied.clear();

	const double *px = pos_x.ptr();
	const double *py = pos_y.ptr();
	const int32_t *codes = body_code.ptr();
	const uint8_t *settled_flags = settled.ptr();
	const double *spacing = body_spacing.ptr();
	const int64_t spacing_size = body_spacing.size();

	for (int slot = 0; slot < _count; ++slot) {
		int cell = _cell_of(px[slot], py[slot]);
		_next[slot] = -1;
		if (_tails[cell] < 0) {
			_head[cell] = slot;
			_occupied.push_back(cell);
		} else {
			_next[_tails[cell]] = slot;
		}
		_tails[cell] = slot;
		_push_x[slot] = 0.0f;
		_push_y[slot] = 0.0f;
	}
	_occupied_cells = static_cast<int>(_occupied.size());

	// A cell is a settled body's interior when everyone in it is settled and they are all
	// the same body. Walking each bucket once, after the index is built, gives the same
	// answer as the GDScript pass's incremental test because both are asking the same
	// question of the same occupants.
	for (size_t i = 0; i < _occupied.size(); ++i) {
		int cell = _occupied[i];
		int first = _head[cell];
		int code = codes[first];
		bool settled_cell = settled_flags[first] != 0;
		int population = 1;
		for (int slot = _next[first]; slot >= 0; slot = _next[slot]) {
			++population;
			if (settled_cell && (settled_flags[slot] == 0 || codes[slot] != code)) {
				settled_cell = false;
			}
		}
		if (population > _cell_population_max) {
			_cell_population_max = population;
		}
		_cell_settled[cell] = settled_cell ? 1 : 0;
		_cell_body[cell] = settled_cell ? code : -1;
	}

	const double minimum_sq = minimum * minimum;
	// The same required spacing the GDScript pass computes, from the same two numbers.
	const double required_spacing = minimum + settle_epsilon * 2.0;

	for (size_t i = 0; i < _occupied.size(); ++i) {
		int cell = _occupied[i];

		// Inside one cell: every pair, once, in bucket order.
		int slot_a = _head[cell];
		while (slot_a >= 0) {
			int slot_b = _next[slot_a];
			while (slot_b >= 0) {
				++_pairs;
				_consider(px, py, slot_a, slot_b, minimum, minimum_sq);
				slot_b = _next[slot_b];
			}
			slot_a = _next[slot_a];
		}

		// Against the half-neighbourhood in front, so each pair of cells is visited once.
		int cell_row = cell / _cols;
		int cell_col = cell - cell_row * _cols;
		for (size_t offset = 0; offset < _offset_dx.size(); ++offset) {
			int row = cell_row + _offset_dy[offset];
			if (row < 0 || row >= _rows) {
				continue;
			}
			int col = cell_col + _offset_dx[offset];
			if (col < 0 || col >= _cols) {
				continue;
			}
			int neighbour = cell + _offset_dy[offset] * _cols + _offset_dx[offset];
			if (neighbour < 0 || neighbour >= static_cast<int>(_head.size()) || _head[neighbour] < 0) {
				continue;
			}
			++_cell_pairs;
			// The settled proof, over body codes. The spacing it tests is the body's own,
			// read from the packed array the caller handed over, and the comparison is
			// against the same required spacing the GDScript pass computes.
			if (_cell_settled[cell] != 0 && _cell_settled[neighbour] != 0) {
				int code = _cell_body[cell];
				if (code >= 0 && code == _cell_body[neighbour] && code < spacing_size && spacing[code] > required_spacing) {
					++_cell_pairs_skipped;
					continue;
				}
			}
			int other = _head[neighbour];
			while (other >= 0) {
				int mine = _head[cell];
				while (mine >= 0) {
					++_pairs;
					_consider(px, py, mine, other, minimum, minimum_sq);
					mine = _next[mine];
				}
				other = _next[other];
			}
		}
	}

	_apply(max_push);
	return _out;
}

// One pair: the reference's arithmetic, on values from the caller's packed arrays.
void NativeOverlapKernel::_consider(const double *px, const double *py, int slot_a, int slot_b,
		double minimum, double minimum_sq) {
	const double ax = px[slot_a];
	const double ay = py[slot_a];
	const double dx = px[slot_b] - ax;
	const double dy = py[slot_b] - ay;
	const double distance_sq = dx * dx + dy * dy;
	if (distance_sq >= minimum_sq) {
		return;
	}
	++_touching;
	if (distance_sq <= 0.0000001) {
		++_coincident;
		const double half = minimum * 0.5;
		_push_x[slot_a] = static_cast<float>(static_cast<double>(_push_x[slot_a]) - half);
		_push_x[slot_b] = static_cast<float>(static_cast<double>(_push_x[slot_b]) + half);
		return;
	}
	const double distance = std::sqrt(distance_sq);
	const double scale = (minimum - distance) * 0.5 / distance;
	const double ox = dx * scale;
	const double oy = dy * scale;
	_push_x[slot_a] = static_cast<float>(static_cast<double>(_push_x[slot_a]) - ox);
	_push_y[slot_a] = static_cast<float>(static_cast<double>(_push_y[slot_a]) - oy);
	_push_x[slot_b] = static_cast<float>(static_cast<double>(_push_x[slot_b]) + ox);
	_push_y[slot_b] = static_cast<float>(static_cast<double>(_push_y[slot_b]) + oy);
}

// The clamp and the displacement the caller will apply, in one pass. Nothing here writes to
// a battle: the output is a number per soldier per axis and the units stay the caller's.
void NativeOverlapKernel::_apply(double max_push) {
	const double ceiling_sq = max_push * max_push;
	_out.resize(_count * 2);
	double *out = _out.ptrw();
	for (int slot = 0; slot < _count; ++slot) {
		double ppx = static_cast<double>(_push_x[slot]);
		double ppy = static_cast<double>(_push_y[slot]);
		if (ppx == 0.0 && ppy == 0.0) {
			out[slot * 2] = 0.0;
			out[slot * 2 + 1] = 0.0;
			continue;
		}
		++_moved;
		const double magnitude_sq = ppx * ppx + ppy * ppy;
		if (magnitude_sq > ceiling_sq) {
			const double factor = max_push / std::sqrt(magnitude_sq);
			ppx *= factor;
			ppy *= factor;
			++_clamped;
		}
		_displacement_sum += std::sqrt(ppx * ppx + ppy * ppy);
		out[slot * 2] = ppx;
		out[slot * 2 + 1] = ppy;
	}
}

int NativeOverlapKernel::last_indexed() const { return _count; }
int NativeOverlapKernel::last_occupied_cells() const { return _occupied_cells; }
int NativeOverlapKernel::last_pairs() const { return _pairs; }
int NativeOverlapKernel::last_touching() const { return _touching; }
int NativeOverlapKernel::last_cell_pairs() const { return _cell_pairs; }
int NativeOverlapKernel::last_cell_pairs_skipped() const { return _cell_pairs_skipped; }
int NativeOverlapKernel::last_coincident() const { return _coincident; }
int NativeOverlapKernel::last_cell_population_max() const { return _cell_population_max; }
int NativeOverlapKernel::last_moved() const { return _moved; }
int NativeOverlapKernel::last_clamped() const { return _clamped; }
double NativeOverlapKernel::last_displacement_sum() const { return _displacement_sum; }
