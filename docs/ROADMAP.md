<!-- Approved roadmap. Captured from the planning conversation 2026-10-08; preamble removed. -->

# Project Banner — Master Development Roadmap



**Version:** 1.0 — Planning Draft\

**Date:** 8 October 2026\

Status: APPROVED — M00 complete 2026-10-08 (D-170). Execution proceeds M01 → M17.

**Project owner:** Jay\

**Technical lead:** GPT-6\

**Local implementation verifier:** Hermes\

**Engine:** Godot 4.7.2-stable\

**Repository:** `JAYST3AM/project-banner`



---



# 0. Executive Direction



## 0.1 What Project Banner is



Project Banner is a single-player medieval mercenary-company strategy game combining:



- A persistent campaign world containing settlements, companies and hostile forces.

- Recruitment and management of individual soldiers.

- Company identity, including customizable banners and eventually a founder character.

- Tactical real-time battles involving independently commanded formations.

- Battlefield terrain, unit positioning, army manoeuvres and large-scale tactical overview.

- Persistent consequences: casualties, experience, equipment, money and company progression.



Its core influences include Battle Brothers, Total War and medieval tactical strategy games.



Its intended visual identity is **grounded medieval HD pixel art**, combining detailed characters and believable landscapes with the readability of large-scale strategy games.



Project Banner must eventually feel like a coherent game, not a collection of impressive technical demonstrations.



## 0.2 Primary development objective



**Produce one complete, enjoyable, independently verified campaign gameplay loop before expanding the feature set.**



The objective is not to implement every planned system.



The objective is to build a game that strangers can understand, play, enjoy and return to.



## 0.3 Current development policy



Development is paused until Jay approves this roadmap.



After approval:



1. GPT-6 makes architecture decisions and authors implementation code.

2. GPT-6 commits changes to isolated GitHub branches.

3. Hermes retrieves those commits into separate local worktrees.

4. Hermes runs tests, reviews behaviour and returns raw evidence.

5. GPT-6 reviews results and corrects defects.

6. Jay authorizes integration when acceptance criteria are satisfied.



No automatic merges. No unverified success claims. No modification of Jay's unfinished local work without explicit authorization.



**One coherent change is completed and verified before the next begins.**



---



# A. Where the Game Actually Is



## A.1 Evidence classification



The project contains substantial working code and historical test evidence. However, a previously passing test does not establish that every current game path works.



Every status claim must use one of these classifications:



| Status                  | Meaning                                                                         |

| ----------------------- | ------------------------------------------------------------------------------- |

| VERIFIED                | Executed on the specified commit with raw passing evidence                      |

| HISTORICALLY VERIFIED   | Documented as passing previously; not freshly re-run                            |

| IMPLEMENTED, UNVERIFIED | Code exists, but current execution evidence is incomplete                       |

| PARTIAL                 | Some functional requirements exist; the complete player-facing feature does not |

| NOT IMPLEMENTED         | Required functionality has not been built                                       |

| UNKNOWN                 | Insufficient evidence to classify accurately                                    |

| BLOCKED                 | A known prerequisite or defect prevents acceptance                              |



GitHub commits prove that source code exists. They do not prove the code compiles, behaves correctly or performs adequately.



Headless tests prove their specific assertions. They do not automatically prove windowed rendering, GPU behaviour or player usability.



## A.2 Main branch baseline



At the last confirmed inspection:



- Branch: `main`

- Commit: `70a6017`

- Engine: Godot 4.7.2-stable

- Historical test baseline: 38 suites, 10,115 assertions, zero failures.

- Additional historical evidence includes native-query tests, separation-equivalence tests and a two-process persistence check.



These numbers are documented in `docs/CURRENT_STATE.md`. They are **historical evidence**, not a fresh validation of every branch or local modification.



The repository's existing `docs/ROADMAP.md` contains approximately 959 lines of historical milestones. Its completed work must not be silently discarded when adopting this new plan.



**Documentation preservation rule:** Before replacing the old roadmap, archive it under an explicitly named historical document and retain its Git history.



## A.3 Existing systems audit



| System                      | Current assessment           | Evidence and qualification                                                                   |

| --------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------- |

| Godot project architecture  | Historically verified        | Autoload services, scenes, configuration and tests exist                                     |

| Main menu                   | Historically verified        | Campaign creation and Continue paths have tests                                              |

| New Campaign screen         | Implemented                  | Company naming, world seed and banner workspace                                              |

| Banner editor               | Historically verified        | Pixel painting, editing tools and campaign-map banner integration documented                 |

| Campaign map                | Historically verified        | Travel, settlements, parties and camera controls                                             |

| Recruitment                 | Historically verified        | Persistent individual soldiers and recruitment rules                                         |

| Soldier statistics          | Implemented                  | Individual records, battle attributes and progression infrastructure                         |

| Encounters                  | Historically verified        | Bandit encounters and context transfer                                                       |

| CPU combat                  | Historically verified        | `BattleSimulator`, formations, combat and result tests                                       |

| GPU battle                  | Partial                      | Campaign launches GPU scene; full current gameplay acceptance remains unproven               |

| Tactical formations         | Partial                      | Existing CPU implementation and GPU formation logic; unresolved integration/behaviour checks |

| Formation navigation        | Implemented, partly verified | Feature-branch navigator and blocked-command fix                                             |

| Terrain generation          | Historically verified        | Deterministic terrain data and channels                                                      |

| GPU terrain collision       | Implemented, unverified      | Collision mask and shader integration; required windowed checks remain open                  |

| Strategic camera            | Partial                      | Zoom/pan infrastructure and overview components exist                                        |

| Strategic LOD               | Implemented, unverified      | Local CPU LOD changes still need complete review/testing                                     |

| Command interface           | Partial                      | UI components exist on feature branch, not accepted into main                                |

| Unit portraits/roster cards | Partial                      | Feature-branch implementation awaits integration and visual review                           |

| Audio                       | Unknown/incomplete           | No accepted production audio coverage established                                            |

| Combat VFX                  | Partial                      | Some projectiles and animation hooks; full effect coverage unverified                        |

| Save/load                   | Historically verified        | CPU-path persistence and separate-process validation                                         |

| GPU battle-to-save contract | Unverified                   | Must be exercised through the real campaign GPU battlefield                                  |

| Performance                 | Historically measured        | GPU probe benchmarks exist, but production scene targets need current measurements           |

| Asset licensing             | Incomplete audit             | Some external assets identified; complete commercial manifest not established                |

| Distribution build          | Unverified                   | No accepted external-player release package established                                      |



These classifications are intentionally conservative.



## A.4 The two-battle-system problem



This is one of the project's most important architectural issues.



### CPU reference path



- `scripts/battle/battle.gd`

- `scripts/battle/battle_simulator.gd`

- `scripts/battle/battle_view.gd`

- `scripts/battle/soldier_field.gd`



The CPU implementation has extensive headless test coverage and serves as an important behavioural reference.



### GPU campaign path



- `scenes/battle/battle_field.tscn`

- `scripts/battle/battle_field.gd`

