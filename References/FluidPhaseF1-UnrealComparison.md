# Project-Fluid vs Unreal Engine Niagara Fluids — an honest field-by-field comparison

Branch `arena/01a071a3-slate`, 2026-09-05, after F1.3 (`cdccdbe`). Companion to `FluidPhaseF1-RecentSurveyAndWebGpuPlan.md`.

**What is being compared.** *Ours* = `Projects/Project-Fluid`, a 2 500-line WebGPU prototype (PB-MPM default, explicit
MLS-MPM selectable, screen-space surface). *Unreal* = Niagara Fluids, the plugin that ships with UE 5.x: **3D FLIP** for
liquids, grid solvers for gas, shallow water for pools, plus the third-party alternatives people actually use in UE
(Zibra Liquids — an MLS-MPM plugin; Fluid Flux — shallow water). Unreal is a shipped engine with a decade of tooling; ours
is three days old. The table says where each genuinely stands **today**, not where we hope to be.

Legend 🥇 clear lead · 🥈 behind but close · 🥉 clearly behind · ➖ not applicable · 🧪 measured in the sandbox
(software GPU: correctness only, timings meaningless) · 📄 first-party documentation or peer-reviewed · 🗣️ practitioner
report (credible but not first-party)

---

## 1. Field by field

| Field | 🧊 Ours (Project-Fluid, F1.3) | 🎮 Unreal Niagara Fluids (UE 5.5–5.8) | Verdict |
|---|---|---|---|
| **Liquid solver** | PB-MPM (EA SEED, SIGGRAPH 2024) 🧪 + explicit MLS-MPM; k Jacobi iterations per sub-step, no pressure solve, no sound speed | 3D FLIP (PIC/FLIP blend) with an iterative Jacobi pressure solve on a grid 📄; "velocities are determined by a grid solver that ensures the fluid doesn't compress" [1] | 🥇 **ours on method** — PB-MPM is the newer algorithm (2024 vs FLIP 2005) and drops the pressure solve; **Unreal on maturity** |
| **Incompressibility** | Volume proof: mean J 0.983 at 2 iterations, 0.992 at 4 🧪; 2 % first-order drift, corrected by the lattice blend | Pressure iterations parameter — "more iterations = more accurate, slower" 📄 [2]; incompressible up to solver convergence | 🥈 **tie** — both are iteration-count knobs; ours is measured, Unreal's is not exposed as a number |
| **Speed / cost per particle** | 5 kernels × (sub-steps × iterations) per tick; 27 atomics per particle per transfer; at 64 cells PB-MPM needs 4×2 = 8 transfers vs explicit 12 | Not published by Epic. 🗣️ "a standard 3D FLIP sim consumes ~80 % of a laptop RTX 3080" [3]; 🗣️ SPH water 10 k particles 0.8 ms, 50 k 3.2 ms on PS5 (UE 5.7) [4] | ❓ **unknown until the GTX run** — the sandbox has no GPU; the `?perkernel=1` CSV is the missing number |
| **Particle budget (real time)** | 5.5 k → 1.4 M particles selectable (records + lattice 144 MB at 1.4 M); real-time ceiling on GTX unknown | 🗣️ 3D FLIP "mainly geared towards cinematic use for now, but doable" — Epic staff, 2022 [3]; UE 5.7 gameplay budgets quote 10–50 k SPH particles [4]; Zibra (MLS-MPM in UE) claims "hundreds of thousands on laptops, millions on high-end" [5] | 🥈 **likely comparable to Zibra, ahead of Niagara FLIP for pure particle throughput** — same algorithm family as Zibra; unproven on hardware |
| **Realism — water motion** | APIC transfers (angular momentum preserved), quadratic B-spline, settle within 2.5 % of the analytic height, slosh decays to 0.12 m/s RMS in 8 s 🧪 | FLIP with PIC blend 0.75–0.95 recommended [6]; vorticity confinement + three turbulence bands to add detail back 📄 [2] | 🥈 **Unreal** — FLIP at high resolution with turbulence detail wins on look; APIC has less numerical dissipation than PIC/FLIP blends but our resolution is lower |
| **Realism — surface rendering** | Screen-space: sphere impostors → narrow-range filter (Truong & Yuksel) → Fresnel / refraction / Beer–Lambert, half-res | 3D FLIP is "rendered by splatting particles into a grid, then rendering the grid as a surface using ray marching" 📄 [1] — volume-consistent, integrates with Lumen/material graph | 🥉 **Unreal** — ray-marched grid surface + full material system vs our fixed shading; no foam, no caustics yet |
| **Viscous fluids (honey, mud, slime, lava)** | ✅ `shear=0…1` per run: 1.0 turns the dam-break into an ooze (RMS 0.04 m/s at 1.5 s vs 1.03 for water) 🧪; MPM is the standard method for mud/snow/sand; elastic/plastic branches exist in the EA reference and slot into `ProjectVolume` | FLIP is an inviscid solver; the 3D Liquid template exposes **no viscosity** parameter 📄 [2]; viscosity in FLIP needs an extra implicit solve (Houdini has it, Niagara does not) | 🥇 **ours** — this is MPM's home turf; one uniform per material today, per-particle material tomorrow |
| **Granular / snow / sand / elastic goo** | 🔜 Not yet, but the same kernels: EA's elastic + visco branches are a per-particle F and an SVD in `ProjectVolume` | ❌ Not a Niagara Fluids feature (Chaos has separate cloth/destruction; no MPM) | 🥇 **ours (potential)** — nothing shipped yet, but the road exists; Unreal has no road |
| **Smoke / fire** | 🔜 F3: Leapfrog Flow Maps (SIGGRAPH 2025) port planned; nothing today | ✅ 2D/3D gas solvers with buoyancy, combustion, baked self-shadowing, ray-marched volumes 📄 [1][2]; 🗣️ 64³ smoke 1.8 ms, 128³ 5.5 ms on PS5 [4] | 🥉 **Unreal, decisively** — shipped and profiled; ours is a plan |
| **Large water bodies (rivers, ocean, lakes)** | ❌ Not in scope of this prototype (F0 plan: FFT + SWE + wave particles, unchanged) | ✅ Shallow Water template 📄 [1]; Water plugin; Fluid Flux (third party) does whole islands at 260–380 FPS on an RTX 3080 🗣️ [7] | 🥉 **Unreal** |
| **Collisions with the world** | 🔜 F1.4: kinematic Jolt-shaped collider (SDF), then two-way impulses; today: box walls only | ✅ Static meshes, skeletal meshes (Physics Asset DI), Geometry Collections, depth maps, landscape 📄 [1][6]; 🗣️ SDF updates once per frame → fast objects tunnel [4] | 🥉 **Unreal** — a full collider zoo vs a box |
| **Gameplay readback (buoyancy, "am I wet")** | Proof readback path exists (async `mapAsync`, ≥ 1 frame latency); nothing gameplay-shaped yet | ✅ Async readback to Blueprints/C++ with 1–2 frame latency 🗣️ [4]; "at least one frame delay … not 100 % reliable" (Fluid Flux) 🗣️ [7] | 🥈 **Unreal on tooling, tie on principle** — same async design, same latency |
| **Determinism** | ✅ Trace hash: identical bit pattern on repeated runs on the same GPU 🧪 (`82af79ca` PB-MPM, `07afb8ce` explicit); fixed-point P2G makes the atomics order-independent | ❌ "The simulation is not deterministic across hardware" 🗣️ [4]; float atomics in P2G are order-dependent | 🥇 **ours** — a real engineering difference, not a prototype artefact; same-hardware determinism is what a replay/lockstep game needs |
| **Self-proving / testability** | ✅ 5 proofs every 30 ticks (containment, mass 0.1 %, finite, volume, settle), exit code 0/2/1, CSV telemetry per kernel | 🗣️ "stat Niagara gives top-line numbers, but the breakdown inside a fluid simulation is hard to get at" [4] | 🥇 **ours** |
| **Adaptivity / LOD** | 🔜 F1.5: camera-distance particle LOD; nothing today | Scalability overrides per quality level 📄 [2]; grid resolution fixed per system; 🗣️ "LOD the simulations down to 2D planes at distance" [4] | 🥈 **tie at "not really"** — neither has spatial adaptivity; Unreal has quality presets |
| **Tooling / authoring** | ❌ A slider panel and a query string | ✅ Niagara editor, templates, modules, Summary View, Sequencer, MRQ baking, Blueprint bindings 📄 [1][2] | 🥉 **Unreal, by a mile** — this is what a decade buys |
| **Platform reach** | Chrome/Edge 113+, Firefox 141+, Safari 26 — Windows/macOS/Linux/Android via WebGPU; no console | Windows/console/Linux/macOS; 🗣️ "not usable on mobile … on PS5/XSX requires careful profiling" [8] | 🥈 **different** — we run in a browser tab (demo/experiment reach), Unreal runs on consoles |
| **Maturity** | 3 days, F1.3 of a ladder to F4 | Beta since UE 5.0 (2022) 📄 [1]; 🗣️ left experimental in 5.5, "genuinely shippable" by 5.7 [4]; other 2026 practitioners still call it "beta … inconsistent across platforms" [8] | 🥉 **Unreal** |
| **Extensibility / ownership** | ✅ 2 500 lines we fully own; every kernel readable; WGSL → Slang port planned for `Engine/` | ✅ Modules are editable HLSL for "R&D developers" 📄 [1], but inside Niagara's stack and data interfaces | 🥇 **ours** — for an engine team that wants to *own* the solver |

