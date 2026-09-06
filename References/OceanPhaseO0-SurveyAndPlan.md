# Ocean phase O0 — 2023–2026 survey and the WebGPU ocean plan (`Projects/Project-Ocean`)

Branch `arena/01a071a3-slate`, 2026-09-06. Companion to `FluidPhaseF1-RecentSurveyAndWebGpuPlan.md` (fluids) and
`FluidPhaseF2-AdaptivePlan.md` (adaptive lanes, paused behind this work by the user's ordering: **ocean report → WebGPU
ocean sim → WebGPU smoke & fire sim → C++ port**).

The brief: a **large body of water** for the engine that is *real time on a GTX-class card, scales up on RTX*, with **foam
and splashes of our own, switchable per quality tier / enable flag**, and that beats Unreal's water on **both quality and
speed**. Everything in §1–§4 is **2023–2026**: peer-reviewed (TOG/SIGGRAPH, Applied Ocean Research, JMSE, ASCE), arXiv,
first-party engine documentation, shipped-product measurements, or vendor/browser status pages. A short pre-2023
appendix (§7) is kept only for the production recipes the 2023–2026 work still descends from; nothing in the
recommendation depends on it alone.

Legend 🥇🥈🥉 ranking for our goal · ✅ fits · ⚠️ with caveats · ❌ does not fit · 🏭 shipped / studio-owned · 🧪 runs in
WebGPU today · 📄 peer-reviewed or first-party · ⚡ GPU-native · 🐢 CPU or offline · 🎚️ natural quality-tier switch

---

## 0. The one-paragraph answer

