#============================================================================================================================================
# Frontier/CMakeLists.txt — Linux/Cross-Platform CMake (for IDE integration and Linux builds only)
#   Windows builds use Projects/<Name>/Build/ToolchainSequence.ps1 (MSVC direct toolchain).
#   ExternalPackages/ are git submodules — run `git submodule update --init --recursive` first.
#
#   This branch (arena/01a071a3-slate) carries the Jolt bring-up only: Project-Physics + the engine files it needs. When it is
#   merged into the Project-Zero branch, append the FRONTIER_PHYSICS_* blocks below to that tree's CMakeLists.txt.
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
        "  powershell -File Projects\\Project-Physics\\Build\\ToolchainSequence.ps1\n"
        "CMake is supported on Linux / macOS only.")
endif()

# ─── ExternalPackages roots ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
set(EXT "${CMAKE_SOURCE_DIR}/ExternalPackages")

foreach(PKG jolt)
    if(NOT EXISTS "${EXT}/${PKG}/Jolt/Jolt.h")
        message(WARNING "[Frontier] ExternalPackages/${PKG} appears uninitialised. Run: git submodule update --init --recursive")
    endif()
endforeach()

#============================================================================================================================================
# Jolt Physics — compiled from the submodule as a static library, rigid-body subset (no GPU compute back ends / hair shaders)
#   Flags mirror Scripts/BuildJolt.sh. Jolt derives JPH_USE_* / JPH_DEBUG from the compiler flags and RegisterTypes() aborts on a
#   library/client mismatch, so FRONTIER_PHYSICS_FLAGS is applied to every target that includes <Jolt/Jolt.h> as well.
#============================================================================================================================================

set(FRONTIER_PHYSICS_FLAGS -mavx -mpopcnt -mfpmath=sse)

file(GLOB_RECURSE JOLT_SOURCES CONFIGURE_DEPENDS "${EXT}/jolt/Jolt/*.cpp")
list(FILTER JOLT_SOURCES EXCLUDE REGEX "/Compute/(CPU|DX12|VK|MTL)/")
list(FILTER JOLT_SOURCES EXCLUDE REGEX "/Shaders/(HairWrapper|TestComputeWrapper)\\.cpp$")

add_library(Jolt STATIC ${JOLT_SOURCES})
target_include_directories(Jolt PUBLIC "${EXT}/jolt")
target_compile_options(Jolt PUBLIC ${FRONTIER_PHYSICS_FLAGS} -pthread)
target_compile_options(Jolt PRIVATE -Wall -Wno-psabi -Wno-stringop-overflow)
target_compile_definitions(Jolt PUBLIC "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")   # Release → JPH_DEBUG off; Debug → asserts on (both sides)
target_link_libraries(Jolt PUBLIC pthread)

# ─── Engine sources shared by every project on this branch ─────────────────────────────────────────────────────────────────────────────────
set(FRONTIER_ENGINE_SOURCES
    Engine/DeviceExchange/OrientationClassifier.cpp
    Engine/DeviceExchange/DiagnosticMetrics.cpp
    Engine/PhysicalDynamics/RigidBodySolver.cpp
)

set(FRONTIER_ENGINE_INCLUDES
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/Engine
)

#============================================================================================================================================
# Project-Physics — Jolt rigid-body testbed (console; plane + falling boxes / spheres / capsules ticked from the main loop)
#============================================================================================================================================

add_executable(Project-Physics
    ${FRONTIER_ENGINE_SOURCES}
    Projects/Project-Physics/Source/DropSceneStructure.cpp
    Projects/Project-Physics/Source/GameExecution.cpp
)
target_include_directories(Project-Physics PRIVATE
    ${FRONTIER_ENGINE_INCLUDES}
    ${CMAKE_CURRENT_SOURCE_DIR}/Projects/Project-Physics/Source
)
target_compile_definitions(Project-Physics PRIVATE FRONTIER_DEVELOPMENT "$<$<CONFIG:Debug>:FRONTIER_DEBUG=1>")
target_compile_options(Project-Physics PRIVATE -Wall -Wextra -Wno-psabi)
target_link_libraries(Project-Physics PRIVATE Jolt pthread)
