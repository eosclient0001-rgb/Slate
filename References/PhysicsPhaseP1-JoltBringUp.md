# Physics phase P1 — Jolt bring-up (`RigidBodySolver` + Project-Physics)

Branch `arena/01a071a3-slate`, 2026-09-05. Scope: get Jolt compiling, stepping from a main loop, and a plane with objects
simulating on it — standalone, so it can be merged into the Project-Zero tree (`arena/01a06c54-slate`) as a later row.

## 1. What is in the tree

| Path | Role | Notes |
|---|---|---|
| `ExternalPackages/jolt` @ `2e28006e` | submodule | Same pin as the Project-Zero branch's CLAUDE.md table (Jolt 5.6.1). Shallow. |
| `Scripts/BuildJolt.sh` / `.ps1` | dependency build | Jolt → `ExternalPackages/jolt/lib/<Config>/libJolt.a` (`Jolt.lib`). 138 TUs, rigid-body subset (no GPU compute / hair). No CMake. |
| `Engine/PhysicalDynamics/RigidBodySolver.h/.cpp` | Solver (role 6) | Owns one Jolt `PhysicsSystem`. **The `.cpp` is the only TU that sees `JPH::`** — the header exposes only Frontier records. |
| `Projects/Project-Physics/Source/GameExecution.cpp` | entry point | Main loop with wall-clock Δτ, clamped, one `Solver.Advance(Δτ)` per tick, poses read back each tick. |
| `Projects/Project-Physics/Source/DropSceneStructure.h/.cpp` | Structure (role 13) | Ground plane + 6 boxes + 4 spheres + 2 capsules (counts are CLI flags). |
| `Projects/Project-Physics/Build/ToolchainSequence.sh` / `.ps1` | build | Same shape as Project-Zero's script minus Vulkan/GLFW/shaders. Builds Jolt first when the archive is absent. |
| `CMakeLists.txt` | Linux/IDE | `Jolt` static target + `Project-Physics`. |
| `Engine/DeviceExchange/OrientationClassifier.*`, `DiagnosticMetrics.*` | copied verbatim | From the Project-Zero branch so the solver and the logger compile here; drop this copy on merge. |

## 2. How the solver fits on Tick

```cpp
// once, before the loop
Frontier::RigidBodyConfiguration PhysicsConfig;          // gravity (0,0,-9.81), FixedStepSeconds 1/60, MaxStepsPerAdvance 4 …
Frontier::RigidBodySolver        Physics;
if (!Physics.Bring(PhysicsConfig)) { /* Physics.QueryLastRefusal() */ }
Frontier::RigidBodyIdentity Ground = Physics.CreateBody(PlaneDescription);   // static, CollisionShapeCategory::Plane
Frontier::RigidBodyIdentity Crate  = Physics.CreateBody(BoxDescription);     // dynamic
Physics.OptimizeBroadPhase();                                                // once after the batch, never per frame

// every tick — Project-Zero: after `Camera.AdvanceLocomotion(Input, Δτ)` (step ②), before `Panel.Present` (step ③)
Physics.Advance(Δτ);                 // accumulates Δτ, steps the world 0..MaxStepsPerAdvance times at exactly FixedStepSeconds
Physics.QueryPoses(Poses);           // every resident body: position [m], orientation, velocities, asleep flag
float α = Physics.QueryInterpolationAlpha();   // accumulator ÷ step, for smoothing a pose between two fixed steps

// shutdown
Physics.Retire();                    // destroys bodies, world, job threads; unregisters Jolt on the last solver
```

* `Advance` is frame-rate independent: a 240 Hz loop steps every fourth tick, a 30 Hz loop steps twice per tick. Anything past
  `MaxStepsPerAdvance × FixedStepSeconds` (default 66 ms) is **dropped**, counted in `RigidBodyMetrics::DroppedSeconds` — a hitch
  never replays into a spiral. Project-Zero's own `if (Δτ > 0.1f) Δτ = 0.1f;` clamp stays in front of it.
