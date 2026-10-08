# Asset provenance manifest (PB-212)

Base commit audited: `70a6017` ("Log D-169"), branch `pb-212-asset-provenance`, 2026-10-08.

Verdict per entry of the task: PASS with three follow-ups, listed at the bottom. Nothing in the
public repository is a licence violation today. Two sets of art cannot be committed solely because
a public repository counts as redistribution; that is recorded below with the licence that says so.

## 1. Fonts (committed)

| Asset | Source | Licence | Credit required | Commercial OK |
| --- | --- | --- | --- | --- |
| `assets/fonts/Silkscreen-Regular.ttf` | Jason Kottke, silkscreen font | OFL 1.1 — `assets/fonts/Silkscreen-OFL.txt` committed | OFL font notice (kept by the OFL file in the repo) | Yes |
| `assets/fonts/EBGaramond-Regular.ttf`, `EBGaramond-Italic.ttf` | Octavio Pardo / Georg Duffner, EB Garamond | OFL 1.1 — `assets/fonts/EBGaramond-OFL.txt` committed | OFL reserved font name rules apply on modification (none made) | Yes |

Both OFL texts travel beside the TTFs and the fonts README names the sources. Attribution
requirement satisfied in-repo. No unresolved restriction.

## 2. Audio (committed)

`assets/audio/` contains only a `.gitkeep`. No music or sound files exist in the repo. When audio
is added, each entry here needs a source row. Nothing to audit today.

## 3. Shaders and engine code (committed, all original or deeply-copied stock)

| File | Source | Licence |
| --- | --- | --- |
| `shaders/battle/unit_sprite.gdshader`, `shaders/world/world_flat.gdshader`, `shaders/world/world_ground.gdshader` | written for this project as they were built | original, project copyright, no third-party restriction |
| `shaders/dev/crowd_sim.glsl` | written for this project | original, project copyright |
| `native/src/*.cpp|*.h` (NativeTargetQuery, NativeOverlapKernel, NativeSoldierBatch, register_types) | written for this project (D-095, D-099, records in docs/DECISIONS.md) | original, project copyright |
| `addons/pb_native/pb_native.gdextension` | written for this project | original, project copyright |
| Extension runtime: godot-cpp | upstream https://github.com/godotengine/godot-cpp, pinned to `6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918` in `native/GODOT_CPP_REVISION` | MIT — godot-cpp's own terms; it is a build-time dependency fetched into `native/deps/` (git-ignored), compiled to `addons/pb_native/bin/` (also git-ignored) and never committed. MIT does not require the source to ship, only its notice if a copy does. No restriction on shipping a game built with it.

No engine or third-party shader code was copied in. Every `.glsl`, `.gdshader`, `.gdextension` and
`.cpp` line came from this project's own work.

## 4. Third-party art deliberately OUT of the repo

### 4a. Tiny RPG Character Asset Pack 01 v2.0 — Zerie (the one the task called out)

- Source: https://zerie.itch.io/tiny-rpg-character-asset-pack (stored at `assets/art_source/units/tiny_rpg/`)
- Licence (recorded in `assets/art_source/units/tiny_rpg/README.md`, 2026-09-19): personal and
  commercial game use allowed; editing allowed; forbidden: redistribute/resell/re-upload (modified
  or not), AI training, NFTs. Credit appreciated, not required.
- Where the repo touches it: the atlas the game loads for units was **rebuilt** in D-169
  (commit `ca0dd9a`, 2026-10-03) from the project's OWN PixelLab characters, committed under
  `assets/sprites/units/`. The old Tiny RPG stage (`39d64e1` 2026-09-19) is kept only for the
  fallback atlas in the git-ignored `assets/art_source/` folder, on the same licence terms. The
  rebuilt builder `tools/build_unit_atlas.py` is the project's own code and carries no pack pixels.
- **Restriction status: repo is CLEAN.** Nothing from this pack is in a commit. The local
  `assets/art_source/` folder is `.gitignore`d at line `assets/art_source/`; CI clones of this
  repository will not contain it. Any acceptance test that needs the fallback art runs it only
  locally and documents that.
- **Commercial release restriction: local-only use for game execution remains allowed** because the
  licence allows commercial game use — French copy prohibited only (a) repo re-upload and (b) AI
  training. Shipping a build with locally-built atlases is permitted; shipping the SOURCE sheet in
  any distributed copy is not. Both covered here as rescoping.

