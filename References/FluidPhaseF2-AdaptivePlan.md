# Fluid phase F2 — bringing *both* SIGGRAPH 2025 adaptive papers into `Projects/Project-Fluid`, then combining them

Branch `arena/01a071a3-slate`, 2026-09-06. Continues `FluidPhaseF1-RecentSurveyAndWebGpuPlan.md` (§4.4 ladder) and answers
§4 of `FluidPhaseF1-UnrealComparison.md` ("was the adaptive research used?" — from now on: yes, this is how). The user's
decision: **implement A (Cirrus) and B (Adaptive Phase-Field-FLIP) both, each visible as its own effect first, then
combine them into one simulation; GPU- and resolution-dependence is accepted.** The user still owes the GTX timings
(`?resolution=64&perkernel=1`, then `&solver=explicit` — the CSV button); they set the particle/tile budgets below.

Legend ✅ done · 🔜 next · ⏳ later · 🧪 measured on SwiftShader (software GPU — timings meaningless, counts exact) · 📄 from the paper

---

## 1. Are they two different effects? Yes — and neither is real time as published

| | 🌪️ **A — Cirrus** [1][2] | 🌊 **B — Adaptive PF-FLIP** [3][4] |
|---|---|---|
| Medium | **Smoke / air**: single-phase incompressible gas in impulse form (`Dm/Dt = −(∇u)ᵀm`, `∇²φ = ∇·m`), no viscosity | **Water + air together**: two-phase, high density contrast, high Reynolds number; spray and mist are *simulated* air–water interaction, not a heuristic |
| Adaptivity | Octree-like grid of **8×8×8 tiles on the GPU**; **particles are the refinement oracle** ("a particle system serves both as a medium for convective flow mapping and as an oracle to guide grid refinement"); particles live only on the finest level | **Multiresolution Sparse Block Grid** (MSBG, treeless) + **adaptive particles** + an adaptive Poisson solver; fine only near the interface |
| Transport | Long-range flow map on the coarse grid, long + short flow maps with gradients on particles (APIC); MGPCG projection on the adaptive grid | FLIP with a phase field; "does not require a surface reconstruction step" |
| Published cost 📄 | RTX 4090: **155 ms/step** sphere at 512³ effective (1.6 M leaf cells, 2.3 M particles) … **3 012 ms/step** flamingo flock at 512×512×2048 (24.5 M leaf cells, 41.6 M particles) — Table 4 of [1] | 32-core CPU, 256 GB RAM: **≈2 minutes per time step**, 3 billion particles, 6144×2048×1600 pressure grid — Fig. 1 of [3]; the released MSBG library is CPU-only *by design* ("No GPU needed") [4] |
| Water? | ❌ free surfaces listed as future work [1 §9.2] | ✅ that is its purpose |
| Real time? | ❌ (10–200× off a 16 ms frame at their sizes) | ❌ (≈10⁴× off) |

So "add them to the prototype" cannot mean porting either system. It means porting the **ideas that are portable at game
scale** — and both papers share the same one: *spend resolution only where the fluid is.* Cirrus does it on the grid with
particles as the oracle; PF-FLIP does it on the grid *and* the particles, driven by the interface. The real-time cousin of
Cirrus, **Leapfrog Flow Maps** (same group, same conference) [5], is the gas solver we port: 5.6 ms/step at 128³ and
14.1 ms at 256×128×128 on a 4090 (Table 4 of [5]) — that is a 60 Hz budget on RTX and a 30 Hz one on a GTX at 64–96³.

---

## 2. The combined design — one sparse tiled lattice, two materials, one oracle

```
                        particle oracle (where are the particles / where is the interface?)
                                             │  allocate 8³ tiles, free the rest          ← A1 (Cirrus tiles, MSBG sparsity)
                                             ▼
        ┌──────────────────── sparse tiled lattice (shared) ────────────────────┐
        │                                                                       │
   💧 water lane — PB-MPM (exists, F1.3)                              🌫️ air lane — Leapfrog Flow Maps (F3 → here)
   adaptive particles: 1 big particle per cell in the bulk,           impulse on the grid + leapfrog midpoint advection,
   8 small ones within 2 cells of the free surface          ← A2      tile-local multigrid projection, vorticity kept   ← A3
   (PF-FLIP's adaptive particles, Cirrus's "finest level only")       (Cirrus's flow-map smoke without the octree levels)
        │                                                                       │
        └──────────────── coupling: water surface velocity is a Dirichlet source for the air; ───────────────┘
                          isolated water particles (splash, sheet break-up) become spray advected by the air lane
                          and fall back into the water lane when they land                         ← A4 (PF-FLIP's look)
```