* Bodies never move outside `Advance`, so the renderer can read poses at any point in the frame without locks.
* Coordinates: Frontier is RH **+Z up, metres**; Jolt is axis-agnostic, so gravity is literally `(0, 0, −9.81)` and no basis
  change exists anywhere. The only axis fix is internal: Jolt's capsule/cylinder run along local **Y**, the solver wraps them in a
  +90° X rotation so a Frontier capsule runs along local **Z** (unit-tested by the capsule drop: it lands lying along Y as authored).
* `RigidBodyIdentity` is a stable `uint32_t` slot for the body's lifetime (freed slots are recycled); Jolt's `BodyID` never leaves
  the `.cpp`. This is the seam the older plan (`References/PhysicsAndGeometryInterchangePlan.md`, branch `01a061e3`) asked for:
  no `JPH::` type crosses the interchange.

## 3. Merge rows for the Project-Zero branch (`arena/01a06c54-slate`)

1. **Submodule** — `git submodule add https://github.com/jrouwe/JoltPhysics.git ExternalPackages/jolt` @ `2e28006e` (it is already
   in that branch's `$SubmoduleList` and `/I` paths; only the gitlink is missing there).
2. **Scripts** — copy `Scripts/BuildJolt.ps1` / `.sh` next to `BuildGLFW.ps1` / `BuildThorVG.ps1`.
3. **ToolchainSequence.ps1** (Project-Zero) — add a Jolt block beside the ThorVG one:
   ```powershell
   $JoltLib = Join-Path $PackageRoot "jolt\lib\$Configuration\Jolt.lib"
   if (-not (Test-Path $JoltLib)) { Invoke-DependencyScript (Join-Path $ScriptRoot 'BuildJolt.ps1') @('-Configuration', $Configuration) }
   ```
   append `'Engine\PhysicalDynamics\RigidBodySolver.cpp'` to `$EngineRelative`, and `$LinkArgs.Add($JoltLib)`.
   The flag sets already agree: Project-Zero compiles `/MD /std:c++20 /EHsc` with `/DNDEBUG` in Release and
   **`/MD` + `/Od` without NDEBUG** in Debug — `BuildJolt.ps1` does exactly the same (`/MD` in both configurations, never `/MDd`).
   ISA is a parameter on every script (`-Isa SSE2|AVX|AVX2`, default **SSE2** — upstream `f78f027`: a Sandy Bridge i3 has no AVX and
   `/arch:AVX` died with `0xc000001d` at launch); `ToolchainSequence.ps1` forwards `-Isa` to `BuildJolt.ps1` so the pair cannot drift.
   ⚠️ If either side ever changes `/arch`, NDEBUG, or the runtime, `JPH::RegisterTypes()` traces `Version mismatch …` and aborts —
   that is the intended fail-fast, not a bug.
4. **CMakeLists.txt** (Project-Zero) — paste the `Jolt` library block from this branch's `CMakeLists.txt`, add
   `Engine/PhysicalDynamics/RigidBodySolver.cpp` to `FRONTIER_ENGINE_SOURCES`, `target_link_libraries(Project-Zero PRIVATE Jolt)`.
   (`${EXT}/jolt` is already in `FRONTIER_ENGINE_INCLUDES` there.)
5. **GameExecution.cpp** (Project-Zero) — the §2 block; the first visible use is to drive `PlacementRecord::World` of a few
   instances from `RigidBodyPose` so the ReSTIR view shows the crates falling (a later row: `SceneStructure` needs a per-instance
   transform update path that re-uploads the flat triangles or, better, the R8 instance transforms).
6. Delete this branch's copies of `OrientationClassifier.*` / `DiagnosticMetrics.*` (identical to the target tree's).

## 4. Proofs (sandbox, g++ 12.2, Release, `--fixed` = deterministic 1/60 s Δτ)

