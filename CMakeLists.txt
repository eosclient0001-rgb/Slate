#============================================================================================================================================
# Frontier/CMakeLists.txt — Linux/Cross-Platform CMake (for IDE integration and Linux builds only)
#   Windows builds use Projects/Project-Zero/Build/ToolchainSequence.ps1 (MSVC direct toolchain).
#   ExternalPackages/ are git submodules — run `git submodule update --init --recursive` first.
#============================================================================================================================================

cmake_minimum_required(VERSION 3.20)
project(FrontierEngine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ─── Reject Windows CMake builds — use ToolchainSequence.ps1 instead ────────────────────────────────────────────────────────────────────────
if(WIN32 AND MSVC)
    message(FATAL_ERROR
        "[Frontier] Windows builds must use the direct MSVC toolchain:\n"
        "  pwsh -File Projects\\Project-Zero\\Build\\ToolchainSequence.ps1\n"
        "CMake is supported on Linux / macOS only.")
endif()

# ─── ExternalPackages roots ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
set(EXT "${CMAKE_SOURCE_DIR}/ExternalPackages")

# Verify submodules are initialised
foreach(PKG imgui glfw thorvg tomlpp jolt cgltf clipper2 earcut fast_obj miniaudio stb ufbx)
    if(NOT EXISTS "${EXT}/${PKG}/CMakeLists.txt" AND NOT EXISTS "${EXT}/${PKG}/include" AND NOT EXISTS "${EXT}/${PKG}/inc")
        message(WARNING "[Frontier] ExternalPackages/${PKG} appears uninitialised. Run: git submodule update --init --recursive")
    endif()
endforeach()

# ─── GLFW — built from source submodule (Linux static) ──────────────────────────────────────────────────────────────────────────────────────
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_DOCS     OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS   OFF CACHE BOOL "" FORCE)
add_subdirectory("${EXT}/glfw" "${CMAKE_BINARY_DIR}/glfw" EXCLUDE_FROM_ALL)

# ─── ThorVG — compile sources directly (no Meson/Ninja required) ────────────────────────────────────────────────────────────────────────────
set(THORVG_SRC "${EXT}/thorvg")

# Generate config.h for ThorVG
file(WRITE "${CMAKE_BINARY_DIR}/thorvg_config/config.h"
    "#pragma once\n"
    "#define THORVG_VERSION_STRING \"1.0.0\"\n"
    "#define THORVG_CPU_ENGINE_SUPPORT 1\n"
    "#define THORVG_SVG_LOADER_SUPPORT 1\n"
    "#define THORVG_THREAD_SUPPORT 1\n"
    "#define THORVG_FILE_IO_SUPPORT 1\n"
)

set(THORVG_SOURCES
    "${THORVG_SRC}/src/common/tvgCompressor.cpp"
    "${THORVG_SRC}/src/common/tvgMath.cpp"
    "${THORVG_SRC}/src/common/tvgStr.cpp"
    "${THORVG_SRC}/src/renderer/tvgAccessor.cpp"
    "${THORVG_SRC}/src/renderer/tvgAnimation.cpp"
    "${THORVG_SRC}/src/renderer/tvgCanvas.cpp"
    "${THORVG_SRC}/src/renderer/tvgFill.cpp"
    "${THORVG_SRC}/src/renderer/tvgInitializer.cpp"
    "${THORVG_SRC}/src/renderer/tvgLoaderMgr.cpp"
    "${THORVG_SRC}/src/renderer/tvgPaint.cpp"
    "${THORVG_SRC}/src/renderer/tvgPicture.cpp"
    "${THORVG_SRC}/src/renderer/tvgRender.cpp"
    "${THORVG_SRC}/src/renderer/tvgSaver.cpp"
    "${THORVG_SRC}/src/renderer/tvgScene.cpp"
    "${THORVG_SRC}/src/renderer/tvgShape.cpp"
    "${THORVG_SRC}/src/renderer/tvgTaskScheduler.cpp"
    "${THORVG_SRC}/src/renderer/tvgText.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwBlendOp.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwFill.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwImage.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwMemPool.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwPostEffect.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwRaster.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwRenderer.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwRle.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwShape.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwStroke.cpp"
    "${THORVG_SRC}/src/renderer/cpu_engine/tvgSwUtil.cpp"
    "${THORVG_SRC}/src/loaders/raw/tvgRawLoader.cpp"
    "${THORVG_SRC}/src/loaders/svg/tvgSvgBuilder.cpp"
    "${THORVG_SRC}/src/loaders/svg/tvgSvgCssStyle.cpp"
    "${THORVG_SRC}/src/loaders/svg/tvgSvgLoader.cpp"
    "${THORVG_SRC}/src/loaders/svg/tvgSvgPath.cpp"
    "${THORVG_SRC}/src/loaders/svg/tvgSvgUtil.cpp"
    "${THORVG_SRC}/src/loaders/svg/tvgXmlParser.cpp"
)

