#[compute]
#version 450

// Dev-only probe: a battle whose soldiers are simulated on the GPU - and whose soldiers
// belong to formations.
//
// One agent per invocation, state resident in the buffers below, one mode per dispatch:
//   0 clear the grid, the damage and the counters   1 bin the living into the grid
//   2 read neighbours: separate hard, and strike an enemy within reach
//   3 walk to your place in the line, take the blows, and never pass through anybody
// The caller runs the four in order with a barrier between each, once a tick. The bodies
// themselves are ten numbers each and are advanced on the CPU, which is where the game
// keeps them too: a body is a roll of ids plus geometry, and the men are the crowd.
//
// A soldier's place is his body's lattice - anchor, facing, files, ranks, spacing - so a
// body marches as one thing, its ranks dress, and the gaps the fallen leave stay open.
// Nothing here is the game's combat: no targeting, no defence, no cooldown, no morale.

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
// [11] the most a soldier may be pushed in one tick, [12] the agreed minimum enemy gap.
layout(set = 0, binding = 4, std430) restrict buffer Params { float f[]; } params;
// [0] agents the grid could not hold, [1] neighbour probes, [2] blows landed, [3] fallen,
// [4] enemy pairs closer than half the separation, [5] closest enemy gap x1000 (min, cleared
// to a large number), [6] furthest step taken x1000 (max), [7] enemy pairs closer than the
// agreed physical minimum, [8..13] the same closest-enemy-gap measurement kept per body - the
// anchors are driven off these, so that a body advances exactly while nobody is in reach of it.
layout(set = 0, binding = 5, std430) restrict buffer Counters { uint c[]; } counters;
// x = hit points, y = side (0 marches +x, 1 marches -x), z = 1 once fallen.
layout(set = 0, binding = 6, std430) restrict buffer Meta { vec4 m[]; } meta;
// Hundredths of a hit point taken this tick, accumulated by atomics.
layout(set = 0, binding = 7, std430) restrict buffer Damage { uint d[]; } damage;
// x = the body this soldier belongs to, y = his file, z = his rank.
layout(set = 0, binding = 8, std430) restrict buffer Attrs { vec4 a[]; } attrs;
// Two vec4 per body: (anchor.xy, forward.xy) and (files, ranks, spacing, engaged).
layout(set = 0, binding = 9, std430) restrict buffer Bodies { vec4 b[]; } bodies;

layout(push_constant, std430) uniform PC { uint mode; uint a; uint b; uint c; } pc;

const uint SLOT_CAPACITY = 64u;
const uint DAMAGE_SCALE = 100u;

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
	float max_push = params.f[11];
	float min_enemy = params.f[12];

	if (pc.mode == 0u) {
		uint step = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
		uint cells = gw * gh;
		for (uint i = gid; i < cells; i += step) {
			cursors.c[i] = 0u;
		}
		for (uint i = gid; i < n; i += step) {
			damage.d[i] = 0u;
		}
		if (gid >= n && gid < n + 14u) {
			uint slot = gid - n;
			// The measuring slots start at "nothing seen yet", not at zero: a minimum
			// distance of zero would read as every soldier standing inside another one.
			if (slot == 5u || slot >= 8u) {
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
		vec2 acc = vec2(0.0);
		uint probes = 0u;
		bool contact = false;
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
							acc += (d / dist) * ((sep - dist) * 0.5);
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
							// of a guessed one. Measuring it by the leading man's x alone got
							// this wrong: two leading men in different bands read as 2.3 apart
							// while the nearest real enemy pair stood 3.52 away, past the 3.4
							// reach - so nobody could fight and nobody could close, and the
							// battle froze at 228 dead with the two lines staring at each other.
							atomicMin(counters.c[8u + uint(attrs.a[gid].x)], uint(dist * 1000.0));
						}
						if (enemy && dist < reach) {
							atomicAdd(damage.d[other], uint(blow * float(DAMAGE_SCALE)));
							atomicAdd(counters.c[2], 1u);
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
						atomicAdd(counters.c[2], 1u);
					}
				}
			}
		}
		atomicAdd(counters.c[1], probes);
		// z carries "an enemy is on me": the man who is fighting does not walk anywhere.
		pushes.p[gid] = vec4(acc, contact ? 1.0 : 0.0, 0.0);
		return;
	}

	if (pc.mode == 4u) {
		// One more relaxation round of the separation, applied straight to the position.
		//
		// Why this exists: with only the single capped correction below, a pressed front
		// settled at a 1.49-unit gap where the agreed minimum is 2.47 - measured on the proof
		// run, 275,000 pair-violations and rising. Each man was being pulled by several
		// neighbours at once and the cap clipped the sum, so the residual never closed.
		// A round re-measures against where everyone now stands, which is how the reference
		// resolves overlaps; repeated a few times a tick it closes the residual, and what the
		// renderer draws is a line that cannot be walked through.
		vec2 acc = vec2(0.0);
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
							acc += (d / dist) * ((sep - dist) * share);
						}
					} else {
						// Exactly on top of each other: shove along a fixed axis so the pair
						// has a direction to separate along at all.
						acc += vec2(0.01, 0.0);
					}
				}
			}
		}
		float alen = length(acc);
		if (alen > max_push) {
			acc = (acc / alen) * max_push;
		}
		vec2 settled = clamp(pos + acc, vec2(0.0), vec2(fw, fh));
		agents.s[gid] = vec4(settled, agents.s[gid].zw);
		return;
	}

	// mode 3: take the blows, then walk to your place in the line.
	vec4 me = meta.m[gid];
	if (me.x - float(damage.d[gid]) / float(DAMAGE_SCALE) <= 0.0) {
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
