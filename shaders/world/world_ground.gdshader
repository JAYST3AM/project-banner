shader_type canvas_item;
// The campaign map's ground: sixteen plains grounds, meshed.
//
// Four *looks* - Standard, Lush, Dry, Worn - blend into one another across the map, driven by a
// field of weights generated from the world seed. Inside each look, four *sub-variants* rotate from
// repeat to repeat, chosen by a hash of where the repeat is, so the eye never catches the same
// patch twice even though the same art is under it.
//
// Sampled linear with mipmaps: the grounds are paintings, minified hard at map zoom, and mipmaps are
// what stop a 1254-pixel image shimmering as it pans. Pixel art would want nearest here instead.
//
// The ground tiles in world space, not screen space: panning and zooming slide over the ground
// rather than stretching it. The variant hash runs on the same grid as the tiles, which is what
// keeps one variant per repeat instead of shimmering across it.
//
// The height channel is shaded now and will displace geometry later; it comes from the same seed as
// the weights, so a hill on the map is a hill in the battle fought on it.

uniform sampler2D look_lush : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_lush_2 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_lush_3 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_lush_4 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_dry : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_dry_2 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_dry_3 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_dry_4 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_worn : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_worn_2 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_worn_3 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_worn_4 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_standard : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_standard_2 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_standard_3 : repeat_enable, filter_linear_mipmap;
uniform sampler2D look_standard_4 : repeat_enable, filter_linear_mipmap;

// Water and sand, the two kinds the world was missing. The field has carried a height since the first
// version and nothing consumed it, so there were no rivers, no coasts and no beaches: one green sheet,
// which is exactly what the owner kept telling me looked bad. These two grounds are all that is needed
// to turn that channel into country.
uniform sampler2D ground_water : repeat_enable, filter_linear_mipmap;
uniform sampler2D ground_sand : repeat_enable, filter_linear_mipmap;

// Below water_level is water, between the two is shore, above sand_level is land. Tunable from the
// catalogue, so how much of the world is water is a number the owner can move rather than a rebuild.
uniform float water_level = 0.335;
uniform float sand_level = 0.375;

// R, G, B = how much Lush, Dry and Worn this place is. Standard is the remainder, so the four
// always add to one and no fourth weight has to be stored. A = height.
uniform sampler2D field_map : filter_linear;

// World units one repeat of a ground image covers. Smaller means more tiles and the art's detail
// seen closer up - 1254-pixel paintings shrink well at this size because the samplers carry
// mipmaps, which is what stops a small repeat aliasing into coloured speckle.
uniform float tile_units = 260.0;
uniform float shade_strength = 0.46;
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

	// Water and shore, from the height that was always there. The edges are soft over a few thousandths
	// of height, which is what makes a bank rather than a cut-out; the water's own surface breaks up
	// with the same per-repeat nudge the ground uses, so a lake does not read as one stretched sheet.
	float water_edge = smoothstep(water_level - 0.010, water_level + 0.010, field.a);
	float shore_edge = smoothstep(sand_level - 0.012, sand_level + 0.012, field.a);
	vec3 water = texture(ground_water, nudged * 0.5).rgb;
	vec3 shore = texture(ground_sand, nudged * 0.7).rgb;
	vec3 land = mix(shore, ground, shore_edge);
	ground = mix(water, land, water_edge);

	float shade = 1.0 + (field.a - 0.5) * shade_strength;
	COLOR = vec4(ground * shade, 1.0);
}