add_library(thorvg_static STATIC ${THORVG_SOURCES})
target_include_directories(thorvg_static PUBLIC
    "${THORVG_SRC}/inc"
    "${CMAKE_BINARY_DIR}/thorvg_config"
    "${THORVG_SRC}/src/common"
    "${THORVG_SRC}/src/renderer"
    "${THORVG_SRC}/src/renderer/cpu_engine"
    "${THORVG_SRC}/src/loaders/svg"
    "${THORVG_SRC}/src/loaders/raw"
)
target_compile_definitions(thorvg_static PRIVATE DTVG_STATIC DTVG_BUILD NOMINMAX)
target_compile_options(thorvg_static PRIVATE -fPIC -w)

# ─── ImGui — compiled as object lib (docking branch) ────────────────────────────────────────────────────────────────────────────────────────
set(IMGUI_SRC "${EXT}/imgui")
set(IMGUI_SOURCES
    "${IMGUI_SRC}/imgui.cpp"
    "${IMGUI_SRC}/imgui_draw.cpp"
    "${IMGUI_SRC}/imgui_tables.cpp"
    "${IMGUI_SRC}/imgui_widgets.cpp"
    "${IMGUI_SRC}/backends/imgui_impl_glfw.cpp"
    "${IMGUI_SRC}/backends/imgui_impl_vulkan.cpp"
)

# ─── Vulkan ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
find_package(Vulkan REQUIRED)

# ─── Shader lowering — the .slang file is GLSL source, compiled to SPIR-V ───────────────────────────────────────────────────────────────────
find_program(GLSLC_EXECUTABLE glslc
    HINTS "$ENV{VULKAN_SDK}/bin" "/usr/bin" "/usr/local/bin")
find_program(SLANGC_EXECUTABLE slangc
    HINTS "$ENV{VULKAN_SDK}/bin" "/usr/bin" "/usr/local/bin")

set(SLANG_SRC "${CMAKE_SOURCE_DIR}/Engine/Shaders/ReSTIRViewport.slang")
set(SPV_OUT   "${CMAKE_SOURCE_DIR}/Engine/Shaders/ReSTIRViewport.spv")
set(GLSLC_STAGE_SOURCE "${CMAKE_BINARY_DIR}/ReSTIRViewport.comp")

if(GLSLC_EXECUTABLE AND EXISTS "${SLANG_SRC}")
    add_custom_command(
        OUTPUT  "${SPV_OUT}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${SLANG_SRC}" "${GLSLC_STAGE_SOURCE}"
        COMMAND "${GLSLC_EXECUTABLE}"
                "-DFRONTIER_SHADER_TOOLCHAIN=1"
                "-I${CMAKE_SOURCE_DIR}/Engine"
                --target-env=vulkan1.2 -fshader-stage=compute
                "${GLSLC_STAGE_SOURCE}" -o "${SPV_OUT}"
        DEPENDS "${SLANG_SRC}"
        COMMENT "[Project-Zero] Compiling ReSTIRViewport.slang as GLSL compute → SPIR-V"
        VERBATIM)
    add_custom_target(ReSTIRViewportSpirv DEPENDS "${SPV_OUT}")
elseif(SLANGC_EXECUTABLE AND EXISTS "${SLANG_SRC}")
    add_custom_command(
        OUTPUT  "${SPV_OUT}"
        COMMAND "${SLANGC_EXECUTABLE}"
                "${SLANG_SRC}"
                "-DFRONTIER_SHADER_TOOLCHAIN=1"
                "-I${CMAKE_SOURCE_DIR}/Engine"
                -target spirv -profile glsl_450
                -o "${SPV_OUT}"
        DEPENDS "${SLANG_SRC}"
        COMMENT "[Project-Zero] Lowering ReSTIRViewport.slang → ReSTIRViewport.spv"
        VERBATIM)
    add_custom_target(ReSTIRViewportSpirv DEPENDS "${SPV_OUT}")
else()
    message(WARNING "[Project-Zero] glslc/slangc not found or ReSTIRViewport.slang absent — SPV must be pre-compiled.")
    add_custom_target(ReSTIRViewportSpirv)
endif()

