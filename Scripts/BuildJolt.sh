#!/usr/bin/env bash
# BuildJolt.sh — compiles Jolt Physics as a static library with g++/clang++ directly (no CMake, no Ninja).
#                Mirrors Scripts/BuildJolt.ps1 flag-for-flag: Jolt derives its JPH_USE_* / JPH_DEBUG defines from the
#                compiler flags, and RegisterTypes() aborts at run time when the library and the client disagree, so the
#                ToolchainSequence that consumes this archive MUST pass the same -std / -m<isa> / NDEBUG set.
#
#     bash Scripts/BuildJolt.sh                 # Release  → ExternalPackages/jolt/lib/Release/libJolt.a
#     bash Scripts/BuildJolt.sh debug           # Debug    → ExternalPackages/jolt/lib/Debug/libJolt.a  (asserts on)
#     bash Scripts/BuildJolt.sh --rebuild
#     JOBS=4 CXX=clang++ bash Scripts/BuildJolt.sh

set -euo pipefail

Configuration='Release'
Rebuild=0
for Argument in "$@"
do
    case "$Argument" in
        debug|Debug)     Configuration='Debug' ;;
        release|Release) Configuration='Release' ;;
        --rebuild)       Rebuild=1 ;;
        *) echo "[FAILED]   unknown argument '$Argument'"; exit 1 ;;
    esac
done

ScriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RepositoryRoot="$(cd "$ScriptRoot/.." && pwd)"
JoltRoot="$RepositoryRoot/ExternalPackages/jolt"
BuildRoot="$JoltRoot/_build/$Configuration"
OutputRoot="$JoltRoot/lib/$Configuration"
Archive="$OutputRoot/libJolt.a"

CXX="${CXX:-g++}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

report() { printf '%-10s %s\n' "[$1]" "$2"; }

if [ ! -f "$JoltRoot/Jolt/Jolt.h" ]
then
    report 'FAILED' "Jolt submodule is absent at $JoltRoot; run: git submodule update --init ExternalPackages/jolt"
    exit 1
fi

if [ "$Rebuild" -eq 1 ]
then
    rm -rf "$BuildRoot" "$Archive"
fi
mkdir -p "$BuildRoot" "$OutputRoot"

#------------------------------------------------------------------------------------------------------------------------
#                                   FLAGS  (keep identical to Projects/*/Build/ToolchainSequence.sh)
#------------------------------------------------------------------------------------------------------------------------
# -mavx mirrors the Windows /arch:AVX so every host derives the same JPH_USE_AVX / SSE4_2 / SSE4_1 trio from Core.h.
# No optional JPH_* feature define is set on either side (no profiler, no debug renderer, no object stream, no double
# precision); JPH_DEBUG / JPH_ENABLE_ASSERTS follow NDEBUG exactly as they do for the engine translation units.
CommonFlags=(
    -std=c++20
    -c
    -mavx
    -mpopcnt
    -mfpmath=sse
    -fPIC
    -pthread
    -Wall
    -Wno-psabi
    -Wno-stringop-overflow
    "-I$JoltRoot"
)
if [ "$Configuration" = 'Debug' ]
then
    Flags=("${CommonFlags[@]}" -O0 -g)
else
    Flags=("${CommonFlags[@]}" -O2 -g -DNDEBUG)
fi

#------------------------------------------------------------------------------------------------------------------------
#                                                     SOURCES
#------------------------------------------------------------------------------------------------------------------------
# Every Jolt/*.cpp except the GPU compute back ends (DX12 / Vulkan / Metal / CPU-compute and their HLSL wrappers).
# Those need dxc-compiled shaders and are only used by Jolt's hair simulation; rigid bodies do not touch them.
mapfile -t Sources < <(find "$JoltRoot/Jolt" -name '*.cpp' \
    -not -path '*/Compute/CPU/*'  \
    -not -path '*/Compute/DX12/*' \
    -not -path '*/Compute/VK/*'   \
    -not -path '*/Compute/MTL/*'  \
    -not -name 'HairWrapper.cpp'  \
    -not -name 'TestComputeWrapper.cpp' | sort)

if [ "${#Sources[@]}" -eq 0 ]
then
    report 'FAILED' "no Jolt sources found under $JoltRoot/Jolt"
    exit 1
fi

#------------------------------------------------------------------------------------------------------------------------
#                                                   COMPILATION
#------------------------------------------------------------------------------------------------------------------------
Stale=()
Objects=()
for Source in "${Sources[@]}"
do
    Stem="$(basename "$Source" .cpp)"
    Object="$BuildRoot/$Stem.o"
    Objects+=("$Object")
    # Jolt has no duplicate basenames (checked at pin 2e28006e), so a flat object folder is safe.
    if [ ! -f "$Object" ] || [ "$Source" -nt "$Object" ]
    then
        Stale+=("$Source")
    fi
done

if [ "${#Stale[@]}" -eq 0 ] && [ -f "$Archive" ]
then
    report 'SKIP' "Jolt ($Configuration) unchanged - $Archive"
    exit 0
fi

report 'Build' "Jolt ($Configuration) - translating ${#Stale[@]} of ${#Sources[@]} units with $CXX, $JOBS jobs"

compile_one()
{
    local Source="$1"
    local Stem
    Stem="$(basename "$Source" .cpp)"
    "$CXX" "${Flags[@]}" -o "$BuildRoot/$Stem.o" "$Source"
}
export -f compile_one
export CXX BuildRoot
export FlagsSerialised
FlagsSerialised="$(printf '%q ' "${Flags[@]}")"

# xargs -P fans the translation out across cores; the flags are re-materialised inside each worker shell.
printf '%s\0' "${Stale[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c '
    eval "Flags=($FlagsSerialised)"
    Stem="$(basename "$0" .cpp)"
    if ! "$CXX" "${Flags[@]}" -o "$BuildRoot/$Stem.o" "$0"
    then
        echo "[FAILED]   $0"
        exit 255
    fi
'

#------------------------------------------------------------------------------------------------------------------------
#                                                     ARCHIVING
#------------------------------------------------------------------------------------------------------------------------
report 'Build' 'Jolt - archiving libJolt.a'
rm -f "$Archive"
ar rcs "$Archive" "${Objects[@]}"
report 'Compiled' "$Archive"
