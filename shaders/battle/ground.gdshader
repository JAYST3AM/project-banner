shader_type canvas_item;
render_mode unshaded;

// Battlefields are world-space, and the data maps are sampled continuously.
// Ground sprites are deliberately 1x1 white pixels scaled to the actual field.
uniform sampler2D ground_map : filter_linear, repeat_disable;
uniform sampler2D overlay_map : filter_linear, repeat_disable;
uniform sampler2D type_map : filter_linear, repeat_disable;

// Four 64x64 sub-tiles per biome variant, concatenated horizontally.
// Filename/path resolution is owned by data/terrain/biomes.json.
uniform sampler2D variant_a : filter_nearest, repeat_disable;
uniform sampler2D variant_b : filter_nearest, repeat_disable;
uniform sampler2D variant_c : filter_nearest, repeat_disable;
uniform sampler2D variant_d : filter_nearest, repeat_disable;

// One source tile per overlay: coverage and strength come from terrain data.
uniform sampler2D overlay_1 : filter_nearest, repeat_disable;
uniform sampler2D overlay_2 : filter_nearest, repeat_disable;
uniform sampler2D overlay_3 : filter_nearest, repeat_disable;
uniform sampler2D overlay_4 : filter_nearest, repeat_disable;
uniform vec4 overlay_active = vec4(0.0);
uniform vec4 overlay_strengths = vec4(0.8, 0.7, 0.6, 0.7);

// Optional shared material art; defaults retain a readable battlefield.
uniform sampler2D type_water : filter_nearest, repeat_disable;
uniform sampler2D type_rock : filter_nearest, repeat_disable;
uniform sampler2D type_mud : filter_nearest, repeat_disable;
uniform vec3 type_active = vec3(0.0);

uniform vec2 map_span = vec2(100.0, 60.0);
uniform float tile_units = 4.0;
uniform float overlay_units = 3.0;
uniform float type_units = 3.0;
uniform float shade_strength = 0.3;

float tile_hash(vec2 point) {
    return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453);
}

// Sub-tile selection must not change with FPS or with camera position.
// The four authored alternatives are selected from world tile coordinates.
vec3 variant_sample(sampler2D atlas, vec2 world, float units) {
    vec2 position = world / max(units, 0.1);
    vec2 cell = floor(position);
    vec2 inside = fract(position);
    float slot = floor(tile_hash(cell) * 4.0);
    vec2 atlas_uv = vec2((slot + inside.x) / 4.0, inside.y);
    return texture(atlas, atlas_uv).rgb;
}

vec4 detail_sample(sampler2D picture, vec2 world, float units) {
    return texture(picture, fract(world / max(units, 0.1)));
}

void fragment() {
    vec2 world = UV * map_span;
    vec4 weights = texture(ground_map, UV);
    vec4 marks = texture(overlay_map, UV);
    vec3 ground_material = texture(type_map, UV).rgb;

    // BattlefieldTerrain.build_ground_map encodes variants 2..4 in RGB,
    // height in A. The first variant is the remaining weight.
    vec4 bands = vec4(
        max(0.0, 1.0 - weights.r - weights.g - weights.b),
        max(0.0, weights.r),
        max(0.0, weights.g),
        max(0.0, weights.b)
    );
    bands /= max(dot(bands, vec4(1.0)), 0.0001);

    // Skip near-zero atlas fetches on fields dominated by one material.
    vec3 colour = vec3(0.0);
    if (bands.x > 0.002) {
        colour += variant_sample(variant_a, world, tile_units) * bands.x;
    }
    if (bands.y > 0.002) {
        colour += variant_sample(variant_b, world, tile_units) * bands.y;
    }
    if (bands.z > 0.002) {
        colour += variant_sample(variant_c, world, tile_units) * bands.z;
    }
    if (bands.w > 0.002) {
        colour += variant_sample(variant_d, world, tile_units) * bands.w;
    }

    if (overlay_active.x > 0.5 && marks.r > 0.002) {
        vec4 pixels = detail_sample(overlay_1, world, overlay_units);
        colour = mix(colour, pixels.rgb, clamp(
            marks.r * overlay_strengths.x * pixels.a, 0.0, 0.9));
    }
    if (overlay_active.y > 0.5 && marks.g > 0.002) {
        vec4 pixels = detail_sample(overlay_2, world, overlay_units);
        colour = mix(colour, pixels.rgb, clamp(
            marks.g * overlay_strengths.y * pixels.a, 0.0, 0.9));
    }
    if (overlay_active.z > 0.5 && marks.b > 0.002) {
        vec4 pixels = detail_sample(overlay_3, world, overlay_units);
        colour = mix(colour, pixels.rgb, clamp(
            marks.b * overlay_strengths.z * pixels.a, 0.0, 0.9));
    }
    if (overlay_active.w > 0.5 && marks.a > 0.002) {
        vec4 pixels = detail_sample(overlay_4, world, overlay_units);
        colour = mix(colour, pixels.rgb, clamp(
            marks.a * overlay_strengths.w * pixels.a, 0.0, 0.9));
    }

    // These are the actual generated terrain TYPE masks, not random props.
    // Keep a colour fallback if the shared water/rock/mud PNG is absent.
    if (ground_material.r > 0.002) {
        vec3 water = vec3(0.19, 0.31, 0.39);
        if (type_active.x > 0.5) {
            water = variant_sample(type_water, world, type_units);
        }
        colour = mix(colour, water, ground_material.r);
    }
    if (ground_material.g > 0.002) {
        vec3 rock = vec3(0.43, 0.43, 0.39);
        if (type_active.y > 0.5) {
            rock = detail_sample(type_rock, world, type_units).rgb;
        }
        colour = mix(colour, rock, ground_material.g);
    }
    if (ground_material.b > 0.002) {
        vec3 mud = vec3(0.34, 0.28, 0.22);
        if (type_active.z > 0.5) {
            mud = detail_sample(type_mud, world, type_units).rgb;
        }
        colour = mix(colour, mud, ground_material.b);
    }

    // Subtle height-based tonal shape. No baked lighting in the source art.
    float relief = (weights.a - 0.5) * shade_strength * 0.42;
    colour *= 1.0 + relief;
    COLOR = vec4(clamp(colour, 0.0, 1.0), 1.0);
}
