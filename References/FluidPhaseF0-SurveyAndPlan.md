# Fluid phase F0 — survey of real-time fluid simulation + rendering, and the WebGPU experiment plan

Branch `arena/01a071a3-slate`, 2026-09-05. Written before any fluid code exists, so that the WebGPU experiments test the
right candidates. Target: **AAA look, real time on a GTX-class card, scaling up on RTX**. Jolt stays the rigid-body
authority; fluid/cloth/smoke/fire are separate solvers (Jolt has no fluid — see §1).

Legend used in every table
🥇🥈🥉 ranking for our goal · ✅ fits · ⚠️ with caveats · ❌ does not fit · 🏭 shipped in a AAA title · 🧪 proven in WebGPU
· 📄 peer-reviewed / first-party source · 🐢 CPU-bound · ⚡ GPU-native

---

## 1. Where Jolt stands (what "complete" means)

| Item | State | Evidence |
|---|---|---|
| Rigid bodies from a main-loop Tick | ✅ done | `RigidBodySolver` + Project-Physics proofs (`PhysicsPhaseP1-JoltBringUp.md` §4) |
| Merged into the main tree | ✅ done upstream | `unassignedinbox/Slate@8d323d9` integrated `ac51363`; `f78f027` made ISA switchable (`-Isa SSE2|AVX|AVX2`, default SSE2); `0f910c9` pinned submodules |
| Wired into Project-Zero's loop / rendered | ❌ not yet | `Projects/Project-Zero/Source/GameExecution.cpp` on `arena/01a0718d-slate` has no `RigidBodySolver`; merge rows are in P1 §3 |
| Windows build executed | ⚠️ by upstream, not here | `f78f027` fixed a `0xc000001d` (AVX on a Sandy Bridge i3) — i.e. the `.ps1` path was run and now defaults to SSE2 |
| Linux scripts follow `-Isa` | ⚠️ no | `Scripts/BuildJolt.sh` / `ToolchainSequence.sh` still hard-code `-mavx -mpopcnt`; mirror the switch when Linux matters |
| Not exposed yet (Jolt has them) | ⏳ later rows | constraints (21 types), character controller, vehicles, ragdolls, contact listeners, ray/shape queries, soft bodies (XPBD cloth/volumes; `SoftBodySharedSettings::sCreateCube`, cloth built from the Samples pattern), buoyancy (`Body::GetSubmergedVolume` / `ApplyBuoyancyImpulse`) |
| Not in Jolt at all | ❌ | fluids (liquid, smoke, fire), GPU cloth. GPU hair exists in 5.6 (`Jolt/Physics/Hair`, `Compute/DX12|VK|MTL`) but is marked "still in development" and was excluded from our library |

**Verdict:** the *bring-up* is complete and merged; the *integration* (bodies driving rendered instances in Project-Zero,
gameplay queries, contact events) is the next Jolt row and is independent of the fluid work below.

---

## 2. Simulation methods — what the credible sources say