```
[INFO] [Bootstrap] Jolt 5.6.1 ready - fixed step 0.0167 s, gravity (0.00 0.00 -9.81) m/s^2, 1 worker threads
[INFO] [Scene] Drop scene: ground plane (z = 0, half extent 50 m) + 12 dynamic bodies (6 boxes, 4 spheres, 2 capsules) from z = 6.0 m
[INFO] [Proof] Free-fall witness Box05 after 0.500 s: dropped 1.256 m (analytic ½gt² = 1.226 m)
[INFO] [Summary] 964 ticks, 964 fixed steps in 16.07 s simulated, 0.000 s dropped by the hitch guard, last step 0.000 ms, 13 bodies resident
[INFO] [Proof] free fall OK (1.256 m vs 1.226 m)  |  settled floor clearance -0.0200 m OK (transient dip -0.138 m, Sphere00 at 1.08 s)  |  all bodies asleep - settled
```

* **Free fall**: +2.4 % over ½gt² — symplectic Euler at 60 Hz integrates velocity first (`v·Δt` overshoot ≈ ½·g·Δt·t), within the
  15 % gate. Not damping (0.05/s over 0.5 s is −1.2 %, the other direction).
* **No tunnelling**: every body ends with centre − inscribed radius = **−0.020 m** = Jolt's `PenetrationSlop` exactly. The transient
  dip (−0.138 m for one step) is contact resolution: a body arriving at 10 m/s covers 0.17 m per step and the speculative contact
  distance is 0.02 m, so it lands ~0.15 m deep for one step and is pushed out the next. Expected, reported, not judged.
* **Settles**: all 12 bodies asleep at 15.6 s (the loop exits 0.5 s later). Box column topples as authored (yaw 0.15 rad/level).
* **Determinism**: two `--fixed` runs produce byte-identical 11 569-row traces (`--trace a.csv` vs `b.csv`, `cmp` silent).
  Holds per thread count only (Jolt guarantee); wall-clock mode is not deterministic by construction.
* **Wall clock**: 8 s real → 480 fixed steps from 945 ticks (~118 Hz poll), 0 s dropped, same verdicts. A forced 1.5 s stall
  (`SIGSTOP`/`SIGCONT` mid-run) is absorbed as 4 catch-up steps + **0.047 s metered as dropped** — the guard is live, no spiral.
* **Stress**: 550 bodies (300 boxes / 200 spheres / 50 capsules) — 1.2 ms per step at peak on 1 worker thread, 40 s simulated in
  1.2 s wall, verdicts OK. (Ground half-extent scales with body count: with a 50 m plane the pile flung 40 bodies off the edge,
  which looks exactly like tunnelling in the log — ⚠️ a `PlaneShape` is finite in the broad phase.)
* **Debug build**: `JPH_ENABLE_ASSERTS` on both sides, no assert fires over the 20 s run.
* **CMake path**: same binary, same verdicts.

Not proven here: Windows/MSVC (`BuildJolt.ps1` + `ToolchainSequence.ps1` are line-for-line mirrors of the ThorVG/Project-Zero
scripts and were reviewed, not executed — no `cl.exe` in the sandbox); multi-thread determinism; rendering.

## 5. Deviations flagged ⚠️

* ⚠️ CLAUDE.md lists `jolt` as "headers only" — it is not. Jolt ships 153 `.cpp` and must be compiled with the **same** ISA / NDEBUG /
  runtime flags as the client (`Core.h` derives `JPH_USE_*` from `__AVX__` etc.; `RegisterTypes()` verifies a version-features ID).
  Hence `Scripts/BuildJolt.*` and the flag-parity comments in every build script. The table row should read "rigid-body physics;
  Windows: `Scripts/BuildJolt.ps1` → `lib\<Config>\Jolt.lib`".
* ⚠️ `RigidBodyConfiguration` exposes three `PhysicsSettings` knobs (`SpeculativeContactDistance`, `PenetrationSlop`,
  `TimeBeforeSleepSeconds`); the rest stay at Jolt defaults until a project needs them.
* ⚠️ Sphere rolling: `PlaneShape` has no rolling resistance, a sphere on it never stops. The drop scene sets `AngularDamping = 1.0`
  on spheres as a stand-in; a real rolling-friction model is a later row.
* ⚠️ `ContinuousCollision` (Jolt `LinearCast`) is on for the spheres only — they leave the sphere-sphere rebounds at > 7 m/s. It
  engages only once a step would move a body > ¾ of its inner radius, so it does not remove the one-step landing dip above.