---

## 2. Scorecard

| | 🧊 Ours | 🎮 Unreal |
|---|---|---|
| 🥇 leads | solver method, viscous & granular materials, determinism, self-proving, ownership | surface rendering, smoke/fire, large water, colliders, tooling, maturity |
| 🥈 close | incompressibility, particle budget (vs Zibra), gameplay readback, adaptivity | realism of water motion (needs our resolution to go up) |
| ❓ unmeasured | **speed on the GTX** — the one number that decides everything else | — |

**Bottom line.** On the *algorithm* we are ahead of Niagara's FLIP (PB-MPM is the 2024 state of the art and it is the
method EA chose for their own engine); on *everything around the algorithm* — rendering, colliders, gas, tools — Unreal
is years ahead, as expected. The comparison that matters for the roadmap is not "ours vs Unreal" but "**MPM vs FLIP as
the engine's liquid core**": MPM gives water, honey, mud, snow and sand from one solver, FLIP gives water only. That is
why Unreal users who need more than water buy Zibra (MLS-MPM) — the same family we built.

---

## 3. "Is this only for liquid?" — what the solver can already do and what it cannot

MPM does not know it is simulating water; it simulates a continuum and the *constitutive model* decides the material.
In `ProjectVolume` the model is two lines:

```
D ← D − ShearRelaxation · sym(D)        (how much shear survives an iteration → viscosity)
D ← D + ω·α·I,  α = (1/J − 1 − tr D)/3  (volume preservation → pressure)
```