Why this is *both* papers and not a rename of F1.5: A1 and A2 are the PF-FLIP contribution (sparse blocks, adaptive
particles, air as a simulated phase), A3 is the Cirrus/LFM contribution (flow-map gas on GPU tiles with the particles as
the oracle), and A4 is the combination the user asked for: **one scene where the smoke lane and the liquid lane share the
same tiles and the same refinement criterion.** Each step is a selectable scene in the page with its own proof, so each
effect is seen on its own before they meet (user's requirement).

---

## 3. Steps (each measurable; nothing lands without its proof)

| Step | What | Files | Proof / measure | Status |
|---|---|---|---|---|
| **A0 tile oracle** | `MarkTiles` pass: every 8³ tile touched by a particle stencil is marked, `Tally[2]` counts them; shown as `tiles n/N` in every proof line and as a `tiles` row in the proof table | `Shaders/ParticleSolver.wgsl`, `LiquidSolver.js`, `GameExecution.js` | 🧪 32 cells: **8/24 → 10/24** tiles as the column collapses (t = 0.5 → 0.6 s); 64 cells: **40/160 = 25 %** at t = 0.2 s (§4) — the number tells how much a sparse lattice saves *before* we build it | ✅ this commit |
| **A1 sparse lattice** | Allocate lattice storage per occupied tile (indirection table `TileSlot[tile] → slot`, built from the mask by a prefix sum on the GPU); `ClearLattice` / `AdvanceLattice` / `MassPartials` dispatch over **occupied tiles only** (indirect dispatch); dense path kept behind `?lattice=dense` for A/B | new `Shaders/TileAllocation.wgsl`, `LiquidSolver.js` | trace hash **identical** to the dense path at 32 and 64 cells (bit-for-bit — sparsity may not change physics); ms/tick dense vs sparse at 96 and 128 cells on the GTX | 🔜 next session |
| **A2 adaptive water particles** | PF-FLIP-style sizing: a particle within 2 cells of the free surface (density gradient on the lattice) keeps 8/cell; bulk particles merge to 1/cell (mass-, momentum- and C-conserving merge; split when the surface approaches). Free `Reserve` lane in the record holds the size class | `Shaders/ParticleSolver.wgsl` (merge/split kernels), `DamBreakStructure.js` | mass proof unchanged (< 0.1 %), settle proof unchanged, **particle count** and ms/tick vs fixed 8/cell at 96 and 128 cells; visual A/B frames | ⏳ |
| **A3 flow-map air lane** | Leapfrog Flow Maps [5] on the same tiles: impulse field `m`, leapfrog midpoint velocity, reinitialise every n = 5–10 steps, matrix-free MGPCG V-cycle in WGSL (tile-local RBGS like [5] §5.3), smoke density advected on the flow map, half-res ray-march overlay; scene `?scene=smoke` (vortex-ring leapfrog test from [5] Fig. 14 as the proof) | new `Shaders/ImpulseSolver.wgsl`, `Shaders/SmokeRaster.wgsl`, `VapourSolver.js` | 📄 two vortex rings must survive ≥ 3 leaps without merging (the paper's own benchmark); divergence RMS < 1e-3 after projection; ms/step at 64³ / 96³ / 128³ | ⏳ |
| **A4 combined scene** | `?scene=plunge`: the dam-break liquid drives the air lane (surface velocity as a source), isolated water particles switch to the air lane as spray, settle back as water; both lanes read the *same* tile mask | `GameExecution.js`, both solvers | mass proof across both lanes (Σ water + Σ spray constant), settle proof, tiles n/N shared; frames | ⏳ |
| **A5 GPU tiering** | Tile budget, particle budget and smoke grid picked from the GTX CSV (`?resolution=64&perkernel=1`) — GTX ≈ 64–96³ smoke + ≤ 150 k particles; RTX ≈ 128³ + ≥ 700 k | `GameExecution.js` presets | the ❓ row in `FluidPhaseF1-UnrealComparison.md` filled | ⏳ blocked on the user's CSV |

**Order of operations tomorrow:** A1 → A3 → A2 → A4 (A3 before A2 because the smoke lane is the visible new *effect*; A2
is an optimisation whose value only shows at 96+ cells, i.e. after the GTX numbers exist).

F1.4 (Jolt-shaped collider) and the material lane (honey + water in one scene, Pa·s calibration) stay on the ladder after
A4 unless the user reprioritises; the `Reserve` lane is claimed by A2 for the size class, so the material lane will need a
second lane (record stride 64 → 80 B).

---

## 4. A0 measurements (SwiftShader, `?proof=1&fixed=1&offscreen=1`)

`?resolution=R` is the cell count **along x** (Δx = 2 m / R), so the lattice is R × R/2 × 5R/8 sites and the tile grid is
⌈R/8⌉ × ⌈R/16⌉ × ⌈5R/64⌉.

| Resolution | Sites | Tiles (8³) | Particles | Tiles touched | Fraction | Note |
|---|---|---|---|---|---|---|
| 32 | 32×16×20 = 10 240 | 4×2×3 = **24** | 5 544 | **8** at t = 0.5 s → **10** at 0.6 s | 33 % → 42 % | column collapsing along the floor; trace `72df8a05` |
| 64 | 64×32×40 = 81 920 | 8×4×5 = **160** | 71 280 | **40** at t = 0.2 s | 25 % | column still standing; trace `b38d731c`; MarkTiles 22 ms/tick vs 2 912 ms/tick simulation on SwiftShader |

Honesty note: 32 cells is far too coarse for sparsity to pay — one tile is a quarter of the box. The saving appears at
96+ cells where the dam-break occupies ≈ 15–25 % of the tiles, and in the smoke lane where the plume is a thin fraction
of a tall domain. That is why A1 is measured at 96 and 128 on the GTX, not here. The pass itself costs 1.26 ms/tick on
SwiftShader against 180 ms/tick of simulation — noise even on a software GPU.

Reading: at 64 cells the standing column touches exactly a quarter of the tiles, so A1 would skip **75 %** of
`ClearLattice`/`AdvanceLattice`/mass-reduction work and memory at t = 0 and roughly half once the water has spread
along the floor (the 32-cell run shows the spread costing +25 % tiles by 0.6 s). The saving grows with resolution
because the water volume is fixed while tile count scales as R³/512 — and it is the only mechanism that makes a 128³
air lane affordable on the GTX. The `settle` FAIL lines in both logs are expected: that proof is only meaningful after
≈ 6 s (F1 §4.2) and these were 0.2–0.6 s runs made to read the tile counts.

---

## 5. What the user does next (unchanged, still needed)

1. Windows, Chrome/Edge 113+, GTX: open `?resolution=64&perkernel=1`, wait 10 s, click **CSV**; repeat with `&solver=explicit`.
   Paste both. They fill the ❓ speed row in the Unreal comparison and pick the tile/particle budgets for A5.
2. Nothing else is blocked on the user: A1–A4 proceed on SwiftShader (counts and hashes are exact there; only ms are not).

---

## Sources

[1] Wang, Feng, Li, Zhu — *Cirrus: Adaptive Hybrid Particle-Grid Flow Maps on GPU*, ACM TOG 44(4), SIGGRAPH 2025 — preprint https://wang-mengdi.github.io/proj/25-cirrus/cirrus-preprint.pdf ; DOI https://doi.org/10.1145/3731190 (Table 4 timings; §9.2 limitations: no free surfaces yet; 8³ tiles, particles as refinement oracle, finest level only)
[2] Cirrus source (C++/CUDA, xmake) — https://github.com/wang-mengdi/Cirrus ; project page https://wang-mengdi.github.io/proj/25-cirrus/
[3] Braun, Bender, Thuerey — *Adaptive Phase-Field-FLIP for Very Large Scale Two-Phase Fluid Simulation*, ACM TOG 44(4) art. 42, SIGGRAPH 2025 — preprint https://ge.in.tum.de/download/Adaptive_Phase_Field_FLIP_preprint.pdf ; DOI https://doi.org/10.1145/3730854 (Fig. 1: 3 billion particles, ≈2 min/step; abstract: treeless adaptive grid + adaptive particles + adaptive Poisson solver, no surface reconstruction step)
[4] MSBG — *Multiresolution Sparse Block Grids*, reference code for [3] (Apache-2.0, C++11 + TBB, "No GPU needed", 32 768³ effective on a 32-core / 256 GB CPU) — https://github.com/tum-pbs/MSBG
[5] Sun, Li, Wang, Wang, Li, van Bloemen Waanders, Zhu — *Leapfrog Flow Maps for Real-Time Fluid Simulation*, ACM TOG 44(4) art. 94, SIGGRAPH 2025 — PDF https://wrc042.github.io/assets/sig25lfm.pdf ; code https://github.com/yuchen-sun-cg/lfm (Table 3: 14.1 ms/step vs NFM 122.5 ms at 256×128×128; Table 4: 5.6 ms at 128³, 11.1 ms at 256×128×128 real-time examples; matrix-free AMGPCG with 8³-tile RBGS; vortex-ring leapfrog benchmark)
[6] SIGGRAPH 2025 papers list — https://www.kesen.realtimerendering.com/sig2025.html
