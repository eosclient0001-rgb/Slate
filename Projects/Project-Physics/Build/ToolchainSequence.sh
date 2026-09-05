#!/usr/bin/env bash
# Frontier/Projects/Project-Physics/Build/ToolchainSequence.sh
#   Builds Project-Physics with g++/clang++ directly (no CMake). Builds libJolt.a first via Scripts/BuildJolt.sh when absent.
#
#     bash Projects/Project-Physics/Build/ToolchainSequence.sh
#     bash Projects/Project-Physics/Build/ToolchainSequence.sh debug
#     bash Projects/Project-Physics/Build/ToolchainSequence.sh --rebuild --run
#     bash Projects/Project-Physics/Build/ToolchainSequence.sh --run -- --seconds 6 --quiet     # arguments after -- go to the binary

set -euo pipefail

Configuration='Release'
Rebuild=0
Run=0
RunArguments=()
while [ $# -gt 0 ]
do
    case "$1" in
        debug|Debug)     Configuration='Debug' ;;
        release|Release) Configuration='Release' ;;
        --rebuild)       Rebuild=1 ;;
        --run)           Run=1 ;;
        --)              shift; RunArguments=("$@"); break ;;
        *) echo "[FAILED]   unknown argument '$1'"; exit 1 ;;
    esac
    shift
done

ScriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RepositoryRoot="$(cd "$ScriptRoot/../../.." && pwd)"
EngineRoot="$RepositoryRoot/Engine"
PackageRoot="$RepositoryRoot/ExternalPackages"
ProjectRoot="$RepositoryRoot/Projects/Project-Physics"
OutputRoot="$ProjectRoot/Build/Output/Linux/$Configuration"
ObjectRoot="$OutputRoot/Object"
BinaryRoot="$OutputRoot/Binary"
Executable="$BinaryRoot/Project-Physics"

CXX="${CXX:-g++}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

report() { printf '%-10s %s\n' "[$1]" "$2"; }

echo "Project-Physics - $Configuration"

#------------------------------------------------------------------------------------------------------------------------
#                                                   DEPENDENCIES
#------------------------------------------------------------------------------------------------------------------------
if [ ! -f "$PackageRoot/jolt/Jolt/Jolt.h" ]
then
    report 'Build' 'Jolt submodule absent - initialising ExternalPackages/jolt'
    (cd "$RepositoryRoot" && git submodule update --init -- ExternalPackages/jolt)
fi

JoltArchive="$PackageRoot/jolt/lib/$Configuration/libJolt.a"
if [ "$Rebuild" -eq 1 ]
then
    bash "$RepositoryRoot/Scripts/BuildJolt.sh" "$Configuration" --rebuild
elif [ ! -f "$JoltArchive" ]
then
    report 'Build' 'libJolt.a absent - invoking Scripts/BuildJolt.sh'
    bash "$RepositoryRoot/Scripts/BuildJolt.sh" "$Configuration"
else
    report 'SKIP' "Jolt ($Configuration) present"
fi

#------------------------------------------------------------------------------------------------------------------------
#                                          FLAGS  (ISA / NDEBUG set == Scripts/BuildJolt.sh)
#------------------------------------------------------------------------------------------------------------------------
CommonFlags=(
    -std=c++20
    -c
    -mavx
    -mpopcnt
    -mfpmath=sse
    -pthread
    -Wall
    -Wextra
    -Wno-psabi
    -DFRONTIER_DEVELOPMENT
    "-I$RepositoryRoot"
    "-I$EngineRoot"
    "-I$ProjectRoot/Source"
    "-I$PackageRoot/jolt"
)
if [ "$Configuration" = 'Debug' ]
then
    Flags=("${CommonFlags[@]}" -O0 -g -DFRONTIER_DEBUG=1)
else
    Flags=("${CommonFlags[@]}" -O2 -g -DNDEBUG)
fi

#------------------------------------------------------------------------------------------------------------------------
#                                                      SOURCES
#------------------------------------------------------------------------------------------------------------------------
Sources=(
    "$EngineRoot/DeviceExchange/OrientationClassifier.cpp"
    "$EngineRoot/DeviceExchange/DiagnosticMetrics.cpp"
    "$EngineRoot/PhysicalDynamics/RigidBodySolver.cpp"
    "$ProjectRoot/Source/DropSceneStructure.cpp"
    "$ProjectRoot/Source/GameExecution.cpp"
)
for Source in "${Sources[@]}"
do
    if [ ! -f "$Source" ]
    then
        report 'FAILED' "missing source file: $Source"
        exit 1
    fi
done

if [ "$Rebuild" -eq 1 ]
then
    rm -rf "$ObjectRoot"
fi
mkdir -p "$ObjectRoot" "$BinaryRoot"

#------------------------------------------------------------------------------------------------------------------------
#                                                     TRANSLATION
#------------------------------------------------------------------------------------------------------------------------
Objects=()
Stale=()
for Source in "${Sources[@]}"
do
    Stem="$(basename "$Source" .cpp)"
    Object="$ObjectRoot/$Stem.o"
    Objects+=("$Object")
    # Rebuild when the source, or any header it recorded in its .d file, is newer than the object.
    Fresh=0
    if [ -f "$Object" ] && [ ! "$Source" -nt "$Object" ] && [ -f "$ObjectRoot/$Stem.d" ]
    then
        Fresh=1
        while read -r Header
        do
            [ -z "$Header" ] && continue
            if [ ! -f "$Header" ] || [ "$Header" -nt "$Object" ]; then Fresh=0; break; fi
        done < <(sed -e 's/\\$//' -e 's/^[^:]*://' "$ObjectRoot/$Stem.d" | tr ' ' '\n' | grep -v '^$')
    fi
    [ "$Fresh" -eq 0 ] && Stale+=("$Source")
done

if [ "${#Stale[@]}" -eq 0 ]
then
    report 'SKIP' 'Project-Physics unchanged'
else
    report 'Build' "Project-Physics - translating ${#Stale[@]} of ${#Sources[@]}"
    FlagsSerialised="$(printf '%q ' "${Flags[@]}")"
    export CXX ObjectRoot FlagsSerialised
    printf '%s\0' "${Stale[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c '
        eval "Flags=($FlagsSerialised)"
        Stem="$(basename "$0" .cpp)"
        if ! "$CXX" "${Flags[@]}" -MMD -MF "$ObjectRoot/$Stem.d" -o "$ObjectRoot/$Stem.o" "$0"
        then
            echo "[FAILED]   $0"
            exit 255
        fi
    '
fi

#------------------------------------------------------------------------------------------------------------------------
#                                                        LINK
#------------------------------------------------------------------------------------------------------------------------
report 'Build' 'Linking Project-Physics...'
"$CXX" -pthread -o "$Executable" "${Objects[@]}" "$JoltArchive"
report 'Compiled' "$Executable"

if [ "$Run" -eq 1 ]
then
    report 'Build' 'Launching Project-Physics (working directory = repository root)...'
    (cd "$RepositoryRoot" && "$Executable" "${RunArguments[@]}")
    report 'Build' "Project-Physics exited with code $?"
fi
