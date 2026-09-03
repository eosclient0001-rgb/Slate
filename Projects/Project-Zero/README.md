# Project-Zero — Windowed ReSTIR GI Renderer

Real-time Cornell Box rendered on the GPU with **ReSTIR DI + ReSTIR GI** via a
Vulkan compute shader, displayed in a native GLFW window with a live **ImGui
Control Centre** overlay.

---

## Dependencies

| Library  | Version | Install (Windows via vcpkg)                                  | Install (Ubuntu/Debian)              |
|----------|---------|--------------------------------------------------------------|--------------------------------------|
| Vulkan   | 1.2+    | Vulkan SDK from https://vulkan.lunarg.com/                   | `libvulkan-dev`                      |
| GLFW     | 3.3+    | `vcpkg install glfw3:x64-windows`                            | `libglfw3-dev`                       |
| ImGui    | 1.90+   | `vcpkg install imgui[glfw-binding,vulkan-binding]:x64-windows` | clone to `ThirdParty/imgui`         |
| ThorVG   | 0.12+   | `vcpkg install thorvg:x64-windows`                           | `libthorvg-dev`                      |
| glslc    | –       | Included in Vulkan SDK (`$VULKAN_SDK/Bin/glslc.exe`)         | `glslc` or `vulkan-tools`            |

---

## Build — Windows (PowerShell 5.1 or 7+)

```powershell
# From the repository root (Frontier/)
powershell -NoProfile -ExecutionPolicy Bypass `
  -File Projects/Project-Zero/Build/ToolchainSequence.ps1 `
  -Configuration Release -Rebuild

# Build + launch immediately
powershell -NoProfile -ExecutionPolicy Bypass `
  -File Projects/Project-Zero/Build/ToolchainSequence.ps1 `
  -Configuration Release -Rebuild -Run
```

The build uses MSVC directly and discovers the latest installed Vulkan SDK. It
also builds GLFW when needed and packages both `glfw3.dll` and
`ReSTIRViewport.spv` beside the executable.

---

## Build — Linux (Bash)

```bash
# Initialize the pinned dependencies, then build from the repository root
# (a Vulkan SDK, glslc/slangc, CMake, and X11 development headers are required)
git submodule update --init --recursive
bash Projects/Project-Zero/Build/ToolchainSequence.sh release --rebuild

# Build + launch
bash Projects/Project-Zero/Build/ToolchainSequence.sh release --run
```

---

## Runtime

The packaged runtime is self-contained and may be launched from PowerShell,
CMD, or by double-clicking the executable:

```text
Projects\Project-Zero\Build\Output\Windows\Release\Binary\
  Project-Zero.exe
  glfw3.dll
  ReSTIRViewport.spv
  Diagnostics\ProjectZero_TelemetryReport.md   (created on launch)
```

`Project-Zero.exe` intentionally uses the Windows **console subsystem**. A
console and a separate native GLFW/Vulkan window remain open together. Startup
stages are echoed to the console, while lifecycle milestones and the final
failure reason are persisted in the diagnostic report. If a Vulkan/GLFW stage
fails, both outputs include the exact failed API operation and error code.

---

## Controls

| Input               | Action                        |
|---------------------|-------------------------------|
| `W / A / S / D`     | Fly forward / strafe          |
| `Q / E`             | Descend / ascend              |
| `RMB + drag`        | Look around (yaw + pitch)     |
| `Scroll wheel`      | Adjust flight speed           |
| `Left Shift`        | 3× speed boost                |
| `Escape`            | Quit                          |

---

## ImGui Control Centre

Docked to the **right edge** of the window. Live-tunable parameters:

- **Camera** — position, orientation, speed, FoV (read-only telemetry)
- **ReSTIR DI + GI** — candidates per pixel, spatial resampling passes, ACES exposure
- **Scene** — Cornell Box triangle / material count, colour-coded surface legend
- **Device** — GPU name, type, Vulkan API version