- `scripts/dev/gpu_crowd.gd`

- `shaders/dev/crowd_sim.glsl`



The actual world-map encounter flow calls:



`SceneManager.change_scene("battle_field", {"context": context})`



The primary existing end-to-end test still enters:



`SceneManager.change_scene_and_wait("battle", {"context": context})`



**Consequence:** The CPU end-to-end test does not prove that the GPU campaign battle completes the same journey correctly.



The GPU implementation has a real campaign adapter, combat simulation, rendering and result-resolution code. It also has documented windowed demonstrations.



However, the currently reviewed evidence does not establish one independently verified, automated, complete GPU-path campaign-to-battle-to-campaign-to-restart contract on the current integration state.



This must be closed before calling the new game loop verified.



### Architectural decision



- The GPU battlefield is the intended production battle implementation.

- The CPU battlefield remains a reference and testing oracle during reconciliation.

- Common data contracts should be shared where practical.

- The CPU and GPU systems do not need identical implementation details or identical frame-by-frame visuals.

- They must honour the same defined gameplay contracts where parity is required.

- No second permanent set of gameplay rules should be developed casually.

- The CPU reference must not be deleted until replacement tests are sufficient and Jay approves its retirement.



The September `docs/BATTLE_MIGRATION_PLAN.md` contains older statements describing CPU battles as the live campaign path. The current scene registry and world-map code show that this routing has since changed. That document needs a historical-status annotation.



## A.5 The 88-commit feature branch



Primary branch:



`feature/battle-command-overview-v1`



Related branch:



`wt/nav-blocked-command`



At the last direct GitHub comparison:



- Main base: `70a6017`

- Feature branch: 87 commits ahead of main.

- Navigator-fix branch: 88 commits ahead of main.

- Overall changed-file set: 32 files.



The reported 88-commit figure reflects the navigator continuation. Branch heads should be rechecked when development resumes.



### What this branch contains



The feature branch combines several distinct systems.



**Battle commands and presentation**



- `battle_command_bar.gd`

- `battle_unit_dock.gd`

- `battle_minimap.gd`

- `battle_tactical_overview.gd`

- `battle_deployment_overlay.gd`



**Formation movement**



- `battle_formation_navigator.gd`

- `battle_placement_planner.gd`

- `battle_formation_cohesion.gd`



**Terrain and rendering**



- `battle_ground_painter.gd`

- `battle_scenery.gd`

- `battle_terrain_art_audit.gd`

- `battle_terrain_gpu_mask.gd`

- Terrain rendering updates and associated shaders.



**Live battlefield integration**



- Extensive changes to `scripts/dev/gpu_crowd.gd`

- Related changes to `battle_field.gd`, `battle_view.gd` and GPU compute shaders.



**Tests and specifications**



- Additional battle module test suites.

- Test-runner registrations.

- Visual-target and terrain-integration documentation.



### What is wrong with its current state?



The primary problem is not that this code is necessarily broken.



The problem is that it is **too much unreviewed integration work in one development lineage**.



Risks include:



- A passing low-level test hiding an integration failure.

- Multiple independent features depending on the same large controller changes.

- CPU/GPU behaviour drifting without an explicit contract.

- A renderer or shader change appearing correct on paper but failing on hardware.

- Difficult regression isolation.

- Features being described as complete before they are exposed and usable in the campaign.

- Large merges conflicting with Jay's local changes.

- Accumulated changes eventually becoming too expensive to review.



The branch must remain preserved, but it must not be merged wholesale merely to clear the backlog.



## A.6 Navigator fix status



Commit: `a4a42b8`



The blocked-command fix rejects a nearest-reachable fallback path consisting solely of the formation's current tile.



The diff has been reviewed and its logic accepted at code-review level.



Hermes reported passing navigator and related suites, with multiple rounds of verification.



It remains subject to integration verification when its parent branch is decomposed.



## A.7 GPT-6 formation foundation branch



Branch:



`gpt6/formation-command-foundation-v1`



Commit:



`1a6695a2ee0a781b96e1cbf77e9aef8738fb4986`



This is a single main-based extraction containing:



- Formation navigation.

- Formation placement.

- Formation cohesion.

- The blocked-command fix.

- Boundary movement handling that preserves group spacing.

- Three test suites and runner registration.

- Supporting documentation.



Eight files changed.



**Status: committed, pushed, not locally accepted.**



The commit has not received Hermes' completed Godot verification report in this conversation.



It is frozen during planning mode.



It must not be merged or extended until this roadmap is approved and its tests pass.



## A.8 Uncommitted local LOD work



Jay's local working tree contains unfinished changes in:



- `scripts/battle/battle.gd`

- `scripts/battle/battle_view.gd`

- `data/config/game_config.json`



These changes implement a strategic zoom presentation handoff between individual soldiers and grouped battlefield rectangles.



Reported evidence:



- Code applied and compiled.

- Existing targeted suites passed: `battle_view` 8/8, `unit_sprites` 460/460 and `formation_battle` 132/132.



Still unverified:



- Newly required threshold and transition tests.

- Selection and orders across all zoom levels.

- Cache invalidation after casualties and formation changes.

- Long-run render/simulation equivalence.

- Windowed four-zoom captures.

- Performance measurements.

- Full regression against the changed tree.

- Interaction with the actual GPU campaign battlefield.



This code stays untouched until it is safely captured and reviewed.



**Important:** The CPU zoom thresholds and GPU camera thresholds describe different rendering paths. They must not be assumed numerically interchangeable.



## A.9 What has not been proved



The following are outstanding acceptance gaps, not blanket claims that the functionality has never run:



1. A complete current GPU campaign encounter, controlled by a player, through battle resolution and restart, with independently captured evidence.

2. Reliable selection and movement orders at every required strategic zoom level in the live GPU campaign scene.

3. Shader-backed terrain collision through realistic battle scenarios, including diagonal movement and separation.

4. A fully reviewed and mergeable replacement for the unreviewed feature branch.

5. Consistent production rendering at target resolutions, including dense formation overlap.

6. Commercial readiness of every shipped art/audio asset.

7. Reproducible production performance measurements against an agreed hardware target.

8. A packaged build successfully played by someone unfamiliar with the project.



These are central roadmap blockers.



---



# B. Definition of Done



## B.1 The single indispensable gameplay loop



```

NEW COMPANY

     ↓

CREATE BANNER / CHOOSE COMPANY NAME

     ↓

ENTER CAMPAIGN WORLD

     ↓

VISIT SETTLEMENT

     ↓

RECRUIT AND PREPARE SOLDIERS

     ↓

TRAVEL / ENCOUNTER ENEMY

     ↓

DEPLOY FORMATIONS

     ↓

COMMAND A TACTICAL BATTLE

     ↓

WIN / LOSE / RETREAT

     ↓

APPLY CASUALTIES, REWARDS AND PROGRESSION

     ↓

RETURN TO THE SAME CAMPAIGN

     ↓

SAVE → EXIT → RELOAD

     ↓

CONTINUE WITH THE SAME COMPANY

```



