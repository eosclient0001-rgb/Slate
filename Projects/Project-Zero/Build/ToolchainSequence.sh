#!/usr/bin/env bash
#============================================================================================================================================
# Frontier/Projects/Project-Zero/Build/ToolchainSequence.sh — Linux Build (g++/clang++ + Vulkan + ExternalPackages submodules)
#   Requires: g++ >= 12 or clang++ >= 15, cmake, make, Vulkan SDK (VULKAN_SDK env var or /usr)
#   Usage:    bash ToolchainSequence.sh [debug|release] [--rebuild] [--run]
#============================================================================================================================================

set -euo pipefail

#---
#                                            ARGUMENTS
#---

CONFIGURATION="release"
REBUILD=0
RUN=0

for ARG in "$@"; do
    case "$ARG" in
        debug|Debug)     CONFIGURATION="debug"   ;;
        release|Release) CONFIGURATION="release" ;;
        --rebuild)       REBUILD=1               ;;
        --run)           RUN=1                   ;;
        *) echo "[ToolchainSequence] Unknown argument: $ARG" && exit 1 ;;
    esac
done

#---
#                                           PATH SETUP
#---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENGINE_ROOT="$REPO_ROOT/Engine"
PKG_ROOT="$REPO_ROOT/ExternalPackages"
SCRIPT_TOOLS="$REPO_ROOT/Scripts"
PROJECT_ROOT="$REPO_ROOT/Projects/Project-Zero"
OUTPUT_ROOT="$PROJECT_ROOT/Build/Output/Linux/$CONFIGURATION"
OBJ_DIR="$OUTPUT_ROOT/Object"
BIN_DIR="$OUTPUT_ROOT/Binary"

echo "[ToolchainSequence] Configuration : $CONFIGURATION"
echo "[ToolchainSequence] Repo root      : $REPO_ROOT"

#---
#                                            COMPILER
#---

CXX="${CXX:-g++}"
if ! command -v "$CXX" &>/dev/null; then
    CXX="clang++"
    if ! command -v "$CXX" &>/dev/null; then
        echo "[ToolchainSequence] ERROR: neither g++ nor clang++ found." && exit 1
    fi
fi
echo "[ToolchainSequence] Compiler       : $($CXX --version | head -1)"

#---
#                                          VULKAN SDK
#---

VULKAN_SDK="${VULKAN_SDK:-/usr}"
VULKAN_INC="$VULKAN_SDK/include"
VULKAN_LIB="$VULKAN_SDK/lib"

# Resolve the GLSL compiler (prefer glslc because this .slang file contains GLSL).
GLSLC="$VULKAN_SDK/bin/glslc"
if [ ! -x "$GLSLC" ]; then GLSLC="$(command -v glslc 2>/dev/null || true)"; fi
SLANGC="$VULKAN_SDK/bin/slangc"
if [ ! -x "$SLANGC" ]; then SLANGC="$(command -v slangc 2>/dev/null || true)"; fi

#---
#                                         SUBMODULES
#---

echo "[ToolchainSequence] Ensuring ExternalPackages submodules are initialised..."
(cd "$REPO_ROOT" && git submodule update --init --recursive -- \
    ExternalPackages/imgui \
    ExternalPackages/glfw \
    ExternalPackages/thorvg \
    ExternalPackages/tomlpp \
    ExternalPackages/jolt \
    ExternalPackages/cgltf \
    ExternalPackages/clipper2 \
    ExternalPackages/earcut \
    ExternalPackages/fast_obj \
    ExternalPackages/miniaudio \
    ExternalPackages/stb \
    ExternalPackages/ufbx)

#---
#                                     BUILD GLFW (static, Linux)
#---

GLFW_SRC="$PKG_ROOT/glfw"
GLFW_BUILD="$GLFW_SRC/_build_linux"
GLFW_LIB="$GLFW_BUILD/src/libglfw3.a"