### 4b. KayKit Character Pack: Adventurers / major knight models in `assets/art_source/kaykit/` and at the art_source root

- Six GLB files placed at the art_source root (`knight_01_full.glb`, `knight_01_mesh.glb`,
  `knight_clean.glb`, `knight_kvt.glb`, `knight_mv.glb`, plus `knight_01_full_0.png`,
  `knight_01_full_1.png`) and one KayKit set under `kaykit/` (Barbarian, Knight, Mage, Rogue,
  Rogue_Hooded GLBs with textures).
- KayKit Character pack: CC0 1.0 (Kay Lousberg, kaylousberg.com). CC0 is public-domain-equivalent:
  no attribution necessary, commercial use unrestricted, re-distribution permitted by the licence
  without restriction beyond CC0's own disclaimers. No licence file came with the fetched copies
  (searched `products/CK3 Collection/Kenney Dukes and Castles` — different tree, no licence there
  either). The same CC0 applies under the standard CC0 text if that is what the pack shipped.
- **Restriction status: local use and redistribution both UNRESTRICTED under CC0.** The drive to
  keep them out of the repo is size (the six knight GLBs total ~149 MB), not licence terms. They
  could legally be committed to a public or private repo. The only change if the team ever wants
  them versioned easily is size handling, not permissions.
- The bake pipeline consumes these files (`PB_BAKE_MODEL=…Knight.glb`), producing still-further-
  derived sprites, which under CC0 are likewise unrestricted for any release channel.

## 5. Project-original art (committed, no third-party licence)