**Cascaded spectral (FFT) ocean as the base, with a breaking-energy foam tier, a shallow-water "shoal" patch tier for
shorelines and wakes, and our existing PB-MPM particle lane as the splash tier.** Unreal's Water plugin is, as the user
suspected, a *shader*: a sum of Gerstner waves in World Position Offset on quadtree-LOD tiles [9][10]. The only 2024
apples-to-apples measurement we found puts UE5's ocean at **9.54 ms** on an RTX 2060 at 1280×800 (89 FPS) against an FFT
ocean (NVIDIA WaveWorks 2.0) at **3.87 ms** in the same scene [7] — and a modern cascaded FFT is far cheaper than
WaveWorks: **0.08–0.11 ms of simulation and ≈ 1.06 ms of rendering at 1440p on an RTX 4070** after FP16 textures and LOD
[4]. The FFT base is also *better*: a statistically correct sea from a measured or model spectrum (JONSWAP/TMA) instead
of hand-stacked sine waves [1][3], with physically motivated foam from the Jacobian *and* the vertical-acceleration
breaking criterion [1]. Neither Unreal nor Unity ships breaking shoreline waves or physical splashes (Unity says so
explicitly [8]; Unreal's docs offer ripple/wake fluid-sim samples, not breakers or spray [10][11]); those are exactly the tiers our tile/particle lanes already
give us, so they are the differentiators — each behind a flag so the GTX profile can run the base alone.

---

## 1. What we are competing with (first-party facts)

| Engine | Wave model | Mesh / LOD | Foam | Breaking waves / splashes | Interaction | Known costs and limits |
|---|---|---|---|---|---|---|
| **Unreal 5.x Water plugin** 🏭 [9][10] | **Gerstner sum** per water body (Num Waves, wavelength/amplitude/steepness ranges + falloff, dominant wind angle + spread, seed); micro detail = material normal maps; custom generators via C++/Blueprint | Spline-defined bodies on one shared water mesh; **quadtree traversed each frame**, concentric LOD rings each with half the vertices of the previous | material-driven | none physical; ripples/wakes "cosmetic" (fluid-sim samples in the content folder) [10][11] | buoyancy component (CPU Gerstner queries) | measured **9.542 ms / 89 FPS** on an RTX 2060 at 1280×800 in [7] (full UE material — see the caveat in §2); no built-in FFT as of 5.7 [11] |
| **Unity HDRP Water (2022 LTS/2023.1 →)** 🏭 [8] | **FFT**, up to **3 frequency bands** (Swell/Agitation/Ripples; Pool 1, River 2, Ocean 3) on a repeated square patch; per-band fade with distance | quad/“infinite” surface, water mask, deformers | wind-speed "dimmer" drives simulation foam amount + lifespan; foam generators; **monochrome** | **explicitly none**: "no breaking waves on shorelines"; "focuses on plane deformation, not fluid or splash simulation" | decals, excluders, foam generators; optional **CPU mirror** (Burst) for height queries that "doubles the work" | no motion vectors (TAA/DLSS ghosting), MSAA incompatible |
| **Crest Water (Unity, 5.x release notes)** 🏭 [17] | FFT/Gerstner cascades centred on the viewer | pop-free multi-scale mesh matched 1:1 to texels | simulated foam LOD chain (feedback blur) | none | **dynamic-wave sim** (2-D) deposits foam for wakes; input culling per LOD | per-simulation resolution and texture format now configurable (5.0), VRAM reductions (5.8.2) |

Take-away for "beat Unreal": the base bar is *cheap Gerstner + good material*. Our base must therefore be **≤ its cost at
equal resolution** (an FFT cascade set clears that by a wide margin, §2) and must add the things it cannot do: spectral
realism, breaking foam, shoreline behaviour, real splashes.

---

## 2. The 2023–2026 landscape

| Year | Work | Kind | What it gives us | Measured speed | Verdict |
|---|---|---|---|---|---|
| 2024 | **Donatini et al.** — *Physically accurate real-time synthesis of ocean waves for maritime simulators*, Applied Ocean Research 143 📄 ⚡ [1] | multi-band FFT, CUDA | Input **frequency/direction spectrum** (measured buoy data *or* JONSWAP-class models) mapped at runtime onto **N wavenumber synthesis bands**; recommended default **3 bands × 512² at 16 m / 4 m / 1 m spacing**; the **ψ = 4 rule** that drops short waves the band cannot resolve (an aliasing source "never described before"); foam from **Jacobian ≤ threshold** *or* **vertical acceleration ≤ −0.39 g** (Chen et al.; consistent with Miche's 1/7 steepness, −0.45 g at a breaking crest); depth-dependent ω per wavenumber as a first shallow-water approximation | "real time even on older GPUs" at 3×512²; per band 5–6 inverse DFTs; cost split: spectrum update ≈ 10 %, derivatives ≈ 7 %, texture writes ≈ 24 % | 🥇 **base-tier recipe** (bands, ψ rule, both foam criteria) |
| 2024/25 | **Donatini et al.** follow-up — floating-body RAO responses on the GPU, Applied Ocean Research (10.1016/j.apor.2024.104393) 📄 [2] | buoyancy from the same spectrum | Body motion computed from the *spectrum* (response amplitude operators) instead of sampling the height field — the cheap path to boats on the RTX tier | — | ⚠️ later (Project-Physics coupling) |
| 2025–26 | **R. Ryan** — *Ocean Rendering* Part 1 (theory, Oct 2025) and Part 2 (profiling, Mar 2026), code on GitHub ⚡ [3][4] | cascaded FFT, DX12/Vulkan | TMA spectrum + Donelan–Banner spreading, 4 cascades; the **profiling record we plan against**: RTX 4070 @1440p, 4 cascades × 2 × 256² textures → **simulation 0.08–0.11 ms**; rendering **4.03 ms → 1.06 ms** via FP16 textures (−1.3 ms), an index buffer (−0.37), Z-curve indices (−0.14), repacking and **LOD (−1.31)**; a CPU-frustum-culled 16×16 set of 128² tiles was *slower* than one **2048² vertex-shader-generated grid**; bottleneck is L1TEX from per-vertex cascade sampling | as left | 🥇 **performance template** (what to build first, what to measure) |
| 2025 | **Real-Time Interactive Hybrid Ocean: Spectrum-Consistent Wave Particle–FFT Coupling** (arXiv 2511.02852, SJTU) 📄 ⚡ [5] | FFT far field + local wave-particle patches | Particles injected at the patch rim from the **same JONSWAP spectrum** (A = √(2 S Δω Δθ), r = πg/ω², c = g/ω, equal-energy frequency buckets), so boats/objects get reflection, diffraction and wakes without a seam | Table 2: FFT-only 512² **2000+ FPS**; wave-particles alone 4 FPS; hybrid (16,16) patches 86 FPS, (12,12) 139, (8,8) 306; 1024² 56 FPS; wind 3/10/15 m·s⁻¹ → 39/220/318 FPS | 🥈 **interaction tier (deep water)**; limits: no feedback from patches to the far field, no adaptive sampling |
| 2023 | **Jeschke & Wojtan** — *Generalizing Shallow Water Simulations with Dispersive Surface Waves*, TOG 42(4) (SIGGRAPH 2023) 📄 ⚡ [6] | height field: SWE bulk flow + Airy waves | One height-field solver for **flooding, eddies, boat wakes with correct dispersion, run-up onto a beach**: decompose into bulk flow (Stelling–Duinmeijer finite volume, exact volume conservation) + surface waves (eWave exponential integrator with an exact numerical-dispersion correction β); depth handled with 4 Airy solves at {1, 4, 16, 64} m (≤ 8 % speed error) | CUDA on an **RTX 2080 Max-Q laptop**: 512² at Δx = 1 m, **> 40 FPS with rendering, ≈ 100 FPS simulation only**; the diffusion-based decomposition is **87 %** of the cost (128 explicit sub-steps) | 🥈 **shoal-tier reference**; the *bulk SWE half* is what we port first (cheap), the Airy half only where dispersion is visible |
| 2024 | **Duan, Liu, Wang** — *Real-Time Wave Simulation of Large-Scale Open Sea Based on Self-Adaptive Filtering and Screen-Space LOD*, JMSE 12(4) 📄 ⚡ [7] | Gerstner in screen-space projected grid + per-pixel analytic normals + wavelength low-pass by projected size | Two things we take: (a) the **only published 2024 side-by-side against UE5's ocean we found** (Table 1, RTX 2060, 1280×800, 100 waves: theirs 0.553 ms; **WaveWorks 2.0 FFT 3.872 ms; Unreal 5 ocean 9.542 ms / 89 FPS**; quadtree tessellation 6.147 ms); (b) the horizon lesson — filter wavelengths below the projected pixel size or the horizon aliases | 60 waves: 0.184 ms modelling at 6 m camera height | ⚠️ their scoring uses a simple shader while UE5 ran its full material — treat the UE5 number as an upper bound, not a like-for-like; screen-space grids also break under camera roll (they patch it) |
| 2021–2025 | **Fluid Flux 3.0** (ImaginaryBlend, UE 4.26–5.5, updated Jan 2025) 🏭 ⚡ [12] | 2-D SWE heightfield + ocean blend | The most-used shipped SWE water in Unreal; honest published limits: **no wave-break effect** ("the fluid approximation lacks the data"), axis-aligned non-movable domains, ≤ 1024² recommended, Niagara readback one frame late | **RTX 3080 1440p 320–380 FPS (river) / 260–310 (island); RTX 2080 160–200 / 110–160; GTX 860M 1080p 25–30 / 20–25**; sim 0.3–0.5 ms + 1.0–1.5 ms rendering | 🥉 cost reference for an SWE patch on GTX-class hardware |
| 2026 | **Realistic Shoreline & Ocean Waves** (Reboot16, Godot 4.7, MIT) 🏭 ⚡ [13] | nonlinear SWE finite-volume on GPU | Waves **shoal, break as bores, run up and drain back**; foam advected by the real current; wet sand | RTX 4070 laptop 1080p: beach **608² cells at 5 cm → 60 FPS**; 2×2 km island 4.2 M cells → 28 FPS; open ocean 200+ FPS | ✅ proves the SWE shoreline tier is game-rate on mid hardware when the domain is small and camera-local |
| 2026 | **Celeris-WebGPU** — *An Interactive Nearshore Wave Simulator…*, ASCE J. Waterway Port Coastal Ocean Eng. 📄 🧪 ⚡ [14] | Boussinesq / NLSW in **WebGPU** | Depth-integrated phase-resolving waves (enhanced and fully nonlinear extended Boussinesq), hybrid FV–FD, validated on regular wave breaking on a beach and run-up on a conical island | "faster than real time on typical desktop hardware within a web browser" | 🧪 the existence proof that our O2 shoal patch is buildable in WGSL |
| 2024 | **Skull and Bones** (Ubisoft Singapore, Anvil) — Digital Foundry tech review 🏭 [15] | FFT-class sea + particles | "The particle system developed for near-shore waves cresting: a white swarm of particles interacts with whatever it collides with"; spray at hull; SSS by crest thickness — i.e. a shipped **particle splash tier on top of a spectral sea** | console performance modes (DF notes drops only in the hub on PS5/Series S) | ✅ confirms the tiered design ships in AAA |
| 2024 | **Still Wakes the Deep** (The Chinese Room, UE 5.3) — 80.lv / Creative Bloq 🏭 [16] | Niagara **2-D SWE** indoors + Gerstner sea | Meshes baked into a heightmap as SWE boundaries; "pumps" inject velocity; Niagara GPU readback for buoyancy | — | ✅ same split as ours: cheap global sea + local simulated patch |
| 2024–26 | **UE5 community/vendor practice** — StraySpark guide 🏭 ⚠️ [11] | — | Third-party but consistent with the docs: no built-in FFT (5.7), Gerstner is "global — no locally calm/rough water", interaction "cosmetic"; Niagara Grid2D 256² ≈ 0.1–0.3 ms, SPH 50 k ≈ 0.2–0.5 ms as typical budgets | — | ⚠️ use only as corroboration |
| 2025–26 | **FFT oceans already in WebGPU**: Three.js Water Pro (3 JONSWAP cascades, Jacobian foam, clipmap, WebGPU/TSL) [18]; Popov72's Babylon.js WebGPU port of gasgiant's FFT-Ocean [19] 🧪 ⚡ | — | Cascaded FFT + Jacobian foam + clipmap is routine in the browser now; nothing in the base tier needs a native API | — | 🧪 platform risk for O1 ≈ zero |
| 2026 | **WebGPU platform**: `shader-f16` available on **95 %** of hardware adapters (webgpu.report, Aug 2026; Chrome 95.5 %, Firefox 97.2 %) [20]; `subgroups` shipped in Chrome 134 (see F1 [23]) | platform | Ryan's biggest single win (FP16 cascade textures, −1.3 ms) is reproducible in WGSL; `rgba16float` storage textures are core regardless | — | ✅ |

---

## 3. Quality *and* speed against Unreal — where each tier wins

| Property | Unreal Water plugin (Gerstner shader) | Ours (recommended) | Why it is better, with the source |
|---|---|---|---|
| Wave statistics | N hand-ranged Gerstner waves; repetitive at distance; cost grows per wave; "20+ layers for convincing results" [9][11] | Spectral sea: JONSWAP/TMA + Donelan–Banner spreading, 3–4 bands; fixed cost independent of wave count [1][3] | Correct energy distribution and directional spread from oceanography; cost is O(N log N) per band, not O(waves × verts) |
| Cost of the base | 9.54 ms measured in [7] (upper bound, full material) | FFT simulation 0.08–0.11 ms + ≈ 1 ms draw on an RTX 4070 [4]; GTX estimate §4 | Even ×5 slower on a GTX 1060-class card the base stays ≈ 3 ms at 1080p |
| Horizon | Tile LOD; aliasing at the horizon noted in [7] | Wavelength cut by projected size (ψ rule per band [1]; low-pass by pixel footprint [7]) + slope-variance roughness (§7 LEADR lineage) | No shimmer, cheaper far field |
| Foam | Material masks | Breaking-energy texture from **J < 0.3–0.5** *or* **α_z ≤ −0.39 g** [1], decay + blur, stretch/squeeze modulation, contact foam from depth | Foam appears where waves physically break, persists and drifts |
| Shoreline | Shoreline blend only; no shoaling | SWE shoal patch: shoaling, bores, run-up, drain-back [6][13][14] | Unity states it cannot do this at all [8] |
| Splashes / spray | Cosmetic Niagara particles [11] | PB-MPM particle lane spawned by the breaking mask and impacts, mass exchanged with the height field (§4 tier 3) | Real fluid particles that carry momentum and rejoin the surface |
| Interaction | Ripple sim samples; global wave field | SWE patch for wakes/run-up; spectrum-consistent wave-particle patches on RTX [5] | Wakes with correct dispersion; no seam with the far field |
| Buoyancy queries | CPU Gerstner evaluation | GPU displacement window read back asynchronously (Crest [17]), or RAO from the spectrum [2] | No CPU mirror ("doubles the work" in Unity [8]) |
| Temporal AA | — | We write motion vectors from the displacement delta (Unity lacks them → ghosting [8]) | Stable under TAA/DLSS |
| Scalability | one quality | **Tiers**: surface → +foam → +shoal → +splashes → +breakers; each a flag | GTX runs tier 0–1; RTX all |

---

## 4. Recommendation — the tiered ocean (best choice for GTX → RTX)

### Tier 0 — Spectral surface (always on)
* **Bands**: GTX profile **3 × 256²** (spacings ≈ 16 m / 4 m / 1 m as in [1] but at 256² → patch lengths 4096 / 1024 / 256 m); RTX profile **4 × 512²** (adds a capillary band at 0.25 m). Per band 8 real fields packed as 4 complex FFTs: h, δx, δy, ∂h/∂x, ∂h/∂y, ∂δx/∂x, ∂δy/∂y, ∂δx/∂y (the two-texture RGBA16F layout Ryan profiled [4]); Jacobian and slopes come free from those derivatives.
* **Spectrum**: JONSWAP with TMA depth correction and Donelan–Banner spreading [3]; swell parameter à la Horvath (§7) for long-crested swell; ψ = 4 exclusion of under-resolved waves per band [1]; the same input spectrum can later be a measured buoy spectrum [1].
* **FFT in WGSL**: Stockham radix-2 in workgroup memory, one row per workgroup (256 threads; at 512² two elements per thread to stay under the default 256-invocation limit); horizontal then vertical pass; `rgba16float` outputs, `f16` arithmetic when `shader-f16` is present [20].
* **Mesh**: one vertex-shader-generated grid centred on the camera with a horizon skirt (Ryan measured it faster than CPU-culled tiles [4]); LOD by dropping bands with distance (fade ranges as in Unity [8]); optional clipmap later.
* **Shading**: Fresnel + refraction with depth fog, SSS on thin crests from a wave-peak mask, slope-variance (LEADR-lineage) roughness so the far field stays sharp, motion vectors from the displacement delta.
* **Budget**: RTX 4070 class ≈ 0.1 ms sim + ≈ 1 ms draw at 1440p [4]. **GTX 1060-class estimate ≈ 0.4–0.5 ms sim + ≈ 2–3 ms draw at 1080p** — spec-sheet arithmetic (a GTX 1060 has ≈ 0.4× the bandwidth and ≈ 0.15× the FP32 of a 4070, and the FFT is bandwidth/L1-bound), to be *replaced* by the user's GTX CSV from O1, not trusted.

### Tier 1 — Foam 🎚️ (`foam=1`, default on for both profiles)
* Breaking mask per band: **J < threshold (0.3–0.5)** *or* **vertical acceleration ≤ −0.39 g** [1] (one extra inverse DFT per band for α_z, or reuse ∂²h/∂t² from two frames).
* The mask **injects energy** into a persistent foam texture: exponential decay, small blur, advection by the band's horizontal displacement; density modulated by J (stretched J > 1 → thinner, squeezed → thicker) — the production recipe from §7 [B5][B6].
* Contact foam from the depth buffer where geometry meets the surface; foam also whitens the refraction ("milkiness").
* Cost ≈ 0.1–0.2 ms (one 2-D pass + one IDFT per band).

### Tier 2 — Shoal patch 🎚️ (`shoal=1`; GTX 256², RTX 512²–1024²)
* A camera-centred **shallow-water height field** (Stelling–Duinmeijer finite volume — the exactly-conserving half of [6]) over the terrain height map: shoaling, bores, run-up, drain-back, wakes, footsteps. Cost references: Fluid Flux 0.3–0.5 ms sim on an RTX 3080 [12], the Godot NLSW beach 608² at 60 FPS on a 4070 laptop [13], Celeris in WebGPU [14].
* Blend with tier 0 by depth: FFT bands attenuate with depth (Donatini's depth-dependent ω [1]; Crest's depth attenuation [17]); inside the patch the SWE height is added, its slope replaces the FFT normal where |∇h| is large.
* Bores mark the foam texture and (tier 3) spawn particles. Dispersion-correct wakes (the Airy half of [6], 87 % of its cost) and spectrum-consistent wave particles [5] are the **RTX-only** extension.

### Tier 3 — Splashes 🎚️ (`spray=1`; RTX default, GTX optional)
* **Reuse `Projects/Project-Fluid`'s PB-MPM lane** (`ParticleSolver.wgsl`, tile oracle `MarkTiles`, SSFR renderer): particles are **born** where the breaking mask fires (tier 1) or a bore forms (tier 2) or a body impacts, seeded with the surface velocity + the crest's horizontal velocity; they **die back** into the height field, returning height and momentum (the Chentanez–Müller hand-off, §7 [B4]). Skull and Bones ships exactly this split [15].
* Budget by tier: GTX ≤ 20–50 k particles in ≤ 3 ms (the exact number waits for the user's `?resolution=64&perkernel=1` CSVs); RTX 200 k+. Camera-distance particle LOD from F1.5 applies unchanged.

### Tier 4 — Breakers 🎚️ (`breakers=1`; RTX / quality)
* Overhanging, tube-forming waves are **not** a height-field phenomenon. Two routes, decided in O4 after O1–O3 data: (a) **baked cross-section vector displacement** swept along wavefront curves, generated in a compute shader — Guerrilla's Horizon Forbidden West recipe, proven on PS4 (§7 [B1]); (b) SWE bores at 5–10 cm cells + tier-3 particles for the white water (the Godot route [13]). (a) gives the curl, (b) gives the physics; both feed the same foam and spray textures.

### Why not the alternatives
* **Gerstner-only (Unreal's choice)** ❌ — cheaper only at small wave counts; cannot reach spectral realism or physical foam, and [7] measured UE5's implementation slower than an FFT.
* **Screen-space projected grid (Duan 2024)** ⚠️ — fastest published Gerstner, but roll/underwater/aquarium views need patches and it is still Gerstner; we keep only its horizon low-pass idea.
* **Wave particles everywhere** ❌ — 4 FPS alone in [5]; only as local patches.
* **Full 3-D fluid ocean (PB-MPM / FLIP everywhere)** ❌ — F1/F2 costs (`FluidPhaseF2-AdaptivePlan.md`) are per 8³ tile; an ocean is a 2-D problem with a 3-D *skin* (tier 3), which is exactly how we tier it.
* **Unity-style CPU mirror for physics** ❌ — "doubles the work" [8]; async GPU readback of a small window [17] or spectral RAO [2] instead.

---

## 5. Fit with our architecture (Frontier / Slate)

* **Same shape as Project-Fluid**: a standalone browser page under `Projects/Project-Ocean` with `GameExecution.js` (host loop, proofs, telemetry, query flags, `window.ProjectOceanExit` 0/2/1), a `…Structure.js` scene/tuning file, and WGSL kernels — all compute + one render pass, nothing WebGPU-exclusive except timestamps (Slang/Vulkan port later, as with fluids).
* **Roles (`<Subject><Role>` names, closed suffixes)**: `SwellSolver.wgsl` (spectrum → bands → FFT), `FoamSolver.wgsl` (breaking mask, decay/blur/advect), `ShoalSolver.wgsl` (SWE patch), `SpraySolver.wgsl` (= the PB-MPM particle lane, shared with Project-Fluid; moved to `Engine/` at port time), `HorizonProjection.wgsl` (grid + shading), `OceanStructure.js`, `GameExecution.js`. Banned/retired words avoided (no Buffer/Data/System/Region/Boundary…); units `[m]`, `[s]`, `[m·s⁻²]`, +Z up.
* **Tiles**: tier 2 and tier 3 are 2-D/3-D lanes of the same 8³-tile idea already measured in F2-A0 (`MarkTiles`): the shoal patch is a dense 2-D grid, the spray lane is sparse tiles allocated only where the mask fires — the F2-A1 sparse lattice is directly reusable.
* **Physics**: Project-Physics (Jolt) samples height/velocity from a small read-back window of tier 0 + tier 2 (one-frame latency like Fluid Flux/SWTD [12][16]); RAO-based motion [2] later.
* **Quality tiers = flags**: `tier=gtx` → 3 × 256², foam on, shoal 256², spray off; `tier=rtx` → 4 × 512², foam, shoal 512²–1024², spray on, breakers optional. Every tier reports `ms` per kernel in the CSV (`perkernel=1`) exactly like Project-Fluid.

---

## 6. The plan — `Projects/Project-Ocean` (WebGPU only; each step a measurable experiment)

| Step | Experiment | Proof / measure | Sources |
|---|---|---|---|
| **O1 Surface + Foam** | JONSWAP/TMA + Donelan–Banner spectrum; 3–4 bands; ψ = 4 exclusion; Stockham FFT in WGSL; `rgba16float` + optional `f16`; vertex-generated grid + horizon fade; Fresnel/SSS/roughness shading; **foam** from J and α_z with decay/blur/advection; motion vectors | (1) **energy proof**: height variance of the synthesised field = ∫S(k) dk within ±5 %; (2) **dispersion proof**: a single seeded wavenumber travels at √(g k tanh kh) within 1 %; (3) foam fraction monotone in wind speed and zero below breaking; (4) trace hash; (5) `perkernel=1` CSV on the user's GTX → replaces the §4 estimates | [1][3][4][7][20] |
| **O2 Shoal** | Camera-centred SWE patch over a terrain height map (Stelling–Duinmeijer FV), depth blend with the bands, bores → foam, wakes from a moving box | mass conservation to 1e-4 over 60 s; run-up height vs the analytic solitary-wave benchmark used by Celeris; ms at 256²/512²/1024² | [6][12][13][14] |
| **O3 Spray** | Attach the PB-MPM lane: birth from the breaking mask/bores/impacts, death back into the height field with mass + momentum return; SSFR render over the surface | mass balance height field ↔ particles; particle-count vs ms curve on GTX and RTX; tier flag off = zero cost | [15][B4] + Project-Fluid |
| **O4 Breakers** (RTX) | Decide (a) baked cross-section displacement vs (b) fine SWE bores after O1–O3 numbers; implement one | visual overhang + foam continuity; ms | [B1][13] |
| **Exit** | Per the user's sequence: after O3 the smoke & fire WebGPU sim (F2-A3 Leapfrog Flow Maps lane) comes next, then the C++ port of Fluid + Ocean + Smoke together | — | `FluidPhaseF2-AdaptivePlan.md` |

Query string planned for O1: `?tier=gtx|rtx`, `bands=3|4`, `size=256|512`, `wind=<m/s>`, `fetch=<km>`, `depth=<m>`,
`swell=0…1`, `foam=0|1`, `shoal=0|1`, `spray=0|1`, `f16=0|1`, `proof=1`, `fixed=1`, `seconds=N`, `perkernel=1`,
`offscreen=1` (SwiftShader runs in the sandbox via `Scratchpad/FluidHeadlessRun.mjs`).

---

## 7. Background, pre-2023 (production lineage only — nothing above rests on these alone)

* [B1] Malan (Guerrilla) — *Rendering Water in Horizon Forbidden West*, SIGGRAPH 2022 Advances in Real-Time Rendering: breaking waves from **one baked animated cross-section** (XYZ offset → RGB rows), applied by a **compute shader** along artist shape/guide/animation curves (Coons-patch interpolation baked to a grid), variation texture for gaps; runs on PS4 — https://advances.realtimerendering.com/s2022/SIGGRAPH2022-Advances-Water-Malan.pdf
* [B2] Horvath — *Empirical directional wave spectra for computer graphics*, DigiPro 2015 (TMA, Donelan–Banner, "swell" parameter; EncinoWaves code, Apache-2) — https://dl.acm.org/doi/10.1145/2791261.2791267 ; https://github.com/blackencino/EncinoWaves
* [B3] Dupuy et al. — *LEADR mapping*, SIGGRAPH Asia 2013 (slope-moment roughness filtering — the horizon anti-aliasing lineage used by Atlas and cascaded-FFT oceans) — https://dl.acm.org/doi/10.1145/2508363.2508422
* [B4] Chentanez & Müller — *Real-time Simulation of Large Bodies of Water with Small Scale Details*, SCA 2010/2011 (height field ↔ spray/splash/foam particles with mass and momentum exchange) — https://matthias-research.github.io/pages/publications/hfFluid.pdf
* [B5] Gaijin / NVIDIA — *Ocean rendering in War Thunder*, CGDC 2015 slides (4 FFT cascades 5 m–1 km, foam = J < 0.3–0.5, turbulent-energy injection with decay and blur, stretch/squeeze modulation)
* [B6] Rare — *The Technical Art of Sea of Thieves*, SIGGRAPH 2018 Talks (FFT via WaveWorks, Jacobian-peak foam + depth-buffer contact foam in a camera window, feedback blur, wave-peak SSS mask)
* [B7] Mihelich & Tcheblokov — *Atlas: Wakes, Explosions and Lighting*, GDC 2019 (LEADR statistics from the FFT, interactive wakes) — https://www.youtube.com/watch?v=Dqld965-Vv0
* [B8] Tessendorf — *Simulating Ocean Water*, SIGGRAPH course notes (choppy displacement, Jacobian J⁻ folding criterion) — https://jtessen.people.clemson.edu/reports/papers_files/coursenotes2004.pdf

---

## Sources (2023–2026)

[1] Donatini, L. et al. — *Physically accurate real-time synthesis of ocean waves for maritime simulators*, Applied Ocean Research 143 (2024) 103866 — PDF https://www.vliz.be/imisdocs/publications/80/394980.pdf ; https://doi.org/10.1016/j.apor.2023.103866
[2] Donatini, L. et al. — floating-body responses (RAO) on the GPU from the same spectral pipeline, Applied Ocean Research (2024/25) — https://doi.org/10.1016/j.apor.2024.104393
[3] Ryan, R. — *Ocean Rendering, Part 1 — Simulation* (4 Oct 2025) — https://rtryan98.github.io/2025/10/04/ocean-rendering-part-1.html
[4] Ryan, R. — *Ocean Rendering, Part 2 — Profiling and Optimization* (22 Mar 2026; RTX 4070 numbers) — https://rtryan98.github.io/2026/03/22/ocean-rendering-part-2.html ; code https://github.com/rtryan98/renderer
[5] *Real-Time Interactive Hybrid Ocean: Spectrum-Consistent Wave Particle–FFT Coupling*, arXiv 2511.02852 (Nov 2025) — https://arxiv.org/abs/2511.02852
[6] Jeschke, S., Wojtan, C. — *Generalizing Shallow Water Simulations with Dispersive Surface Waves*, ACM TOG 42(4), SIGGRAPH 2023 — https://dl.acm.org/doi/10.1145/3592098 ; PDF https://d1qx31qr3h6wln.cloudfront.net/publications/Dispersive_Waves_in_a_Shallow_Water_Framework.pdf
[7] Duan, X., Liu, J., Wang, X. — *Real-Time Wave Simulation of Large-Scale Open Sea Based on Self-Adaptive Filtering and Screen Space Level of Detail*, J. Mar. Sci. Eng. 12(4):572 (2024) — https://www.mdpi.com/2077-1312/12/4/572
[8] Unity — *The new HDRP Water System in 2022 LTS and 2023.1* (blog, June 2023) — https://unity.com/blog/engine-platform/new-hdrp-water-system-in-2022-lts-and-2023-1 ; HDRP manual *Water System* overview/properties (@16) — https://docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@16.0/manual/WaterSystem-Overview.html
[9] Epic Games — *Simulating Waves Using the Water Waves Asset* (UE 5.x docs) — https://dev.epicgames.com/documentation/en-us/unreal-engine/simulating-waves-using-the-water-waves-asset-in-unreal-engine
[10] Epic Games — *Water System* and *Water Meshing System and Surface Rendering* (UE 5.x docs) — https://dev.epicgames.com/documentation/en-us/unreal-engine/water-system-in-unreal-engine ; https://dev.epicgames.com/documentation/en-us/unreal-engine/water-meshing-system-and-surface-rendering-in-unreal-engine
[11] StraySpark — *Ocean and Water Simulation in UE5: From the Built-In Water Plugin to FFT Niagara Oceans* (Mar 2026; third-party) — https://www.strayspark.studio/blog/ocean-water-simulation-ue5-guide
[12] ImaginaryBlend — *Fluid Flux* product page (limits, performance table; v3.0.4 Jan 2025) — https://imaginaryblend.com/2021/09/26/fluid-flux/ ; 2023 update numbers — https://www.reddit.com/r/unrealengine/comments/1258tif/fluid_flux_realtime_waterfall_simulation/
[13] Reboot16 — *Realistic Shoreline & Ocean Waves* (Godot 4.7 asset, MIT, 2026) — https://store.godotengine.org/asset/reboot16/waves/
[14] Celeris-WebGPU (P. Lynett's group) — *An Interactive Nearshore Wave Simulator for Rapid Design Prototyping and Natural Hazard Education* (Celeris-WebGPU), ASCE J. Waterway, Port, Coastal, and Ocean Engineering (2026) — https://ascelibrary.org/doi/10.1061/JWPED5.WWENG-2370 ; code https://github.com/plynett/plynett.github.io
[15] Digital Foundry — *Skull and Bones: the good, the bad, the ugly* (2024 tech review) — https://www.digitalfoundry.net/articles/digitalfoundry-2024-skull-and-bones-the-good-the-bad-the-ugly-and-the-utterly-bizarre
[16] 80.lv — *Learn How Still Wakes the Deep Used Unreal Engine 5 to Create Water Mechanics* (Nov 2024) — https://80.lv/articles/learn-how-still-wakes-the-deep-used-unreal-engine-5-to-create-water-mechanics ; Creative Bloq (June 2024) — https://www.creativebloq.com/3d/video-game-design/how-unreal-engine-5-3-made-still-wakes-the-deep-more-terrifyingly-beautiful
[17] Wave Harmonic — *Crest Water* release notes 5.0–5.10 (2024–2025) — https://docs.crest.waveharmonic.com/About/History.html
[18] *Three.js Water Pro* — FFT ocean for Three.js WebGPU (3 cascades, Jacobian foam, clipmap) — https://docs.threejswaterpro.com/
[19] Popov72 — *OceanDemo* (Babylon.js WebGPU port of gasgiant's FFT-Ocean) — https://github.com/Popov72/OceanDemo ; gasgiant — *Ocean-URP* — https://github.com/gasgiant/Ocean-URP
[20] webgpu.report — `shader-f16` availability (95.3 %, Aug 2026) — https://webgpu.report/features/shader-f16 ; Chrome 133/134 subgroups notes — https://developer.chrome.com/blog/new-in-webgpu-133
