//============================================================================================================================================
// 📦 Frontier/CLAUDE.md — Architecture, Naming, Formatting and Compilation Directives for Frontier Engine
//============================================================================================================================================

# Frontier Engine Directives

## 1. Architectural Philosophy & Integrity
- **Decoupled Architecture**: Frontier is an independent, high-performance Vulkan simulation and rendering engine.
- **Strict Role-Based Nomenclature**: Every class, struct, module, and folder strictly follows the two-word `<Subject><Role>` format.
- **No Banned Words**: Never use OOP/AI tropes or vague abstractions.
- **Fail-Fast Error Handling**: Expected domain failures are returned as `Refusal` or wrapped in `Deliver<T>`. No raw C++ exceptions crossing module seams.
- **Linear Memory Management**: Monotonic extents via `ByteSpace` with reset at Phase ⑭. No uncontrolled heap allocations during simulation or rendering loops.

---

## 2. Definitive Closed Role Suffixes (19 Authorized Roles)
1. `Sequence`      : Deterministic multi-step ordered execution.
2. `Codec`         : Bidirectional bit-level encoding and decoding.
3. `Exchange`      : Low-level C-ABI boundary and hardware transport.
4. `Interchange`   : High-level platform interop and network datagrams (e.g. EOS).
5. `Extension`     : Optional hardware, platform, or engine feature set.
6. `Solver`        : Mathematical constraint satisfaction and integration (Jolt, XPBD, Fluid).
7. `Integrator`    : Numerical differential equation advancing (ReSTIR, Photometrics, Acoustics).
8. `Classifier`    : Decision tree and capability discrimination (Hardware, Orientation).
9. `Projection`    : Coordinate space transformation and visibility mapping.
10. `Specification`: Mathematical and structural declarations.
11. `Configuration`: Runtime tunable parameters and subsystem setups.
12. `Criteria`     : Validation thresholds and filtering conditions.
13. `Structure`    : Spatial and physical topology representations.
14. `Space`        : Continuous coordinate realms and scalar fields (LevelSet, Clusters).
15. `Index`        : Direct spatial lookup and fast addressing structures.
16. `Metrics`      : Quantitative profiling counters and microsecond telemetry.
17. `Scheduler`    : Fiber work-stealing execution graphs and clock loops.
18. `Queue`        : Lock-free atomic FIFO / double-ended work queues.
19. `Panel`        : Immediate mode UI rendering overlays (ImGui).
20. `Host`         : Root coordinator and executable lifecycle entry point.

---

## 3. Forbidden Words (Strictly Banned)
`Manager`, `Handler`, `Processor`, `Controller`, `Service`, `Utility`, `Helper`, `Node`, `Frame`, `Module`,
`Core`, `System`, `Backend`, `Pass`, `Stage`, `Harness`, `Shell`, `Entity`, `Element`, `Subsystem`,
`Hierarchy`, `Data`, `Info`, `Object`, `Item`, `Thing`, `Kind`, `Base`, `flag`, `state`, `value`,
`Parent`, `Child`, `Sibling`, `Table`, `Map`, `Block`, `Digest`, `Model`, `Handle`, `Store`,
`Bridge`, `Atlas`, `Substrate`, `Fabric`, `Cache`, `Evaluator`, `Evaluate`, `Journal`, `Resolver`,
`Mesh`, `Pool`, `Registry`, `Catalog`, `Repository`, `Directory`, `Vault`, `Arena`, `Inventory`,
`Ledger`, `Plan`, `Filter`, `Grid`, `Array`, `Dispatcher`, `Memory`, `Buffer`, `Pipeline`, `Flow`,
`Composite`, `Compose`, `Composition`, `Allocation`, `Tier`, `Nesting`, `Stratum`, `Mip`, `Messenger`,
`Probe`, `Blend`, `History`, `Bake`, `Stamp`, `Contract`, `Outcome`, `Prelude`, `Cadence`, `Binding`,
`Submission`, `Footprint`, `Region`, `Tree`, `Vacancy`, `Ordinates`, `Draft`, `Draught`, `Paint`,
`Depot`, `Ordinal`, `Actor`, `Source`, `API`.

---

