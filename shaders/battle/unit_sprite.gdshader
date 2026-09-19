shader_type canvas_item;
// MultiMesh battle-unit sprites: one atlas, one frame per instance.
//
// The frame a soldier is drawn with is packed into the instance's custom data by
// SoldierField: xy is the frame's top-left corner in normalised atlas coordinates, zw is the
// frame's size in the same units. A negative zw.x mirrors the frame, which is how a
// left-facing soldier is drawn from a right-facing sprite without a second copy of the art
// (the pack's characters are single-direction, so a flip is the whole of "the other way").
//
// Everything else is the default canvas behaviour: the fragment samples TEXTURE at the
// remapped UV and multiplies by COLOR, which carries the per-instance tint (a fallen soldier
// is drawn darkened through it) and the node's modulate.
//
// The v axis is flipped once here. A QuadMesh's v runs bottom-to-top when drawn on the canvas
// (its vertices are laid out for a quad facing +Z), so placing the frame's top row at
// CUSTOM.y with a plain UV * CUSTOM.zw sampled the atlas bottom-up and every soldier was drawn
// upside down - found by drawing one frame through this pipeline beside the raw art
// (scenes/dev/sprite_orientation.tscn). Flipping v in the vertex function fixes both
// renderers at once, and leaves the horizontal mirror (a negative CUSTOM.z) alone.
void vertex() {
	UV = INSTANCE_CUSTOM.xy + vec2(UV.x, 1.0 - UV.y) * INSTANCE_CUSTOM.zw;
}
