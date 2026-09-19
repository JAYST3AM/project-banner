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
void vertex() {
	UV = INSTANCE_CUSTOM.xy + UV * INSTANCE_CUSTOM.zw;
}