## 4. Formatting Standards
- **File Headers**: Exactly 142 characters wide (`//` followed by 140 `=` characters).
- **Section Banners**: Exactly 122 characters wide (`//` followed by 120 `-` characters).
- **Indentation**: 4 spaces everywhere. Tabs are strictly forbidden.
- **Braces**: Allman style (opening brace on a new line at enclosing indentation level).
- **Namespaces**: Flat indentation inside `namespace Frontier { ... }` (declarations at column 0).
- **Unit Annotations**: Vertically aligned comments with bracketed physical units `[m]`, `[s]`, `[kg]`, `[lux]`, `[rad]`, `[Hz]`, `[-]`.
- **Unicode Math Glyphs**: Use real mathematical symbols ($α, β, γ, Δτ, ν, ρ, θ, ω, \nabla, \phi, \Sigma$).
- **Single Accessor Conversion**: Use C++20 templated conversion accessors (`template<typename T> T Query() const` or conversion operators) instead of duplicating multiple method variants.

---

## 5. Build & Compilation Commands

### Project-Zero — Windows (PowerShell 5.1+ / MSVC direct toolchain)
```powershell
# Release (default)
powershell -File Projects\Project-Zero\Build\ToolchainSequence.ps1

# Debug
powershell -File Projects\Project-Zero\Build\ToolchainSequence.ps1 -Configuration Debug

# Full rebuild + run
powershell -File Projects\Project-Zero\Build\ToolchainSequence.ps1 -Rebuild -Run
```
- Requires: Visual Studio 2022 (MSVC), Vulkan SDK (sets `VULKAN_SDK` env var or falls back to `C:\VulkanSDK\<latest>`), PowerShell 5.1 or later
- GLFW is built automatically via `Scripts\BuildGLFW.ps1` when `ExternalPackages\glfw\lib-vc2022\glfw3dll.lib` is absent (cmake VS17 2022 → DLL + import lib)
- ThorVG is built automatically via `Scripts\BuildThorVG.ps1` when `ExternalPackages\thorvg\lib\thorvg.lib` is absent (direct `cl.exe` → static lib)
- Jolt is built automatically via `Scripts\BuildJolt.ps1` when `ExternalPackages\jolt\lib\<Configuration>\Jolt.lib` is absent (direct `cl.exe` → static lib, 138 TUs, rigid-body subset). ⚠️ Jolt derives `JPH_USE_*`/`JPH_DEBUG` from compiler flags and `RegisterTypes()` aborts on a client mismatch — every TU that includes `<Jolt/Jolt.h>` must use the same `/arch:AVX`, `/MD`, NDEBUG choice as the library
- Shaders: `.slang` → SPIR-V via `slangc.exe` (ships with Vulkan SDK)
- Compatible with Windows PowerShell 5.1 and PowerShell 7+ (both `powershell.exe` and `pwsh.exe` work)
- `Construct.ps1` is a banned script name — use `ToolchainSequence.ps1`

### Project-Zero — Linux (g++/clang++)
```bash
bash Projects/Project-Zero/Build/ToolchainSequence.sh
bash Projects/Project-Zero/Build/ToolchainSequence.sh debug
bash Projects/Project-Zero/Build/ToolchainSequence.sh --rebuild --run
```
- Requires: g++ ≥ 12 or clang++ ≥ 15, cmake, Vulkan SDK (`VULKAN_SDK` env var or `/usr`)
- GLFW built from source submodule (cmake static)
- ThorVG built from source submodule (direct `clang++/g++` → static lib via `ar`)
- Slang shaders lowered via `slangc` if available; falls back to existing `.spv`

### Dependency build scripts (invoked automatically by ToolchainSequence.ps1)
```powershell
powershell -File Scripts\BuildGLFW.ps1            # builds ExternalPackages/glfw/lib-vc2022/glfw3dll.lib + glfw3.dll
powershell -File Scripts\BuildThorVG.ps1          # builds ExternalPackages/thorvg/lib/thorvg.lib
powershell -File Scripts\BuildThorVG.ps1 -Configuration Debug
powershell -File Scripts\BuildJolt.ps1            # builds ExternalPackages/jolt/lib/Release/Jolt.lib   (Linux: bash Scripts/BuildJolt.sh)
powershell -File Scripts\BuildJolt.ps1 -Configuration Debug   # lib/Debug/Jolt.lib with JPH_ENABLE_ASSERTS
```

