# Project Banner — Battle Visual Direction & Acceptance Standard

**Status:** Target specification, not a claim that the current battle meets it.  
**Visual benchmark:** The cinematic readability, tactical clarity and production cohesion of **Total War** battles, expressed in **realistic medieval HD pixel art** rather than copying their 3D assets or interface.

## Non-negotiables

1. **A game, not a debugger.** No developer counters, GPU timings or placeholder overlays during ordinary gameplay. Diagnostics behind F3 only.
2. **Scale without visual chaos.** Close-up soldiers are individually readable. Medium zoom shows coherent formations, banners and battlefield context. Full-map zoom shows accurate oriented formation footprints, strength and destinations. Transitions cannot change simulation or orders.
3. **Realistic medieval material language.** Worn iron, damp wool, mail, brigandine, weathered timber, trampled earth. Grounded proportions and authentic silhouette. No oversized anime weapons, saturated fantasy armour or modern flat-design game HUD.
4. **Terrain that reads as terrain.** Not a procedural debug colour map: field-scale shape, distinct roads and clearings, believable tree groups, rocky ridges, terrain edges, weather and tactically relevant landmarks. Altitude, woods, mud and routes should be recognizable without toggling a debugging legend.
5. **Formation fidelity.** The rectangle in overview must represent each body's *actual footprint and facing*, not a disconnected symbol. Changing width should move real soldiers into new ranks. Multiple selected bodies never overlap simply because an order has one destination.
6. **Motion that belongs to the action.** Individual footsteps differ slightly; units turn and reform with convincing delays. Attacks use their actual weapon and have observable wind-up, release, contact and recovery. Hit reactions, routed movement, projectile paths and combat audio must agree with the simulation.
7. **Information hierarchy.** The player should read selected units, sides, troop strength, order/stance, morale, fatigue, terrain and formations in under a second without blocking the view.

## Minimum polished battle slice

Build and playtest *one* visually complete encounter before scaling the spectacle:
- Six authentic unit archetypes from the existing PixelLab atlas.
- 4–6 controllable formations on each side, several soldiers each, on a hand-reviewed field.
- Three useful camera scales: close, command distance, whole map.
- Click/box select, persistent group selection, drag-to-frontage and ghost order preview.
- Actual unit portraits, bottom cards, bar indicators, current stance and command strip.
- Battlefield with authored pixel-art ground tiles, vegetation and at least one elevation/obstacle feature.
- Ranged volleys and melee exchanges that visually match attack timing, with credible damage feedback.
- A screenshot and short capture for each zoom level at the target resolution.

## Production asset matrix

| Layer | Target | Acceptance |
|---|---|---|
| Ground | Tiling multi-variant HD pixel-art grass, soil, mud, stone, woods, paths | No giant visible simulation-cell squares or repeating seams |
| Topography | Hills, low ground, escarpments, depressions | Relief readable; traversability matches collision/LOS |
| Props | Trees, rocks, fences, hedges, ruins, carts | Appropriate shadows and consistent lighting; never conceal selection |
| Soldiers | Clean frame-to-frame proportions, realistic equipment, 8-facing system | Legible at command zoom; visible weapon identity and correct frame timing |
| Formation markers | Thin grounded highlights, flags, facing arrows | Consistent between close and overview zoom |
| Battle UI | Medieval restrained metal/cloth/parchment palette and original unit portraits | No developer labels; distinct selected/damaged/routing states |
| Effects | Contact impacts, dust, arrows, blood sparingly, crowd reaction | Tied to events, not random ambient noise |
| Audio | Footfalls by surface, arrows, material-specific hits, army ambience | Positional, controlled, not exhausting |

## Scale realism

- The existing **64×64** PixelLab roster is a workable distant/mid-distance unit asset, but it cannot by itself deliver modern Total War close-up fidelity.
- For a genuine close-up **HD pixel-art** result, build higher-detail animation sources (or higher-resolution character rigs), plus more directional action animations.
- Do **not** upscale the existing 64×64 raster to 256×256 and call it higher fidelity. It remains the same information enlarged.
- Large armies need an explicit multi-level LOD pipeline: full soldiers nearby, simplified/decimated movement further away, stable formation geometry at full-field zoom. The simulation need not change with LOD.

## Implementation tracks

**Track A — Battle commands / presentation:** Cards, selection, unit facing, drag width, overview, command bar. Current draft PR targets this.

**Track B — Battlefield art pipeline:** Connect authored tile art through the already present `TerrainGround` shader, then vegetation, relief, landmarks, decals, lighting. The procedural fallback is a temporary safety net, not final art.

**Track C — Soldier animation and effects:** Accurate weapon-specific animation vocabulary, animation events from combat state, impacts/projectiles/corpses, VFX and audio.

**Track D — Tactical combat mechanics:** Collision, pathfinding, morale, fatigue, cover, terrain penalties, flanks, ranged fire, enemy tactics. Do not mistake a visual effect for a simulation mechanic.

**Track E — Performance & QA:** Verify the map at 1080p, ultrawide and smaller windows; profile one full real-time battle, test selection accuracy and camera transitions, regression-test persistence and deterministic outcomes.

## Release gate

Never call a battle scene **Total War-grade** until it passes a hands-on visual and interaction review. Passing headless unit tests, rendering a textured field, or importing sprite atlases is necessary infrastructure—not proof of production-ready visuals.
