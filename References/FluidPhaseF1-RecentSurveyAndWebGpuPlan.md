# Fluid phase F1 — 2023–2026 survey refresh and the WebGPU-only prototype (`Projects/Project-Fluid`)

Branch `arena/01a071a3-slate`, 2026-09-05. Supersedes the plan sections (§5–§6) of `FluidPhaseF0-SurveyAndPlan.md`; the F0
document stays as the background on the *classic* methods (2005–2018) that the modern papers build on. Everything cited
here is **2023–2026**, peer-reviewed (SIGGRAPH / SIGGRAPH Asia / TOG / CGF / Computers & Graphics), first-party engine
documentation, or a browser vendor's own release notes. Target unchanged: **AAA look, real time on a GTX-class card,
scaling up on RTX** — and the decision taken this session: **the prototype is WebGPU only, no C++ for now**.

Legend 🥇🥈🥉 ranking for our goal · ✅ fits · ⚠️ with caveats · ❌ does not fit · 🏭 shipped / studio-owned · 🧪 runs in WebGPU today
· 📄 peer-reviewed or first-party · ⚡ GPU-native · 🐢 CPU or offline · 🎬 candidate for the Two Minute Papers episode

---

## 1. What changed since the classic literature (the 2023–2026 picture)

| Year | Work | Kind | What it changes for us | Real time? | Verdict |
|---|---|---|---|---|---|
| 2023 | **Neural Flow Maps** (Deng, Yu, Zhang, Wu, Zhu — SIGGRAPH Asia 2023, best paper) 📄 [1] | smoke/vortical, grid | Starts the *flow-map* line: advect **impulse** along long-range flow maps instead of velocity → far less numerical dissipation than semi-Lagrangian/BFECC | ❌ offline (neural field) | research origin of the 2024–25 real-time descendants |
| 2024 | **Particle Flow Maps** (Zhou, Chen, Deng, … Zhu — SIGGRAPH 2024; code) 📄 ⚡ [2] | smoke/vortical, hybrid | Replaces the neural field with particles carrying flow-map Jacobians; Taichi GPU code | ⚠️ interactive on a 4090, not game-rate | the reference the 2025 GPU papers beat |
| 2024 | **A Position Based Material Point Method** (Lewin, EA SEED — SIGGRAPH 2024; BSD-3 WebGPU code) 📄 🏭 🧪 ⚡ [3][4] | liquid + sand + snow, MPM | Position-based (iterative) MPM: large stable steps, particle deletion, velocity clamping; **the reference implementation is WebGPU/WGSL** | ✅ designed for games | 🥇 **liquid solver upgrade path** |
| 2024 | **Vertex Block Descent** (Chen, Liu, Yang, Yuksel — SIGGRAPH 2024) 📄 ⚡ [5] | elastic bodies / cloth | Per-vertex Gauss-Seidel blocks, unconditionally stable, embarrassingly parallel on GPU | ✅ | 🥇 cloth/soft-body candidate for phase F4 |
| 2024 | **Gaussian Splashing** (Feng et al., 2024) 📄 [6] | liquid + 3DGS rendering | Couples PBD/MPM particles with 3D-Gaussian scene reconstruction; rendering, not solving | ⚠️ offline-ish | research watch (rendering water inside splatted scenes) |
| 2024 | **Fluid Implicit Particle Simulation for CPU and GPU** (arXiv 2404.01931) 📄 ⚡ [7] | liquid, FLIP | Honest GPU FLIP cost table: 100 k @ 32³ 18 ms · 500 k @ 64³ 83 ms · 1 M @ 128³ 204 ms — a Poisson solve per step is what makes FLIP lose to MPM at game budgets | ⚠️ | confirms F0's "grid solve is the problem" |
| 2024 | **UE 5.4–5.6 Niagara Fluids** (Epic docs) 🏭 [8] | liquid / gas / SWE | Ships PIC/FLIP 3-D liquids, 2-D shallow water and 3-D gas as Niagara emitters; SDF + jump-flood surface | ✅ (paid for by big GPUs) | the engine-native baseline to beat on cost |
| 2025 | **Leapfrog Flow Maps for Real-Time Fluid Simulation** (Sun et al. — SIGGRAPH 2025; CUDA + Vulkan code) 📄 ⚡ [9] | smoke / fire, grid | Hybrid velocity–impulse leapfrog + matrix-free AMGPCG: **256×128×128 in 14.1 ms/step, 128³ in 5.6 ms, 256³ in 40.7 ms on an RTX 4090**; 8.7× faster than NFM | ✅ on RTX, ⚠️ on GTX (halve the grid) | 🥇 **smoke/fire solver (phase F3)** — replaces GPU Gems 3 ch. 30 |
| 2025 | **Cirrus: Adaptive Hybrid Particle-Grid Flow Maps on GPU** (Wang, Feng, Li, Zhu — SIGGRAPH 2025; code) 📄 ⚡ 🎬 [10] | smoke / vortical, **adaptive** | Particles carry long- and short-range flow maps *and* drive octree-like grid adaptation; up to **512×512×2048 effective** on a 4090; 1.5–2× over PFM, adaptivity gives 1–2 orders of magnitude savings | ⚠️ seconds per frame at those sizes; adaptivity is the transferable idea | 🥈 RTX-tier stretch for F3; **TMP candidate A** |
| 2025 | **Adaptive Phase-Field-FLIP for Very Large Scale Two-Phase Fluid Simulation** (Braun, Bender, Thuerey — SIGGRAPH 2025; code MSBG) 📄 🐢 🎬 [11][12] | liquid **+ air**, adaptive | Two-phase (water and the air it drags), treeless adaptive grid + adaptive particles + adaptive Poisson; billions of particles on a **CPU** workstation | ❌ offline (hours) | quality reference for spray/foam; **TMP candidate B** |
| 2025 | **Augmented Vertex Block Descent** (Giles, Diaz, Yuksel — SIGGRAPH 2025 + Real-Time Live!) 📄 ⚡ [13] | rigid + soft + joints | Hard constraints, friction, joints in the VBD framework; Real-Time Live! showed **110 k stacked blocks in 3.5 ms sim / 9.8 ms with collision on a 4090** | ✅ | 🥇 GPU cloth/soft-body for F4, and a GPU rigid-body *alternative* to keep an eye on next to Jolt |
| 2025 | **Compressible Flow Maps** / **Vortex PFM** / **Clebsch-gauge PFM** / **EDGE buffer-free flow maps** (SIGGRAPH 2025) 📄 [14] | grid / vortical | Flow maps extended to compressible + shallow-water, and to memory-light "buffer-free" forms | ⚠️ | research watch — the SWE variant matters for T0 water later |
| 2025 | **Gaze-contingent / foveated adaptive fluid for VR** (Wang et al., 2023–25) 📄 [15] | perceptual adaptivity | Allocates particle resolution by a perceptual sizing function: up to **3.62×** speed-up at equal perceived quality | ✅ | 🥉 a *cheap* adaptivity we can add to any particle solver (camera-distance LOD) |
| 2025 | **GPU-native AMR for lattice Boltzmann** (Comput. Phys. Commun. 2025) 📄 ⚡ [16] | adaptive grid | Block-based refinement on consumer GPUs | ⚠️ | peripheral; confirms block-AMR is GPU-practical |
| 2024–25 | **WebGPU-Ocean / Splash** (matsuoka-601) 🧪 ⚡ [17][18] | liquid, MLS-MPM in WGSL | 100 k particles on integrated graphics, ~300 k mid-range, ~1 M on capable GPUs in a browser; fixed-point atomics for P2G | ✅ | proof that MLS-MPM is the right first kernel set in WebGPU |
| 2023 | **Anisotropic screen-space rendering** (Xu et al., Computers & Graphics 2023) 📄 [19] | rendering | WPCA-stretched sprites + a filter comparison: **narrow-range filter is the preferred screen-space filter** (quality vs frame rate) | ✅ | confirms NRF as the default; anisotropy is an upgrade |
| 2024 | **Screen-space rendering for multiphase particle fluids** (Zhang et al., SIMPAT 2024) 📄 [20] | rendering | Phase-fraction textures on top of NRF-style SSFR | ✅ | later (mud/water mixing) |
| 2025–26 | **WebGPU platform**: W3C Candidate Recommendation Draft (2025 → 21 May 2026 CRD) [21]; Chrome 121 timestamp queries + DXC on Windows [22]; Chrome 134 `subgroups` shipped [23]; Firefox 141 / Safari 26 ship WebGPU [24] | platform | Subgroups (wave ops) make GPU reductions/scans first-class; timestamps make per-kernel telemetry possible; three engines ship | ✅ | the browser is now a credible experiment platform |