### Project-Physics (Jolt rigid-body testbed — console, no window, self-proving)
```powershell
powershell -File Projects\Project-Physics\Build\ToolchainSequence.ps1 -Run                          # plane + falling boxes/spheres/capsules
powershell -File Projects\Project-Physics\Build\ToolchainSequence.ps1 -Run -RunArguments '--fixed','--seconds','20','--quiet'
bash Projects/Project-Physics/Build/ToolchainSequence.sh --run -- --fixed --seconds 20 --quiet     # Linux; exit 0 = proof passed
```
- Flags: `--seconds N` budget, `--fixed` deterministic 1/60 s Δτ, `--boxes/--spheres/--capsules N`, `--quiet`, `--trace out.csv`
- Writes `Diagnostics/ProjectPhysics_TelemetryReport.md`; exit 0 proof OK, 2 proof failed (tunnelled / free fall off), 1 bring-up refusal
- Merge plan into Project-Zero: `References/PhysicsPhaseP1-JoltBringUp.md`

### Linux CMake (IDE integration / non-Windows only)
```bash
cmake -B build && cmake --build build --config Release
```
CMake is **not supported on Windows** — use `ToolchainSequence.ps1` there.

### Development UI
Compiled conditionally with `#ifdef FRONTIER_DEVELOPMENT`.

---

## 6. Engine vs. Game Project Decoupling Architecture
- **Engine Core Scope**:
  - Provides hardware-agnostic abstractions, mathematical types, and engine foundations (`DeviceExchange`, `PhysicalDynamics`, `VolumetricDynamics`, `GeometricRaster`, `PhotometricIllumination`, `PlatformInterchange`, `DisplayPresentation`).
  - Standard virtual key and mouse state enumeration (`VirtualKeyCategory`, `MouseButtonCategory` in `DeviceExchange/InputExchange.h`) provides a universal, standard hardware abstraction covering alphanumeric keys (A-Z, 0-9), function keys (F1-F12), navigation, modifiers, mouse buttons, and gamepad records.
  - Baseline camera projections (`GeometricRaster/CameraProjection.h`) declare standard viewport geometry, perspective matrices, and ray construction.
- **Game / Project Scope (`Projects/<ProjectName>/`)**:
  - Individual games (e.g. `Project-F20`, `Project-Zero`) define their own gameplay mechanics, physics tuning, and input action bindings without altering engine core files.
  - Game action mapping (e.g. mapping `VirtualKeyCategory::KeyW` to forward movement, or `MouseButtonCategory::ButtonRight` to flight steering) and specialized camera controllers (e.g. `FlyThroughSolver`, `OrbitSolver`, `ChaseCamSolver`) reside entirely within the respective project codebase.
  - Prevents engine bloat, maintains clean module boundaries, and guarantees that any game project can implement arbitrary control schemes using the engine's universal input hardware abstraction.

---

## 7. 3D Coordinate System & Physical Units Standards
- **Right-Handed Coordinate System Convention ($+Z$ Up)**:
  - **$+X$ Axis**: Right / East (Red Color)
  - **$+Y$ Axis**: Forward / North (Green Color)
  - **$+Z$ Axis**: Up / Zenith (Blue Color) — **$Z$ is strictly the upward vertical axis across the engine and all games**.
  - **Vector Cross Products**: $\vec{X} \times \vec{Y} = \vec{Z}$ (Right $\times$ Forward $=$ Up), $\vec{Y} \times \vec{Z} = \vec{X}$ (Forward $\times$ Up $=$ Right), $\vec{Z} \times \vec{X} = \vec{Y}$ (Up $\times$ Right $=$ Forward).
- **Default Physical Units**:
  - **Distance / Coordinates**: **Meters ($[m]$)** strictly (never centimeters, millimeters, or feet).
  - **Time**: **Seconds ($[s]$)**.
  - **Mass**: **Kilograms ($[kg]$)**.
  - **Velocity**: **Meters per second ($[m/s]$)**.
  - **Luminous Flux / Illuminance**: **Lux ($[lux]$)** / Lumens ($[lm]$).
  - **Angles**: **Radians ($[rad]$)** for mathematical calculation, degrees ($[deg]$) only for human-facing UI input.
