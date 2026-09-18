# Dual-grid corner sheets - PLACEHOLDER

Grass, dirt and sand corner sheets from
**jess-hammer/dual-grid-tilemap-system-godot** (https://github.com/jess-hammer/dual-grid-tilemap-system-godot),
used as placeholders until the owner's own art replaces them. The owner's words: "for now this is
placeholder, we can change it later."

**MIT licensed.** Using these in a shipped build needs the MIT notice somewhere in the credits. That is
the only condition and it is worth writing down next to the files rather than remembering later.

## What they are

Each sheet is 64x64: a **4x4 atlas of sixteen 16x16 tiles**, one per corner combination. A dual-grid
tile's appearance is decided by its four *corners*, not its four edges, which is why sixteen covers
every case including inner and outer corners, edges, and the all-one-kind tile.

The technique is Oskar Stalberg's; the implementation and sheets here are jess-hammer's.

## The lookup, exactly as their `DualGridTilemap.cs` defines it

Corners are read in the order **(top-left, top-right, bottom-left, bottom-right)**, each `Some`(land)
or `None`(empty). Atlas coordinates are (column, row) in the 4x4 grid:

    (Some, Some, Some, Some) -> (2, 1)   all corners (interior)
    (None, Some, None,  Some) -> (1, 0)  right edge
    (Some, None, Some,  None) -> (3, 2)  left edge
    (None, None, Some,  Some) -> (3, 0)  bottom edge
    (Some, Some, None,  None) -> (1, 2)  top edge
    (None, None, None,  Some) -> (1, 3)  outer bottom-right corner
    (None, None, Some,  None) -> (0, 0)  outer bottom-left corner
    (None, Some, None,  None) -> (0, 2)  outer top-right corner
    (Some, None, None,  None) -> (3, 3)  outer top-left corner
    (None, Some, Some,  Some) -> (1, 1)  inner bottom-right corner
    (Some, None, Some,  Some) -> (2, 0)  inner bottom-left corner
    (Some, Some, None,  Some) -> (2, 2)  inner top-right corner
    (Some, Some, Some,  None) -> (3, 1)  inner top-left corner
    (None, Some, Some,  None) -> (2, 3)  opposite corners, bottom-left and top-right
    (Some, None, None,  Some) -> (0, 1)  opposite corners, top-left and bottom-right
    (None, None, None,  None) -> empty

## How this fits our map

The campaign map already reads the terrain field at each tile's four corners - that went in for the soft
coastline. Selecting one of these sixteen pieces from those four corner readings is the same mechanism
the shader already uses to pick between four ground variants, so the crisp coastline needs no TileMap,
no per-frame tile drawing, and no chunk management: one quad, one draw call, sixteen tiles chosen in the
fragment shader.

The owner's own art replaces these sheets when it exists, and the same sixteen-piece layout is what
Webtyler's slicing rule produces from a single source image.