if [ ! -f "$GLFW_LIB" ]; then
    echo "[ToolchainSequence] Building GLFW from source (Linux static)..."
    mkdir -p "$GLFW_BUILD"
    cmake -S "$GLFW_SRC" -B "$GLFW_BUILD" \
        -DGLFW_BUILD_EXAMPLES=OFF \
        -DGLFW_BUILD_TESTS=OFF \
        -DGLFW_BUILD_DOCS=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-fPIC" \
        2>&1
    cmake --build "$GLFW_BUILD" --config Release -j"$(nproc)"
fi

#---
#                                    BUILD THORVG (static, Linux)
#---

THORVG_SRC="$PKG_ROOT/thorvg"
THORVG_LIB_DIR="$THORVG_SRC/lib_linux"
THORVG_LIB="$THORVG_LIB_DIR/libthorvg.a"
THORVG_BUILD="$THORVG_SRC/_build_linux"

if [ ! -f "$THORVG_LIB" ]; then
    echo "[ToolchainSequence] Building ThorVG from source (Linux static, no Meson)..."

    mkdir -p "$THORVG_BUILD" "$THORVG_LIB_DIR"

    # Generate config.h
    cat > "$THORVG_BUILD/config.h" << 'CONFIG'
#pragma once
#define THORVG_VERSION_STRING "1.0.0"
#define THORVG_CPU_ENGINE_SUPPORT 1
#define THORVG_SVG_LOADER_SUPPORT 1
#define THORVG_THREAD_SUPPORT 1
#define THORVG_FILE_IO_SUPPORT 1
CONFIG

    THORVG_SRCS=(
        # common
        "$THORVG_SRC/src/common/tvgCompressor.cpp"
        "$THORVG_SRC/src/common/tvgMath.cpp"
        "$THORVG_SRC/src/common/tvgStr.cpp"
        # renderer
        "$THORVG_SRC/src/renderer/tvgAccessor.cpp"
        "$THORVG_SRC/src/renderer/tvgAnimation.cpp"
        "$THORVG_SRC/src/renderer/tvgCanvas.cpp"
        "$THORVG_SRC/src/renderer/tvgFill.cpp"
        "$THORVG_SRC/src/renderer/tvgInitializer.cpp"
        "$THORVG_SRC/src/renderer/tvgLoaderMgr.cpp"
        "$THORVG_SRC/src/renderer/tvgPaint.cpp"
        "$THORVG_SRC/src/renderer/tvgPicture.cpp"
        "$THORVG_SRC/src/renderer/tvgRender.cpp"
        "$THORVG_SRC/src/renderer/tvgSaver.cpp"
        "$THORVG_SRC/src/renderer/tvgScene.cpp"
        "$THORVG_SRC/src/renderer/tvgShape.cpp"
        "$THORVG_SRC/src/renderer/tvgTaskScheduler.cpp"
        "$THORVG_SRC/src/renderer/tvgText.cpp"
        # cpu_engine
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwBlendOp.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwFill.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwImage.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwMemPool.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwPostEffect.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwRaster.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwRenderer.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwRle.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwShape.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwStroke.cpp"
        "$THORVG_SRC/src/renderer/cpu_engine/tvgSwUtil.cpp"
        # loaders
        "$THORVG_SRC/src/loaders/raw/tvgRawLoader.cpp"
        "$THORVG_SRC/src/loaders/svg/tvgSvgBuilder.cpp"
        "$THORVG_SRC/src/loaders/svg/tvgSvgCssStyle.cpp"
        "$THORVG_SRC/src/loaders/svg/tvgSvgLoader.cpp"
        "$THORVG_SRC/src/loaders/svg/tvgSvgPath.cpp"
        "$THORVG_SRC/src/loaders/svg/tvgSvgUtil.cpp"
        "$THORVG_SRC/src/loaders/svg/tvgXmlParser.cpp"
    )

    TVG_INCS=(
        "-I$THORVG_SRC/inc"
        "-I$THORVG_BUILD"
        "-I$THORVG_SRC/src/common"
        "-I$THORVG_SRC/src/renderer"
        "-I$THORVG_SRC/src/renderer/cpu_engine"
        "-I$THORVG_SRC/src/loaders/svg"
        "-I$THORVG_SRC/src/loaders/raw"
    )

    TVG_FLAGS=(
        "-std=c++17"
        "-O2"
        "-fPIC"
        "-DTVG_STATIC"
        "-DTVG_BUILD"
        "-DNOMINMAX"
    )

    TVG_OBJS=()
    for SRC in "${THORVG_SRCS[@]}"; do
        OBJ="$THORVG_BUILD/$(basename "${SRC%.cpp}").o"
        TVG_OBJS+=("$OBJ")
        echo "  [ThorVG] $(basename "$SRC")"
        "$CXX" "${TVG_FLAGS[@]}" "${TVG_INCS[@]}" -c "$SRC" -o "$OBJ"
    done

    ar rcs "$THORVG_LIB" "${TVG_OBJS[@]}"
    echo "[ToolchainSequence] ThorVG built: $THORVG_LIB"