- **Vulkan Projection Mapping (World → Vulkan image)**:
  - Vulkan NDC has clip $Z \in [0, 1]$ and inverted $Y$. Projections in `CameraProjection` and shaders map from Right-Handed $Z$-up World Space into Vulkan clip coordinates with appropriate depth clamping and $Y$-inversion.
  - The single authoritative translation lives in `Engine/Shaders/RayGeneration.slang` (`GeneratePrimaryRay`) and its CPU twin in `CameraProjection`. World basis: Right $=+X$, Forward $=+Y$, Up $=+Z$. Vulkan image basis: $x$ right, $y$ **down**, origin top-left, $(u,v)=(\text{pixel}+0.5)/\text{extent}$, $\text{ndc}=(2u-1,\;1-2v)$. A ray direction is therefore $\text{Forward}\cdot f + \text{Right}\cdot\text{ndc}_x\cdot a + \text{Up}\cdot\text{ndc}_y$ — the $Y$ flip happens **once**, in the NDC construction, and nowhere else. No project may re-derive this mapping; include the shared shader.

---

## 8. Standalone & Embedded Content Creation Tools Architecture (`Tools/`)
- Tools are structured as dual-target modular applications:
  1. **Standalone Executables**: Can be compiled and run as independent desktop creation tools (e.g. `Tools/TexturePainter/`, `Tools/ParametricSketcher/`).
  2. **Embedded Development Workspaces**: Can be invoked inside the engine editor while testing or simulating a game via `#ifdef FRONTIER_DEVELOPMENT` within `DisplayPresentation/WorkspaceHost`.
- Common Tool Suite:
  - **Texture Painting**: Interactive 3D surface texel painting, brush projection, PBR layer blending.
  - **Texture Baking**: High-to-low poly ray-traced baking (Normal, AO, Curvature, Bent Normals, Thickness).
  - **Parametric Sketching**: 2D/3D CAD constraint solving, spline/NURBS surfaces, profile extrusions, boolean solids.
  - **UV Unwrapping**: Conformal flattening (ABF++/LSCM), seam tagging, island packing, distortion metrics.
  - **Procedural Plants / Foliage**: L-system parametric branching, leaf scattering, wind binding.
  - **Material Shader Graph**: Node-based PBR graph authoring with live SPIR-V compute compilation.

---

## 9. Scratchpad Directory Directive for Temporary Work
- **Strict Anti-Pollution Rule**: Any temporary scripts, scratch experiments, intermediate log outputs, generation prototypes, or ad-hoc diagnostic tools MUST reside strictly within a dedicated `/Scratchpad` directory (`Scratchpad/`).
- Never write scratch files, loose temporary images, or ad-hoc test scripts into the repository root or project source folders (`Source/`, `DisplayPresentation/`, `Projects/`, etc.). Keep the working tree completely clean and organized.

---

## 10. Repository Folder Layout