**This is the foundation of Project Banner.**



Every major development decision should be evaluated against whether it improves, stabilizes or meaningfully expands this loop.



## B.2 First shippable target: Playable Alpha



The initial shippable target is a **self-contained single-player Windows alpha** suitable for external playtesting.



It is not a full commercial release.



### Minimum player-facing experience



A stranger can:



- Launch the game without an editor, debugger or developer instructions.

- Create a company, name it and select a banner.

- Understand the world map and move between useful locations.

- Recruit and manage a small army.

- Encounter hostile forces through normal play.

- Deploy and command several distinct formations.

- Zoom from individual soldiers to a readable battlefield overview.

- Use the intended GPU battle scene.

- Win, lose or retreat and understand the consequences.

- Obtain meaningful rewards and improve their company.

- Save, close the application, reload and continue playing.



### Minimum tactical content



- At least three mechanically distinct troop archetypes, including melee and ranged troops.

- A manageable encounter with multiple formations on each side.

- Hold, move and engage commands.

- Selection, group selection and understandable order feedback.

- Meaningful formation facing and frontage.

- At least one battlefield with tactically relevant terrain.

- Actual casualties and consistent results.

- A coherent presentation at close, medium and full-map zoom.



### Minimum campaign content



- A coherent playable starting region.

- Accessible settlement and recruitment systems.

- Hostile encounters with meaningful risk.

- An understandable money/recruitment/reward loop.

- Persistent soldiers, company state and enemy consequences.

- A reason to undertake another encounter after the first one.



### Minimum production quality



- No unavoidable progress blockers in the core loop.

- No known save corruption or silent loss of campaign data.

- No obvious placeholder/debug UI in ordinary gameplay.

- Readable controls and tooltips.

- Functional audio and visual feedback for major actions.

- All included assets cleared for distribution.

- Stable performance on the explicitly agreed target hardware.

- An external tester can complete the full loop without developer intervention.



**A feature is not done because code exists. It is done when a player can use it and its acceptance evidence is recorded.**



## B.3 Commercial-release definition



A paid release requires additional standards beyond the first playable alpha:



- Sufficient replayability and content variety to justify the price.

- Visual consistency rather than mixed temporary assets.

- Credible encounter balance and progression.

- Settings, accessibility and basic quality-of-life features.

- Robust packaging, installation, crash handling and user support.

- Commercial licensing compliance.

- Independent playtest feedback and defect resolution.

- A release plan, storefront assets and clear communication of feature scope.



Commercial-release timing must be based on demonstrated quality and player interest, not a predetermined date.



## B.4 Explicitly outside the first alpha



The following are not required for the first playable release:



- Full kingdom management.

- Diplomacy and political simulation.

- Castle sieges.

- Multiplayer.

- Naval warfare.

- Massive procedural faction economies.

- Extensive cavalry systems.

- Hundreds of recruitable character classes.

- Thousands of soldiers in an ordinary player encounter.

- Cinematic animation quality matching modern 3D Total War games.



These may be worthwhile later, but they must not prevent the first complete game from existing.



---



# C. Ordered Development Roadmap



## Milestone 00 — Approve Scope and Freeze the Baseline



**Status:** DONE — Jay approved 2026-10-08 (D-170)\

**Priority:** Critical\

**Type:** Documentation, design\

**Release gate:** BLOCKING\

**Dependencies:** Jay's approval



### Deliverables



- Approve or revise this roadmap.

- Confirm that the GPU battlefield is the production target.

- Approve the first-alpha feature boundaries.

- Confirm the initial target platform and display resolutions.

- Preserve the previous roadmap as historical documentation.

- Define acceptance-report formatting and branch rules.

- Record important design decisions in `docs/DECISIONS.md`.



### Acceptance checks



- Jay explicitly approves the roadmap.

- Scope exclusions are acknowledged.

- Target platform and intended test machine are recorded.

- Existing unfinished work is declared protected.

- Development remains paused until this approval is complete.



### Dependency note



This milestone authorizes the others. No implementation begins before it.



### Jay's decision required



Approve the initial scope, release target and technical direction.



---



## Milestone 01 — Reproducible Baseline and Repository Protection



**Status:** IN PROGRESS — working tree snapshot pushed as backup/jay-tree-2026-10-08\

**Priority:** Critical\

**Type:** Tooling, testing, documentation\

**Release gate:** BLOCKING\

**Dependencies:** M00



### Deliverables



- Record main branch and all development branch heads.

- Inventory the protected dirty working tree.

- Capture the uncommitted LOD patch without changing its contents.

- Establish an isolated Git worktree for Hermes validation.

- Establish repeatable headless and windowed verification commands.

- Produce an accurate baseline test report.

- Confirm that the machine remains usable during local testing.



### Acceptance checks



- Full headless suite run on clean main with raw logs.

- Suite count, assertions, failures and exit code recorded.

- Two-process restart test executed.

- Windowed launch smoke test executed.

- Local dirty files verified unchanged.

- Test output identifies branch, full commit SHA, Godot version and renderer.

- A local verification failure is never reported as a passing change.



### Dependency note



All subsequent verification relies on an honest baseline.



### Operational restriction



GPU/windowed tests must be coordinated with Jay. Heavy rendering, benchmark and stress tests must not monopolize his desktop during normal use.



---



## Milestone 02 — Reconcile the Unreviewed Battle Feature Branch



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code integration, tests, documentation\

**Release gate:** BLOCKING\

**Dependencies:** M01



### Objective



Convert the approximately 88-commit experimental development lineage into small, understandable, testable integration slices.



### Proposed extraction order



**Slice A — Formation-command foundation**



Use `gpt6/formation-command-foundation-v1` as the starting candidate, subject to Hermes' verification and any necessary corrections.



Contains pure navigation, placement and cohesion logic.



**Slice B — Standalone battle UI**



Command bar, unit dock, minimap, tactical overview and deployment overlay, with isolated UI tests.



**Slice C — Terrain presentation**



Ground painter, terrain visuals and scenery, without GPU collision logic changes.



**Slice D — GPU terrain collision**



Terrain-mask serialization, compute shader bindings and associated collision behaviour.



**Slice E — Live GPU battlefield integration**



Controller wiring, selection, orders, camera transitions and UI lifecycle.



**Slice F — Documentation and remaining tests**



Reconcile manuals, feature matrices and integration tests after the actual functionality is verified.



### Acceptance checks



- Complete file and dependency map of the feature lineage.

- Original experimental branches preserved.

- No whole-branch blind merge.

- Each slice builds independently against its declared prerequisites.

- Tests associated with each slice are registered and executed.

- All new standalone files are checked for unused or duplicate implementations.

- Shared-controller changes are reviewed by functional hunk.

- No unexpected simulation or shader changes in presentation-only slices.

- Every proposed merge receives independent Hermes execution, GPT-6 code review and Jay approval.

- GitHub main passes the regression gate after each accepted integration.



### Dependency note



This milestone produces a trustworthy integration base. Later features must not rely on unreconciled experimental code.