fi

#---
#                                        SHADER LOWERING (.slang → SPIR-V)
#---

SLANG_SRC="$ENGINE_ROOT/Shaders/ReSTIRViewport.slang"
SPV_OUT="$ENGINE_ROOT/Shaders/ReSTIRViewport.spv"

if [ -f "$SLANG_SRC" ]; then
    if [ "$REBUILD" -eq 1 ] || [ ! -f "$SPV_OUT" ] || [ "$SLANG_SRC" -nt "$SPV_OUT" ]; then
        if [ -x "$GLSLC" ]; then
            echo "[ToolchainSequence] Compiling ReSTIRViewport.slang as GLSL compute → ReSTIRViewport.spv"
            TEMP_GLSL="$(mktemp --suffix=.comp)"
            cp "$SLANG_SRC" "$TEMP_GLSL"
            if ! "$GLSLC" \
                    -DFRONTIER_SHADER_TOOLCHAIN=1 \
                    "-I$ENGINE_ROOT" \
                    --target-env=vulkan1.2 \
                    -fshader-stage=compute \
                    "$TEMP_GLSL" -o "$SPV_OUT"; then
                rm -f "$TEMP_GLSL"
                echo "[ToolchainSequence] ERROR: glslc rejected ReSTIRViewport.slang."
                exit 1
            fi
            rm -f "$TEMP_GLSL"
        elif [ -x "$SLANGC" ]; then
            echo "[ToolchainSequence] Lowering ReSTIRViewport.slang → ReSTIRViewport.spv"
            "$SLANGC" "$SLANG_SRC" \
                -DFRONTIER_SHADER_TOOLCHAIN=1 \
                "-I$ENGINE_ROOT" \
                -target spirv \
                -profile glsl_450 \
                -o "$SPV_OUT"
        elif [ ! -f "$SPV_OUT" ]; then
            echo "[ToolchainSequence] ERROR: glslc/slangc not found and ReSTIRViewport.spv is absent."
            exit 1
        else
            echo "[ToolchainSequence] WARNING: no shader compiler found — using existing SPV."
        fi
    else
        echo "[ToolchainSequence] ReSTIRViewport.slang unchanged — skipping"
    fi
elif [ ! -f "$SPV_OUT" ]; then
    echo "[ToolchainSequence] ERROR: ReSTIRViewport.slang and ReSTIRViewport.spv are both absent."
    exit 1
fi

#---
#                                           DIRECTORIES
#---

[ "$REBUILD" -eq 1 ] && rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR" "$BIN_DIR"

#---
#                                          INCLUDE FLAGS
#---