```
Frontier/
├── Engine/                         ← All engine module folders live here (NEVER at repo root)
│   ├── DeviceExchange/             ← Vulkan device, swapchain, memory, input, diagnostics
│   ├── DisplayPresentation/        ← ImGui panels, font/vector codecs, UI cycle, host
│   ├── GeometricRaster/            ← Geometry, camera, visibility, raster, material codec
│   ├── PhotometricIllumination/    ← Direct/global/atmosphere light integrators, clusters
│   ├── PhysicalDynamics/           ← Rigid/deformable bodies, locomotion, spatial, world
│   │   └── RigidBodySolver.h/.cpp  ← Jolt behind a JPH-free seam: Bring/CreateBody/Advance(Δτ)/QueryPoses/Retire; +Z up, m/kg/s
│   ├── PlatformInterchange/        ← Audio, voice, online (EOS)
│   ├── Shaders/                    ← .slang shaders lowered to SPIR-V via slangc (Vulkan SDK)
│   └── VolumetricDynamics/         ← Level-set, fluid, particle integrators
│
├── EngineContent/                  ← Engine-level canonical assets (NOT Content/ or Engine/Content/)
│   ├── FontArchives/               ← One subfolder per font family; fonts downloaded via Scripts/
│   │   ├── Archivo/
│   │   │   ├── Archivo.toml        ← TOML descriptor (parsed via tomlpp); replaces .manifest
│   │   │   ├── Archivo-Light.ttf
│   │   │   ├── Archivo-Regular.ttf
│   │   │   ├── Archivo-Medium.ttf
│   │   │   ├── Archivo-SemiBold.ttf
│   │   │   └── Archivo-Bold.ttf
│   │   └── <Family>/               ← Same structure for all other families
│   ├── GraphicArchives/
│   └── MaterialArchives/
│
├── ExternalPackages/               ← Git submodules — pinned SHAs matching Slate repo (all 12)
│   ├── cgltf/         @85cd6238   ← glTF 2.0 loader (single-header)
│   ├── clipper2/      @f9c5eb6e   ← Polygon clipping / offsetting (headers only)
│   ├── earcut/        @f25bc765   ← Fast polygon triangulation (single-header)
│   ├── fast_obj/      @d620667f   ← Wavefront OBJ parser (single-header)
│   ├── glfw/          @92dcf4ce   ← Window + input; Windows: DLL via Scripts/BuildGLFW.ps1
│   │   └── lib-vc2022/            ← Deposit: glfw3dll.lib + glfw3.dll  (generated, not committed)
│   ├── imgui/         @12b79775   ← Immediate-mode UI (docking branch); TUs compiled directly
│   ├── jolt/          @2e28006e   ← Rigid-body physics; NOT header-only — Scripts/BuildJolt.ps1|.sh → static lib
│   │   └── lib/<Config>/          ← Deposit: Jolt.lib / libJolt.a  (generated, not committed; ISA+NDEBUG must match client)
│   ├── miniaudio/     @9634bedb   ← Cross-platform audio (single-header)
│   ├── stb/           @2c980bb5   ← Image load/save, TrueType rasterisation (single-header)
│   ├── thorvg/        @3a2ce054   ← SVG / glyph rasterisation; Windows: Scripts/BuildThorVG.ps1
│   │   └── lib/                   ← Deposit: thorvg.lib  (generated, not committed)
│   ├── tomlpp/        @1e8829b7   ← TOML config parsing (header-only); replaces ALL .manifest files
│   └── ufbx/          @fcc5d6ba   ← FBX scene loading (single-file C library)
│
├── Projects/
│   ├── Project-Zero/               ← ReSTIR GI testbed (GLFW window, Vulkan, ImGui, ThorVG, Slang)
│   │   ├── Build/
│   │   │   ├── ToolchainSequence.ps1   ← PowerShell 5.1+ Windows build  (NOT Construct.ps1)
│   │   │   └── ToolchainSequence.sh    ← Linux/macOS build script
│   │   ├── Content/
│   │   │   ├── AudioArchives/
│   │   │   ├── FontArchives/
│   │   │   ├── GeometryArchives/
│   │   │   ├── GraphicArchives/
│   │   │   ├── ShaderArchives/
│   │   │   │   └── ReSTIRViewport.toml ← Shader descriptor (NOT .manifest)
│   │   │   └── WorldArchives/
│   │   └── Source/
│   │       ├── GameExecution.cpp
│   │       ├── FlyThroughSolver.h/.cpp
│   │       ├── RayTracingSolver.h/.cpp
│   │       └── TracingIndex.h
│   ├── Project-Physics/            ← Jolt rigid-body testbed (console; ground plane + drop scene ticked from main loop)
│   │   ├── Build/ToolchainSequence.ps1/.sh
│   │   └── Source/
│   │       ├── GameExecution.cpp   ← main loop: Solver.Advance(Δτ) → Solver.QueryPoses(); free-fall + no-tunnel proof
│   │       └── DropSceneStructure.h/.cpp
│   └── Project-F20/                ← Racing game (same Content/ layout)
│
├── Scripts/                        ← Utility scripts — invoked by build scripts as needed
│   ├── BuildGLFW.ps1               ← cmake VS17 2022 → glfw3.dll + glfw3dll.lib
│   ├── BuildThorVG.ps1             ← cl.exe + lib.exe → thorvg.lib  (no Meson/Ninja)
│   ├── BuildJolt.ps1/.sh           ← cl.exe + lib.exe (g++ + ar) → Jolt.lib / libJolt.a  (no CMake; flags == client TUs)
│   ├── DownloadFonts.bat/.ps1/.py  ← Download TTF font files into EngineContent/FontArchives/
│   └── ApplyImGuiPatches.ps1       ← Apply Frontier-specific ImGui patches before build
│
├── Scratchpad/                     ← Temporary work only — never in Source/ or root
└── CMakeLists.txt                  ← Linux/IDE integration only; Windows uses ToolchainSequence.ps1
```

