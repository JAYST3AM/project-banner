"""Build the battle unit atlas from the Tiny RPG character strips.

Run from anywhere:  python tools/build_unit_atlas.py

Reads   assets/art_source/units/tiny_rpg/source/<character>/<animation>.png   (100 px cells)
Writes  assets/art_source/units/tiny_rpg/unit_atlas.png
        assets/art_source/units/tiny_rpg/unit_atlas.json

Why an atlas at all: the battle draws every soldier as one MultiMesh instance, and a
MultiMesh has exactly one texture. All animations of both characters therefore have to live
in one image, and the per-frame source rectangle travels per instance in custom data.

Two rules the game depends on:

* **One crop box per character, for every animation.** The box is the union of every frame's
  opaque pixels (idle through death, attack swings included), so cell size never changes
  between animations and the feet stay on the same pixel - otherwise a soldier's feet would
  jump when he starts walking.
* **The anchor is the idle body's centre line, measured from the cell's bottom.** The battle
  places that point at the soldier's world position, so the drawn man stands on his disc
  however wide the attack frames are.

The art is Zerie's Tiny RPG Character Asset Pack (see README.md beside it); it is git-ignored
and must not be redistributed. This script only ever reads the local copy.
"""

import json
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ART = os.path.join(ROOT, "assets", "art_source", "units", "tiny_rpg")
OUT_PNG = os.path.join(ART, "unit_atlas.png")
OUT_JSON = os.path.join(ART, "unit_atlas.json")

CELL = 100  # the pack's cell size
PAD = 2     # transparent border around every cell: with nearest sampling this is belt and braces
UNITS_PER_PIXEL = 0.16  # world units one atlas pixel draws as; tuned against the battle camera

# Animation name -> (source file stem, milliseconds per frame). The durations are the look of
# the pack's own animations (a slow breath, a brisk walk, a fast swing), not physics.
CHARACTERS = {
    "soldier": {
        "source": "source/soldier",
        "animations": {
            "idle": ("idle", 140),
            "walk": ("walk", 95),
            "attack": ("attack01", 65),
            "hurt": ("hurt", 90),
            "death": ("death", 110),
        },
    },
    "orc": {
        "source": "source/orc",
        "animations": {
            "idle": ("idle", 140),
            "walk": ("walk", 95),
            "attack": ("attack01", 65),
            "hurt": ("hurt", 90),
            "death": ("death", 110),
        },
    },
}


def load_frames(path):
    image = Image.open(path).convert("RGBA")
    if image.size[1] != CELL:
        raise SystemExit(f"{path}: expected {CELL}px tall strips, got {image.size}")
    count = image.size[0] // CELL
    if count == 0:
        raise SystemExit(f"{path}: no {CELL}px cells")
    return [image.crop((i * CELL, 0, (i + 1) * CELL, CELL)) for i in range(count)]


def union_bbox(frames):
    box = None
    for frame in frames:
        alpha = frame.getchannel("A")
        part = alpha.getbbox()
        if part is None:
            continue
        box = part if box is None else (
            min(box[0], part[0]), min(box[1], part[1]),
            max(box[2], part[2]), max(box[3], part[3]),
        )
    if box is None:
        raise SystemExit("every frame was empty")
    return box


def build():
    table = {
        "generated_by": "tools/build_unit_atlas.py",
        "source_pack": "Tiny RPG Character Asset Pack 01 v2.0 - Free Soldier & Orc",
        "author": "Zerie (https://zerie.itch.io/tiny-rpg-character-asset-pack)",
        "usage": "personal & commercial game projects; no redistribution, no AI training",
        "atlas": "unit_atlas.png",
        "units_per_pixel": UNITS_PER_PIXEL,
        "characters": {},
    }

    rows = []  # (character, animation, frames, cell box) - laid out after every box is known
    cells = {}
    for name, spec in CHARACTERS.items():
        loaded = {}
        for anim, (stem, ms) in spec["animations"].items():
            path = os.path.join(ART, spec["source"], stem + ".png")
            if not os.path.exists(path):
                raise SystemExit(f"missing source strip: {path}")
            loaded[anim] = (load_frames(path), ms)

        box = union_bbox([frame for frames, _ in loaded.values() for frame in frames])
        x0 = max(0, box[0] - PAD)
        y0 = max(0, box[1] - PAD)
        x1 = min(CELL, box[2] + PAD)
        y1 = min(CELL, box[3] + PAD)
        cell_w, cell_h = x1 - x0, y1 - y0

        # The anchor: the idle body's centre column (the one pose with no weapon thrown out),
        # and the cell's bottom as the feet plane.
        idle_box = union_bbox(loaded["idle"][0])
        anchor_x = (idle_box[0] + idle_box[2]) * 0.5 - x0
        # The head: how tall the soldier stands in his idle pose, from the cell's bottom. The
        # cell's top is the tallest thing any frame draws - a raised sword in the attack row -
        # so a health bar placed off the cell floats a gap above his head between swings. The
        # bar hangs off this instead, and a sword crossing the bar is the lesser price.
        head_px = max(1, y1 - idle_box[1])

        cells[name] = (cell_w, cell_h)
        table["characters"][name] = {
            "cell": [cell_w, cell_h],
            "anchor": [round(anchor_x, 2), 0.0],
            "head": head_px,
            "source_box": [x0, y0, x1, y1],
            "animations": {},
        }
        for anim, (frames, ms) in loaded.items():
            rows.append((name, anim, frames, (x0, y0, x1, y1), cell_w, cell_h))
            table["characters"][name]["animations"][anim] = {
                "row": 0, "y": 0, "frames": len(frames), "ms": ms,
            }

    widest = max(cell_w * len(frames) for _, _, frames, _, cell_w, _ in rows)
    height = sum(cell_h for _, _, _, _, _, cell_h in rows)
    atlas = Image.new("RGBA", (widest, height), (0, 0, 0, 0))

    y = 0
    for name, anim, frames, (x0, y0, x1, y1), cell_w, cell_h in rows:
        entry = table["characters"][name]["animations"][anim]
        entry["row"] = y // cell_h if cell_h else 0
        entry["y"] = y
        for index, frame in enumerate(frames):
            atlas.alpha_composite(frame.crop((x0, y0, x1, y1)), (index * cell_w, y))
        y += cell_h

    atlas.save(OUT_PNG)
    table["atlas_size"] = [widest, height]
    with open(OUT_JSON, "w", encoding="utf-8") as handle:
        json.dump(table, handle, indent=2)
        handle.write("\n")

    print(f"atlas {widest}x{height} -> {OUT_PNG}")
    for name, entry in table["characters"].items():
        anims = ", ".join(
            f"{anim} {data['frames']}f@{data['ms']}ms y{data['y']}"
            for anim, data in entry["animations"].items()
        )
        print(f"  {name}: cell {entry['cell'][0]}x{entry['cell'][1]} anchor {entry['anchor'][0]} "
              f"box {entry['source_box']}  {anims}")


if __name__ == "__main__":
    build()