INCLUDES=(
    "-I$REPO_ROOT"
    "-I$ENGINE_ROOT"
    "-I$PROJECT_ROOT/Source"
    "-I$VULKAN_INC"
    "-I$PKG_ROOT/imgui"
    "-I$PKG_ROOT/imgui/backends"
    "-I$PKG_ROOT/glfw/include"
    "-I$PKG_ROOT/thorvg/inc"
    "-I$PKG_ROOT/tomlpp/include"
    "-I$PKG_ROOT/jolt"
    "-I$PKG_ROOT/cgltf"
    "-I$PKG_ROOT/stb"
)

#---
#                                        COMPILER FLAGS
#---

if [ "$CONFIGURATION" = "release" ]; then
    OPT_FLAGS=("-O2" "-DNDEBUG")
else
    OPT_FLAGS=("-O0" "-g3" "-DFRONTIER_DEBUG=1")
fi

CXXFLAGS=(
    "-std=c++20"
    "-Wall" "-Wextra"
    "-fPIC"
    "-DFRONTIER_DEVELOPMENT"
    "-DFRONTIER_ENABLE_GLFW"
    "-DGLFW_INCLUDE_NONE"
    "${INCLUDES[@]}"
    "${OPT_FLAGS[@]}"
)

#---
#                                          SOURCES
#---

IMGUI_SRCS=(
    "$PKG_ROOT/imgui/imgui.cpp"
    "$PKG_ROOT/imgui/imgui_draw.cpp"
    "$PKG_ROOT/imgui/imgui_tables.cpp"
    "$PKG_ROOT/imgui/imgui_widgets.cpp"
    "$PKG_ROOT/imgui/backends/imgui_impl_glfw.cpp"
    "$PKG_ROOT/imgui/backends/imgui_impl_vulkan.cpp"
)

ENGINE_SRCS=(
    # DeviceExchange
    "$ENGINE_ROOT/DeviceExchange/SwapchainExchange.cpp"
    "$ENGINE_ROOT/DeviceExchange/VulkanExchange.cpp"
    "$ENGINE_ROOT/DeviceExchange/ByteSpace.cpp"
    "$ENGINE_ROOT/DeviceExchange/TaskScheduler.cpp"
    "$ENGINE_ROOT/DeviceExchange/ExecutionQueue.cpp"
    "$ENGINE_ROOT/DeviceExchange/VendorClassifier.cpp"
    "$ENGINE_ROOT/DeviceExchange/OrientationClassifier.cpp"
    "$ENGINE_ROOT/DeviceExchange/WindowExchange.cpp"
    "$ENGINE_ROOT/DeviceExchange/InputExchange.cpp"
    "$ENGINE_ROOT/DeviceExchange/RenderTargetExchange.cpp"
    "$ENGINE_ROOT/DeviceExchange/DiagnosticMetrics.cpp"
    # DisplayPresentation
    "$ENGINE_ROOT/DisplayPresentation/ReSTIRIntegrator.cpp"
    "$ENGINE_ROOT/DisplayPresentation/RenderScheduler.cpp"
    "$ENGINE_ROOT/DisplayPresentation/ThemeStructure.cpp"
    "$ENGINE_ROOT/DisplayPresentation/VectorCodec.cpp"
    "$ENGINE_ROOT/DisplayPresentation/FontCodec.cpp"
    "$ENGINE_ROOT/DisplayPresentation/ControlCentreHost.cpp"
    "$ENGINE_ROOT/DisplayPresentation/WorkspaceHost.cpp"
    "$ENGINE_ROOT/DisplayPresentation/CycleScheduler.cpp"
    "$ENGINE_ROOT/DisplayPresentation/FidelityClassifier.cpp"
    "$ENGINE_ROOT/DisplayPresentation/FrontierHost.cpp"
    # GeometricRaster
    "$ENGINE_ROOT/GeometricRaster/GeometryStructure.cpp"
    "$ENGINE_ROOT/GeometricRaster/CameraProjection.cpp"
    "$ENGINE_ROOT/GeometricRaster/VisibilityProjection.cpp"
    "$ENGINE_ROOT/GeometricRaster/RasterSequence.cpp"
    "$ENGINE_ROOT/GeometricRaster/MaterialCodec.cpp"
    # PhotometricIllumination
    "$ENGINE_ROOT/PhotometricIllumination/ClusteredSpace.cpp"
    "$ENGINE_ROOT/PhotometricIllumination/DirectIlluminationIntegrator.cpp"
    "$ENGINE_ROOT/PhotometricIllumination/GlobalIlluminationIntegrator.cpp"
    "$ENGINE_ROOT/PhotometricIllumination/AtmosphereIntegrator.cpp"
    # PhysicalDynamics
    "$ENGINE_ROOT/PhysicalDynamics/RigidBodySolver.cpp"
    "$ENGINE_ROOT/PhysicalDynamics/DeformableSolver.cpp"
    "$ENGINE_ROOT/PhysicalDynamics/LocomotionSolver.cpp"
    "$ENGINE_ROOT/PhysicalDynamics/WorldSpace.cpp"
    # VolumetricDynamics
    "$ENGINE_ROOT/VolumetricDynamics/LevelSetSpace.cpp"
    "$ENGINE_ROOT/VolumetricDynamics/FluidSolver.cpp"
    "$ENGINE_ROOT/VolumetricDynamics/ParticleIntegrator.cpp"
    # PlatformInterchange
    "$ENGINE_ROOT/PlatformInterchange/AcousticStructure.cpp"
    "$ENGINE_ROOT/PlatformInterchange/AcousticIntegrator.cpp"
    "$ENGINE_ROOT/PlatformInterchange/VoiceExchange.cpp"
    "$ENGINE_ROOT/PlatformInterchange/OnlineInterchange.cpp"
    # Project-Zero
    "$PROJECT_ROOT/Source/RayTracingSolver.cpp"
    "$PROJECT_ROOT/Source/FlyThroughSolver.cpp"
    "$PROJECT_ROOT/Source/GameExecution.cpp"
    # ImGui
    "${IMGUI_SRCS[@]}"
)