### Special risks



`gpu_crowd.gd` is a major integration hotspot. Large changes to it cannot be reviewed as an indivisible feature.



---



## Milestone 03 — Resolve CPU/GPU Architecture and Feature Parity



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Architecture, code, tests, documentation\

**Release gate:** BLOCKING\

**Dependencies:** M02



### Objective



Define exactly which combat rules and outcomes the GPU battlefield must reproduce.



### Deliverables



A verified comparison matrix covering:



- Soldier identity and persistence.

- Formation identity and membership.

- Movement and path orders.

- Target acquisition.

- Hit chance and damage.

- Attack cooldown and range.

- Death and casualty recording.

- Formation cohesion and behaviour.

- Terrain movement and collision.

- Battle termination.

- Victory, defeat and retreat.

- Reward and persistence semantics.

- Random-seed behaviour and determinism.



Each row must identify the current CPU rule, GPU behaviour, source files, test evidence and required action.



### Acceptance checks



- Every player-visible combat contract classified as matching, intentionally different, missing or unverified.

- No assumption that the two engines share implementation semantics.

- Gameplay differences explicitly approved or corrected.

- Both engines tested against shared reference scenarios where applicable.

- CPU reference remains runnable.

- Documentation updated to distinguish live GPU gameplay from CPU reference tests.



### Dependency note



Gameplay correctness cannot be measured reliably until there is an agreed contract.



### Architecture decision



The GPU system becomes the only intended production battlefield. The CPU implementation remains a validation oracle until its useful contracts are covered elsewhere.



---



## Milestone 04 — Real GPU Campaign Battle Harness



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code, testing, tooling\

**Release gate:** BLOCKING\

**Dependencies:** M02–M03



### Objective



Build an executable integration test of the actual campaign battle path.



### Deliverables



A deterministic test scenario covering:



`world_map → battle_field → battle resolution → world_map`



It must exercise the real `BattleContext`, real campaign adapter and real GPU battlefield, not substitute the CPU scene.



Because the compute scene requires a functioning rendering device, the GPU-specific test must run in a real rendering environment.



Headless tests continue to cover non-GPU contracts.



### Acceptance checks



- Actual campaign-generated battle context reaches `battle_field`.

- Soldier IDs, sides, quantities and attributes are preserved.

- GPU simulation starts and advances.

- Player-issued orders affect the intended formations.

- Battle reaches a defined outcome or supported retreat.

- Outcome returns to campaign state.

- No duplicate result application.

- No shader compilation or descriptor errors.

- Raw log and run configuration attached.

- Test repeatable without manual reconstruction of the scenario.



### Dependency note



This becomes the primary foundation for future gameplay verification.



---



## Milestone 05 — Reliable Formation Movement and Commands



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code, tests\

**Release gate:** BLOCKING\

**Dependencies:** M03–M04



### Objective



Make directing formations reliable, predictable and understandable.



### Deliverables



- Select one or several formations.

- Order movement to legal positions.

- Preserve relative formation spacing when moving groups.

- Allow frontage changes without merging formations.

- Retain meaningful facing.

- Reject impossible movement instead of silently accepting standing still.

- Prevent illegal pathing through obstacles.

- Preserve valid queued orders after rejected requests.



### Acceptance checks



- Single-formation movement works.

- Multi-formation movement preserves independent identities.

- A wide formation cannot pass through an undersized route.

- An impossible move produces visible refusal feedback.

- Rejection preserves existing route, cursor, width, facing and order.

- Formation membership and positions remain valid after casualties.

- No teleportation, stacking or silently compressed placement.

- Equivalent seed/order sequences remain deterministic.

- Full relevant regression passes.



### Dependency note



Advanced camera and UI work is not useful if orders do not behave reliably.



---



## Milestone 06 — Combat Reliability and Resolution



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code, tests\

**Release gate:** BLOCKING\

**Dependencies:** M03–M05



### Objective



Prove that battles fight, progress and finish correctly.



### Deliverables



- Correct attack targeting and target replacement.

- Appropriate melee and ranged attack timing.

- Consistent health, damage and death.

- Formation engagement and disengagement.

- Predictable stop/arrival behaviour.

- Victory, defeat, withdrawal and timeout rules.

- Reliable battle termination and result generation.



### Acceptance checks



- Melee and ranged combat produce valid outcomes.

- Combat animation events correspond to actual simulation events.

- Destroyed formations cease issuing movement or combat effects.

- Living units can reacquire valid opponents.

- Battle does not freeze permanently when surviving forces can still engage.

- Victory, defeat and retreat scenarios have explicit tests.

- Same seed and identical input timeline reproduce authoritative tick results.

- Results contain the correct persistent soldier IDs and casualties.

- No battle continues mutating state after resolution.



### Dependency note



The result and persistence pipeline requires trustworthy combat outcomes.



---



## Milestone 07 — Terrain Collision and Battlefield Legality



**Status:** NOT STARTED\

**Priority:** High\

**Type:** Code, tests, tooling\

**Release gate:** BLOCKING\

**Dependencies:** M04–M06



### Objective



Make the battlefield's gameplay terrain agree with what soldiers can traverse.



### Deliverables



- Verified GPU terrain-mask handling.

- Correct use of static obstacles.

- Terrain-aware formation anchor routing.

- Collision during normal movement and separation.

- Legal deployment positions.

- Usable obstacle and elevation presentation.



### Acceptance checks



- GPU shader's expected terrain binding compiles and executes.

- Traversable and blocked cells match the authoritative terrain data.

- Soldiers cannot move through tested blocked terrain during regular movement.

- Separation iterations cannot push soldiers through tested walls.

- Diagonal corners and narrow gaps checked.

- Wide and narrow formation pathing differ appropriately.

- No soldiers spawn inside impassable terrain.

- Same seeds produce equivalent terrain and legal deployment.

- Performance impact of collision support measured.

- Known local-steering limitations documented rather than concealed.



### Dependency note



Terrain must be mechanically correct before its artwork is considered finished.



---



## Milestone 08 — Camera, Strategic Zoom and Formation Readability



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code, art/presentation, tests\

**Release gate:** BLOCKING\

**Dependencies:** M04–M07



### Objective



Deliver the player-facing scale transition that is central to Project Banner's identity.



### Deliverables



- Close zoom: readable individual soldiers.

- Middle zoom: recognizable formations and order context.

- Far zoom: clear tactical formation rectangles or footprints.

- Consistent facing, strength and ownership information.

- Selection and issuing orders at every supported command scale.

- Smooth camera pan, zoom and field framing.



### Acceptance checks



- CPU LOD patch separately reviewed and tested.

- Live GPU zoom behaviour tested in its own camera scale.

- Soldier/formation representations do not duplicate or disappear at thresholds.

- Formations remain selectable and orderable at minimum zoom.

- Friendly and enemy units visually distinguishable.

- Casualties and rotation update overview graphics correctly.

- No stale formation rectangles after movement, death or reforming.

- No visually empty transition frames.

- No simulation change from zooming.

- Screenshots captured at all required scales.

