# Frontier/Projects/Project-Physics/Build/ToolchainSequence.ps1
#   Builds Project-Physics with cl.exe / link.exe directly. Builds Jolt.lib first via Scripts\BuildJolt.ps1 when absent.
#   Compatible with Windows PowerShell 5.1 and PowerShell 7+. No Vulkan SDK, GLFW or shaders are needed for this project.
#
#     powershell -File Projects\Project-Physics\Build\ToolchainSequence.ps1
#     powershell -File Projects\Project-Physics\Build\ToolchainSequence.ps1 -Configuration Debug
#     powershell -File Projects\Project-Physics\Build\ToolchainSequence.ps1 -Rebuild -Run
#     powershell -File Projects\Project-Physics\Build\ToolchainSequence.ps1 -Run -RunArguments '--seconds','6','--quiet'

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Release',
    [switch]   $Rebuild,
    [switch]   $Run,
    [string[]] $RunArguments = @(),
    [int]      $Parallel = 0,
    # Instruction set of the OLDEST machine this binary must run on. MUST match every other Frontier build
    #    script: Jolt derives JPH_USE_AVX/SSE4_2/SSE4_1 from __AVX__ and RegisterTypes() aborts on a mismatch.
    #    ⚠️ Sandy Bridge Core i3 (e.g. i3-2120) has NO AVX -> 0xc000001d STATUS_ILLEGAL_INSTRUCTION at launch.
    [ValidateSet('SSE2', 'AVX', 'AVX2')] [string] $Isa = 'SSE2'
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$EngineRoot     = Join-Path $RepositoryRoot 'Engine'
$PackageRoot    = Join-Path $RepositoryRoot 'ExternalPackages'
$ScriptRoot     = Join-Path $RepositoryRoot 'Scripts'
$ProjectRoot    = Join-Path $RepositoryRoot 'Projects\Project-Physics'
$OutputRoot     = Join-Path $ProjectRoot    "Build\Output\Windows\$Configuration"

#---
#                                        CONSOLE REPORTING
#---

function Write-Report
{
    param([string] $Tag, [System.ConsoleColor] $Colour, [string] $Message)
    Write-Host ("[$Tag]".PadRight(10)) -ForegroundColor $Colour -NoNewline
    Write-Host " $Message"
}

function Write-Building([string] $Message) { Write-Report -Tag 'Build'    -Colour DarkGray -Message $Message }
function Write-Skipped([string]  $Message) { Write-Report -Tag 'SKIP'     -Colour Cyan     -Message $Message }
function Write-Rejected([string] $Message) { Write-Report -Tag 'FAILED'   -Colour Red      -Message $Message }
function Write-Produced([string] $Message) { Write-Report -Tag 'Compiled' -Colour Green    -Message $Message }

#---
#                                       TOOLCHAIN ACQUISITION
#---