#---
#                                          COMPILE
#---

OBJ_FILES=()
TOTAL=${#ENGINE_SRCS[@]}
echo "[ToolchainSequence] Compiling $TOTAL translation units..."

for SRC in "${ENGINE_SRCS[@]}"; do
    BASENAME="$(basename "${SRC%.cpp}")"
    OBJ="$OBJ_DIR/${BASENAME}.o"
    OBJ_FILES+=("$OBJ")

    # Freshness check — skip if object is newer than source
    if [ "$REBUILD" -eq 0 ] && [ -f "$OBJ" ] && [ "$OBJ" -nt "$SRC" ]; then
        continue
    fi

    echo "  $CXX $(basename "$SRC")"
    "$CXX" "${CXXFLAGS[@]}" -c "$SRC" -o "$OBJ"
done

#---
#                                            LINK
#---

EXE="$BIN_DIR/Project-Zero"
echo "[ToolchainSequence] Linking $EXE..."

"$CXX" "${OBJ_FILES[@]}" \
    -L"$VULKAN_LIB" \
    "$GLFW_LIB" \
    "$THORVG_LIB" \
    -lvulkan \
    -lX11 -ldl -lpthread \
    -o "$EXE"

# Keep the renderer self-contained when launched outside the repository root.
cp "$SPV_OUT" "$BIN_DIR/ReSTIRViewport.spv"

echo "[ToolchainSequence] Build complete: $EXE"
echo "[ToolchainSequence] Runtime shader: $BIN_DIR/ReSTIRViewport.spv"

#---
#                                         OPTIONAL RUN
#---

if [ "$RUN" -eq 1 ]; then
    echo "[ToolchainSequence] Launching Project-Zero..."
    "$EXE"
fi
