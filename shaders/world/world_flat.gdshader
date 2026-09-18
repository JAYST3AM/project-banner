shader_type canvas_item;

// Flat colours by terrain kind - the honest placeholder while the art is being sorted elsewhere.
//
// No textures at all: the field's own weights choose the colour, so the ground reads as water, shore,
// lush, dry or worn country at a glance. This is not a stand-in for finished art so much as a map that
// can be *read* - and it costs five texture samples a pixel with nothing to load.

uniform sampler2D field_map : filter_linear;
uniform vec2 map_origin = vec2(0.0);
uniform vec2 map_span = vec2(4096.0, 4096.0);
uniform float water_level = 0.335;
uniform float sand_level = 0.375;
uniform float shade_strength = 0.35;

const vec3 WATER = vec3(0.20, 0.34, 0.46);
const vec3 SHALLOW = vec3(0.28, 0.44, 0.55);
const vec3 SAND = vec3(0.72, 0.66, 0.48);
const vec3 LUSH = vec3(0.34, 0.47, 0.24);
const vec3 DRY = vec3(0.55, 0.53, 0.30);
const vec3 WORN = vec3(0.45, 0.40, 0.28);
const vec3 STANDARD = vec3(0.42, 0.49, 0.27);

void fragment() {
	vec2 world = map_origin + UV * map_span;
	vec4 field = texture(field_map, UV);
	// The four ground weights always add to one; Standard is whatever is left, exactly as the painted
	// shader treats it.
	vec3 weight = clamp(field.rgb, 0.0, 1.0);
	float standard = clamp(1.0 - weight.r - weight.g - weight.b, 0.0, 1.0);
	vec3 ground = weight.r * LUSH + weight.g * DRY + weight.b * WORN + standard * STANDARD;

	// Water and shore, with a band of shallow water at the edge so a coastline has depth rather than a
	// hard cut: the owner asked for colours per terrain kind, and a sea with a shallow rim reads as one.
	float water_edge = smoothstep(water_level - 0.010, water_level + 0.010, field.a);
	float shore_edge = smoothstep(sand_level - 0.012, sand_level + 0.012, field.a);
	vec3 shallow = mix(SHALLOW, WATER, smoothstep(water_level - 0.06, water_level, field.a));
	vec3 land = mix(SAND, ground, shore_edge);
	vec3 colour = mix(shallow, land, water_edge);

	float shade = 1.0 + (field.a - 0.5) * shade_strength;
	COLOR = vec4(colour * shade, 1.0);
}