function Import-ToolchainEnvironment
{
    if (Get-Command cl.exe -ErrorAction SilentlyContinue)
    {
        Write-Skipped 'toolchain already on PATH'
        return
    }

    $Candidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat'
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'
    )

    $Selected = $null
    foreach ($Candidate in $Candidates)
    {
        if (Test-Path $Candidate)
        {
            $Selected = $Candidate
            break
        }
    }

    if ($Selected -eq $null)
    {
        throw 'no vcvarsall.bat was found; the C++ toolchain is not installed where this script looks'
    }

    Write-Building "toolchain $Selected"

    $Captured = cmd.exe /c "`"$Selected`" x64 > nul & set"

    foreach ($Line in $Captured)
    {
        if ($Line -match '^([^=]+)=(.*)$')
        {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }

    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue))
    {
        throw 'vcvarsall.bat ran but cl.exe is still absent from PATH'
    }
}

#---
#                                         COMPILATION FLAGS  (ISA / runtime / NDEBUG set == Scripts\BuildJolt.ps1)
#---

function Get-CompilationFlags([string] $Selection)
{
    $MpFlag = '/MP'
    if ($Parallel -gt 0) { $MpFlag = "/MP$Parallel" }

    $Common = @(
        '/nologo'
        '/c'
        '/EHsc'
        $MpFlag
        '/MD'
        '/std:c++20'
        '/permissive-'
        '/fp:precise'
        '/W4'
        '/utf-8'
        '/Zc:__cplusplus'
        '/DWIN32_LEAN_AND_MEAN'
        '/DNOMINMAX'
        '/D_CRT_SECURE_NO_WARNINGS'
        '/DFRONTIER_DEVELOPMENT'
    )
    # Must equal BuildJolt.ps1: Jolt's RegisterTypes() aborts on an ISA/define mismatch.
    if ($Isa -ne 'SSE2') { $Common += "/arch:$Isa" }

    if ($Selection -eq 'Debug')
    {
        return $Common + @('/Od', '/Zi', '/Zf', '/DFRONTIER_DEBUG=1')
    }

    return $Common + @('/O2', '/Zi', '/Zf', '/DNDEBUG')
}

function Get-IncludePaths
{
    return @(
        "/I$RepositoryRoot"
        "/I$EngineRoot"
        "/I$(Join-Path $ProjectRoot 'Source')"
        "/I$(Join-Path $PackageRoot 'jolt')"
    )
}

#---
#                                          RESPONSE FILES
#---

function Write-ResponseFile([string] $ResponsePath, [string[]] $Arguments)
{
    $Lines = New-Object System.Collections.Generic.List[string]

    foreach ($Argument in $Arguments)
    {
        if ($Argument -notmatch '[ \t"]')
        {
            $Lines.Add($Argument)
        }
        else
        {
            $Trailing = 0
            while ($Trailing -lt $Argument.Length -and
                   $Argument[$Argument.Length - 1 - $Trailing] -eq '\')
            {
                $Trailing++
            }
            $Lines.Add('"' + $Argument + ('\' * $Trailing) + '"')
        }
    }

    [System.IO.File]::WriteAllText($ResponsePath, ($Lines -join "`r`n"), [System.Text.Encoding]::ASCII)
}

#---
#                                       TRANSLATION FRESHNESS
#---

function Test-ObjectFresh([string] $ObjectPath, [string] $SourcePath, [string] $DependencyPath)
{
    if ($Rebuild)                     { return $false }
    if (-not (Test-Path $ObjectPath)) { return $false }
    if (-not (Test-Path $SourcePath)) { return $false }

    $ObjectWritten = (Get-Item $ObjectPath).LastWriteTimeUtc

    if ($ObjectWritten -le (Get-Item $SourcePath).LastWriteTimeUtc) { return $false }
    if (-not (Test-Path $DependencyPath))                           { return $false }

    try
    {
        $Recorded = Get-Content $DependencyPath -Raw | ConvertFrom-Json
        $Included = $Recorded.Data.Includes
    }
    catch { return $false }

    if ($Included -eq $null) { return $false }

    foreach ($Header in $Included)
    {
        if (-not (Test-Path $Header))                                       { return $false }
        if ((Get-Item $Header).LastWriteTimeUtc -ge $ObjectWritten)         { return $false }
    }

    return $true
}

#---
#                                           TRANSLATION
#---

function Invoke-Translation([string[]] $Sources, [string] $Label, [string] $ObjectRoot, [string[]] $Flags, [string[]] $IncludePaths)
{
    if (-not (Test-Path $ObjectRoot))
    {
        New-Item -ItemType Directory -Force -Path $ObjectRoot | Out-Null
    }

    $DependencyRoot = Join-Path $ObjectRoot 'Dependency'
    if (-not (Test-Path $DependencyRoot))
    {
        New-Item -ItemType Directory -Force -Path $DependencyRoot | Out-Null
    }

    $Produced = New-Object System.Collections.Generic.List[string]
    $Stale    = New-Object System.Collections.Generic.List[string]

    foreach ($Source in $Sources)
    {
        $Stem           = [System.IO.Path]::GetFileNameWithoutExtension($Source)
        $ObjectPath     = Join-Path $ObjectRoot "$Stem.obj"
        $DependencyPath = Join-Path $DependencyRoot "$Stem.json"
        $Produced.Add($ObjectPath)

        if (-not (Test-ObjectFresh $ObjectPath $Source $DependencyPath))
        {
            $Stale.Add($Source)
        }
    }

    if ($Stale.Count -eq 0)
    {
        Write-Skipped "$Label unchanged"
        return $Produced.ToArray()
    }

    $Arguments = New-Object System.Collections.Generic.List[string]
    foreach ($F in $Flags)        { $Arguments.Add($F) }
    foreach ($I in $IncludePaths) { $Arguments.Add($I) }
    $Arguments.Add('/Fo' + $ObjectRoot + '\')
    $Arguments.Add("/Fd$(Join-Path $ObjectRoot 'ProjectPhysics.pdb')")
    $Arguments.Add('/sourceDependencies' + $DependencyRoot + '\')
    foreach ($S in $Stale)        { $Arguments.Add($S) }

    $ResponsePath = Join-Path $ObjectRoot 'ProjectPhysics.rsp'
    Write-ResponseFile $ResponsePath $Arguments.ToArray()

    Write-Building "$Label - translating $($Stale.Count) of $($Sources.Count)"

    $Diagnostics = & cl.exe '/nologo' "@$ResponsePath"
    $Rejected    = $LASTEXITCODE -ne 0

    $Notable = $Diagnostics | Where-Object { $_ -match ': (warning|error) ' -or $_ -match 'fatal error' }
    if ($Notable) { $Notable | ForEach-Object { Write-Host "    $_" } }

    if ($Rejected)
    {
        if ((-not $Notable) -and $Diagnostics) { $Diagnostics | ForEach-Object { Write-Host "    $_" } }
        Write-Rejected "$Label - cl.exe rejected the translation batch"
        throw "$Label - cl.exe rejected the translation batch"
    }

    return $Produced.ToArray()
}

#---
#                                     DEPENDENCY BUILD SCRIPTS
#---

function Invoke-DependencyScript([string] $ScriptPath, [string[]] $Arguments)
{
    $Host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if (Test-Path $Host51)
    {
        & $Host51 -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    }
    else
    {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    }

    return $LASTEXITCODE
}

#---
#                                           THE RUN
#---

Write-Host "Project-Physics - $Configuration"

Import-ToolchainEnvironment

# Ensure the Jolt submodule is present (soft on network failure when the directory is already populated)
Write-Building 'Ensuring ExternalPackages/jolt submodule is initialised...'
Push-Location $RepositoryRoot
$ErrorActionBak = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
& git submodule update --init -- ExternalPackages/jolt 2>&1 | Out-Null
$UpdateOk = $LASTEXITCODE -eq 0
$ErrorActionPreference = $ErrorActionBak
Pop-Location
if (-not $UpdateOk -and -not (Test-Path (Join-Path $PackageRoot 'jolt\Jolt\Jolt.h')))
{
    throw 'git submodule update failed and ExternalPackages\jolt is empty'
}

# Build Jolt.lib if absent (or on -Rebuild)
$JoltLib = Join-Path $PackageRoot "jolt\lib\$Configuration\Jolt.lib"
if ($Rebuild -or (-not (Test-Path $JoltLib)))
{
    Write-Building "Jolt.lib ($Configuration) absent or rebuild requested - invoking BuildJolt.ps1"
    # -Isa MUST be forwarded: an AVX Jolt.lib against an SSE2 client (or the reverse) aborts in RegisterTypes().
    $JoltArguments = @('-Configuration', $Configuration, '-Isa', $Isa)
    if ($Rebuild) { $JoltArguments += '-Rebuild' }
    $ExitCode = Invoke-DependencyScript (Join-Path $ScriptRoot 'BuildJolt.ps1') $JoltArguments
    if ($ExitCode -ne 0) { throw 'BuildJolt.ps1 failed' }
}
else
{
    Write-Skipped "Jolt.lib ($Configuration) present"
}

# Prepare output directory
if ($Rebuild -and (Test-Path $OutputRoot))
{
    Remove-Item (Join-Path $OutputRoot 'Object') -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$ObjectRoot = Join-Path $OutputRoot 'Object'

$Flags        = Get-CompilationFlags $Configuration
$IncludePaths = Get-IncludePaths

# Collect sources
$EngineRelative = @(
    'Engine\DeviceExchange\OrientationClassifier.cpp'
    'Engine\DeviceExchange\DiagnosticMetrics.cpp'
    'Engine\PhysicalDynamics\RigidBodySolver.cpp'
    'Projects\Project-Physics\Source\DropSceneStructure.cpp'
    'Projects\Project-Physics\Source\GameExecution.cpp'
)

$AllSources = New-Object System.Collections.Generic.List[string]
foreach ($Rel in $EngineRelative)
{
    $AllSources.Add((Join-Path $RepositoryRoot $Rel))
}

# Fail fast with NAMES if the source list ever rots.
$MissingSources = @($AllSources | Where-Object { -not (Test-Path $_) })
if ($MissingSources.Count -gt 0) { throw ('missing source files in the translation batch:' + [Environment]::NewLine + ($MissingSources -join [Environment]::NewLine)) }

# Translate
$ObjectFiles = Invoke-Translation $AllSources.ToArray() 'Project-Physics' $ObjectRoot $Flags $IncludePaths

# Link
$BinaryRoot = Join-Path $OutputRoot 'Binary'
New-Item -ItemType Directory -Force -Path $BinaryRoot | Out-Null

$ExePath = Join-Path $BinaryRoot 'Project-Physics.exe'

if (Test-Path $ExePath)
{
    try
    {
        Remove-Item $ExePath -Force -ErrorAction Stop
    }
    catch
    {
        $Running = Get-Process -Name 'Project-Physics' -ErrorAction SilentlyContinue
        if ($Running) { $Running | Stop-Process -Force }
        Start-Sleep -Milliseconds 200
        Remove-Item $ExePath -Force -ErrorAction Stop
    }
}

$LinkArgs = New-Object System.Collections.Generic.List[string]
$LinkArgs.Add('/nologo')
$LinkArgs.Add('/DEBUG')
$LinkArgs.Add('/SUBSYSTEM:CONSOLE')
$LinkArgs.Add("/OUT:$ExePath")
$LinkArgs.Add("/PDB:$(Join-Path $BinaryRoot 'Project-Physics.pdb')")
foreach ($Obj in $ObjectFiles) { $LinkArgs.Add($Obj) }
$LinkArgs.Add($JoltLib)

Write-Building 'Linking Project-Physics.exe...'
$Diagnostics = & link.exe @($LinkArgs.ToArray())

if ($LASTEXITCODE -ne 0)
{
    $Diagnostics | ForEach-Object { Write-Host "    $_" }
    Write-Rejected 'link.exe rejected Project-Physics'
    throw 'link.exe rejected Project-Physics'
}

Write-Produced $ExePath

if ($Run)
{
    Write-Building 'Launching Project-Physics (working directory = repository root)...'
    Push-Location $RepositoryRoot
    try     { & "$ExePath" @RunArguments; Write-Building "Project-Physics exited with code $LASTEXITCODE" }
    finally { Pop-Location }
}