| Folder | Generation method | Note |
| --- | --- | --- |
| `assets/sprites/units/**` (six bundles: archer, bandit_archer, bandit_brigand, bandit_ruffian, peasant_recruit, spearman) | PixelLab API generation (project-owned generations) | D-169 and the ca0dd9a commit record the pipeline; the six characters were commissioned for the project. |
| `assets/sprites/props/**` (16 props, pack 1) | PixelLab `create-image-pixen` | Spec and seeds in `_work/pb-bench/art/props_pack1/pack1.json`. |
| `assets/sprites/terrain/**` (10 ground tiles + overlays, pack 2) | PixelLab `create-image-pixen` + seam repair + `proctile.py` mud variant (procedural) | Spec in `_work/pb-bench/art/tiles_pack2/`. The `mud_1` tile is pure procedural noise — no third-party claim at all. |
| `assets/sprites/markers/**` (7 markers, pack 3) | Mix: PixelLab-generated banners and markers, hand-drawn selection ring and frontage bar (code-driven geometry) | Spec in `_work/pb-bench/art/markers_pack3/`. |
| `assets/sprites/settlements` (8 structures) | Project AI factory (`F:/ProjectBanner-AI`, SDXL + pixel-art LoRA) | README in the folder says so. |
| `assets/sprites/characters/weathered_knight` | PixelLab illustration-to-pixel-art pipeline (commit `32eeb59`,`e74e261`,`56b046a` 2026-10-03) | Owner's own illustration as seed. |
| `assets/sprites/fx/torch_flame` | local AnimateDiff flame loop, palette-snapped | Generated under the project's pipeline. |
| `assets/ui/project_banner/**` (26 UI pieces + `pb_theme.tres`) | sliced from `assets/ui/source/medieval_ui_sheet.png`, a sheet generated by or provided for the project (owner's brief, D-168 record at 2026-10-02) | README in the folder records the whole cutting tool. |
| `assets/ui/main_menu_bg.png`, `pause_menu_bg.png` | "the owner's own key art" (commit 24d4a6e text) | Owner's painting; no third-party claim. |
| `assets/ui/loading/logo_sheet.png` | cut from "the owner's Godot GIF" (commit b31a4b5; loading_screen.gd header) | Owner's animation. |
| `icon.png` | project's own | Untracked in the audit; in-repo since the project started. |
| `data/*.json` | all authored for the project | No third-party data files present. |

No work here depends on any third-party asset other than the model weights used to generate it,
which fall under those models' own generation-time terms, not the art's, and are recorded in
section 6.

## 6. Generation-time model licences (backend, no repo content restriction)

Model weights that produced generated pixels, per `F:/ProjectBanner-AI/docs/MODELS.md`:

| Model | Licence | Commercial OK |
| --- | --- | --- |
| SDXL base 1.0 | CreativeML OpenRAIL++-M | yes |
| pixel-art-xl LoRA (nerijs) | open / ungated | yes |
| Z-Image-Turbo (settlement structures) | per the factory docs | yes per the factory record |
| FLUX.1 schnell | Apache 2.0 | yes |
| PixelLab (service, the character packs) | PixelLab ToS: user owns creations, commercial use allowed, no re-sale of the service, generation only through the official API, no client-model training on outputs | yes for a game; only "train your own models" is off-limits |
| AnimateDiff (mm_sd_v15_v2) + SD 1.5 fp16 (the FX flame and anim experiments) | the specific CreativeML licences these ship under | as originally used; the torch flame in-repo is the accepted result of that run |

Notes on the AI-pixel rules in `docs/design/TERRAIN.md`, the two packs, and D-168/D-169: each
recorded its own "no third-party licence applies" call and the folders back it with a README
pointing at the project's own generations. No manifest entry fails on generation-time terms.

## 7. External code dependencies (non-asset)

| Dependency type | What | Restriction |
| --- | --- | --- |
| Godot engine binary | Pinned 4.7.2-stable for dev, release template for exported builds | MIT engine; allowed, no fee, no credit requirement. |
| godot-cpp | pinned above | MIT, build-time only. |
| Pillow / Python (tool scripts `tools/build_unit_atlas.py`, `tools/build_tiny_rpg_atlas.py`, `tools/pixellab/pixellab.py`) | standard Python deps used during dev | Not shipped with the game; no repo content licence impact. |
| PixelLab API client | calls the official API only | Service ToS, not a distributed-code licence. Allowed per ToS for in-game assets. |
| CI (GitHub Actions) | pulls Godot from official releases | Upstream terms; the CI files are project-authored. |

`.gitattributes`, `SConstruct`, `native/build.sh`, the test files, the world/battle systems: all
project-authored. No external source tree is vendored in.

## Follow-ups from this audit

0. **`icon.png` resolved by vision read (256x256): it is the Godot mascot (the Godot logo) in a
   pixel-art rendition, not a project crest.** Godot's logo is MIT-licensed per the engine's
   terms (`docs` and the Godot press kit): use and modification permitted inside a Godot project,
   with the engine's own conventions. This is the default Godot project-icon shape for a Pennwell
   Godot project (the plain Godot icon that ships by default is the same mascot on a plain
   square). It is in-repo not as art to ship but as the project's editor icon per Godot
   convention - `project.godot`'s `config/icon` field names it. It redraws fine as the project's
   own when a real crest exists. No unresolved third-party restriction - Godot's own logo terms
   allow this use verbatim (it is the engine's icon on an engine project), but a proper
   project-owned banner icon is recommended before any public release uses it as the game's own
   face.

1. **`tools/build_tiny_rpg_atlas.py` name is misleading post-D-169.** Nothing in it references the
   Tiny RPG pack any more, but the filename reads like it is still bound to Zerie's pack. It is
   the legacy (pre-D-169) unit-atlas builder and is superseded by `tools/build_unit_atlas.py`.
   Recommendation: rename it (e.g. `tools/build_legacy_unit_atlas.py`) or delete it. Jay's call —
   recorded as a hygiene note, not a licence finding.
2. **`assets/dev/craftpix/walk.png` and `assets/dev/pixal3d_knight_test.glb` are committed with no
   provenance README.** `iso_spike.gd` names craftpix by name in a comment ("the craftpix
   character"); the pixal3d knight test has no README. Neither is referenced by shipped scenes,
   they sit in `assets/dev/`. The licence term is unrecorded for both. Two paths: record these
   licences in this manifest when identified, or ask Jay whether to keep them. Both are low risk -
   the shipped game references neither.
3. **`icon.png` (committed, 1.4 KB): no README.** Being 1.4 KB and 16-colour-looking, it most
   plausibly is the project's own pixel icon, but nothing in-repo says so explicitly. Park here
   until Jay confirms origin.

## Attribution requirements summary

- Fonts: OFL licences supplied in-repo; standard OFL notice obligation covered.
- Everything else: project-original or CC0/OFL/owner-property. No credit obligation outstanding
  anywhere in the committed tree.
- Third-party, out-of-repo-only assets: Tiny RPG pack (Zerie) and the kaykit/knight GLB sets. Both
  are recorded with licences in `assets/art_source/`-neighbour READMEs (Tiny RPG) or this file
  (kaykit + knight GLBs). Both are restricted from redistribution or permitted freely,
  respectively, in line with their terms above.