- Dense overlapping formations evaluated for selectable hit regions.

- Frame costs compared using the same battle and hardware.



### Required technical comparison



CPU strategic LOD thresholds currently include 6.0, 1.5 and 0.6 with a 0.4 minimum camera zoom.



The GPU camera currently has separate tactical-overview thresholds around 1.65 and 0.52.



These are separate systems and must be evaluated independently before deciding whether their behaviours should converge.



### Dependency note



This is an essential differentiating feature, not optional visual polish.



### Jay's decision required



Approve the final visual hierarchy at close, middle and whole-battlefield zoom.



---



## Milestone 09 — Battle HUD, Deployment and Order Feedback



**Status:** NOT STARTED\

**Priority:** High\

**Type:** Code, UI art, tests\

**Release gate:** BLOCKING\

**Dependencies:** M05 and M08



### Objective



Make the battlefield usable without knowing its implementation.



### Deliverables



- Clear deployment interface.

- Selection highlights and readable formation cards.

- Order command strip.

- Current stance and unit strength.

- Battle state, pause and resume indicators.

- Navigable minimap.

- Movement destination and frontage previews.

- Meaningful feedback for refused orders.



### Acceptance checks



- Each command invokes the correct action once.

- Cards show actual living troops.

- Eliminated or absent formations do not leave misleading interactive cards.

- Selected formation remains correctly highlighted.

- Minimap navigation does not accidentally issue orders.

- Deployment and combat controls cannot be confused.

- HUD does not conceal important battlefield regions.

- 1280×720, 1920×1080 and ultrawide layout checks completed.

- Ordinary gameplay hides developer diagnostics.

- A new player can identify selected troops, their current stance and their destination.



### Dependency note



Commands and battlefield representations must stabilize before their user interface is polished.



---



## Milestone 10 — Persistent Battle Consequences



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code, tests, tooling\

**Release gate:** BLOCKING\

**Dependencies:** M04 and M06



### Objective



Ensure that the actual GPU battlefield produces persistent, correct campaign consequences.



### Deliverables



- Casualty and survivor transfer.

- Experience and reward application.

- Persistent enemy damage and losses.

- Victory, defeat and retreat semantics.

- Save/load after battle.

- Save compatibility and corruption handling.



### Acceptance checks



- Real GPU battle result changes the correct campaign.

- Soldier health and death persist accurately.

- No reward or XP applied more than once.

- Retreat does not generate unintended victory rewards.

- Surviving enemies preserve their actual condition.

- Save, exit process, relaunch and Continue restore exact tested state.

- Re-saving loaded state remains stable.

- Corrupt or incompatible saves fail safely without overwriting good saves.

- Existing persistence regression suites remain green.



### Dependency note



This is the milestone that turns a battlefield into part of a continuing strategy game.



---



## Milestone 11 — Minimum Meaningful Campaign Progression



**Status:** NOT STARTED\

**Priority:** High\

**Type:** Code, content, design, tests\

**Release gate:** BLOCKING\

**Dependencies:** M10



### Objective



Make another battle feel worthwhile.



### Deliverables



A minimal sustainable company loop:



- Recruit troops.

- Spend money to expand or maintain the company.

- Travel to meaningful encounters.

- Win rewards or suffer losses.

- Improve surviving soldiers or company capability.

- Make an informed decision about what to do next.



Implement only the minimum additional progression functionality that the existing systems cannot already provide.



### Acceptance checks



- Gold income and expenditure are understandable.

- Recruitment and rewards have visible consequences.

- Soldier improvement provides a meaningful gameplay benefit.

- Losses create pressure without making ordinary play routinely unrecoverable.

- There is a useful next objective after the first successful battle.

- Campaign cannot trivially generate unlimited resources through repeatable exploits.

- Multiple starting seeds provide a viable first encounter.

- At least one repeated campaign loop works across successive battles.



### Dependency note



A stable battle does not become an engaging game until it supports a reason to continue.



### Jay's decision required



Approve the intended difficulty, permadeath severity and initial progression philosophy.



---



## Milestone 12 — Minimum Visual Content and Art Direction



**Status:** NOT STARTED\

**Priority:** High\

**Type:** Art, content, tooling\

**Release gate:** BLOCKING for minimum quality\

**Dependencies:** M07–M09



### Objective



Give Project Banner one coherent, believable visual identity.



### Deliverables



- One visually complete battlefield environment.

- Consistent terrain tiles, roads and obstacle assets.

- Readable medieval soldiers with class-specific silhouettes.

- Coherent banners and faction colours.

- Formation standards and strength indicators.

- Consistent HUD palette, fonts, borders and icons.

- Correct animation orientation and transparent assets.



### Acceptance checks



- No obvious debug terrain cells in normal gameplay.

- Ground tiles blend without conspicuous seams.

- Unit types distinguishable at practical viewing distances.

- All sprites have correct orientation, anchors and rendering order.

- Visible effects correspond to actual gameplay events.

- Selected and enemy formations remain readable against the ground.

- Artwork is consistent in perspective, shading and material style.

- Asset source files and exported atlases can be rebuilt reproducibly.

- Every included asset has recorded licensing status.

- Jay approves representative screenshots before mass production of related assets.



### Scope limitation



Do not attempt hundreds of animations or six completely different biomes before completing one polished battle environment.



Do not enlarge low-resolution raster artwork and treat it as newly detailed art.



### Dependency note



Visual polish follows mechanical correctness, but essential readability is a requirement from the beginning.



### Jay's decision required



Approve the final medieval pixel-art reference standard and representative combat visuals.



---



## Milestone 13 — Audio and Combat Feedback



**Status:** NOT STARTED\

**Priority:** Medium\

**Type:** Audio, code, content\

**Release gate:** BLOCKING for minimum feedback; advanced audio optional\

**Dependencies:** M06, M09, M12



### Objective



Make gameplay actions understandable through sound and visual response.



### Deliverables



- Selection and order acknowledgment sounds.

- Soldier footsteps and movement ambience.

- Weapon impact, misses and ranged attack sounds.

- Basic combat ambience.

- Victory and defeat feedback.

- Volume settings and mute controls.

- Safe sound-event handling during large battles.



### Acceptance checks



- Audio triggered by authoritative events rather than unrelated cosmetic timers.

- No missed-action sound implies a successful hit.

- Mass combat does not produce excessive overlapping audio.

- Audio does not cause noticeable frame instability.

- Settings persist after restart.

- Missing optional sounds fail gracefully.

- All sound assets licensed for intended distribution.

- Jay approves the sound palette and intensity.



### Dependency note



Audio must follow established gameplay events, not define combat behaviour.



### Scope limitation



Procedurally generated or AI-created sound effects must be auditioned and approved before integration.



---



## Milestone 14 — Performance, Stability and Determinism



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Code, testing, tooling\

**Release gate:** BLOCKING\

**Dependencies:** M04–M13



### Objective



Deliver stable, responsive gameplay rather than impressive isolated benchmark figures.



### Deliverables



- Repeatable production battle benchmarks.

