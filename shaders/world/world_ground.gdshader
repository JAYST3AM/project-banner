shader_type canvas_item;
// The campaign map's ground.
//
// Two grounds and a field of weights: where the weight is 0 the first shows, where it is 1 the
// second does, and in between they mix. That is the whole of "meshing" here - the border between
// two biomes is a band the width the field gives it, not a line, and the same field will later
// drive movement and props, so what a place looks like and what it does cannot disagree.
//
// The height channel is shaded now and will displace geometry later; it is generated from the same
// seed as the weights, so a hill on the map is a hill in the battle fought on it.

uniform sampler2D ground_a : repeat_enable, filter_linear;
uniform sampler2D ground_b : repeat_enable, filter_linear;
uniform sampler2D field_map : filter_linear;

// World units one repeat of a ground image covers. Smaller means the texture's detail is seen
// closer up.
uniform float tile_units = 74.0;
// How much the height channel lightens and darkens the ground. 0 draws it flat.
uniform float shade_strength = 0.32;
// Where this rect sits in the world, and how big it is: the textures tile in world space, so they
// do not stretch when the map's rectangle changes.
uniform vec2 map_origin = vec2(0.0);
uniform vec2 map_span = vec2(1600.0, 900.0);

void fragment() {
	vec2 world = map_origin + UV * map_span;
	vec2 tiled = world / max(1.0, tile_units);
	vec3 first = texture(ground_a, tiled).rgb;
	vec3 second = texture(ground_b, tiled).rgb;
	vec3 field = texture(field_map, UV).rgb;
	float weight = clamp(field.r, 0.0, 1.0);
	vec3 ground = mix(first, second, weight);
	float shade = 1.0 + (field.g - 0.5) * shade_strength;
	COLOR = vec4(ground * shade, 1.0);
}
