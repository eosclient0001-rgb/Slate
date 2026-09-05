# BuildJolt.ps1 — compiles Jolt Physics as a static library using MSVC directly (cl.exe and lib.exe).
#                 Requires no CMake, Python, Meson or Ninja. Mirrors Scripts/BuildJolt.sh flag-for-flag.
#
#     powershell -File Scripts\BuildJolt.ps1                          # Release → ExternalPackages\jolt\lib\Release\Jolt.lib
#     powershell -File Scripts\BuildJolt.ps1 -Configuration Debug     # Debug   → ExternalPackages\jolt\lib\Debug\Jolt.lib  (asserts on)
#     powershell -File Scripts\BuildJolt.ps1 -Rebuild
#
# ⚠️  Jolt derives its JPH_USE_* / JPH_DEBUG defines from the compiler flags and RegisterTypes() aborts at run time when the
#     library and the client disagree. Every ToolchainSequence.ps1 that links Jolt.lib MUST compile its own translation units
#     with the same /arch, /MD|/MDd and NDEBUG choices made here (Project-Zero already uses /MD + /arch:AVX + /DNDEBUG).

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Release',
    [switch] $Rebuild,
    [int]    $Parallel = 0
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$PackageRoot    = Join-Path $RepositoryRoot 'ExternalPackages'
$JoltRoot       = Join-Path $PackageRoot    'jolt'
$BuildDir       = Join-Path $JoltRoot       "_build\$Configuration"
$OutputDir      = Join-Path $JoltRoot       "lib\$Configuration"
$Archive        = Join-Path $OutputDir      'Jolt.lib'

function Write-Report([string] $Tag, [System.ConsoleColor] $Colour, [string] $Message)
{
    Write-Host ("[$Tag]".PadRight(10)) -ForegroundColor $Colour -NoNewline
    Write-Host " $Message"
}

function Write-Building([string] $Message) { Write-Report 'Build'    DarkGray $Message }
function Write-Skipped([string]  $Message) { Write-Report 'SKIP'     Cyan     $Message }
function Write-Produced([string] $Message) { Write-Report 'Compiled' Green    $Message }