- Per-system simulation and render measurements.

- Memory usage and resource-lifecycle checks.

- Large army stability checks.

- Performance comparison across camera scales.

- Reliable battle clock and deterministic state checks.

- Graphics settings where needed for supported hardware.



### Proposed performance acceptance targets



These are **provisional design targets, not achieved benchmarks**.



For the first agreed test hardware configuration:



- Target smooth 60 FPS presentation in ordinary small-to-medium battles.

- Aim for median frame time at or below 16.7 ms.

- Aim for p95 frame time at or below 33.3 ms during active representative combat.

- No persistent gameplay freezes.

- No sustained simulation backlog.

- No accumulating resources or unbounded memory growth.

- No frame-rate-dependent changes to authoritative combat results.



If the baseline shows these targets are unrealistic, document actual results and ask Jay to approve a revised target rather than claiming success.



### Acceptance checks



- Machine, GPU, driver and rendering backend recorded.

- Fixed scenario and seed used across comparisons.

- Small, medium and stress scenarios measured.

- Median and p95 frame timings recorded.

- Simulation ticks/sec measured separately from rendered FPS.

- Repeatability checked across relevant frame caps.

- No unexplained visual regression after optimization.

- No memory growth across repeated scene transitions.

- Real campaign battlefield tested, not only the standalone stress probe.



### Dependency note



Final performance optimization follows representative gameplay implementation. Major regressions discovered earlier remain immediate blockers.



---



## Milestone 15 — Release-Focused UX and Quality Assurance



**Status:** NOT STARTED\

**Priority:** High\

**Type:** Code, UI, testing, documentation\

**Release gate:** BLOCKING\

**Dependencies:** M10–M14



### Objective



Make the game understandable and resilient for a player with no development knowledge.



### Deliverables



- Clear new-game flow.

- Helpful controls and tooltips.

- Readable information hierarchy.

- Accessible settings and predictable input behaviour.

- Pause, resume and exit handling.

- Graceful failure when resources or saves are unavailable.

- Clear victory, loss and next-step feedback.

- A concise player-controls reference.



### Acceptance checks



- New player can navigate without developer console access.

- Essential actions visible or discoverable.

- No unexplained nonfunctional controls.

- Quit/Continue behaviour predictable.

- Window resize does not destroy input usability.

- Save errors and invalid actions produce comprehensible messages.

- Keyboard/mouse controls do not conflict.

- Known crashes and progression blockers triaged and addressed.

- Fresh-install smoke test passes.



### Dependency note



This hardening milestone happens after the core systems are functionally complete, but usability defects found earlier should be logged immediately.



---



## Milestone 16 — Licensing, Packaging and Build Reproducibility



**Status:** NOT STARTED\

**Priority:** High\

**Type:** Tooling, documentation, content\

**Release gate:** BLOCKING\

**Dependencies:** M12–M15



### Objective



Create a legitimate, portable build that can safely be distributed to testers.



### Deliverables



- Commercial asset provenance manifest.

- Licenses and attribution documentation.

- Reproducible asset import pipeline.

- Windows export configuration.

- Clear build/version identifiers.

- Clean-install instructions.

- Separate user data and test data.

- Basic crash/error-log collection strategy.



### Acceptance checks



- Every third-party asset has a documented origin and permitted use.

- Restricted source assets are not redistributed improperly.

- No API keys, user credentials or private files in the build.

- Fresh exported build launches outside the editor.

- No dependency on absolute paths from Jay's machine.

- Build can be recreated from repository state and permitted asset inputs.

- Save files remain separate from executable data.

- Build includes version and diagnostic information.



### Dependency note



A project that works inside the developer's editor is not necessarily distributable.



### Jay's decision required



Approve the first platform and distribution channel.



---



## Milestone 17 — First Stranger Playtest



**Status:** NOT STARTED\

**Priority:** Critical\

**Type:** Testing, design, content\

**Release gate:** BLOCKING\

**Dependencies:** M00–M16



### Objective



Prove that Project Banner is actually playable and understandable without Jay or Hermes explaining it.



### Procedure



Provide an exported build to one or more external testers who have not been involved in development.



Observe normal use and record errors, confusion and engagement.



### Acceptance checks



- Tester launches without developer assistance.

- Tester creates a company.

- Tester recruits troops and enters a real campaign encounter.

- Tester deploys and commands formations.

- Tester understands win/loss outcome and consequences.

- Tester returns to campaign and finds another useful objective.

- Tester saves and continues after a process restart.

- No critical progression blocker encountered.

- Confusing controls and unused features documented.

- Tester feedback identifies whether the core loop is enjoyable.



### Qualitative evaluation



Ask what was fun, confusing, frustrating or unrewarding.



Do not substitute test counts, screenshots or performance statistics for actual player feedback.



### Dependency note



This is the first meaningful confirmation that the engineering has produced a real game.



### Jay's decision required



Approve testers, distribution and the level of polish appropriate for the alpha.



---



## Milestone 18 — Public Demo or Early-Access Release Gate



**Status:** NOT STARTED\

**Priority:** Future\

**Type:** Code, content, art, audio, testing, documentation\

**Release gate:** BLOCKING for public/commercial release\

**Dependencies:** M17 and Jay's release authorization



### Objective



Convert the validated alpha into a public-facing product.



### Deliverables



- Additional replayable encounters and content diversity.

- Balance and progression improvements based on tester feedback.

- Stable release build.

- Finished minimum marketing presentation.

- Store description accurately reflecting implemented features.

- Screenshots and trailer captured from actual gameplay.

- Release notes, known limitations and player support workflow.

- Clearly documented save compatibility policy.



### Acceptance checks



- All release-critical playtest defects resolved.

- No known data-loss defects.

- Release build tested on a clean installation.

- Store claims backed by actual features.

- All shipped content approved and licensed.

- External feedback confirms the core experience is worthwhile.

- Jay explicitly authorizes release.



### Dependency note



Shipping is a product decision, not the automatic result of completing the code roadmap.



---



# D. Post-Alpha Expansion Roadmap



These milestones are **optional for the first playable alpha**. Their ordering is provisional and must respond to player feedback.



## Milestone 19 — Soldier Identity and Equipment



**Type:** Code, content, art\

**Release gate:** OPTIONAL\

**Dependencies:** M10–M17



### Deliverables



Equipment slots, visible gear changes, soldier specialties, traits, upgrades and stronger individual identity.



### Acceptance checks



- Equipment has consistent mechanical effects.

- Visuals correctly represent equipped gear where promised.

- Equipment and progression survive save/reload.

- Balance tests prevent trivial dominant loadouts.



### Jay's decision required



Choose how deep soldier customization should become.



---



## Milestone 20 — Tactical Depth and Battlefield Variety



**Type:** Code, content, art, audio\

**Release gate:** OPTIONAL\

**Dependencies:** M06–M17



### Deliverables



More formation types, tactical stances, morale, fatigue, cavalry, weather effects, tactical AI improvements and battlefield variants.



### Acceptance checks



