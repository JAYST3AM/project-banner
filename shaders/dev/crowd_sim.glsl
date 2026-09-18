#[compute]
#version 450

// Dev-only probe: a battle whose soldiers are simulated on the GPU - and whose soldiers
// belong to formations.
//
// One agent per invocation, state resident in the buffers below, one mode per dispatch:
//   0 clear the grid, the damage, the correction and the counters   1 bin the living into the grid
//   2 read neighbours: separate hard, measure the proof, acquire / keep / release / strike a target
//   3 walk to your place in the line, take the blows, and never pass through anybody
//   4 add this round's separation, in fixed-point integers   5 apply it
// The caller runs 0-3 in order, then 4 and 5 once a round for three rounds, with a barrier
// between every pass, once a tick. The bodies themselves are ten numbers each and are advanced on
// the CPU, which is where the game keeps them too: a body is a roll of ids plus geometry, and the
// men are the crowd.
//
// 4 and 5 are split apart, and the sums are integers, for one reason: reproducibility. A round
// that wrote positions while reading its neighbours produced a different battle every run, and a
// float sum whose value depends on the order the neighbours were visited in did the same. Both
// were measured, not suspected: two identical runs parted company at tick 2.
//
// A soldier's place is his body's lattice - anchor, facing, files, ranks, spacing - so a
// body marches as one thing, its ranks dress, and the gaps the fallen leave stay open.
//
// Target acquisition (Phase 4.3 slice 1). A soldier remembers the opponent it is dealing
// with (binding 11: target id and its next awareness tick) instead of striking every enemy
// neighbour in reach. It keeps the opponent while it is alive, hostile and within the retention
// radius; it looks again on its own staggered cadence (agent id modulo the interval) or at once
// when a loss was taken inside its own reach; and it releases an opponent that dies or walks out
// of relevance. Only the acquired opponent is struck. The search is the 3x3 neighbourhood this
// dispatch already reads for the separation, plus one ring when that finds nobody; ties are broken
// by the lower agent id so the answer cannot depend on the order the grid binned the men in.
//
// The legacy behaviour - every enemy within reach is struck, no opponent is remembered - is kept
// in this same shader behind a parameter (params.f[17] < 0.5) so a benchmark can run before and
// after in one build, tick for tick.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// xy = position, zw = the step taken last tick.
layout(set = 0, binding = 0, std430) restrict buffer Agents { vec4 s[]; } agents;
// xy = the separation this tick, already halved for the pair.
layout(set = 0, binding = 1, std430) restrict buffer Pushes { vec4 p[]; } pushes;
// One cursor per grid cell: how many agents have been binned into it this tick.
layout(set = 0, binding = 2, std430) restrict buffer Cursors { uint c[]; } cursors;
// cell * SLOT_CAPACITY + slot -> agent index.
layout(set = 0, binding = 3, std430) restrict buffer Slots { uint s[]; } slots;
// [0] agents, [1] grid width, [2] grid height, [3] cell size, [4] separation radius,
// [5] dt, [6] field width, [7] field height, [8] walk speed, [9] reach, [10] blow,
// [11] the most a soldier may be pushed in one tick, [12] the agreed minimum enemy gap,
// [13] the current simulation tick, [14] target reacquisition cadence in ticks,
// [15] target retention radius, [16] target switch advantage, [17] 1 = target acquisition on
// (the shipped behaviour), 0 = every enemy in reach struck (the legacy behaviour),
// [18] target search radius, [19] 1 = an in-reach loss reacquires at once.
layout(set = 0, binding = 4, std430) restrict buffer Params { float f[]; } params;
// [0] agents the grid could not hold, [1] neighbour probes, [2] blows landed, [3] fallen,
// [4] enemy pairs closer than half the separation, [5] closest enemy gap x1000 (min, cleared
// to a large number), [6] furthest step taken x1000 (max), [7] enemy pairs closer than the
// agreed physical minimum, [8..13] the same closest-enemy-gap measurement kept per body - the
// anchors are driven off these, so that a body advances exactly while nobody is in reach of it.
// [14] target acquisitions, [15] ticks spent retaining a valid target, [16] scheduled looks made
// while already holding a target, [17] targets released for distance, [18] targets lost to death,
// [19] losses inside reach that forced an immediate look, [20] looks made on the cadence,
// [21] target switches, [22] looks that found nobody. The clear pass resets all of them.
layout(set = 0, binding = 5, std430) restrict buffer Counters { uint c[]; } counters;
// x = hit points, y = side (0 marches +x, 1 marches -x), z = 1 once fallen.
layout(set = 0, binding = 6, std430) restrict buffer Meta { vec4 m[]; } meta;
// Hundredths of a hit point taken this tick, accumulated by atomics.
layout(set = 0, binding = 7, std430) restrict buffer Damage { uint d[]; } damage;
// x = attack, y = defence, z = the reach of his weapon, w = how many ticks between his blows.
// Read from the game's own unit definitions rather than invented here, so a spearman in this scene
// is the spearman the campaign fields: attack 7, defence 4, reach 2.4, a blow every 1.5 seconds.
layout(set = 0, binding = 12, std430) restrict buffer Stats { vec4 s[]; } stats;
// What each soldier has done, and who did for him. x = kills credited to him, y = hundredths of a
// hit point he has dealt, z = the lowest-numbered attacker to strike him *this tick*, w = the blow
// that killed him, NO_KILLER while he lives.
//
// z is cleared every tick on purpose: a wound taken early in a fight must not be mistaken for the
// lethal one later. x and y are a man's own slots and he writes them himself - except for a kill,
// which is credited by the *dying* man's thread, because only there is it known that a blow was
// the lethal one. That credit is an atomic add into a count, so the order the threads ran in cannot
// change the total: the same rule that keeps the separation deterministic.
layout(set = 0, binding = 13, std430) restrict buffer Tallies { uvec4 t[]; } tallies;
// x = the body this soldier belongs to, y = his file, z = his rank.
layout(set = 0, binding = 8, std430) restrict buffer Attrs { vec4 a[]; } attrs;
// Two vec4 per body: (anchor.xy, forward.xy) and (files, ranks, spacing, engaged).
layout(set = 0, binding = 9, std430) restrict buffer Bodies { vec4 b[]; } bodies;
// The separation correction being accumulated this round, in fixed-point integers (x, y), with
// zw spare. Integer atomics add the same way whatever the order the neighbours are visited in,
// which is the whole point: floats summed in binning order made every run diverge from tick two.
layout(set = 0, binding = 10, std430) restrict buffer Corr { ivec4 c[]; } corr;
// The opponent each soldier remembers, and when it may look again: x = target agent id (-1 for
// none), y = the simulation tick its next scheduled look is due, zw spare. Written only by the
// soldier itself, so no two threads race for it. See the header's target-acquisition note.
layout(set = 0, binding = 11, std430) restrict buffer Targets { ivec4 t[]; } targets;

