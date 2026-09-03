# Frontier/Projects/Project-Zero/Build/ToolchainSequence.ps1
#   Builds Project-Zero with cl.exe / lib.exe / link.exe directly.
#   Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#
#     powershell -File Projects\Project-Zero\Build\ToolchainSequence.ps1
#     powershell -File Projects\Project-Zero\Build\ToolchainSequence.ps1 -Configuration Debug
#     powershell -File Projects\Project-Zero\Build\ToolchainSequence.ps1 -Rebuild -Run

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Release',
    [switch] $Rebuild,
    [switch] $Run,
    [int]    $Parallel = 0
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$EngineRoot     = Join-Path $RepositoryRoot 'Engine'
$PackageRoot    = Join-Path $RepositoryRoot 'ExternalPackages'
$ScriptRoot     = Join-Path $RepositoryRoot 'Scripts'
$ProjectRoot    = Join-Path $RepositoryRoot 'Projects\Project-Zero'
$OutputRoot     = Join-Path $ProjectRoot    "Build\Output\Windows\$Configuration"

$script:GlfwBuilt   = $false
$script:ThorVGBuilt = $false

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
function Write-Lowered([string]  $Message) { Write-Report -Tag 'SPIR-V'   -Colour Magenta  -Message $Message }

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

function Resolve-VulkanRoot
{
    if ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK))
    {
        return $env:VULKAN_SDK
    }

    $Installed = Get-ChildItem 'C:\VulkanSDK' -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending |
                 Select-Object -First 1

    if ($Installed -eq $null)
    {
        throw 'no Vulkan SDK was found; VULKAN_SDK is unset and C:\VulkanSDK holds nothing'
    }

    return $Installed.FullName
}

#---
#                                         COMPILATION FLAGS
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
        '/DGLFW_DLL'
        '/DFRONTIER_DEVELOPMENT'
        '/DFRONTIER_ENABLE_GLFW'
    )

    if ($Selection -eq 'Debug')
    {
        return $Common + @('/Od', '/Zi', '/Zf', '/DFRONTIER_DEBUG=1')
    }

    return $Common + @('/O2', '/Zi', '/Zf', '/DNDEBUG')
}

#---
#                                           INCLUDE PATHS
#---