- Each added mechanic produces a meaningful decision.

- No silent conflict with existing simulation rules.

- Distinct enemy strategies demonstrated.

- New maps remain navigable and performant.

- Existing encounters remain balanced and completable.



---



## Milestone 21 — Living Campaign World



**Type:** Code, design, content\

**Release gate:** OPTIONAL\

**Dependencies:** M11, M17



### Deliverables



Dynamic factions, richer settlements, trade, roaming forces, contracts, relationships and evolving world events.



### Acceptance checks



- World activities produce meaningful player decisions.

- NPC state is persistent and deterministic under declared rules.

- Campaign remains recoverable after normal setbacks.

- Systems do not cause runaway simulation costs.

- Long campaigns remain stable and saveable.



---



## Milestone 22 — Grand Strategy Expansion



**Type:** Code, content, UI, art\

**Release gate:** OPTIONAL\

**Dependencies:** M20–M21



### Deliverables



Territory control, diplomacy, political factions, castles, sieges, larger armies and expanded strategic systems.



### Acceptance checks



- Complete gameplay contracts and tests for each major system.

- Strategic decisions have measurable consequences.

- No unbounded complexity in economy or AI simulation.

- Interfaces remain usable at increasing scale.

- Large scenarios meet agreed performance targets.



**This milestone is not permission to expand into a full Total War clone before the core game succeeds.**



---



# E. Development Ownership and Verification



## E.1 GPT-6 — Technical lead



Responsibilities:



- Own implementation architecture.

- Write source code and automated tests.

- Review the relevant existing repository files before modifications.

- Design and implement coherent features.

- Create isolated branches and focused commits.

- Push changes to GitHub.

- Review Hermes' raw execution evidence.

- Diagnose failures and produce corrections.

- Maintain technical documentation and dependency decisions.

- Explain tradeoffs and raise scope decisions to Jay.



GPT-6 must not claim local execution success without corresponding evidence.



## E.2 Hermes — Local executor and independent verifier



Responsibilities:



- Fetch and check out GPT-6 branches in isolated worktrees.

- Run compiler/import checks and required test suites.

- Perform windowed GPU tests on Jay's hardware.

- Capture screenshots, traces and measurements.

- Inspect and challenge implementation behaviour.

- Identify unsupported claims and regressions.

- Report raw logs and an explicit verdict.

- Keep Jay's active working tree intact.

- Avoid declaring acceptance based solely on GPT-6's explanation.



Hermes may recommend fixes but does not silently rewrite the intended architecture.



The former Warden role is discontinued. Verification responsibility now rests with Hermes' independent execution, GPT-6's review and Jay's final integration authorization.



## E.3 Jay — Owner and game director



Responsibilities:



- Set the game's creative direction.

- Approve scope, priorities and acceptance criteria.

- Make final decisions about gameplay feel and visual quality.

- Decide which tradeoffs are acceptable.

- Authorize merges and release decisions.

- Play the game and identify problems automated tests cannot.

- Control access to the machine and test sessions.



Decisions that require Jay specifically include:



- Release scope and target platform.

- Art style and visual quality threshold.

- Gameplay difficulty and permadeath severity.

- Progression philosophy and pacing.

- Whether features belong in alpha or later.

- Hardware/performance tradeoffs.

- Whether a design feels enjoyable.

- Approval to merge or ship.



## E.4 One-change development protocol



A change follows this exact lifecycle:



**1. Plan** — GPT-6 identifies scope, dependencies, files and test requirements.



**2. Implement** — GPT-6 writes code on a clean, isolated branch.



**3. Commit** — GPT-6 provides branch, commit SHA, files and expected tests.



**4. Verify** — Hermes fetches into a temporary worktree and runs actual commands.



**5. Report** — Hermes returns raw pass/fail output, visual observations and failures.



**6. Review** — GPT-6 evaluates the evidence and either fixes defects or recommends acceptance.



**7. Approve** — Jay authorizes merge.



**8. Integrate** — Changes are merged only after approval and required regression gates.



**9. Document** — Roadmap and current-state documentation record the accepted milestone and evidence.



At any failure, the change returns to implementation rather than quietly advancing.



### Standard verification report



```

[PB-RESULT]



Milestone:

Branch:

Base commit:

Head commit:

Files changed:

Godot version:

GPU/renderer:

Commands executed:

Suites run:

Assertions passed:

Assertions failed:

Process exit code:

Windowed observations:

Screenshots/log references:

Regressions:

Known limitations:

Verdict: PASS / FAIL / BLOCKED

```



The PASS verdict must explicitly state which checks actually ran.



## E.5 Desktop-machine policy



Jay has one primary development computer.



The project must not make it impractical for him to use his machine.



Rules:



- Work in isolated worktrees.

- Avoid expensive concurrent benchmarks.

- Coordinate windowed GPU tests with Jay.

- Use capped workloads during normal development.

- Do not automatically switch windows, close applications or take keyboard/mouse control without permission.

- Keep heavy asset generation separate from active gameplay testing.

- Never delete or reset uncommitted work without explicit consent.

- Record test duration and system resource pressure where relevant.



---



# F. Risks and Reality



## F.1 Technical risk register



| Risk                      | Early warning                                            | Mitigation                                                 |

| ------------------------- | -------------------------------------------------------- | ---------------------------------------------------------- |

| CPU/GPU divergence        | Same battle behaves differently across engines           | Shared rule matrix and paired scenarios                    |

| Feature-branch sprawl     | Large diffs, unclear dependencies, repeated conflicts    | Small main-based integration slices                        |

| GPU shader defects        | Vulkan errors, incorrect state, visual glitches          | Real-device testing and reference checks                   |

| Non-deterministic combat  | Divergent tick checksums with identical inputs           | Fixed-tick tests and divergence tracing                    |

| Broken formation orders   | Stacking, teleporting, impossible paths accepted         | Isolated planners, movement contracts, integration tests   |

| Renderer LOD failures     | Duplicate units, missing groups, unselectable rectangles | Threshold tests and windowed captures                      |

| Fake test confidence      | Headless green while player path fails                   | Separate GPU campaign end-to-end acceptance                |

| Save corruption           | Missing soldiers, repeated rewards, invalid old saves    | Two-process persistence testing                            |

| Performance regression    | Frame spikes, simulation backlog, memory growth          | Reproducible benchmarks and resource monitoring            |

| Asset/license issues      | Unclear commercial permission or missing sources         | Provenance manifest and approved replacements              |

| Art-scope explosion       | Endless iterations without playable build                | Representative assets first, visual signoff before scaling |

| Integration conflicts     | Dirty-tree overlap with proposed merges                  | Isolated worktrees, protected local changes                |

| Single-machine bottleneck | Tests disrupt Jay's normal computer use                  | Scheduling and lightweight verification first              |

| Scope creep               | More systems added before current loop is playable       | Strict blocking/optional milestone separation              |

| Weak player experience    | Many features but little reason to continue              | Early external playtests and progression evaluation        |



## F.2 Risks outside our control



- Availability and stability of Godot, GPU drivers and supporting tooling.