layout(push_constant, std430) uniform PC { uint mode; uint a; uint b; uint c; } pc;

const uint SLOT_CAPACITY = 64u;
const uint DAMAGE_SCALE = 100u;
// The counter block's size, and the last slot whose value is a per-body "closest enemy" reading
// (these start at 8 and run to 13, one per body). Everything from 14 up is a target counter that
// starts at zero. The clear pass covers the whole block: covering too few was a real bug once -
// the tail was never reset and every "this tick" figure became a running total.
const uint COUNTER_COUNT = 96u;

// A one-off mix: the same man striking on the same tick rolls the same number on any machine, in
// any order, which is the whole reason the strike model can live on the GPU and still be checked.
uint pb_hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

// The top twenty-four bits as a number in [0, 1): enough resolution for a hit chance and a fifteen
// per cent spread, and exact in a float.
float pb_unit(uint h) {
	return float(h & 0xFFFFFFu) / float(0x1000000u);
}
const uint BODY_GAP_BASE = 32u;
const uint BODY_GAP_SLOTS = 60u;
// The per-body blocks are written and read at the same base. They were not, once: the reader moved
// to 32 and the writer stayed at 8, so every body read "no enemy anywhere near" and pressed until
// the fronts stood 2.05 apart with 24,314 pairs under the agreed minimum. The base is now named in
// both places and the fault cannot recur silently.
const int NO_TARGET = -1;
const uint NO_KILLER = 0xFFFFFFFFu;
// The unit the separation corrections are accumulated in. Fixed-point integers, deliberately:
// the order neighbours are visited in depends on which thread binned which man first, and a float
// sum whose value depends on the order it was summed in is a battle that comes out a different
// war every run - measured, tick 2, with 1,192 of 1,193 ticks differing between two identical
// runs. Integers add the same way whatever the order.
const float FIXED = 1024.0;

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint n = uint(params.f[0]);
	uint gw = uint(params.f[1]);
	uint gh = uint(params.f[2]);
	float cell = params.f[3];
	float sep = params.f[4];
	float dt = params.f[5];
	float fw = params.f[6];
	float fh = params.f[7];
	float walk = params.f[8];
	float reach = params.f[9];
	float blow = params.f[10];
	// [22] chance to hit, [23] damage taken off per point of defence, [24] the battle clock in
	// ticks a second, [25] 1 = the reference's strike model, 0 = the flat placeholder it replaced.
	float hit_chance = params.f[22];
	float defence_mitigation = params.f[23];
	float tick_hz = max(1.0, params.f[24]);
	bool real_strikes = params.f[25] > 0.5;
	float max_push = params.f[11];
	float min_enemy = params.f[12];
	uint tick_now = uint(params.f[13]);
	uint cadence = uint(max(params.f[14], 1.0));
	float retention = params.f[15];
	float switch_adv = params.f[16];
	bool targeting = params.f[17] > 0.5;
	float search_radius = params.f[18];
	bool immediate_loss = params.f[19] > 0.5;

	if (pc.mode == 0u) {
		uint step = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
		uint cells = gw * gh;
		for (uint i = gid; i < cells; i += step) {
			cursors.c[i] = 0u;
		}
		for (uint i = gid; i < n; i += step) {
			damage.d[i] = 0u;
			// The attacker of this tick's blow is cleared every tick - it is a reading, not a
			// record. The tallies themselves are set once, at the start of the battle.
			if (tick_now == 0u) {
				tallies.t[i] = uvec4(0u, 0u, NO_KILLER, NO_KILLER);
			} else {
				tallies.t[i].z = NO_KILLER;
			}
			corr.c[i] = ivec4(0);
		}
		if (gid >= n && gid < n + COUNTER_COUNT) {
			uint slot = gid - n;
			// The measuring slots start at "nothing seen yet", not at zero: a minimum
			// distance of zero would read as every soldier standing inside another one.
			if (slot == 5u || (slot >= BODY_GAP_BASE && slot < BODY_GAP_BASE + BODY_GAP_SLOTS)) {
				counters.c[slot] = 4294967295u;
			} else {
				counters.c[slot] = 0u;
			}
		}
		return;
	}

	if (gid >= n) {
		return;
	}

	if (pc.mode == 1u) {
		pushes.p[gid] = vec4(0.0);
		if (meta.m[gid].z > 0.5) {
			return;
		}
		vec2 pos = agents.s[gid].xy;
		int cx = int(clamp(floor(pos.x / cell), 0.0, float(gw) - 1.0));
		int cy = int(clamp(floor(pos.y / cell), 0.0, float(gh) - 1.0));
		uint ci = uint(cy) * gw + uint(cx);
		uint slot = atomicAdd(cursors.c[ci], 1u);
		if (slot < SLOT_CAPACITY) {
			slots.s[ci * SLOT_CAPACITY + slot] = gid;
		} else {
			atomicAdd(counters.c[0], 1u);
		}
		return;
	}

	if (meta.m[gid].z > 0.5) {
		return;
	}

	vec2 pos = agents.s[gid].xy;
	int cx = int(clamp(floor(pos.x / cell), 0.0, float(gw) - 1.0));
	int cy = int(clamp(floor(pos.y / cell), 0.0, float(gh) - 1.0));

	if (pc.mode == 2u) {
		float side = meta.m[gid].y;
		ivec2 acc = ivec2(0);
		uint probes = 0u;
		bool contact = false;
		// The opponent this soldier is already dealing with, if any. Cheap by construction:
		// one index probe and a distance, with no spatial query - which is what makes
		// retaining an opponent cheaper than finding one, and why this is asked first.
		int held_id = targets.t[gid].x;
		uint next_tick = uint(max(targets.t[gid].y, 0));
		bool has_held = false;
		bool due = false;
		float held_d2 = 1.0e30;
		if (held_id >= 0) {
			if (uint(held_id) < n) {
				uint h = uint(held_id);
				vec2 hdelta = agents.s[h].xy - pos;
				held_d2 = dot(hdelta, hdelta);
				if (meta.m[h].y == side) {
					// Not reachable today - the search only ever returns enemies - but a
					// remembered answer that has become an ally is refused rather than hit.
					atomicAdd(counters.c[18], 1u);
					held_id = NO_TARGET;
				} else if (meta.m[h].z > 0.5) {
					// The remembered opponent is dead. If it was inside this soldier's own
					// reach the loss was taken mid-swing, and the next look is brought
					// forward off the cadence; otherwise it waits its turn. See D-083.
					atomicAdd(counters.c[18], 1u);
					if (immediate_loss && held_d2 <= reach * reach) {
						due = true;
						atomicAdd(counters.c[19], 1u);
					}
					held_id = NO_TARGET;
				} else if (held_d2 > retention * retention) {
					// It walked out of relevance: release it rather than chase it across
					// the field. The radius is the search ceiling on purpose. See D-082.
					atomicAdd(counters.c[17], 1u);
					held_id = NO_TARGET;
				} else {
					has_held = true;
				}
			} else {
				atomicAdd(counters.c[18], 1u);
				held_id = NO_TARGET;
			}
		}
		int prior_valid = has_held ? held_id : NO_TARGET;
		// Whether this soldier is going to look this tick at all: in reach it holds and never
		// searches, otherwise it looks when a loss or its own cadence has made it due.
		bool in_reach = has_held && held_d2 <= reach * reach;
		bool want_search = targeting && !in_reach && (due || tick_now >= next_tick);
		// The nearest enemy the local window offers, and its squared distance. Only the
		// acquisition path reads these; the legacy path never fills them.
		uint best_cand = 0xFFFFFFFFu;
		float best_d2 = 1.0e30;
		for (int oy = -1; oy <= 1; ++oy) {
			int ny = cy + oy;
			if (ny < 0 || ny >= int(gh)) {
				continue;
			}
			for (int ox = -1; ox <= 1; ++ox) {
				int nx = cx + ox;
				if (nx < 0 || nx >= int(gw)) {
					continue;
				}
				uint ci = uint(ny) * gw + uint(nx);
				uint count = min(cursors.c[ci], SLOT_CAPACITY);
				probes += count;
				for (uint k = 0u; k < count; ++k) {
					uint other = slots.s[ci * SLOT_CAPACITY + k];
					if (other == gid) {
						continue;
					}
					vec2 d = pos - agents.s[other].xy;
					float d2 = dot(d, d);
					bool enemy = meta.m[other].y != side;
					if (d2 > 0.000001) {
						float dist = sqrt(d2);
						if (dist < sep) {
							acc += ivec2(round((d / dist) * ((sep - dist) * 0.5) * FIXED));
							// An enemy at body's length, or your own man actually overlapping
							// you: either way your place is taken and you hold it where you are.
							if (enemy || dist < sep * 0.9) {
								contact = true;
							}
						}
						if (enemy) {
							// The proof this milestone is judged on, taken every tick in the
							// shader itself: the closest enemy gap anywhere on the field, and
							// how many pairs are inside the agreed minimum.
							atomicMin(counters.c[5], uint(dist * 1000.0));
							if (dist < min_enemy) {
								atomicAdd(counters.c[7], 1u);
							}
							// The same measurement per body. The anchors are driven off this:
							// a body advances exactly while nobody is in reach of it, which is
							// the game's "press into the gap" rule with a measured gap instead
							// of a guessed one.
							atomicMin(counters.c[BODY_GAP_BASE + uint(attrs.a[gid].x)], uint(dist * 1000.0));
							// The local search the acquisition is built on: the nearest enemy
							// this 3x3 neighbourhood offers. Ties are broken by the lower
							// agent id, so the answer cannot depend on the order the grid
							// happened to bin the men in.
							if (targeting && d2 <= search_radius * search_radius) {
								bool better = d2 < best_d2 - 0.000001 \
									|| (abs(d2 - best_d2) <= 0.000001 && other < best_cand);
								if (better) {
									best_cand = other;
									best_d2 = d2;
								}
							}
							// Legacy: every enemy in reach is struck. Shipped: only the
							// acquired opponent is, below.
							if (!targeting && dist < reach) {
								atomicAdd(damage.d[other], uint(blow * float(DAMAGE_SCALE)));
								atomicAdd(counters.c[2], 1u);
							}
						}
						// A man standing inside an enemy: the number this milestone has to
						// keep at zero, or all the "collisions" talk is decoration.
						if (enemy && dist < sep * 0.5) {
							atomicAdd(counters.c[4], 1u);
						}
					} else if (enemy) {
						contact = true;
						atomicMin(counters.c[5], 0u);
						atomicAdd(counters.c[7], 1u);
						if (!targeting) {
							atomicAdd(counters.c[2], 1u);
						}
					}
				}
			}
		}
		// The second rung of the look, and only when the first found nobody: a soldier whose
		// opponent died in front of it should find the rank behind it, and that rank stands
		// one file back - about five units, past a 3x3 window's guaranteed reach. When a look
		// is due and the first rung was empty, the ring around it is read as well. Separation
		// and the collision proof are never taken from this rung; it only answers the search.
		if (targeting && want_search && best_cand == 0xFFFFFFFFu) {
			for (int oy = -2; oy <= 2; ++oy) {
				int ny = cy + oy;
				if (ny < 0 || ny >= int(gh)) {
					continue;
				}
				for (int ox = -2; ox <= 2; ++ox) {
					if (abs(ox) <= 1 && abs(oy) <= 1) {
						continue;
					}
					int nx = cx + ox;
					if (nx < 0 || nx >= int(gw)) {
						continue;
					}
					uint ci = uint(ny) * gw + uint(nx);
					uint count = min(cursors.c[ci], SLOT_CAPACITY);
					probes += count;
					for (uint k = 0u; k < count; ++k) {
						uint other = slots.s[ci * SLOT_CAPACITY + k];
						if (other == gid || meta.m[other].y == side) {
							continue;
						}
						vec2 d = pos - agents.s[other].xy;
						float d2 = dot(d, d);
						if (d2 > 0.000001 && d2 <= search_radius * search_radius) {
							bool better = d2 < best_d2 - 0.000001 \
								|| (abs(d2 - best_d2) <= 0.000001 && other < best_cand);
							if (better) {
								best_cand = other;
								best_d2 = d2;
							}
						}
					}
				}
			}
		}
		atomicAdd(counters.c[1], probes);
		if (!targeting) {
			// The behaviour this slice replaces: every enemy in reach is struck and no
			// opponent is remembered. Kept in the same shader so the benchmark can run
			// both halves in one build.
			pushes.p[gid] = vec4(vec2(acc) / FIXED, contact ? 1.0 : 0.0, 0.0);
			return;
		}
		if (has_held) {
			atomicAdd(counters.c[15], 1u);
		}
		int chosen = held_id;
		float chosen_d2 = held_d2;
		if (in_reach) {
			// An opponent in reach is the fastest path through target handling: it is
			// kept without asking the battlefield anything, and the cadence does not run.
			contact = true;
		} else if (due || tick_now >= next_tick) {
			if (!due) {
				atomicAdd(counters.c[20], 1u);
			}
			if (has_held) {
				atomicAdd(counters.c[16], 1u);
			}
			if (best_cand != 0xFFFFFFFFu) {
				bool take = true;
				if (has_held) {
					// Hysteresis: a rival has to be clearly closer than the remembered
					// opponent, or two similar enemies would exchange the answer on
					// alternate looks. Compared squared. See D-081.
					take = best_d2 * switch_adv * switch_adv < held_d2;
				}
				if (take) {
					chosen = int(best_cand);
					chosen_d2 = best_d2;
				} else {
					chosen = held_id;
					chosen_d2 = held_d2;
				}
			} else {
				atomicAdd(counters.c[22], 1u);
				// Nobody local: a valid remembered opponent is still worth keeping (it is
				// simply standing beyond the search), and otherwise there is nobody to
				// strike until the next look.
				chosen = has_held ? held_id : NO_TARGET;
				chosen_d2 = held_d2;
			}
			next_tick = tick_now + cadence;
		}
		if (chosen >= 0 && prior_valid < 0) {
			atomicAdd(counters.c[14], 1u);
		} else if (chosen >= 0 && chosen != prior_valid) {
			atomicAdd(counters.c[21], 1u);
		}
		// His own weapon decides what he can reach, not the scene's global one: an archer stands
		// behind the line and strikes past it, a spearman reaches further than a knife.
		float my_reach = real_strikes ? stats.s[gid].z : reach;
		if (chosen >= 0 && chosen_d2 <= my_reach * my_reach) {
			// Strike the acquired opponent - and only it. This is the behaviour change the
			// slice exists for: the legacy path struck every neighbour inside reach.
			bool ready = true;
			if (real_strikes) {
				// A weapon has a rhythm. The tick a man may strike again is kept on him, and
				// until it passes he can hold a fight without adding to it.
				ready = float(tick_now) >= meta.m[gid].w;
				if (ready) {
					meta.m[gid].w = float(tick_now) + max(1.0, stats.s[gid].w);
				}
			}
			if (ready) {
				float damage_taken = blow;
				bool landed = true;
				if (real_strikes) {
					// One roll per man per blow, from a hash of who and when: the same battle
					// rolls the same numbers whatever order the threads ran in, which is what
					// keeps the determinism gate passing with the model on the GPU.
					uint h = pb_hash(uint(gid) * 0x9E3779B9u ^ uint(tick_now) * 0x85EBCA6Bu ^ 0x2545F491u);
					landed = pb_unit(h) <= hit_chance;
					if (landed) {
						float raw = stats.s[gid].x * (0.85 + 0.3 * pb_unit(pb_hash(h)));
						float reduction = min(0.7, stats.s[chosen].y * defence_mitigation);
						damage_taken = max(1.0, floor(raw * (1.0 - reduction) + 0.5));
					}
				}
				if (landed) {
					atomicAdd(damage.d[uint(chosen)], uint(damage_taken * float(DAMAGE_SCALE)));
					// His own tally, and who struck the man he struck. The lowest id wins a tie so
					// that two attackers in one tick resolve the same way in every run.
					tallies.t[gid].y += uint(damage_taken * float(DAMAGE_SCALE));
					atomicMin(tallies.t[uint(chosen)].z, gid);
					atomicAdd(counters.c[2], 1u);
				} else {
					atomicAdd(counters.c[23], 1u);
				}
			}
			contact = true;
		}
		targets.t[gid] = ivec4(chosen, int(next_tick), 0, 0);
		// z carries "an enemy is on me": the man who is fighting does not walk anywhere. The
		// correction goes out in world units again, from the fixed-point sum.
		pushes.p[gid] = vec4(vec2(acc) / FIXED, contact ? 1.0 : 0.0, 0.0);
		return;
	}

	if (pc.mode == 4u) {
		// One relaxation round of the separation: every overlap this man is in is added, in
		// fixed-point integers, into the correction buffer; the round is applied by mode 5.
		//
		// Two things make a round reproducible, and both were measured wrong before:
		//   * the sum is an integer atomic add, so the order the neighbours are visited in cannot
		//     change the result - a float sum could, and did: two identical runs diverged from
		//     tick two;
		//   * nothing is written to the positions here, so no thread can read a neighbour that
		//     another thread has half finished moving.
		//
		// Why rounds exist at all: with a single capped correction a pressed front settled at a
		// 1.49-unit gap where the agreed minimum is 2.47 - measured, 275,000 pair-violations and
		// rising. Each man was pulled by several neighbours at once and the cap clipped the sum,
		// so the residual never closed. A round re-measures against where everyone now stands.
		float my_side = meta.m[gid].y;
		for (int oy = -1; oy <= 1; ++oy) {
			int ny = cy + oy;
			if (ny < 0 || ny >= int(gh)) {
				continue;
			}
			for (int ox = -1; ox <= 1; ++ox) {
				int nx = cx + ox;
				if (nx < 0 || nx >= int(gw)) {
					continue;
				}
				uint ci = uint(ny) * gw + uint(nx);
				uint count = min(cursors.c[ci], SLOT_CAPACITY);
				for (uint k = 0u; k < count; ++k) {
					uint other = slots.s[ci * SLOT_CAPACITY + k];
					if (other == gid) {
						continue;
					}
					vec2 d = pos - agents.s[other].xy;
					float d2 = dot(d, d);
					if (d2 > 0.000001) {
						float dist = sqrt(d2);
						if (dist < sep) {
							// The enemy gets no share of this: he never displaces me, I move
							// myself clear of him, the whole overlap, every round. Sharing it
							// half-and-half let my own rear rank push me into him - the two
							// pushes cancelled and the front sat 0.38 inside the agreed gap
							// with the solver reporting a clean pass. My own man only takes
							// half, because we are both trying to leave.
							float share = (meta.m[other].y != my_side) ? 1.0 : 0.5;
							vec2 push = (d / dist) * ((sep - dist) * share);
							atomicAdd(corr.c[gid].x, int(round(push.x * FIXED)));
							atomicAdd(corr.c[gid].y, int(round(push.y * FIXED)));
						}
					} else {
						// Exactly on top of each other: shove along a fixed axis so the pair
						// has a direction to separate along at all.
						atomicAdd(corr.c[gid].x, int(round(0.01 * FIXED)));
					}
				}
			}
		}
		return;
	}

	if (pc.mode == 5u) {
		// Apply the round's accumulated separation and clear it for the next round. The clamp
		// still bounds one man's correction, so a crowded cell cannot fling anybody across the
		// field - but the correction itself is now the sum of everything on him, not a sum
		// clipped one neighbour at a time.
		vec2 acc = vec2(corr.c[gid].xy) / FIXED;
		corr.c[gid] = ivec4(0);
		if (acc != vec2(0.0)) {
			float alen = length(acc);
			if (alen > max_push) {
				acc = (acc / alen) * max_push;
			}
			vec2 settled = clamp(pos + acc, vec2(0.0), vec2(fw, fh));
			agents.s[gid] = vec4(settled, agents.s[gid].zw);
		}
		return;
	}

	// mode 3: take the blows, then walk to your place in the line.
	vec4 me = meta.m[gid];
	if (me.x - float(damage.d[gid]) / float(DAMAGE_SCALE) <= 0.0) {
		// He died of this tick's wounds, so the man recorded against him is the man who did it.
		// The credit lands on the killer's own counter, written from here because only the
		// dying thread knows the blow was the lethal one. It is a count, added atomically, so
		// the order of threads cannot change it.
		uint killer = tallies.t[gid].z;
		if (killer != NO_KILLER && killer < uint(params.f[0])) {
			atomicAdd(tallies.t[killer].x, 1u);
			tallies.t[gid].w = killer;
		}
		meta.m[gid] = vec4(0.0, me.y, 1.0, 0.0);
		agents.s[gid] = vec4(pos, vec2(0.0));
		atomicAdd(counters.c[3], 1u);
		return;
	}
	meta.m[gid] = vec4(me.x - float(damage.d[gid]) / float(DAMAGE_SCALE), me.y, 0.0, 0.0);

	uint bid = uint(attrs.a[gid].x);
	vec4 head = bodies.b[bid * 2u];
	vec4 shape = bodies.b[bid * 2u + 1u];
	vec2 forward = head.zw;
	vec2 right = vec2(-forward.y, forward.x);
	float files = shape.x;
	float ranks = shape.y;
	float spacing = shape.z;
	float file = attrs.a[gid].y;
	float rank = attrs.a[gid].z;
	vec2 slot = head.xy
		+ right * ((file - (files - 1.0) * 0.5) * spacing)
		+ forward * ((rank - (ranks - 1.0) * 0.5) * spacing);

	// Walk to the place, never overshooting it - unless an enemy is on you, in which case you
	// hold where you stand and only the collision moves you. That is what stops two lines
	// walking through each other: the slots may press, the men cannot.
	vec2 step = vec2(0.0);
	if (pushes.p[gid].z < 0.5) {
		vec2 to_slot = slot - pos;
		float dist = length(to_slot);
		if (dist > 0.0001) {
			step = (to_slot / dist) * min(dist, walk * dt);
		}
	}

	// The separation as a position correction, not a velocity: this is the collision. Two
	// ranks that meet cannot pass through one another, they compress, and the cap stops one
	// crowded cell from flinging a man across the field.
	vec2 correction = pushes.p[gid].xy;
	float clen = length(correction);
	if (clen > max_push) {
		correction = (correction / clen) * max_push;
	}

	vec2 p = pos + step + correction;
	p.x = clamp(p.x, 0.0, fw);
	p.y = clamp(p.y, 0.0, fh);
	// How far this tick actually moved him, for the probe's displacement ceiling.
	atomicMax(counters.c[6], uint(length(p - pos) * 1000.0));
	agents.s[gid] = vec4(p, step / max(dt, 0.0001));
}
