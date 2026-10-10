#[compute]
#version 450
// Slice 3: independently select a nearest local enemy and apply strict
// squared-distance switching hysteresis. Read-only shadow of CPU combat.
// Input roster: id, side (0/1), alive (0/1), cached auto-target id.
// Input geometry: x, y, maximum search radius, retention radius.
// Input orders: explicit attack-order id, 0, 0, 0.
// Output: chosen id, reason, local candidate id, valid retained id.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set=0, binding=0, std430) readonly buffer SoldierRoster { ivec4 soldiers[]; };
layout(set=0, binding=1, std430) readonly buffer SoldierGeometry { vec4 places[]; };
layout(set=0, binding=2, std430) readonly buffer SoldierOrders { ivec4 orders[]; };
layout(set=0, binding=3, std430) writeonly buffer Decisions { ivec4 decisions[]; };
layout(push_constant, std430) uniform Params {
    uint count;
    float advantage_squared;
    uint reserved0;
    uint reserved1;
} pc;
// Reasons: 0 inactive, 1 no local/cached, 2 acquire, 3 incumbent nearest,
// 4 incumbent protected by hysteresis, 5 switch, 6 hold nonlocal,
// 7 explicit attack order overrides automatic search.
void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= pc.count) return;
    ivec4 self = soldiers[index];
    ivec4 answer = ivec4(-1, 1, -1, -1);
    if (self.z == 0) {
        answer.y = 0;
        decisions[index] = answer;
        return;
    }
    if (orders[index].x >= 0) {
        answer.y = 7;
        decisions[index] = answer;
        return;
    }
    int cached = -1;
    float cached_distance = 0.0;
    int nearest = -1;
    float nearest_distance = 3.402823466e+38;
    vec2 me = places[index].xy;
    float ceiling_sq = places[index].z * places[index].z;
    float retention_sq = places[index].w * places[index].w;
    for (uint j = 0u; j < pc.count; ++j) {
        ivec4 other = soldiers[j];
        if (other.y == self.y || other.z == 0) continue;
        vec2 delta = places[j].xy - me;
        float distance_sq = dot(delta, delta);
        if (other.x == self.w && distance_sq <= retention_sq) {
            cached = other.x;
            cached_distance = distance_sq;
        }
        if (distance_sq > ceiling_sq) continue;
        if (nearest < 0 || distance_sq < nearest_distance ||
                (distance_sq == nearest_distance && other.x < nearest)) {
            nearest = other.x;
            nearest_distance = distance_sq;
        }
    }
    answer.z = nearest;
    answer.w = cached;
    if (nearest < 0) {
        if (cached >= 0) {
            answer.x = cached;
            answer.y = 6;
        }
    } else if (cached < 0) {
        answer.x = nearest;
        answer.y = 2;
    } else if (cached == nearest) {
        answer.x = cached;
        answer.y = 3;
    } else if (nearest_distance * pc.advantage_squared < cached_distance) {
        answer.x = nearest;
        answer.y = 5;
    } else {
        answer.x = cached;
        answer.y = 4;
    }
    decisions[index] = answer;
}