- Hardware-specific Vulkan and rendering issues.

- Third-party asset and software license terms.

- External AI asset-generation consistency and output quality.

- GitHub and CI service availability.

- Commercial distribution platform requirements.

- Player interest, community reception and market conditions.



Do not design critical gameplay to depend on a continuously available AI service.



The shipped game must function independently of GPT-6, Hermes and external model APIs.



## F.3 What could stall the project



**1. Building too many systems before integrating them.**\

Solution: Stop treating a feature branch as proof of gameplay progress. Integrate accepted slices.



**2. Repeatedly replacing presentation without accepting a target.**\

Solution: Approve representative screenshots and a minimum visual standard before broad art production.



**3. Pursuing massive battles prematurely.**\

Solution: Prove ordinary army-size gameplay first. Larger battles become a scaling problem, not an initial requirement.



**4. Improving the CPU implementation while the game uses GPU combat.**\

Solution: Treat CPU work as reference or shared-contract work unless specifically justified.



**5. Mistaking technical sophistication for fun.**\

Solution: Measure player decisions, feedback, progression and repeat play.



**6. Letting test infrastructure grow faster than playable content.**\

Solution: Every hardening task must protect a defined player-facing contract or a necessary engineering invariant.



**7. Failing to protect Jay's machine and source work.**\

Solution: Isolated worktrees, no blind resets, no unauthorized merges, controlled local tests.



## F.4 How progress will be measured



Track three different categories.



### Functional progress



- Completed player-facing actions.

- Number of accepted gameplay loops.

- Successful campaign-to-battle-to-campaign runs.

- Successful independent save/restart runs.

- Number of unresolved blocking defects.



### Engineering reliability



- Test suites and assertion counts per commit.

- Pass/fail trends.

- Determinism checks.

- Windowed GPU verification.

- Frame times and memory usage.

- Crash and resource-leak trends.



### Product quality



- New-player understanding.

- Combat readability.

- Command reliability.

- Perceived enjoyment.

- Progression clarity.

- Replay interest.

- Visual and audio consistency.



None of these categories replaces the others.



---



# G. Dependency Map and Release Gates



## G.1 Critical sequence



```

M00  Approve roadmap and scope

  ↓

M01  Establish baseline and protect work

  ↓

M02  Reconcile unreviewed feature branch

  ↓

M03  Define CPU/GPU gameplay contracts

  ↓

M04  Verify real GPU campaign battle

  ↓

M05  Reliable formation commands

  ↓

M06  Reliable combat and outcomes

  ↓

M07  Terrain collision correctness

  ↓

M08  Camera, LOD and strategic readability

  ↓

M09  Battle HUD and controls

  ↓

M10  Persistent battle consequences

  ↓

M11  Sustainable campaign progression

  ↓

M12  Minimum approved art

  ↓

M13  Gameplay audio feedback

  ↓

M14  Performance and stability

  ↓

M15  Usability and release QA

  ↓

M16  Licensing and export build

  ↓

M17  First independent playtest

  ↓

FIRST PLAYABLE ALPHA ACCEPTED

  ↓

M18  Public demo / release preparation

  ↓

OPTIONAL EXPANSIONS M19–M22

```



This is the primary acceptance order, not a requirement that every safe, independent art or documentation task wait until the prior milestone is fully complete.



Parallel preparation is allowed only when:



- It does not risk shared implementation conflicts.

- It does not distract from unresolved critical blockers.

- Its outputs are clearly labelled unaccepted until integrated.

- Jay approves the scope.



## G.2 Milestone summary



| ID  | Milestone                      | Alpha gate | Primary category  |

| --- | ------------------------------ | ---------- | ----------------- |

| M00 | Approve scope                  | Blocking   | Design/docs       |

| M01 | Baseline and repository safety | Blocking   | Tooling/tests     |

| M02 | Branch reconciliation          | Blocking   | Code/tests        |

| M03 | CPU/GPU architecture           | Blocking   | Architecture      |

| M04 | Live GPU end-to-end harness    | Blocking   | Code/tests        |

| M05 | Formation orders               | Blocking   | Code/tests        |

| M06 | Combat reliability             | Blocking   | Code/tests        |

| M07 | Terrain legality               | Blocking   | Code/tests        |

| M08 | Strategic zoom and selection   | Blocking   | Code/presentation |

| M09 | Battle UI                      | Blocking   | UI/code           |

| M10 | Battle persistence             | Blocking   | Code/tests        |

| M11 | Campaign progression           | Blocking   | Code/content      |

| M12 | Minimum visual identity        | Blocking   | Art/content       |

| M13 | Minimum audio feedback         | Blocking   | Audio/code        |

| M14 | Performance and determinism    | Blocking   | QA/tooling        |

| M15 | UX and stability               | Blocking   | UI/QA             |

| M16 | Licenses and packaging         | Blocking   | Tooling/docs      |

| M17 | Stranger playtest              | Blocking   | Product QA        |

| M18 | Public/commercial release      | Later gate | Product           |

| M19 | Soldier/equipment depth        | Optional   | Code/content      |

| M20 | Expanded tactical systems      | Optional   | Code/content      |

| M21 | Living campaign world          | Optional   | Code/content      |

| M22 | Grand strategy systems         | Optional   | Code/content      |



## G.3 Completion criteria for the first major new checkpoint



Declare **PROJECT BANNER — PLAYABLE ALPHA** only when:



- The production GPU battle path is tested and accepted.

- The complete campaign loop works in an exported build.

- Combat, orders, terrain and LOD function reliably.

- Results and saves survive a complete restart.

- The game has meaningful reasons to keep playing.

- Essential visuals and sounds are coherent.

- Performance meets the approved target.

- No critical progression or data-loss defects remain.

- Licensing requirements are met.

- An external tester completes the intended loop.

- Jay approves the result.



No screenshot, milestone report, test count or GitHub commit can substitute for these conditions.



---



# H. Immediate State After Roadmap Approval



The first development action, **only after Jay authorizes it**, is M01: establish the reproducible baseline and preserve the current local work.



Then M02 begins by independently testing the already-pushed formation-foundation commit.



Do not create a replacement implementation simply because the existing branch is inconvenient.



Do not merge the 88-commit feature lineage wholesale.



Do not abandon the unfinished LOD work.



Do not begin new large-scale gameplay features before the core battlefield is reliably integrated.



## Final project principle



**Project Banner advances when a real player-facing capability works, survives verification and improves the game—not when another impressive subsystem is written.**



The long-term vision remains ambitious: detailed medieval mercenary management, beautiful HD pixel-art battlefields and large-scale tactical command.



The immediate mission is narrower:



**Make one company, one campaign, one complete battle and one persistent consequence feel like a real game.**



Everything else builds from there.



---



**ROADMAP STATUS: DRAFT — AWAITING JAY'S APPROVAL**



**DEVELOPMENT STATUS: PAUSED**



**NEXT AUTHORIZED ACTION: None until Jay gives direction.**



Add a one-page approval summaryResolve the alpha scope contradictions