function Get-IncludePaths([string] $VulkanRoot)
{
    return @(
        "/I$RepositoryRoot"
        "/I$EngineRoot"
        "/I$(Join-Path $ProjectRoot 'Source')"
        "/I$(Join-Path $VulkanRoot  'Include')"
        "/I$(Join-Path $PackageRoot 'imgui')"
        "/I$(Join-Path $PackageRoot 'imgui\backends')"
        "/I$(Join-Path $PackageRoot 'glfw\include')"
        "/I$(Join-Path $PackageRoot 'thorvg\inc')"
        "/I$(Join-Path $PackageRoot 'tomlpp\include')"
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
        $DependencyPath = Join-Path $ObjectRoot "$Stem.deps.json"
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
    $Arguments.Add("/Fd$(Join-Path $ObjectRoot 'ProjectZero.pdb')")
    $Arguments.Add('/sourceDependencies' + $DependencyRoot + '\')
    foreach ($S in $Stale)        { $Arguments.Add($S) }

    $ResponsePath = Join-Path $ObjectRoot 'ProjectZero.rsp'
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

    foreach ($Source in $Stale)
    {
        $Stem              = [System.IO.Path]::GetFileNameWithoutExtension($Source)
        $FileName          = [System.IO.Path]::GetFileName($Source)
        $WrittenCandidateA = Join-Path $DependencyRoot "$FileName.json"
        $WrittenCandidateB = Join-Path $DependencyRoot "$Stem.json"
        $Wanted            = Join-Path $ObjectRoot     "$Stem.deps.json"

        if (Test-Path $WrittenCandidateA)
        {
            Move-Item $WrittenCandidateA $Wanted -Force
        }
        elseif (Test-Path $WrittenCandidateB)
        {
            Move-Item $WrittenCandidateB $Wanted -Force
        }
    }

    return $Produced.ToArray()
}

#---
#                                         SHADER LOWERING  (.slang -> SPIR-V)
#---

function Resolve-SlangCompiler([string] $VulkanRoot)
{
    $Compiler = Join-Path $VulkanRoot 'Bin\slangc.exe'

    if (-not (Test-Path $Compiler))
    {
        throw "the Vulkan SDK at $VulkanRoot carries no slangc.exe; install Slang via the Vulkan SDK installer"
    }

    return $Compiler
}

function Invoke-ShaderLowering([string] $VulkanRoot)
{
    $SlangSrc = Join-Path $EngineRoot 'Shaders\ReSTIRViewport.slang'

    if (-not (Test-Path $SlangSrc))
    {
        Write-Skipped 'no .slang shaders found in Engine\Shaders\ - skipping shader lowering'
        return
    }

    $Compiler  = Resolve-SlangCompiler $VulkanRoot
    $SpirvRoot = Join-Path $EngineRoot 'Shaders'
    $SpirvPath = Join-Path $SpirvRoot  'ReSTIRViewport.spv'

    if ((-not $Rebuild) -and (Test-Path $SpirvPath) -and
        (Get-Item $SpirvPath).LastWriteTimeUtc -gt (Get-Item $SlangSrc).LastWriteTimeUtc)
    {
        Write-Skipped 'ReSTIRViewport.slang unchanged'
        return
    }

    Write-Building 'Lowering ReSTIRViewport.slang -> ReSTIRViewport.spv'

    $Arguments = @(
        $SlangSrc
        '-DFRONTIER_SHADER_TOOLCHAIN=1'
        "-I$EngineRoot"
        '-target'
        'spirv'
        '-profile'
        'glsl_450'
        '-o'
        $SpirvPath
    )

    & $Compiler @Arguments | ForEach-Object { Write-Host "    $_" }

    if ($LASTEXITCODE -ne 0)
    {
        Write-Rejected 'slangc rejected ReSTIRViewport.slang'
        throw 'slangc rejected ReSTIRViewport.slang'
    }

    Write-Lowered $SpirvPath
}

#---
#                                     DEPENDENCY BUILD SCRIPTS
#---

function Invoke-DependencyScript([string] $ScriptPath, [string[]] $Arguments)
{
    # Works on both PS5.1 and PS7 - call powershell.exe explicitly so the
    # sub-script also runs under whichever host is available.
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

Write-Host "Project-Zero - $Configuration"

Import-ToolchainEnvironment
$VulkanRoot = Resolve-VulkanRoot
Write-Building "Vulkan SDK $VulkanRoot"

# Ensure submodules are present — all 12 packages, soft on network/SSL failure
Write-Building 'Ensuring ExternalPackages submodules are initialised...'
Push-Location $RepositoryRoot
$SubmoduleList = @(
    'ExternalPackages/imgui'
    'ExternalPackages/glfw'
    'ExternalPackages/thorvg'
    'ExternalPackages/tomlpp'
    'ExternalPackages/jolt'
    'ExternalPackages/ufbx'
    'ExternalPackages/earcut'
    'ExternalPackages/cgltf'
    'ExternalPackages/clipper2'
    'ExternalPackages/stb'
    'ExternalPackages/miniaudio'
    'ExternalPackages/fast_obj'
)
# Pass 1 — try normal update (will use cached objects when already checked out)
& git submodule update --init -- $SubmoduleList 2>&1 | Out-Null
$UpdateOk = $LASTEXITCODE -eq 0

if (-not $UpdateOk)
{
    # Pass 2 — SSL/network error; retry once with verification disabled
    Write-Skipped 'git submodule update failed; retrying with GIT_SSL_NO_VERIFY=1 ...'
    $env:GIT_SSL_NO_VERIFY = '1'
    & git submodule update --init -- $SubmoduleList 2>&1 | Out-Null
    $UpdateOk = $LASTEXITCODE -eq 0
    Remove-Item Env:\GIT_SSL_NO_VERIFY -ErrorAction SilentlyContinue
}

if (-not $UpdateOk)
{
    # 💡 git submodule update fails when:
    #    a) network/SSL is unavailable even with verification disabled
    #    b) the user did  git clone  without  --recurse-submodules
    #
    # In either case the directories may already be populated (manual clone or
    # prior successful init).  We check that every listed package directory is
    # non-empty — anything with at least one file is considered present.
    # An empty or absent directory means the submodule is genuinely missing.
    $Missing = New-Object System.Collections.Generic.List[string]
    foreach ($Sub in $SubmoduleList)
    {
        $SubPath  = Join-Path $RepositoryRoot $Sub
        $HasFiles = (Test-Path $SubPath) -and
                    ((Get-ChildItem $SubPath -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
        if (-not $HasFiles) { $Missing.Add($Sub) }
    }
    if ($Missing.Count -gt 0)
    {
        Write-Rejected 'git submodule update failed; these directories are absent or empty:'
        $Missing | ForEach-Object { Write-Host "    $_" }
        Pop-Location
        throw 'git submodule update failed and one or more ExternalPackages directories are missing'
    }
    Write-Skipped "git submodule update non-zero but all $($SubmoduleList.Count) package directories are present — continuing"
}
Pop-Location

# Build GLFW DLL if absent
$GlfwLib = Join-Path $PackageRoot 'glfw\lib-vc2022\glfw3dll.lib'
if ((-not (Test-Path $GlfwLib)) -and (-not $script:GlfwBuilt))
{
    Write-Building 'GLFW binaries absent - invoking BuildGLFW.ps1'
    $ExitCode = Invoke-DependencyScript (Join-Path $ScriptRoot 'BuildGLFW.ps1') @()
    if ($ExitCode -ne 0) { throw 'BuildGLFW.ps1 failed' }
    $script:GlfwBuilt = $true
}

# Build ThorVG static lib if absent
$ThorVGLib = Join-Path $PackageRoot 'thorvg\lib\thorvg.lib'
if ((-not (Test-Path $ThorVGLib)) -and (-not $script:ThorVGBuilt))
{
    Write-Building 'ThorVG library absent - invoking BuildThorVG.ps1'
    $ExitCode = Invoke-DependencyScript (Join-Path $ScriptRoot 'BuildThorVG.ps1') @('-Configuration', $Configuration)
    if ($ExitCode -ne 0) { throw 'BuildThorVG.ps1 failed' }
    $script:ThorVGBuilt = $true
}

# Lower shaders
Invoke-ShaderLowering $VulkanRoot

# Prepare output directory
if ($Rebuild -and (Test-Path $OutputRoot))
{
    Remove-Item (Join-Path $OutputRoot 'Object') -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$ObjectRoot = Join-Path $OutputRoot 'Object'

$Flags        = Get-CompilationFlags $Configuration
$IncludePaths = Get-IncludePaths $VulkanRoot

# Collect sources
$ImGuiSources = @(
    (Join-Path $PackageRoot 'imgui\imgui.cpp')
    (Join-Path $PackageRoot 'imgui\imgui_draw.cpp')
    (Join-Path $PackageRoot 'imgui\imgui_tables.cpp')
    (Join-Path $PackageRoot 'imgui\imgui_widgets.cpp')
    (Join-Path $PackageRoot 'imgui\backends\imgui_impl_glfw.cpp')
    (Join-Path $PackageRoot 'imgui\backends\imgui_impl_vulkan.cpp')
)

$EngineRelative = @(
    'Engine\DeviceExchange\SwapchainExchange.cpp'
    'Engine\DeviceExchange\VulkanExchange.cpp'
    'Engine\DeviceExchange\ByteSpace.cpp'
    'Engine\DeviceExchange\TaskScheduler.cpp'
    'Engine\DeviceExchange\ExecutionQueue.cpp'
    'Engine\DeviceExchange\VendorClassifier.cpp'
    'Engine\DeviceExchange\OrientationClassifier.cpp'
    'Engine\DeviceExchange\WindowExchange.cpp'
    'Engine\DeviceExchange\InputExchange.cpp'
    'Engine\DeviceExchange\RenderTargetExchange.cpp'
    'Engine\DeviceExchange\DiagnosticMetrics.cpp'
    'Engine\DisplayPresentation\ReSTIRIntegrator.cpp'
    'Engine\DisplayPresentation\RenderScheduler.cpp'
    'Engine\DisplayPresentation\ThemeStructure.cpp'
    'Engine\DisplayPresentation\VectorCodec.cpp'
    'Engine\DisplayPresentation\FontCodec.cpp'
    'Engine\DisplayPresentation\ControlCentreHost.cpp'
    'Engine\DisplayPresentation\WorkspaceHost.cpp'
    'Engine\DisplayPresentation\CycleScheduler.cpp'
    'Engine\DisplayPresentation\FidelityClassifier.cpp'
    'Engine\DisplayPresentation\FrontierHost.cpp'
    'Engine\GeometricRaster\GeometryStructure.cpp'
    'Engine\GeometricRaster\CameraProjection.cpp'
    'Engine\GeometricRaster\VisibilityProjection.cpp'
    'Engine\GeometricRaster\RasterSequence.cpp'
    'Engine\GeometricRaster\MaterialCodec.cpp'
    'Engine\PhotometricIllumination\ClusteredSpace.cpp'
    'Engine\PhotometricIllumination\DirectIlluminationIntegrator.cpp'
    'Engine\PhotometricIllumination\GlobalIlluminationIntegrator.cpp'
    'Engine\PhotometricIllumination\AtmosphereIntegrator.cpp'
    'Engine\PhysicalDynamics\RigidBodySolver.cpp'
    'Engine\PhysicalDynamics\DeformableSolver.cpp'
    'Engine\PhysicalDynamics\LocomotionSolver.cpp'
    'Engine\PhysicalDynamics\WorldSpace.cpp'
    'Engine\VolumetricDynamics\LevelSetSpace.cpp'
    'Engine\VolumetricDynamics\FluidSolver.cpp'
    'Engine\VolumetricDynamics\ParticleIntegrator.cpp'
    'Engine\PlatformInterchange\AcousticStructure.cpp'
    'Engine\PlatformInterchange\AcousticIntegrator.cpp'
    'Engine\PlatformInterchange\VoiceExchange.cpp'
    'Engine\PlatformInterchange\OnlineInterchange.cpp'
    'Projects\Project-Zero\Source\RayTracingSolver.cpp'
    'Projects\Project-Zero\Source\FlyThroughSolver.cpp'
    'Projects\Project-Zero\Source\GameExecution.cpp'
)

$EngineSources = New-Object System.Collections.Generic.List[string]
foreach ($Rel in $EngineRelative)
{
    $EngineSources.Add((Join-Path $RepositoryRoot $Rel))
}

$AllSources = New-Object System.Collections.Generic.List[string]
foreach ($S in $EngineSources) { $AllSources.Add($S) }
foreach ($S in $ImGuiSources)  { $AllSources.Add($S) }

# Translate
$ObjectFiles = Invoke-Translation $AllSources.ToArray() 'Project-Zero' $ObjectRoot $Flags $IncludePaths

# Link
$BinaryRoot = Join-Path $OutputRoot 'Binary'
New-Item -ItemType Directory -Force -Path $BinaryRoot | Out-Null

$ExePath = Join-Path $BinaryRoot 'Project-Zero.exe'

# Copy GLFW DLL beside executable
$GlfwDll = Join-Path $PackageRoot 'glfw\lib-vc2022\glfw3.dll'
if (Test-Path $GlfwDll) { Copy-Item $GlfwDll $BinaryRoot -Force }

if (Test-Path $ExePath)
{
    try
    {
        Remove-Item $ExePath -Force -ErrorAction Stop
    }
    catch
    {
        $Running = Get-Process -Name 'Project-Zero' -ErrorAction SilentlyContinue
        if ($Running) { $Running | Stop-Process -Force }
        Start-Sleep -Milliseconds 200
        Remove-Item $ExePath -Force -ErrorAction Stop
    }
}

$LinkArgs = New-Object System.Collections.Generic.List[string]
$LinkArgs.Add('/nologo')
$LinkArgs.Add('/DEBUG')
$LinkArgs.Add('/SUBSYSTEM:WINDOWS')
$LinkArgs.Add('/entry:mainCRTStartup')          # 📌 keeps int main() signature with SUBSYSTEM:WINDOWS — no console window
$LinkArgs.Add("/OUT:$ExePath")
$LinkArgs.Add("/PDB:$(Join-Path $BinaryRoot 'Project-Zero.pdb')")
foreach ($Obj in $ObjectFiles)                    { $LinkArgs.Add($Obj) }
$LinkArgs.Add((Join-Path $VulkanRoot 'Lib\vulkan-1.lib'))
$LinkArgs.Add((Join-Path $PackageRoot 'glfw\lib-vc2022\glfw3dll.lib'))
$LinkArgs.Add((Join-Path $PackageRoot 'thorvg\lib\thorvg.lib'))
$LinkArgs.Add('gdi32.lib')
$LinkArgs.Add('user32.lib')
$LinkArgs.Add('shell32.lib')

Write-Building 'Linking Project-Zero.exe...'
$Diagnostics = & link.exe @($LinkArgs.ToArray())

if ($LASTEXITCODE -ne 0)
{
    $Diagnostics | ForEach-Object { Write-Host "    $_" }
    Write-Rejected 'link.exe rejected Project-Zero'
    throw 'link.exe rejected Project-Zero'
}

Write-Produced $ExePath

if ($Run)
{
    Write-Building 'Launching Project-Zero...'
    & "$ExePath"
}