| Material | Today (`?shear=`) | Status | What is missing |
|---|---|---|---|
| 💧 Water | `shear=0.01` (default) | ✅ proven (settle + volume proofs) | — |
| 🍯 Honey / syrup / oil | `shear=0.3…1.0`, `iterations=3` | ✅ works 🧪 — the column oozes: RMS 0.04 m/s at 1.5 s vs 1.03 m/s for water; see `Figures/ProjectFluid_PbMpm_Viscous_*` | a per-particle material lane instead of one global uniform (the `Reserve` lane in the record is free for it) |
| 🟤 Mud / slime | `shear≈1`, lower `iterations` | ⚠️ visually plausible, physically hand-tuned | a yield stress (Bingham): flow only above a threshold — one `max()` in `ProjectVolume` |
| ❄️ Snow / sand / soil | — | 🔜 | per-particle deformation gradient F + SVD + Drucker–Prager or snow plasticity (EA's elastic/visco branch is the template, ~80 lines of WGSL) |
| 🧫 Elastic goo / jelly | — | 🔜 | same F + SVD path with EA's `elasticRelaxation` |
| 🌫️ Smoke / fire | — | 🔜 F3 | a different solver (grid + flow maps), not MPM |
| 🧵 Cloth | — | 🔜 F4 | VBD, not MPM |

Note the units: `shear` is a *per-iteration fraction*, not a viscosity in Pa·s. Mapping it to real viscosities (water
1 mPa·s, honey ≈ 10 Pa·s) needs the per-particle material lane and a calibration run — that is the first thing to do
when a second material is wanted in a scene.

---

## 4. Was the "adaptive fluid" research used?

Not yet — deliberately. The two Two-Minute-Papers candidates, Cirrus (adaptive hybrid particle-grid flow maps) and
Adaptive Phase-Field-FLIP (SIGGRAPH 2025), are *adaptivity* papers: they spend resolution where the camera or the
interface needs it. That only pays once the base solver is fixed and measured. Where they enter the ladder:

| Step | Paper | Form it takes here |
|---|---|---|
| F1.5 | foveated / camera-distance adaptivity (the cheap form of [10][11][15] in the survey) | particle merge/split by distance to the camera on the MPM solver |
| F3 | Leapfrog Flow Maps (SIGGRAPH 2025) → Cirrus's adaptive flow maps as the RTX stretch | smoke/fire solver |
| later | Adaptive PF-FLIP | only if we ever need two-phase (air + water) simulation at very large scale — not a game-engine priority |

What *was* used from the 2023–2026 survey: PB-MPM (EA SEED 2024) as the solver, the narrow-range filter for the surface,
WebGPU-first prototyping (Splash / WebGPU-Ocean precedent), and fixed-point atomics for deterministic P2G. The user's
call on which TMP episode it was (A Cirrus / B Adaptive PF-FLIP) is still open and decides which of the two gets
the F1.5/F3 slot first.

---

## Sources

[1] Epic Games — *Fluid Simulation in Unreal Engine — Overview* (UE 5.8 docs; "Beta feature, use caution when shipping") — https://dev.epicgames.com/documentation/en-us/unreal-engine/fluid-simulation-in-unreal-engine---overview
[2] Epic Games — *Niagara Fluids Reference Guide* (templates 2D/3D Gas, 2D/3D Liquid, Shallow Water; Pressure Solve Iterations, Pressure Relaxation, Vorticity Confinement, Scalability) — https://dev.epicgames.com/documentation/unreal-engine/niagara-fluids-reference-in-unreal-engine
[3] r/unrealengine — *Absolute Noob: Niagara Fluids* (Dec 2022; Epic VFX staff reply: 3D FLIP "mainly geared towards cinematic use for now, but it is doable"; RTX 3080 laptop ~80 % GPU) — https://www.reddit.com/r/unrealengine/comments/zbulm6/absolute_noob_niagara_fluids/
[4] StraySpark — *Niagara Fluids for Gameplay: Beyond VFX in 2026* (Apr 2026; UE 5.7.1 PS5/XSX budgets: 3D smoke 64³ 1.8 ms, 128³ 5.5 ms, SPH 10 k 0.8 ms, 50 k 3.2 ms; non-determinism; readback 1–2 frames) — https://www.strayspark.studio/blog/niagara-fluids-for-gameplay-beyond-vfx-2026
[5] ZibraAI — Zibra Liquids (MLS-MPM in Unity/Unreal; "300 000 particles in 7 ms on a GTX 1050 laptop" prototype claim; neural-SDF colliders) — https://medium.com/@zibraAI/zibraai-and-its-ml-powered-toolset-to-boost-the-game-development-industry-89a948181fdb ; https://www.gamespress.com/AI-powered-solution-for-real-time-liquid-physics-simulation-Zibra-Liqu
[6] 80.lv — *Working with Niagara Fluids to Create Water Simulations* (Jul 2022; PIC/FLIP ratio 0.75–0.95, Num Cells Max Axis, Particles Per Cell, Pressure Iterations, Physics Asset collisions) — https://80.lv/articles/working-with-niagara-fluids-to-create-water-simulations
[7] Imaginary Blend — *Fluid Flux* (shallow water for UE; RTX 3080 260–380 FPS at 1440p; readback "at least one frame delay") — https://imaginaryblend.com/2021/09/26/fluid-flux/
[8] Althera Games — *UE5 Niagara VFX Guide* (May 2026; "Niagara Fluids is still in beta and performance is inconsistent across platforms … not usable on mobile") — https://altheragames.com/en/blog/ue5-niagara-vfx-guide
[9] Epic Games — *Unreal Engine 5.0 Release Notes* (Niagara Fluid Simulation introduced) — https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-5.0-release-notes
[10]–[25] as numbered in `FluidPhaseF1-RecentSurveyAndWebGpuPlan.md` (PB-MPM [3][4], Cirrus [10], Adaptive PF-FLIP [11], foveated fluids [15], Leapfrog Flow Maps [9]).
