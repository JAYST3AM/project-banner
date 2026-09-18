shader_type canvas_item;
// The campaign map's ground: sixteen plains grounds, meshed.
//
// Four *looks* - Standard, Lush, Dry, Worn - blend into one another across the map, driven by a
// field of weights generated from the world seed. Inside each look, four *sub-variants* rotate from
// repeat to repeat, chosen by a hash of where the repeat is, so the eye never catches the same
// patch twice even though the same art is under it.
//
// Sampled nearest with mipmaps: the tiles are pixel art and want crisp edges, but they are still
// minified when the camera pulls back, and without mipmaps a pixel-art ground shimmers as it pans.
//
// The ground tiles in world space, not screen space: panning and zooming slide over the ground
// rather than stretching it. The variant hash runs on the same grid as the tiles, which is what
// keeps one variant per repeat instead of shimmering across it.
//
// The height channel is shaded now and will displace geometry later; it comes from the same seed as
// the weights, so a hill on the map is a hill in the battle fought on it.

uniform sampler2D look_lush : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_lush_2 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_lush_3 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_lush_4 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_dry : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_dry_2 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_dry_3 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_dry_4 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_worn : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_worn_2 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_worn_3 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_worn_4 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_standard : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_standard_2 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_standard_3 : repeat_enable, filter_nearest_mipmap;
uniform sampler2D look_standard_4 : repeat_enable, filter_nearest_mipmap;

// R, G, B = how much Lush, Dry and Worn this place is. Standard is the remainder, so the four
// always add to one and no fourth weight has to be stored. A = height.
uniform sampler2D field_map : filter_linear;

// World units one repeat of a ground image covers. Smaller means more tiles and the art's detail
// seen closer up - 1254-pixel paintings shrink well at this size because the samplers carry
// mipmaps, which is what stops a small repeat aliasing into coloured speckle.
uniform float tile_units = 260.0;
uniform float shade_strength = 0.32;
uniform vec2 map_origin = vec2(0.0);
uniform vec2 map_span = vec2(1600.0, 900.0);

// Four samples, one picked. All four are sampled and then selected with a step, so the choice costs
// the same whatever it lands on and there is no branch to diverge.
vec3 pick_variant(sampler2D one, sampler2D two, sampler2D three, sampler2D four, vec2 uv, float index) {
	float x = index * 4.0;
	vec3 low = mix(texture(one, uv).rgb, texture(two, uv).rgb, step(1.0, x));
	vec3 high = mix(texture(three, uv).rgb, texture(four, uv).rgb, step(3.0, x));
	return mix(low, high, step(2.0, x));
}

// A repeat's own variant, from where the repeat is. Positional, so a repeat always shows the same
// variant, two runs of a campaign grow the same country, and nothing about it has to be stored.
float variant_at(vec2 cell) {
	vec2 mixed = fract(cell * vec2(0.1031, 0.1030));
	mixed += dot(mixed, mixed.yx + 33.33);
	return fract((mixed.x + mixed.y) * mixed.x);
}

void fragment() {
	vec2 world = map_origin + UV * map_span;
	vec2 repeat = world / max(1.0, tile_units);
	vec4 field = texture(field_map, UV);
	vec3 weight = clamp(field.rgb, 0.0, 1.0);
	float standard = clamp(1.0 - weight.r - weight.g - weight.b, 0.0, 1.0);
	float variant = variant_at(floor(repeat));

	// The whole point of pixel art is that its motifs are legible, which is also what makes a tiled
	// ground read as wallpaper: the same flowers land on the same grid every few repeats. Shifting
	// where in the art each repeat starts - by an amount that belongs to that repeat, so it never
	// changes while the camera moves - breaks the grid without touching the art.
	vec2 nudged = repeat + vec2(fract(variant * 7.13), fract(variant * 3.71)) * 0.5;

	vec3 ground = vec3(0.0);
	ground += weight.r * pick_variant(look_lush, look_lush_2, look_lush_3, look_lush_4, nudged, variant);
	ground += weight.g * pick_variant(look_dry, look_dry_2, look_dry_3, look_dry_4, nudged, variant);
	ground += weight.b * pick_variant(look_worn, look_worn_2, look_worn_3, look_worn_4, nudged, variant);
	ground += standard * pick_variant(look_standard, look_standard_2, look_standard_3, look_standard_4, nudged, variant);

	float shade = 1.0 + (field.a - 0.5) * shade_strength;
	COLOR = vec4(ground * shade, 1.0);
}
