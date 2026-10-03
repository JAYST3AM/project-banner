#!/usr/bin/env python3
"""Build the unit sprite atlas the battle renders from.

Source: the PixelLab unit bundles under `assets/sprites/units/<unit>/<animation>/frame_XX.png`
- one character a roster unit, with the idle/walk/attack/hurt/death animations UnitArt carries.
Every character is cropped to one cell, the union of every frame of every animation, so a frame
is always the same size and the runtime just reads offsets; the cell, the anchor (where the
soldier's feet sit) and the head (how tall the idle pose stands, for the health bar) are measured
here, once, and written to the JSON beside the PNG.

Run:  uv run --with pillow python tools/build_unit_atlas.py
Then: godot --headless --import  (so the .import lands beside the fresh PNG)

Keep UNITS in lockstep with UnitArt.UNIT_KEYS and ANIMS with UnitArt.ANIMATIONS.
"""
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "sprites", "units")
OUT_PNG = os.path.join(SRC, "unit_atlas.png")
OUT_JSON = os.path.join(SRC, "unit_atlas.json")

UNITS = [
    "peasant_recruit", "spearman", "archer",
    "bandit_ruffian", "bandit_brigand", "bandit_archer",
]
# Animation name -> milliseconds a frame is held. The old tuned pace, kept: the walk reads at a
# march and the one-shots snap.
ANIMS = [("idle", 140.0), ("walk", 95.0), ("attack", 65.0), ("hurt", 90.0), ("death", 110.0)]
# Chosen so a head (57-61 px, measured below) stands ~3.84 world units - the height the old
# atlas drew soldiers at, so formation spacing and the health bar keep their tuned feel.
UNITS_PER_PIXEL = 0.065


def frame_paths(unit, anim):
    """The unit's frames for one animation: <anim>_frame_NN.png, the install's flat naming."""
    d = os.path.join(SRC, unit)
    if not os.path.isdir(d):
        return []
    return sorted(
        os.path.join(d, f) for f in os.listdir(d)
        if f.startswith(anim + "_frame_") and f.endswith(".png")
    )


def opaque_box(image):
    """The frame's non-transparent bounds, or None when the frame is empty."""
    return image.getchannel("A").getbbox()


def main():
    warnings = []
    # Gather every character's frames first: the union box sets the cell for all of them.
    chars = {}
    for unit in UNITS:
        anim_frames = {}
        idle_pool = frame_paths(unit, "idle")
        if not idle_pool:
            print("ERROR: %s has no idle frames - a unit without a stance cannot be built" % unit)
            return 1
        union = None
        for anim, _ms in ANIMS:
            paths = frame_paths(unit, anim)
            if not paths:
                # The one template the pack lacks still ships: one idle frame, held. The JSON's
                # frame count is what the plan reads, so a 1-frame animation plays as a pose.
                warnings.append("%s: no %s frames - falls back to a held idle pose" % (unit, anim))
                paths = [idle_pool[0]]
            images = [Image.open(p).convert("RGBA") for p in paths]
            for im in images:
                box = opaque_box(im)
                if box is None:
                    continue
                if union is None:
                    union = list(box)
                else:
                    union[0] = min(union[0], box[0])
                    union[1] = min(union[1], box[1])
                    union[2] = max(union[2], box[2])
                    union[3] = max(union[3], box[3])
            anim_frames[anim] = images
        if union is None:
            print("ERROR: %s has no opaque pixels at all" % unit)
            return 1
        x0, y0, x1, y1 = union
        cell = (x1 - x0, y1 - y0)

        # Anchor: the feet, from the idle pose - its horizontal centre and the last idle pixel
        # row, both measured against the cell's own edges so every drawn frame lands under him.
        idle_boxes = [b for b in (opaque_box(im) for im in anim_frames["idle"]) if b]
        idle_bottom = max(b[3] for b in idle_boxes)
        centre_x = sum((b[0] + b[2]) * 0.5 for b in idle_boxes) / len(idle_boxes)
        anchor = (centre_x - x0, y1 - idle_bottom)
        # Head: how tall the idle pose stands, the tallest idle frame - a health bar hangs off it.
        head = max(b[3] - b[1] for b in idle_boxes)
        chars[unit] = {
            "cell": cell, "anchor": anchor, "head": head, "anim_frames": anim_frames,
            "crop": (x0, y0, x1, y1),
        }

    # Lay the rows out: one animation a row, frames left to right, each character's rows stacked.
    width = 0
    height = 0
    for unit in UNITS:
        c = chars[unit]
        for anim, _ms in ANIMS:
            width = max(width, max(1, len(c["anim_frames"][anim])) * c["cell"][0])
            height += c["cell"][1]
    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    table = {"units_per_pixel": UNITS_PER_PIXEL, "characters": {}}
    y = 0
    for unit in UNITS:
        c = chars[unit]
        cw, ch = c["cell"]
        entry = {
            "cell": [cw, ch],
            "anchor": [c["anchor"][0], c["anchor"][1]],
            "head": c["head"],
            "animations": {},
        }
        for anim, ms in ANIMS:
            images = c["anim_frames"][anim]
            for i, im in enumerate(images):
                atlas.alpha_composite(im.crop(c["crop"]), (i * cw, y))
            entry["animations"][anim] = {"y": y, "frames": len(images), "ms": ms}
            y += ch
        table["characters"][unit] = entry
        print("%-15s cell %dx%d head %dpx anchor (%.1f, %.1f) frames %s" % (
            unit, cw, ch, c["head"], c["anchor"][0], c["anchor"][1],
            "/".join("%s:%d" % (a, len(c["anim_frames"][a])) for a, _ in ANIMS)))

    atlas.save(OUT_PNG)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(table, f, indent=1)
        f.write("\n")
    for w in warnings:
        print("WARN:", w)
    print("built %s (%dx%d) + %s" % (
        os.path.relpath(OUT_PNG, ROOT), atlas.width, atlas.height,
        os.path.relpath(OUT_JSON, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