---

## 2. The Two Minute Papers "adaptive fluid simulation" episode — two candidates

The channel index isn't searchable from here, so both 2025 adaptive papers are covered; the user should confirm which
one they saw:

| | **A — Cirrus (SIGGRAPH 2025)** [10] | **B — Adaptive Phase-Field-FLIP (SIGGRAPH 2025)** [11][12] |
|---|---|---|
| What you see in the video | Smoke plumes, vortex rings, aircraft/ink-like vortical flow; visible **octree refinement following the particles** | Breaking waves, waterfalls, spray clouds; **billions of particles**, the air phase simulated too |
| Medium | Gas (single phase) | Water + air (two phase) |
| Hardware | RTX 4090, GPU-native (CUDA) | 32-core CPU workstation, **no GPU** |
| Speed | Interactive at small sizes, minutes at 512×512×2048 effective | Hours per shot |
| Code | https://github.com/wang-mengdi/Cirrus | https://github.com/tum-pbs/MSBG |
| What transfers to a game engine | The **adaptive lattice driven by particle density** and the flow-map impulse advection (low dissipation) | The **adaptive particle sizing** (fewer, bigger particles where nothing happens) and the two-phase idea for spray |
| Role in our plan | RTX-tier stretch for smoke (F3.2) | Quality bar for spray/foam; not a runtime target |