| Method | How it works | Real time on GTX | Scales to RTX | 🧪 WebGPU | 🏭 AAA use | Verdict |
|---|---|---|---|---|---|---|
| **FFT ocean spectrum** (Tessendorf 2001) | Statistical wave spectrum → inverse FFT heightfield + choppiness each frame; not a "simulation" of forces | ✅ trivially (a 256² FFT is sub-millisecond) | ✅ larger cascades, more octaves | ✅ (FFT in compute) | 🏭 Sea of Thieves (Tessendorf FFT, foam from choppiness + depth-buffer intersections) [1]; Horizon FW ocean [2] | 🥇 **for open water** — not a substitute for local liquid |
| **Heightfield SWE** (shallow-water equations: virtual pipes, Kurganov-Petrova) | 2-D grid of depth + flux; vertically averaged Navier-Stokes | ✅ 3 pixel-shader passes per step [3] | ✅ higher grid res | ✅ | 🏭 Sea of Thieves deck water uses a GPU SWE (Mei et al. 2007) [1]; Crimson Desert shoreline: SWE **particles**, ~250 k near camera, colliding with terrain/shoreline SDFs [4] | 🥇 **for rivers, shorelines, puddles, wakes** — cannot break waves or splash [3] |
| **Wave particles** (Yuksel 2007) | Particles carry wave energy, splatted to a heightfield; object wakes/ripples | ✅ hundreds of floating objects real time [5] | ✅ | ✅ | 🏭 referenced by Naughty Dog's water talk (their systems were procedural, *no* real-time physics) [5] | 🥈 local interaction layer on top of FFT/SWE |
| **SPH — PBF** (Position Based Fluids, Macklin & Müller 2013) | Density constraint solved by Jacobi iterations in the PBD framework; artificial pressure = surface tension; vorticity confinement [6] 📄 | ⚠️ ok to ~50–100 k; neighbour search dominates (counting-sort grid, Hoetzlein 2014 [7]) | ✅ | 🧪 LinzhouLi's WebGPU PBF: hash grid + exclusive scan, volume-map boundaries, narrow-range filter [8] | 🏭 NVIDIA FleX (Killing Floor 2, Fallout 4) — FleX needed GTX 770 min / 980 rec. [9] and is now CUDA-only inside PhysX 5, "feature parity … not a priority" (NVIDIA) [10] | 🥈 solid, well understood, but neighbour search caps it on GTX |
| **SPH — DFSPH / IISPH** (Bender & Koschier) | Implicit pressure solve enforcing both constant density and divergence-free velocity; "state of the art" incompressibility [11] 📄 | ⚠️ CPU-oriented reference code (SPlisHSPlasH); heavier per particle than PBF | ✅ | ⚠️ needs multiple neighbour passes per iteration | offline/VFX/research | 🥉 accuracy over speed — not our first choice |
| **PIC / FLIP / APIC** (Zhu & Bridson 2005; Jiang et al. 2015) | Particles carry mass/velocity, a MAC grid solves pressure; FLIP transfers velocity *deltas* (low dissipation, noisy), APIC adds an affine velocity per particle (stable **and** low dissipation) [12][13] 📄 | ⚠️ a 3-D pressure solve per step; UE5 Niagara Fluids uses PIC/FLIP for 3-D liquids with a PIC/FLIP ratio and iteration count [14] | ✅ | ⚠️ Niagara's FLIP relies on 32-bit **float atomics on 3-D textures** (broken on Metal) [15]; WGSL has integer atomics only → fixed-point scatter | 🏭 Epic (Niagara Fluids: FLIP water, shallow water, 3-D gas) [16] | 🥈 the "engine-native" route; grid solve cost is the problem on GTX |
| **MLS-MPM** (Hu et al. 2018) | Particles ↔ grid transfers like APIC but with a moving-least-squares force so **no neighbour search at all**; one material model handles water, sand, snow, jelly [17] | ✅ **~100 k particles on integrated graphics, ~300 k on a mid-range GPU** in a browser (WebGPU-Ocean) [17]; Splash: 70 k on a laptop iGPU, up to ~1 M on capable GPUs, single sub-step per frame with a Tait EOS [18][19] | ✅ GPU MPM research: 10 M particles < 1 min/frame with sparse grids (not real time, shows headroom) [20] | 🧪 **yes** — P2G with `atomicAdd` on fixed-point ints [17] | ⚠️ research + indie; EA's PB-MPM below is the AAA descendant | 🥇 **best sim/cost ratio for local 3-D liquid + granular on GTX** |
| **PB-MPM** (EA SEED, Lewin, SIGGRAPH 2024) | Position-based MPM: several P2G↔G2P cycles per step iteratively solve the particle velocity gradient → large stable steps, particle deletion/velocity clamping [21] 📄 | ✅ designed for games; 2-D WebGPU reference (BSD-3) [22]; 3-D DX12 GPU port exists (Breakpoint, with mesh-shader surface) [23] | ✅ | 🧪 **yes** — EA's reference *is* WebGPU [22] | 🏭 EA SEED (paper + code; in-house 3-D CPU version) [21][23] | 🥇 **the upgrade path from MLS-MPM** — same data layout, more stable |
| **Eulerian grid** (Stam stable fluids; GPU Gems 3 ch. 30) | Velocity/density/temperature on a 3-D grid: advect, add buoyancy/vorticity, project | ✅ since GeForce 8 ("Smoke in a Box", Hellgate: London) with half-res rendering + edge upsample [24] | ✅ | ✅ | 🏭 Hellgate: London [24]; UE5 Niagara 3-D Gas [16] | 🥇 **for smoke / fire / explosions** (phase F3) — for water it needs a level set and loses to particles on splashes [24] |
| **Neural / proprietary** (Zibra Liquids) | Custom solver + neural SDF colliders; DX11/12 Windows plug-in [25] | ✅ (vendor claim) | ✅ | ❌ closed | indie/UE/Unity plug-in | ❌ closed source, not embeddable in our engine |
| **NVIDIA FleX / PhysX 5 particles** | Unified PBD particles (FleX) → rewritten CUDA particle system in PhysX 5 [10] | ❌ CUDA only; falls back to CPU on other vendors [10] | — | ❌ | 🏭 KF2, Fallout 4 [9] | ❌ vendor lock-in |