---

## 11. GPU Presentation & Vulkan Naming Conventions

| Responsibility | Class name | Role suffix | Location |
|---|---|---|---|
| Vulkan device + swapchain + memory | `SwapchainExchange` | Exchange | `Engine/DeviceExchange/` |
| ReSTIR GI compute dispatch | `ReSTIRIntegrator` | Integrator | `Engine/DisplayPresentation/` |
| ImGui control centre overlay | `RenderScheduler` | Panel | `Engine/DisplayPresentation/` |
| GPU triangle geometry upload | `TriangleIndex` | Structure | `Engine/DeviceExchange/SwapchainExchange.h` |
| GPU material/radiance upload | `RadianceStructure` | Structure | `Engine/DeviceExchange/SwapchainExchange.h` |
| Compute push constants | `DispatchConfiguration` | Configuration | `Engine/DeviceExchange/SwapchainExchange.h` |

**Rejected names:** `VulkanViewport`, `Viewport` (not an authorised role suffix), `Construct` (use `ToolchainSequence`).

---

## 12. Shared-vs-Project Code Rule (Modular Game Engine)
- Frontier is a **modular game engine**: anything usable by more than one game lives in `Engine/`, never in `Projects/<Game>/`.
- A project may contain only game-specific content: its scene, its solvers' tuning, its `GameExecution.cpp` wiring. Cameras, ray generation, input polish, overlay hosts, spring motion, recording surfaces, temporal accumulation, etc. are Engine modules that a project **includes**, not copies.
- Shaders follow the same rule: shared `.slang` includes live in `Engine/Shaders/` and are pulled in with `#include`; project shaders may only add project-specific passes on top.
- If a fix is made in a project and a second project would need the same fix, the fix is in the wrong place — lift it into `Engine/` first.

---

## 13. Struct Rename Table

| Old / rejected name | Authorised name | Role |
|---|---|---|
| `TriangleRecord` / `GpuTriangle` / `FacetStructure` | `TriangleIndex` | Structure |
| `MaterialRecord` / `GpuMaterial` | `RadianceStructure` | Structure |
| `ReSTIRPushConstants` | `DispatchConfiguration` | Configuration |

---

## 14. Descriptor File Format Rules

- **`.manifest` files are completely banned.** Every metadata descriptor uses `.toml` format, parsed via `ExternalPackages/tomlpp`.
- Font descriptors: `EngineContent/FontArchives/<Family>/<Family>.toml`
- Shader descriptors: `Projects/<Name>/Content/ShaderArchives/<Shader>.toml`
- Font binaries (`.ttf`) are **not committed** to git — download via `Scripts/DownloadFonts.bat` or `Scripts/DownloadFonts.py`.

---

## 15. Build Script Naming Rules

- Build scripts are named `ToolchainSequence.ps1` (Windows) and `ToolchainSequence.sh` (Linux).
- `Construct`, `LinuxBuild`, `Build` are banned as script base-names.
- All build scripts live in `Projects/<Name>/Build/`.
- PowerShell scripts must be compatible with PS5.1 and PS7+. No `#Requires -Version 7.0`. No `pwsh`-only syntax.

---

## 16. Agentic Instructions

All naming, formatting, emoji, condition-closure, and font/TOML rules are defined in a single
authoritative skill file. Read it before writing or reviewing any source file:

```
AgenticInstructions/SKILL-Naming-Formatting.md
```

That file is the final word on every rule in §2–§4 and §14–§15 above. Where this file and the
skill file conflict, the skill file wins.