# ─── Engine module sources ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
set(FRONTIER_ENGINE_SOURCES
    Engine/DeviceExchange/VulkanExchange.cpp
    Engine/DeviceExchange/ByteSpace.cpp
    Engine/DeviceExchange/TaskScheduler.cpp
    Engine/DeviceExchange/ExecutionQueue.cpp
    Engine/DeviceExchange/VendorClassifier.cpp
    Engine/DeviceExchange/OrientationClassifier.cpp
    Engine/DeviceExchange/WindowExchange.cpp
    Engine/DeviceExchange/InputExchange.cpp
    Engine/DeviceExchange/RenderTargetExchange.cpp
    Engine/DeviceExchange/DiagnosticMetrics.cpp
    Engine/PhysicalDynamics/RigidBodySolver.cpp
    Engine/PhysicalDynamics/DeformableSolver.cpp
    Engine/PhysicalDynamics/LocomotionSolver.cpp
    Engine/PhysicalDynamics/WorldSpace.cpp
    Engine/VolumetricDynamics/LevelSetSpace.cpp
    Engine/VolumetricDynamics/FluidSolver.cpp
    Engine/VolumetricDynamics/ParticleIntegrator.cpp
    Engine/GeometricRaster/GeometryStructure.cpp
    Engine/GeometricRaster/CameraProjection.cpp
    Engine/GeometricRaster/VisibilityProjection.cpp
    Engine/GeometricRaster/RasterSequence.cpp
    Engine/GeometricRaster/MaterialCodec.cpp
    Engine/PhotometricIllumination/ClusteredSpace.cpp
    Engine/PhotometricIllumination/DirectIlluminationIntegrator.cpp
    Engine/PhotometricIllumination/GlobalIlluminationIntegrator.cpp
    Engine/PhotometricIllumination/AtmosphereIntegrator.cpp
    Engine/PlatformInterchange/AcousticStructure.cpp
    Engine/PlatformInterchange/AcousticIntegrator.cpp
    Engine/PlatformInterchange/VoiceExchange.cpp
    Engine/PlatformInterchange/OnlineInterchange.cpp
    Engine/DisplayPresentation/ThemeStructure.cpp
    Engine/DisplayPresentation/VectorCodec.cpp
    Engine/DisplayPresentation/FontCodec.cpp
    Engine/DisplayPresentation/ControlCentreHost.cpp
    Engine/DisplayPresentation/WorkspaceHost.cpp
    Engine/DisplayPresentation/CycleScheduler.cpp
    Engine/DisplayPresentation/FidelityClassifier.cpp
    Engine/DisplayPresentation/FrontierHost.cpp
)

# ─── Engine common include dirs ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
set(FRONTIER_ENGINE_INCLUDES
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/Engine
    ${EXT}/tomlpp/include
    ${EXT}/jolt
)

#============================================================================================================================================
# Project-Zero — Windowed ReSTIR GI Renderer (Vulkan + GLFW + ImGui + ThorVG + Slang)
#============================================================================================================================================

set(PROJECT_ZERO_SOURCES
    ${FRONTIER_ENGINE_SOURCES}
    Engine/DeviceExchange/SwapchainExchange.cpp
    Engine/DisplayPresentation/ReSTIRIntegrator.cpp
    Engine/DisplayPresentation/RenderScheduler.cpp
    Projects/Project-Zero/Source/RayTracingSolver.cpp
    Projects/Project-Zero/Source/FlyThroughSolver.cpp
    Projects/Project-Zero/Source/GameExecution.cpp
    ${IMGUI_SOURCES}
)

add_executable(Project-Zero ${PROJECT_ZERO_SOURCES})
add_dependencies(Project-Zero ReSTIRViewportSpirv)
add_custom_command(TARGET Project-Zero POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${SPV_OUT}"
            "$<TARGET_FILE_DIR:Project-Zero>/ReSTIRViewport.spv"
    COMMENT "[Project-Zero] Packaging ReSTIRViewport.spv beside the executable")

target_include_directories(Project-Zero PRIVATE
    ${FRONTIER_ENGINE_INCLUDES}
    ${CMAKE_CURRENT_SOURCE_DIR}/Projects/Project-Zero/Source
    ${Vulkan_INCLUDE_DIRS}
    ${IMGUI_SRC}
    ${IMGUI_SRC}/backends
    ${EXT}/glfw/include
    ${THORVG_SRC}/inc
    ${EXT}/cgltf
    ${EXT}/stb
)

target_compile_definitions(Project-Zero PRIVATE
    FRONTIER_DEVELOPMENT
    FRONTIER_ENABLE_GLFW
    GLFW_INCLUDE_NONE
)

target_link_libraries(Project-Zero PRIVATE
    ${Vulkan_LIBRARIES}
    glfw
    thorvg_static
    pthread dl
)

#============================================================================================================================================
# FrontierEngine demo target (Linux only)
#============================================================================================================================================

add_executable(FrontierEngine
    ${FRONTIER_ENGINE_SOURCES}
    Engine/DisplayPresentation/EngineExecution.cpp
)
target_include_directories(FrontierEngine PRIVATE ${FRONTIER_ENGINE_INCLUDES})
target_link_libraries(FrontierEngine PRIVATE pthread)

#============================================================================================================================================
# Project-F20 — Racing Game
#============================================================================================================================================

set(PROJECT_F20_SOURCES
    ${FRONTIER_ENGINE_SOURCES}
    Projects/Project-F20/Source/VehicleStructure.h
    Projects/Project-F20/Source/VehicleSolver.cpp
    Projects/Project-F20/Source/TrackSequence.cpp
    Projects/Project-F20/Source/GameHost.cpp
    Projects/Project-F20/Source/GameExecution.cpp
)
add_executable(Project-F20 ${PROJECT_F20_SOURCES})
target_include_directories(Project-F20 PRIVATE
    ${FRONTIER_ENGINE_INCLUDES}
    ${CMAKE_CURRENT_SOURCE_DIR}/Projects/Project-F20/Source
)
target_link_libraries(Project-F20 PRIVATE pthread)