### Why MPM wins for us
1. **No neighbour search** — the single biggest cost in every SPH variant, and the reason WebGPU-Ocean's SPH stalled at ~30 k particles on the same iGPU where MLS-MPM ran 100 k [17].
2. **One solver, many materials** — the same kernels do water, mud, sand, snow, jelly by swapping the constitutive model [17][21]. The next phases the user listed (fluid, then more) get most of this for free; cloth and smoke do **not** (they get their own solvers: Jolt soft bodies / XPBD, and an Eulerian grid).
3. **Already proven in WebGPU** with the exact trick the platform needs (fixed-point `atomicAdd`, because WGSL atomics are `i32`/`u32` only) [17][22][26][27].
4. **A AAA studio owns the modern variant** (EA SEED PB-MPM) and published it with BSD-3 code [21][22].

Known costs to plan for: explicit MLS-MPM wants small steps (nialltl's per-step volume recomputation gets it to 2 sub-steps/frame, "occasionally explodes") [17]; PB-MPM trades that for extra P2G/G2P iterations [21]. Grid memory = domain / cell size — keep the domain **local** (a pool, a splash zone), never the whole map; open water stays FFT + SWE.

---

## 3. Rendering methods

| Method | What it does | GTX cost | RTX upgrade | Verdict |
|---|---|---|---|---|
| **Screen-space fluid rendering** (van der Laan, Green, Sainz 2009; GDC 2010) | Splat particle spheres → depth; smooth depth; thickness pass; normals from smoothed depth; shade with Fresnel, refraction of the scene, Beer-Lambert absorption; noise for detail; foam from thickness [28][29] 📄 | ✅ cost scales with **pixels**, not particles; runs at half/quarter res | ✅ full-res, more filter iterations | 🥇 **the GTX path** |
| — depth filter: bilateral Gaussian | Cheap, separable; leaves blobby artefacts at silhouettes [28] | ✅ | — | ⚠️ starting point only |
| — depth filter: curvature flow | Iterative mean-curvature smoothing; better silhouettes than Gaussian at similar cost [28] | ✅ | ✅ more iterations | 🥈 |
| — depth filter: **narrow-range filter** (Truong & Yuksel 2018) | Considers only depths within a narrow range, handles the rest explicitly → smooth surfaces **and** preserved discontinuities; "computationally efficient" [30] 📄; used by Splash and the WebGPU PBF [8][19] | ✅ overhead "not that much" vs bilateral [19] | ✅ | 🥇 **default filter** |
| — **narrow-band** SSFR (CGF 2022) | Filter only a band of boundary particles: 2.4× faster than NRF alone, −44 % memory [31] 📄 | ✅ | ✅ | 🥈 optimisation once particle counts grow |
| **SDF / density-grid ray-march** | Build a density or SDF grid from particles (an extra P2G), ray-march for surface, shadows, absorption; Niagara uses SDF + jump-flood + Single Layer Water material [14]; Splash ray-marches its density grid for shadows [19] | ⚠️ affordable at low grid res; Splash does it in a browser [19] | ✅ **this is the RTX tier**: true refraction chains, caustics, RT reflections on the SDF surface | 🥈 GTX (shadows only) → 🥇 RTX |
| **Mesh extraction** (marching cubes / mesh shaders on a bilevel grid) | Explicit triangle surface each frame; Breakpoint does it with mesh shaders [23] | ⚠️ mesh shaders = Turing+ ; MC is heavy | ✅ | 🥉 for RT integration only |
| **Anisotropic kernels** (Yu & Turk) | Reconstruct a smooth implicit surface from particle covariance | ❌ offline-grade | — | ❌ |
| **Foam / spray / bubbles** (Ihmsen et al. 2012) | Secondary particles from trapped air + wave crests; needs neighbour data [17] | ⚠️ | ✅ | 🥈 phase F2 (screen-space foam from thickness/velocity first, as Sea of Thieves does [1]) |
| **Volume ray-march for smoke/fire** | 3-D texture ray-march, half-res with edge-aware upsample [24] | ✅ | ✅ RT shadows/scatter | 🥇 for phase F3 |

---

## 4. Platform notes for the experiment (WebGPU)

* Browser reach today: Chrome/Edge 113+, Firefox 141+ on Windows, Safari 26 (macOS Tahoe/iOS 26) [32]. Chrome on Windows sits on D3D12, so it runs on the same GTX cards the engine targets.
* **WGSL atomics are `i32`/`u32` only** — no float `atomicAdd` [26][27]. P2G scatter therefore uses fixed-point integers (WebGPU-Ocean: ×1e7; pbmpm: same idea; toji: quantise-then-dequantise for normals) [17][22][27]. Same constraint exists on Metal for Niagara, which is why its FLIP breaks there [15] — our design must not depend on float image atomics anyway.
* Kernels written in WGSL run **unchanged** natively through Dawn or wgpu-native (`webgpu.h`, D3D12/Metal/Vulkan back ends) [33] — so nothing from the browser experiment is throw-away; the C++ engine can host the same pipelines later.
* Our shaders are Slang; Slang → WGSL is listed **experimental / WIP** [34], but a working CMake pipeline that transpiles Slang to WGSL at build time (with reflection-generated bindings) exists [35]. Plan: write the F1 kernels in WGSL directly (small, ~6 kernels), port to Slang when they move into `Engine/` for the Vulkan path.
* Reference implementations to read first: WebGPU-Ocean (MLS-MPM + SPH + SSFR, TypeScript) [17]; Splash (NRF, 1 sub-step, density ray-march) [19]; EA pbmpm (2-D, BSD-3, "SIGGRAPH 2024" branch is the readable one) [22]; nialltl's MPM guide (the volume-recompute trick) [36]; Ten Minute Physics #18 for FLIP if we ever need the grid-pressure variant [37].

---

## 5. Recommendation — tiered water for GTX→RTX

| Tier | Hardware | Simulation | Rendering | Budget target |
|---|---|---|---|---|
| **T0 — everywhere** | any GTX (Kepler+) | FFT ocean + heightfield SWE for rivers/shore/puddles + wave particles for wakes; Jolt buoyancy samples the heightfield (`ApplyBuoyancyImpulse`) | Heightfield mesh, Fresnel/refraction/absorption, screen-space foam | ≤ 2 ms |
| **T1 — local 3-D liquid** | GTX 10xx/16xx class | **MLS-MPM → PB-MPM**, 50–300 k particles in a local domain (pools, splash zones, mud, sand), 1–2 sub-steps | Screen-space (depth splat → **narrow-range filter** → thickness → shade), half-res | 3–5 ms |
| **T2 — RTX** | RTX 20xx+ | Same solver, ~1 M particles, finer grid | Density/SDF grid ray-march with refraction + caustics; RT reflections via the existing hardware-AS path | 6–10 ms |
| **Smoke / fire (F3)** | any GTX | Eulerian 3-D grid (GPU Gems 3 ch. 30) | Half-res volume ray-march + edge upsample | 2–4 ms |
| **Cloth (F4)** | any | Jolt soft bodies (CPU, XPBD) for gameplay cloth; GPU XPBD later for hero cloth | ordinary mesh | CPU |

Runner-up if MPM disappoints in the experiment: **PBF** with a counting-sort grid [6][7][8] — same rendering stack, so the renderer work is never wasted.

---

## 6. Experiment plan — `Projects/Project-Fluid` (WebGPU, browser first)

Goal of F1: a **dam-break in a box** with a measured particle count at 60 Hz on the user's GTX, rendered with SSFR + NRF, and the same numbers on any RTX available — one HTML page, no build step beyond `npm run serve`.

1. **F1.0 harness** — canvas, camera, GPU timestamp queries (`timestamp-query` feature) per kernel, CSV export like `--trace`. Static box domain 64³ cells.
2. **F1.1 MLS-MPM water** — kernels: clear-grid, P2G (fixed-point atomics), grid update (gravity, boundary), G2P (APIC C matrix), volume recompute; Tait EOS. Proof: mass conserved (Σ fixed-point mass), free surface settles level, no particles leave the box.
3. **F1.2 SSFR** — depth splat, NRF (Truong-Yuksel), thickness, normal + shade with a cubemap; half-res toggle.
4. **F1.3 PB-MPM** — swap the explicit step for k iterations of P2G↔G2P per step (EA reference), compare stability vs sub-steps at equal cost.
5. **F1.4 interaction** — a kinematic box (Jolt-shaped SDF) dragged through the water, one-way coupling; later two-way via impulse sums read back to Jolt.
6. **Exit criteria** to leave WebGPU for `Engine/`: T1 budget met at ≥ 100 k particles on the GTX; kernels stable at 1 sub-step; a documented data layout that Dawn/native can host.

Open decision (not made here): browser page (TypeScript + WGSL, fastest to iterate, no toolchain) **vs** native Dawn/wgpu-native in C++ under `ToolchainSequence.ps1` (fits repo conventions, adds a heavy dependency). Recommendation: browser for F1.0–F1.3, native only when kernels are frozen.

---

## Sources

[1] Ang, Catling, Cifariello Ciardi, Kozin — *The Technical Art of Sea of Thieves*, SIGGRAPH 2018 Talks — https://history.siggraph.org/wp-content/uploads/2022/09/2018-Talks-Ang_The-Technical-Art-of-Sea-of-Thieves.pdf
[2] Jan-Bart van Beek (Guerrilla) on Horizon Forbidden West's wave system — https://www.gamesradar.com/horizon-forbidden-west-dev-explains-why-its-water-looks-so-unbelievably-good/
[3] Stephen Thompson — *Shallow Water Demo* (Kurganov-Petrova on GPU, limitations) — https://www.solarflare.org.uk/shallow_water ; virtual-pipes derivation: https://lisyarus.github.io/blog/posts/simulating-water-over-terrain.html
[4] Crimson Desert shoreline (SWE particles, ~250 k; secondary source quoting the developer) — https://tech.sportskeeda.com/gaming-news/crimson-desert-water-tech-might-dethrone-xbox-game-studios-finest
[5] *From a calm puddle to a stormy ocean — Rendering water in Uncharted* (SIGGRAPH 2012 talk; page also carries the wave-particles abstract) — https://www.researchgate.net/publication/254463329_From_a_calm_puddle_to_a_stormy_ocean_-_Rendering_water_in_Uncharted
[6] Macklin & Müller — *Position Based Fluids*, ACM TOG 32(4), 2013 — https://dl.acm.org/doi/abs/10.1145/2461912.2461984
[7] Hoetzlein — *Fast Fixed-Radius Nearest Neighbors: Interactive Million-Particle Fluids*, NVIDIA GTC 2014 — https://ramakarl.com/pdfs/2014_Hoetzlein_FastFixedRadius_Neighbors.pdf
[8] LinzhouLi — WebGPU PBF with narrow-range filter — https://github.com/LinzhouLi/WebGPU-Fluid-Simulation
[9] Killing Floor 2 FleX requirements (GTX 770 min / 980 rec.) — https://www.pcgamingwiki.com/wiki/Killing_Floor_2
[10] NVIDIA (S. Schirm) on PhysX 5 particles vs FleX — https://github.com/NVIDIA-Omniverse/PhysX/discussions/129 ; context https://www.reddit.com/r/gamedev/comments/18fzldn/why_did_nvidias_flex_physics_not_take_off/
[11] Koschier, Bender, Solenthaler, Teschner — *A Survey on SPH Methods in Computer Graphics*, CGF 41(2), 2022 — https://onlinelibrary.wiley.com/doi/abs/10.1111/cgf.14508
[12] Zhu & Bridson — *Animating Sand as a Fluid* (FLIP/PIC), 2005 — https://www.cs.ubc.ca/~rbridson/docs/yzhu_msc.pdf
[13] Jiang, Schroeder, Selle, Teran, Stomakhin — *The Affine Particle-In-Cell Method*, SIGGRAPH 2015 — https://dl.acm.org/doi/10.1145/2766996
[14] Asher Zhu (Epic) — *Darkhold of Niagara* (Niagara Fluids internals: PIC/FLIP, SDF/jump-flood renderer) — https://asher.gg/darkhold-of-niagara/
[15] Niagara 3-D liquids and float image atomics on Metal — https://www.reddit.com/r/macgaming/comments/1qlglw3/m4_max_1640_unreal_engine_572_gpu_deep_dive/
[16] Epic — *Niagara Fluids Quick Start* — https://dev.epicgames.com/documentation/en-us/unreal-engine/niagara-fluids-quick-start-guide-for-unreal-engine
[17] matsuoka-601 — *WebGPU-Ocean* (MLS-MPM in WebGPU, numbers, fixed-point P2G) — https://github.com/matsuoka-601/WebGPU-Ocean ; Hu et al. 2018 MLS-MPM paper linked there: https://yzhu.io/publication/mpmmls2018siggraph/paper.pdf
[18] matsuoka-601 portfolio (Splash: up to ~1 M particles) — https://matsuoka-601.github.io/
[19] matsuoka-601 — *Splash* (NRF, single sub-step, density ray-march) — https://github.com/matsuoka-601/Splash ; discussion https://www.reddit.com/r/GraphicsProgramming/comments/1jh3pd2/splash_a_realtime_fluid_simulation_in_browsers/
[20] Gao, Wang, Wu, Pradhana, Sifakis, Yuksel, Jiang — *GPU Optimization of Material Point Methods*, SIGGRAPH Asia 2018 — https://github.com/kuiwuchn/GPUMPM
[21] Lewin (EA SEED) — *A Position Based Material Point Method*, SIGGRAPH 2024 — https://www.ea.com/seed/publications ; https://www.researchgate.net/publication/382387434_A_Position_Based_Material_Point_Method
[22] EA — pbmpm WebGPU reference (BSD-3) — https://github.com/electronicarts/pbmpm
[23] *Breakpoint* — 3-D PB-MPM in DirectX 12 with mesh-shader surfacing — https://github.com/danieljgerhardt/Breakpoint
[24] Crane, Llamas, Tariq — *Real-Time Simulation and Rendering of 3D Fluids*, GPU Gems 3 ch. 30 — https://developer.nvidia.com/gpugems/gpugems3/part-v-physics-simulation ; PDF https://www.cs.cmu.edu/~kmcrane/Projects/GPUFluid/paper.pdf
[25] Zibra Liquids (proprietary, DX11/12) — https://www.gamespress.com/AI-powered-solution-for-real-time-liquid-physics-simulation-Zibra-Liqu
[26] WGSL atomics proposal (`i32`/`u32` only) — https://github.com/gpuweb/gpuweb/issues/1360
[27] toji — WebGPU best practices: quantised atomics for float accumulation — https://toji.dev/webgpu-best-practices/compute-vertex-data.html ; https://stackoverflow.com/questions/77979809/equivalent-to-float-atomicadd-in-webgpu
[28] van der Laan, Green, Sainz — *Screen Space Fluid Rendering with Curvature Flow*, I3D 2009 — https://www.researchgate.net/publication/220792184_Screen_space_fluid_rendering_with_curvature_flow
[29] Green — *Screen Space Fluid Rendering for Games*, GDC 2010 — https://developer.download.nvidia.com/presentations/2010/gdc/Direct3D_Effects.pdf
[30] Truong & Yuksel — *A Narrow-Range Filter for Screen-Space Fluid Rendering*, I3D / PACMCGIT 2018 — https://ttnghia.github.io/posts/narrow-range-filter/
[31] *Narrow-Band Screen-Space Fluid Rendering*, Computer Graphics Forum 2022 — https://www.researchgate.net/publication/359849957_Narrow-Band_Screen-Space_Fluid_Rendering
[32] WebGPU browser support matrix — https://www.testmuai.com/learning-hub/webgpu-browser-support/
[33] Dawn (native WebGPU, `webgpu.h`, D3D12/Metal/Vulkan) — https://github.com/hexops/dawn
[34] Slang target table (WGSL experimental) — https://github.com/shader-slang/slang
[35] eliemichel — *SlangWebGPU* (Slang → WGSL at build time, C++ native + web) — https://github.com/eliemichel/SlangWebGPU
[36] nialltl — MLS-MPM guide + `incremental_mpm` — https://github.com/nialltl/incremental_mpm
[37] Müller — Ten Minute Physics #18, *How to write a FLIP Water Simulator* — https://matthias-research.github.io/pages/tenMinutePhysics/index.html
