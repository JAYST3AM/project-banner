#[compute]
#version 450
// Slice 2: independently validate a remembered automatic enemy.
// The GPU does not search for new targets or change battle state.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set=0, binding=0, std430) readonly buffer Soldiers { ivec4 roster[]; };
layout(set=0, binding=1, std430) readonly buffer Positions { vec4 geometry[]; };
layout(set=0, binding=2, std430) writeonly buffer Decisions { ivec4 verdict[]; };
layout(push_constant, std430) uniform Options { uint count; } pc;
// Result: (id or -1, reason, immediate-contact-reacquire, 0).
// Reason: 0 none, 1 valid, 2 missing, 3 ally, 4 dead, 5 far, 6 owner dead.
void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= pc.count) return;
    ivec4 me = roster[index]; // id, side, alive, auto_target_id
    ivec4 answer = ivec4(-1, 0, 0, 0);
    if (me.z == 0) {
        answer.y = 6;
    } else if (me.w >= 0) {
        answer.y = 2;
        for (uint i = 0u; i < pc.count; ++i) {
            ivec4 other = roster[i];
            if (other.x != me.w) continue;
            if (other.y == me.y) {
                answer.y = 3;
            } else if (other.z == 0) {
                answer.y = 4;
                vec2 gap = geometry[index].xy - geometry[i].xy;
                float reach = geometry[index].w;
                answer.z = dot(gap, gap) <= reach * reach ? 1 : 0;
            } else {
                vec2 gap = geometry[index].xy - geometry[i].xy;
                float radius = geometry[index].z;
                if (dot(gap, gap) > radius * radius) {
                    answer.y = 5;
                } else {
                    answer = ivec4(other.x, 1, 0, 0);
                }
            }
            break;
        }
    }
    verdict[index] = answer;
}