#---
#                                       TOOLCHAIN
#---

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue))
{
    $Candidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'
    )

    $Selected = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($null -eq $Selected)
    {
        throw 'no vcvarsall.bat was found; cl.exe is not on PATH'
    }

    $Captured = cmd.exe /c "`"$Selected`" x64 > nul & set"
    foreach ($Line in $Captured)
    {
        if ($Line -match '^([^=]+)=(.*)$')
        {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Test-Path (Join-Path $JoltRoot 'Jolt\Jolt.h')))
{
    throw "Jolt submodule is absent at $JoltRoot; run: git submodule update --init ExternalPackages/jolt"
}

if ($Rebuild -and (Test-Path $BuildDir))
{
    Remove-Item $BuildDir -Recurse -Force
}
if (-not (Test-Path $BuildDir))  { New-Item -ItemType Directory -Force -Path $BuildDir  | Out-Null }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

#---
#                                       SOURCES
#---
# Every Jolt\*.cpp except the GPU compute back ends (DX12 / Vulkan / Metal / CPU-compute and their HLSL wrappers): those
# need dxc-compiled shaders and are only used by Jolt's hair simulation; rigid bodies never touch them.

$Sources = Get-ChildItem (Join-Path $JoltRoot 'Jolt') -Recurse -Filter '*.cpp' |
           Where-Object {
               $_.FullName -notmatch '\\Compute\\(CPU|DX12|VK|MTL)\\' -and
               $_.Name -ne 'HairWrapper.cpp' -and
               $_.Name -ne 'TestComputeWrapper.cpp'
           } |
           Sort-Object FullName

if ($Sources.Count -eq 0)
{
    throw "no Jolt sources found under $JoltRoot\Jolt"
}

#---
#                                       FLAGS  (keep identical to Projects\*\Build\ToolchainSequence.ps1)
#---

$MpFlag = '/MP'
if ($Parallel -gt 0) { $MpFlag = "/MP$Parallel" }

$Flags = @(
    '/nologo'
    '/c'
    $MpFlag
    '/std:c++20'
    '/permissive-'
    '/Zc:__cplusplus'
    '/Zc:inline'
    '/fp:precise'
    '/W3'
    '/utf-8'
    '/arch:AVX'          # == Project-Zero; Core.h derives JPH_USE_AVX / SSE4_2 / SSE4_1 from __AVX__
    '/EHsc'              # == Project-Zero (Jolt itself never throws, but the flag must match the client)
    '/MD'                # == Project-Zero in BOTH configurations (its Debug is /MD + /Od, never /MDd) - LNK2038 otherwise
    '/DWIN32_LEAN_AND_MEAN'
    '/DNOMINMAX'
    "/I$JoltRoot"
)
# RTTI is left at the MSVC default (/GR) because Project-Zero does not pass /GR-; Jolt uses no RTTI itself, so either
# setting works as long as the library and the client agree.

if ($Configuration -eq 'Debug')
{
    $Flags += @('/Od', '/Zi', "/Fd$(Join-Path $BuildDir 'Jolt.pdb')")                # no NDEBUG → JPH_DEBUG + JPH_ENABLE_ASSERTS
}
else
{
    $Flags += @('/O2', '/Zi', "/Fd$(Join-Path $BuildDir 'Jolt.pdb')", '/DNDEBUG')
}

#---
#                                       COMPILATION
#---
# Jolt has no duplicate basenames (checked at pin 2e28006e), so a flat object folder is safe.

$Stale   = New-Object System.Collections.Generic.List[string]
$Objects = New-Object System.Collections.Generic.List[string]

foreach ($Src in $Sources)
{
    $Stem = [System.IO.Path]::GetFileNameWithoutExtension($Src.FullName)
    $Obj  = Join-Path $BuildDir "$Stem.obj"
    $Objects.Add($Obj)

    if ((Test-Path $Obj) -and ((Get-Item $Obj).LastWriteTimeUtc -gt $Src.LastWriteTimeUtc))
    {
        continue
    }
    $Stale.Add($Src.FullName)
}

if ($Stale.Count -eq 0 -and (Test-Path $Archive))
{
    Write-Skipped "Jolt ($Configuration) unchanged - $Archive"
    exit 0
}

Write-Building "Jolt ($Configuration) - translating $($Stale.Count) of $($Sources.Count) translation units"

if ($Stale.Count -gt 0)
{
    # One cl.exe invocation with /MP: the compiler fans the batch out across cores itself.
    $ResponsePath = Join-Path $BuildDir 'Jolt.rsp'
    $Lines = New-Object System.Collections.Generic.List[string]
    foreach ($F in $Flags) { if ($F -match '[ \t"]') { $Lines.Add('"' + $F + '"') } else { $Lines.Add($F) } }
    $Lines.Add('"/Fo' + $BuildDir + '\"')
    foreach ($S in $Stale) { $Lines.Add('"' + $S + '"') }
    [System.IO.File]::WriteAllText($ResponsePath, ($Lines -join "`r`n"), [System.Text.Encoding]::ASCII)

    $Diagnostics = & cl.exe '/nologo' "@$ResponsePath"
    $Notable = $Diagnostics | Where-Object { $_ -match ': (warning|error) ' -or $_ -match 'fatal error' }
    if ($Notable) { $Notable | ForEach-Object { Write-Host "    $_" } }
    if ($LASTEXITCODE -ne 0)
    {
        throw 'cl.exe rejected the Jolt translation batch'
    }
}

#---
#                                       ARCHIVING
#---

Write-Building 'Jolt - archiving Jolt.lib'

$LibArgs = @('/nologo', "/OUT:$Archive") + $Objects.ToArray()
$LibOutput = & lib.exe @LibArgs
if ($LASTEXITCODE -ne 0)
{
    $LibOutput | ForEach-Object { Write-Host "    $_" }
    throw 'lib.exe failed for Jolt.lib'
}

Write-Produced $Archive