Either way the *runtime* lesson is the same and is already reflected below: **spend resolution where the camera and the
motion are** — Cirrus does it on the grid, PF-FLIP on the particles, the VR work [15] on perception — and our first cheap
version of that is camera-distance particle LOD on the MPM solver (F1.5).

---

## 3. Revised ranking (2023–2026 evidence only)

| Need | 🥇 | 🥈 | Why (recent evidence) |
|---|---|---|---|
| Local 3-D liquid, sand, mud, snow on GTX | **MLS-MPM → PB-MPM** (WGSL: [3][4][17][18]) | PBF (unchanged from F0) | Only method with a *2024 AAA-studio paper whose reference code is WebGPU*; no neighbour search; 100 k–1 M particles demonstrated in browsers |
| Liquid surface rendering | **Screen-space, narrow-range filter, half-res** ([19] confirms NRF is the best filter; [20] extends it) | density/SDF ray-march on RTX | Cost scales with pixels; the 2023 comparison picked NRF over curvature flow and bilateral |
| Smoke / fire / explosions | **Leapfrog Flow Maps** [9] | Cirrus-style adaptive grid [10] on RTX | 5.6 ms at 128³ on a 4090 — a 96³ grid should land at 2–4 ms on a GTX 1070-class card; matrix-free AMGPCG ports to WGSL |
| Open water (ocean, rivers, shore) | FFT + SWE + wave particles (F0 §5, unchanged; Niagara SWE [8] and Compressible Flow Maps' shallow-water form [14] are the recent confirmations) | — | No 2023–26 paper displaces this stack for large bodies |
| Cloth / soft bodies (F4) | **VBD / AVBD** [5][13] | Jolt soft bodies (CPU XPBD) for gameplay cloth | Unconditionally stable, GPU-parallel, hard constraints since 2025 |
| Adaptivity | camera-distance particle LOD first [15] → Cirrus-style sparse lattice later [10] | — | Cheapest measurable win first; sparse/adaptive grids are a later WebGPU experiment |

---

## 4. The prototype — `Projects/Project-Fluid` (WebGPU only, standalone, no C++)

Decided this session: browser page, no native host for now. Layout follows the repo's project shape with the browser as
the toolchain:

```
Projects/Project-Fluid/
├── Build/ToolchainSequence.ps1 / .sh    ← static HTTP server (PowerShell 5.1 HttpListener / python3 http.server) + --check
└── Source/
    ├── index.html                        ← page shell: canvas + controls (no logic)
    ├── GameExecution.js                  ← main loop: fixed 60 Hz tick accumulator → LiquidSolver.Advance → Present → proofs
    ├── DamBreakStructure.js              ← the scene: 2 m × 1 m × 1.25 m box, water column, particle records (80 B each)
    ├── LiquidSolver.js                   ← MPM on WebGPU: storage, 7 kernels, two methods (PB-MPM · explicit), proof + trace readback
    ├── SurfaceProjection.js              ← screen-space renderer: background, sprites, thickness, narrow-range smooth, shade
    ├── TimingMetrics.js                  ← timestamp-query telemetry (ms per kernel per tick) + CSV
    └── Shaders/
        ├── ParticleSolver.wgsl           ← ClearLattice · ScatterMass · ScatterStress · ProjectVolume · AdvanceLattice · GatherParticles · ReduceProof
        └── SurfaceProjection.wgsl        ← BackgroundRaster · SpriteRaster · ThicknessRaster · SmoothRaster · ShadeRaster
```

Naming follows CLAUDE.md (`<Subject><Role>`, roles Solver / Projection / Structure / Metrics / Sequence; 142-char
headers and 122-char banners in the `.js` and `.wgsl` files). The vocabulary inside avoids the banned words: the
background Eulerian points are the **lattice** and its **sites**, a particle's 27 sites are its **stencil**, the
fixed-point unit is a **quantum**, GPU passes are **dispatches** (compute) and **rasters** (render).

### 4.1 What F1.0–F1.2 already do (this commit)

* **Solver** — MLS-MPM (Hu et al. 2018, the same core WebGPU-Ocean/Splash and EA's PB-MPM use), APIC transfers,
  quadratic B-spline stencil, Tait EOS (κ = 10 kPa, γ = 7 → c₀ ≈ 8.4 m/s), density re-estimated from the lattice every
  sub-step, separating slip walls, **mirrored-wall density** (a particle resting on the floor reads ρ₀, not 0.6 ρ₀ — without it
  the EOS pulled the whole column into the floor), sub-step count from an acoustic Courant bound (0.6), 3-step look-ahead
  wall push, hard clamp that doubles as the tunnelling detector.
* **P2G in fixed point** — WGSL atomics are `i32`/`u32` only; mass and momentum accumulate as `i32` quanta
  (2⁻²⁰ m_p and 2⁻¹⁷ m_p·m/s) with a per-contribution saturation counter, so precision loss is *measured*, not assumed.
* **Renderer** — sphere impostors → eye distance + hardware depth; additive thickness; **narrow-range filter**
  (Truong & Yuksel; separable 1-D forms + 5×5 clean-up, dynamic range, bias correction) at an offscreen scale (0.5 =
  the GTX setting); Fresnel + sky reflection + refracted background + Beer–Lambert absorption. View modes: water,
  particles (speed), smoothed distance, thickness.
* **Loop + proofs** (same shape as Project-Physics): 60 Hz tick accumulator with catch-up cap and drop counter, proof every
  30 ticks read back asynchronously, exit 0/2/1 in `window.ProjectFluidExit`, trace hash for determinism, CSV export.
  Proofs: containment (all N inside), mass (Σ lattice mass = N·m_p to 0.1 %), finite (no saturation, no NaN), settle
  (final mean height = h_settled/2 ± 15 %, RMS speed < 0.2 m/s).
* **Telemetry** — `timestamp-query` per pass (`?perkernel=1` splits the five kernels), wall time per frame, CSV download.

### 4.2 Validation done in the sandbox (software GPU)

The sandbox has no GPU, so Chromium 149 was run headless on **SwiftShader Vulkan** through WebGPU — correct results,
irrelevant timings (the GPU numbers below are a CPU emulating a GPU and say nothing about a GTX):

| Check | Result |
|---|---|
| WGSL compile (Tint, Chromium 149) | `ParticleSolver.wgsl` 0 messages · `SurfaceProjection.wgsl` 0 messages |
| Pipelines, bind groups, all six kernels, all five rasters | no validation errors (error scopes around every stage) |
| `?resolution=32&seconds=8&proof=1&fixed=1` (5 544 particles, 32×16×20 lattice, 6 sub-steps/tick) | **PASS, exit 0** — containment 5544/5544 · mass 169.189 kg vs 169.189 kg (0.000 %) · finite: 0 saturations, max \|v\| 0.76 m/s · settle: mean height 6.4 cm vs 7.3 cm expected (12.8 %), RMS speed 0.121 m/s |
| Determinism | trace hash `e8a16769` on two consecutive 8 s runs with the same URL (F1.2 build; after the F1.3 wall fix the explicit hash is `07afb8ce`, PB-MPM `82af79ca`) |
| `?resolution=48&seconds=1.5` (26 752 particles, 9 sub-steps/tick) | containment / mass / finite pass; settle correctly reported ❌ at 1.5 s (the water is still sloshing: RMS 1.13 m/s) — the settle proof is only meaningful at ≥ 6 s |
| Offscreen capture | `?offscreen=1` shades into a texture instead of the swapchain (SwiftShader cannot present) and exposes `window.ProjectFluidCapture()` — the screenshots in the reply come from that path |
| Timings | meaningless here (100 ms/tick at 48 cells on a CPU emulating a GPU); the point of the run is correctness |

Two solver fixes came out of these runs and are worth knowing when reading the kernels: (1) **mirrored-wall density** —
without it a particle resting on the floor read ≈ 0.6 ρ₀ (the sites beyond the wall hold no mass), the EOS went
negative and the whole column was sucked into the floor (mean height 2.3 cm instead of 7.3 cm); (2) the cohesion
(tensile) limit had to drop from 0.1 κ to 0.005 κ — 1 kPa of allowed tension was comparable to the hydrostatic head and
cancelled the pressure gradient.

Frames captured through the offscreen path (software GPU, so the *look* is the coarse 32/48-cell setting, not the GTX one):
`References/Figures/ProjectFluid_DamBreak_1s_32cells_SwiftShader.png` (the column hitting the far wall at 1 s),
`…_8s_32cells_SwiftShader.png` (settled), `…_1p5s_48cells_SwiftShader.png` (26 752 particles, first slosh),
`…_2p5s_32cells_SurfaceSheet_SwiftShader.png` (after the sprite radius went to 0.42 Δx and σ = δ = Δx — a closed sheet).

Particle counts per resolution (box fixed at 2 × 1 × 1.25 m, 8 particles/cell): 32 → 5.5 k · 48 → 27 k · 64 → 71 k ·
80 → 149 k · 96 → 269 k · 128 → 688 k · 160 → 1.38 M (records 105 MB + lattice 39 MB, inside the default 128 MiB
`maxStorageBufferBindingSize` per buffer).

### 4.2b F1.3 — position-based MPM (EA SEED 2024) is in, and is now the default solver

The explicit solver's cost is set by the speed of sound, not by the water: at κ = 10 kPa the acoustic Courant bound
needs 6 sub-steps per tick at 32 cells, 9 at 48, ≈ 12 at 64 — and stiffer water (less than 7 % compression under the
column) would need more still. PB-MPM [3][4] removes the sound speed: each sub-step runs *k* Jacobi iterations of
"project every particle's displacement gradient toward volume preservation → average the proposals on the lattice
(P2G ÷ mass → G2P)", and the sub-step is bounded only by advection (v_ref·Δt/Δx). Implemented here in 3-D on the same
storage, following EA's liquid branch (`particleUpdatePBMPM` / `gridToParticle` / `particleIntegrate` of the
`siggraph2024` branch of `electronicarts/pbmpm`, BSD-3):

* `ProjectVolume` (new kernel): with D = C·Δτ, remove ShearRelaxation·sym(D) (viscosity), then D += ω·α·I with
  α = (1/J − 1 − tr D)/3 so that (1 + tr(D + αI))·J → 1; α is floored at −Tension (0.25) as a spray safety net only.
* `ScatterMass` → `AdvanceLattice` → `GatherParticles` are unchanged kernels; the recipe drops `ScatterStress`. Gravity
  enters on iteration 0 only; the last iteration carries `Integrate = 1` and advects, updates J *= 1 + tr D (first-order
  det(I + D)), blends J toward the lattice-measured volume ratio ρ₀/ρ_lattice when compressed (EA's grid-volume rule,
  blend 0.1, with the mirrored-wall density so the floor does not read as tension) and applies the same walls / look-ahead
  push / hard clamp as before.
* Particle record: the two padding lanes became `Volume` (J) and a reserve; still 80 B, so the renderer only re-declared
  the struct. Constants: one 256-byte slice per iteration through a dynamic uniform offset (one bind group serves every
  dispatch); `Iterations ≤ 8`.
* New proof **volume**: mean J within 5 % of 1 at every proof (position-based only — the explicit method never touches J).
  `ReduceProof` now also returns min/max J and the RMS spread.
* Both methods stay selectable: `?solver=positionbased` (default, `&iterations=k`, `&relaxation=ω`, `&shear=s`) and
  `?solver=explicit&stiffness=κ`. The Courant planner knows which bound applies (`Describe()` reports it).

Two host/wall fixes fell out of the PB-MPM proof runs and apply to both solvers:

* **Wall plane site** — the separating slip condition was applied to sites strictly *inside* the margin, not to the
  plane site itself. A particle resting on the plane draws 87.5 % of its velocity from the plane site and the one
  behind it, so the wall was soft by half a cell; the stiffer PB-MPM water exposed it as two containment misses on impact
  (5542/5544 at 0.5 s with ω = 1.5). Including the plane site (`<=` / `>=`) closes it for both methods. The explicit trace
  hash therefore moved from `e8a16769` to `07afb8ce` — the physics changed, deliberately.
* **Proof series** — `fixed=1` now waits for `queue.onSubmittedWorkDone()` before encoding the next tick, so the 30-tick
  proof cadence holds on any GPU (before, an emulated GPU fell hundreds of ticks behind and every proof between the
  first and the last was skipped as "readback still in flight"). Each proof is also logged to the console as one line,
  which is the time series below.

Sandbox results at 32 cells (SwiftShader, correctness only; `?resolution=32&seconds=8&proof=1&fixed=1`, 5 544 particles):

| Solver | Sub-steps × iterations = lattice transfers / tick | 8 s proofs | Settle (mean height vs 7.3 cm · RMS speed) | Trace |
|---|---|---|---|---|
| explicit MLS-MPM κ = 10 kPa (baseline) | 6 × 1 = **6** | containment · mass · finite ✅; settle ❌ at 8 s (RMS 0.269 m/s > 0.2 — acoustic ringing, see the series), ✅ with `seconds=14` (6.9 cm, 0.126 m/s) | 7.0 cm (4.5 %) · 0.269 m/s at 8 s | `07afb8ce` (8 s) · `3164d64e` (14 s) |
| **PB-MPM, 2 iterations (default)** | 3 × 2 = **6** | all ✅ incl. **volume** (mean J 0.983, spread 0.026, min 0.84, max 1.14) | **7.1 cm (2.5 %) · 0.119 m/s** | `82af79ca` |
| PB-MPM, 4 iterations | 3 × 4 = 12 | all ✅ (mean J 0.992, spread 0.017) | **7.3 cm (0.7 %) · 0.103 m/s** | `50811741` |

RMS speed [m/s] every 0.5 s (the slosh decay; both solvers see the same first impact ≈ 1.8–1.9 m/s):

| t [s] | 0.5 | 1.0 | 1.5 | 2.0 | 3.0 | 4.0 | 5.0 | 6.0 | 7.0 | 7.5 | 8.0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| explicit 6×1 | 1.93 | 1.07 | 1.21 | 0.72 | 0.64 | 0.37 | 0.38 | 0.15 | 0.27 | 0.20 | 0.27 |
| PB-MPM 3×2 | 1.80 | 0.90 | 1.03 | 0.52 | 0.54 | 0.27 | 0.21 | 0.15 | 0.17 | 0.07 | 0.12 |
| PB-MPM 3×4 | 1.77 | 0.85 | 0.94 | 0.51 | 0.52 | 0.27 | 0.20 | 0.10 | 0.16 | 0.04 | 0.10 |

Reading:

* At the **same six lattice transfers per tick**, PB-MPM settles closer to the analytic height (2.5 % vs 4.5 % low — the
  explicit column sits compressed by construction of κ), damps the slosh faster (0.12 vs 0.27 m/s at 8 s; the explicit
  water keeps ringing acoustically, which is what tripped its settle proof at 8 s) and holds its volume proof (mean J
  0.98 — the residual 2 % is the first-order det(I + D) integration, corrected by the lattice blend only in compression).
* Doubling the iterations (12 transfers) buys another 1.8 % of height and a stiffer look, at twice the cost; the 4-iteration
  water is essentially incompressible (spread of J 0.017). EA ships 2 iterations; that stays the default.
* The **cost knob is transfers per tick**. PB-MPM spends them on iterations (stiffness) instead of on the speed of sound,
  and drops `ScatterStress` (27 atomics + a density gather per particle — the most expensive kernel) from every transfer;
  at 64 cells the explicit planner needs 12 sub-steps to PB-MPM's 4 × 2, at 128 cells 24 to 8 × 2. That is the number to
  confirm on the GTX with `&perkernel=1`.

Frames: `References/Figures/ProjectFluid_PbMpm_1s_32cells_SwiftShader.png` (1 s, the column hitting the far wall as a
sheet rather than as droplets) and `…_PbMpm_8s_32cells_SwiftShader.png` (settled, 8 s, level surface).

Viscous check (`?shear=1.0&iterations=3&seconds=1.5`): the same dam-break oozes instead of splashing — RMS 0.83 m/s at
0.5 s, **0.04 m/s at 1.5 s** (water: 1.80 → 1.03 m/s), mean J 0.989. Frames `…_PbMpm_Viscous_1p5s_32cells_SwiftShader.png`
(surface) and `…_Particles_SwiftShader.png`. The material comparison against Unreal is in `FluidPhaseF1-UnrealComparison.md`.

### 4.3 What the user runs on the GTX (Windows, Chrome/Edge 113+)

```
powershell -File Projects\Project-Fluid\Build\ToolchainSequence.ps1               # serve + open http://localhost:8765/
powershell -File Projects\Project-Fluid\Build\ToolchainSequence.ps1 -Proof        # 8 s PASS/FAIL run, prints the trace hash
```
Then: `?resolution=64` (~74 k particles), `96` (~280 k), `128` (~700 k); `&perkernel=1` for per-kernel ms; `&scale=1`
for the RTX rendering setting; `&solver=explicit` for the MLS-MPM baseline, `&iterations=3` for stiffer PB-MPM water;
the CSV button exports the table. The numbers to bring back are the **ms/tick per kernel at 64 and 96 for both
solvers** and the largest resolution that holds 60 Hz — those decide T1's particle budget on that card.

### 4.4 Next steps (each a small, measurable experiment; no C++ until F1 exits)

| Step | Experiment | Measures | Source |
|---|---|---|---|
| ~~**F1.3 PB-MPM**~~ | ✅ done (§4.2b): k Jacobi iterations per sub-step, volume proof, both solvers selectable | on the GTX: ms/tick PB-MPM 3×2 vs explicit 6×1 at 64/96 cells | [3][4] |
| **F1.4 Collider** | A kinematic box (Jolt-shaped SDF) dragged through the water, one-way; then impulse sums read back for two-way Jolt coupling | splash correctness, readback latency | Project-Physics `RigidBodySolver` |
| **F1.5 Adaptive LOD** | Camera-distance particle merging/splitting on the MPM solver (the cheap form of [10][11][15]) | speed-up at equal look | [15] |
| **F1.6 Subgroups** | `enable subgroups` for the proof/mass reductions and a sorted P2G (fewer atomics) | P2G ms | [23] |
| **F2 Rendering** | Anisotropic sprites [19], narrow-band filtering (CGF 2022, in F0), foam from thickness/velocity | ms at scale 1.0 | [19][20] |
| **F3 Smoke/fire** | Leapfrog Flow Maps port: 96³ grid, matrix-free AMGPCG in WGSL, half-res ray-march | ms/step vs the paper's 5.6 ms @ 128³ on a 4090 | [9] |
| **F4 Cloth** | VBD in WGSL on a 64×64 sheet, then AVBD constraints | ms/step, stability at 60 Hz | [5][13] |
| **Exit to `Engine/`** | When T1 holds ≥ 100 k particles at 60 Hz on the GTX with stable kernels: port WGSL → Slang for the Vulkan path (kernels are plain compute — no WebGPU-only features are used except timestamps) | — | F0 §4 |

---

## Sources (all 2023–2026)

[1] Deng, Yu, Zhang, Wu, Zhu — *Fluid Simulation on Neural Flow Maps*, ACM TOG 42(6), SIGGRAPH Asia 2023 (best paper) — https://yitongdeng-projects.github.io/neural_flow_maps_webpage/ ; arXiv https://arxiv.org/abs/2312.14635
[2] Zhou, Chen, Deng, Sun, Zhu et al. — *Eulerian-Lagrangian Fluid Simulation on Particle Flow Maps*, SIGGRAPH 2024 — https://pfm-gatech.github.io/pfm-website/ ; code https://github.com/pfm-gatech/particle-flow-maps
[3] Lewin (EA SEED) — *A Position Based Material Point Method*, SIGGRAPH 2024 — https://www.ea.com/seed/publications ; https://www.researchgate.net/publication/382387434_A_Position_Based_Material_Point_Method
[4] EA — pbmpm WebGPU reference implementation (BSD-3) — https://github.com/electronicarts/pbmpm
[5] Chen, Liu, Yang, Yuksel — *Vertex Block Descent*, ACM TOG 43(4), SIGGRAPH 2024 — https://dl.acm.org/doi/10.1145/3658179 ; https://graphics.cs.utah.edu/research/projects/vbd/
[6] Feng, Feng, Shang, Jiang, Yu, Zong, Shao, Wu, Zhou, Jiang, Yang — *Gaussian Splashing: Dynamic Fluid Synthesis with Gaussian Splatting*, 2024 — https://arxiv.org/abs/2401.15318
[7] *Fluid Implicit Particle Simulation for CPU and GPU*, arXiv 2404.01931 (2024) — https://arxiv.org/abs/2404.01931
[8] Epic Games — *Niagara Fluids Quick Start* (UE 5.x) — https://dev.epicgames.com/documentation/en-us/unreal-engine/niagara-fluids-quick-start-guide-for-unreal-engine
[9] Sun et al. — *Leapfrog Flow Maps for Real-Time Fluid Simulation*, ACM TOG 44(4), SIGGRAPH 2025 — PDF https://wrc042.github.io/assets/sig25lfm.pdf ; code https://github.com/yuchen-sun-cg/lfm
[10] Wang, Feng, Li, Zhu — *Cirrus: Adaptive Hybrid Particle-Grid Flow Maps on GPU*, ACM TOG 44(4), SIGGRAPH 2025 — https://dl.acm.org/doi/10.1145/3731190 ; project + code https://wang-mengdi.github.io/proj/25-cirrus/ ; https://github.com/wang-mengdi/Cirrus
[11] Braun, Bender, Thuerey — *Adaptive Phase-Field-FLIP for Very Large Scale Two-Phase Fluid Simulation*, ACM TOG 44(4), SIGGRAPH 2025 — https://dl.acm.org/doi/10.1145/3730854 ; TUM press release https://www.tum.de/en/news-and-events/all-news/press-releases/details/new-method-facilitates-realistic-simulation-of-fluids
[12] MSBG — reference code for [11] — https://github.com/tum-pbs/MSBG ; group post https://ge.in.tum.de/page/2/
[13] Giles, Diaz, Yuksel — *Augmented Vertex Block Descent*, ACM TOG 44(4), SIGGRAPH 2025 — https://dl.acm.org/doi/10.1145/3731195 ; https://graphics.cs.utah.edu/research/projects/avbd/
[14] SIGGRAPH 2025 papers list (Compressible Flow Maps, Vortex PFM, Clebsch-gauge PFM, EDGE) — https://www.realtimerendering.com/kesen/sig2025.html ; Bo Zhu publication list https://faculty.cc.gatech.edu/~bozhu/
[15] Wang et al. — gaze-contingent / foveated adaptive fluid simulation for VR (2023–2025; 3.62× and 2.27× results) — https://hhuiwangg.github.io/ ; https://www.researchgate.net/publication/374709178_Visual_perception_of_fluid_viscosity_Toward_realistic_fluid_simulation
[16] *GPU-native adaptive mesh refinement for lattice Boltzmann*, Computer Physics Communications 2025 — https://www.sciencedirect.com/science/article/pii/S0010465525000463
[17] matsuoka-601 — *WebGPU-Ocean* (MLS-MPM in WGSL; iGPU/mid-range numbers) — https://github.com/matsuoka-601/WebGPU-Ocean
[18] matsuoka-601 — *Splash* (2025; NRF, density ray-march, ~1 M particles) — https://github.com/matsuoka-601/Splash
[19] Xu, Xu, Yin, Ban, Wang, Chang, Zhang — *Anisotropic screen space rendering for particle-based fluid simulation*, Computers & Graphics 110 (Feb 2023) — https://www.sciencedirect.com/science/article/pii/S0097849322002308
[20] Zhang et al. — *Real-time screen space rendering method for particle-based multiphase fluid simulation*, Simulation Modelling Practice and Theory 136 (Nov 2024) — https://doi.org/10.1016/j.simpat.2024.103008
[21] W3C WebGPU status (Candidate Recommendation Snapshot Dec 2024 → CR Drafts through 2025–2026) — https://www.w3.org/TR/webgpu/ ; summary https://rustify.rs/articles/rust-gpu-computing-wgpu-2026
[22] Chrome 121 — timestamp queries in compute/render passes, DXC on Windows — https://developer.chrome.com/blog/new-in-webgpu-121
[23] Chrome 134 — `subgroups` shipped — https://developer.chrome.com/blog/new-in-webgpu-134
[24] Browser support (Chrome/Edge 113+, Firefox 141+, Safari 26) — https://www.testmuai.com/learning-hub/webgpu-browser-support/
[25] Truong & Yuksel — *A Narrow-Range Filter for Screen-Space Fluid Rendering* (2018; the filter implemented in `SurfaceProjection.wgsl`, kept because [19] re-validated it in 2023) — https://ttnghia.github.io/posts/narrow-range-filter/
