#[compute]
#version 450

// Slice 1: independently validate explicit player-issued attack target IDs.
// This is deliberately NOT GPU damage, target search, or campaign resolution.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) readonly buffer CombatRoster {
    ivec4 soldiers[]; // id, side(0/1), alive(0/1), ordered target ID
};
layout(set = 0, binding = 1, std430) writeonly buffer TargetDecisions {
    int chosen[];
};
layout(push_constant, std430) uniform Options {
    uint count;
} pc;

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= pc.count) {
        return;
    }
    ivec4 me = soldiers[index];
    int answer = -1;
    if (me.z != 0 && me.w >= 0) {
        for (uint i = 0u; i < pc.count; ++i) {
            ivec4 target = soldiers[i];
            if (target.x == me.w && target.y != me.y && target.z != 0) {
                answer = target.x;
                break;
            }
        }
    }
    chosen[index] = answer;
}
