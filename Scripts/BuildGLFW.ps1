# BuildGLFW.ps1 — builds GLFW from the submodule source and deposits the DLL import library
#                 and DLL into ExternalPackages/glfw/lib-vc2022/.
#
# Requirements:
#   - cmake.exe on PATH  (ships with Visual Studio 2022)
#   - MSVC toolchain     (imported by ToolchainSequence.ps1 before this is called)
#
#     powershell -File Scripts\BuildGLFW.ps1

[CmdletBinding()]
param(
    [switch] $Rebuild
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$PackageRoot    = Join-Path $RepositoryRoot 'ExternalPackages'
$GlfwRoot       = Join-Path $PackageRoot    'glfw'
$BuildDir       = Join-Path $GlfwRoot       '_build'
$OutputDir      = Join-Path $GlfwRoot       'lib-vc2022'

function Write-Report([string] $Tag, [System.ConsoleColor] $Colour, [string] $Message)
{
    Write-Host ("[$Tag]".PadRight(10)) -ForegroundColor $Colour -NoNewline
    Write-Host " $Message"
}

function Write-Building([string] $Message) { Write-Report 'Build'    DarkGray $Message }
function Write-Produced([string] $Message) { Write-Report 'Compiled' Green    $Message }

#---
#                                       PREREQUISITES
#---

# Ensure cmake.exe is on PATH -- look in VS 18 / VS 2022 CMake locations
if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue))
{
    $CmakeCandidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin',
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
    )
    foreach ($Cand in $CmakeCandidates)
    {
        if (Test-Path (Join-Path $Cand 'cmake.exe'))
        {
            $env:PATH = "$Cand;$env:PATH"
            break
        }
    }
    if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue))
    {
        throw 'cmake.exe is not on PATH; add it via Visual Studio Installer (CMake tools component) or standalone.'
    }
}


if (-not (Test-Path $GlfwRoot))
{
    throw "GLFW submodule is absent at $GlfwRoot; run: git submodule update --init ExternalPackages/glfw"
}

if (-not (Test-Path $OutputDir))
{
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

#---
#                                         CONFIGURE
#---

$Generator = 'Visual Studio 17 2022'
if (($env:VisualStudioVersion -like '18.*') -or
    (Test-Path 'C:\Program Files\Microsoft Visual Studio\18'))
{
    $Generator = 'Visual Studio 18 2026'
}

# A CMake build tree cannot be reused with a different Visual Studio generator.
$CachePath = Join-Path $BuildDir 'CMakeCache.txt'
if ($Rebuild -and (Test-Path $BuildDir))
{
    Remove-Item $BuildDir -Recurse -Force
}
elseif (Test-Path $CachePath)
{
    $RecordedGenerator = Get-Content $CachePath -ErrorAction SilentlyContinue |
                         Where-Object { $_ -like 'CMAKE_GENERATOR:INTERNAL=*' } |
                         Select-Object -First 1
    if ($RecordedGenerator -and ($RecordedGenerator -ne "CMAKE_GENERATOR:INTERNAL=$Generator"))
    {
        Write-Building 'GLFW - discarding a CMake cache produced by another Visual Studio version'
        Remove-Item $BuildDir -Recurse -Force
    }
}

Write-Building "GLFW - cmake configure ($Generator; $BuildDir)"

$ConfigArgs = @(
    '-S', $GlfwRoot
    '-B', $BuildDir
    '-G', $Generator
    '-A', 'x64'
    '-DBUILD_SHARED_LIBS=ON'
    '-DGLFW_BUILD_EXAMPLES=OFF'
    '-DGLFW_BUILD_TESTS=OFF'
    '-DGLFW_BUILD_DOCS=OFF'
    '-DGLFW_INSTALL=OFF'
    '--no-warn-unused-cli'
)

& cmake.exe @ConfigArgs
if ($LASTEXITCODE -ne 0)
{
    throw 'cmake configure failed for GLFW'
}

#---
#                                          BUILD
#---

Write-Building 'GLFW - cmake build (Release)'

$BuildArgs = @(
    '--build', $BuildDir
    '--config', 'Release'
    '--parallel'
)

& cmake.exe @BuildArgs
if ($LASTEXITCODE -ne 0)
{
    throw 'cmake build failed for GLFW'
}

#---
#                                         DEPOSIT
#---

# The Visual Studio generator places the DLL and import library under src/Release/.
$SrcDir = Join-Path $BuildDir 'src\Release'

$DllPath = Join-Path $SrcDir 'glfw3.dll'
$LibPath = Join-Path $SrcDir 'glfw3dll.lib'

if (-not (Test-Path $DllPath))
{
    throw "Expected glfw3.dll at $DllPath but it was not produced."
}

if (-not (Test-Path $LibPath))
{
    throw "Expected glfw3dll.lib at $LibPath but it was not produced."
}

Copy-Item $DllPath (Join-Path $OutputDir 'glfw3.dll')    -Force
Copy-Item $LibPath (Join-Path $OutputDir 'glfw3dll.lib') -Force

Write-Produced (Join-Path $OutputDir 'glfw3.dll')
Write-Produced (Join-Path $OutputDir 'glfw3dll.lib')
