# Frontier/Projects/Project-Ocean/Build/ToolchainSequence.ps1
#   Serves Project-Ocean (a WebGPU page: index.html + ES modules + WGSL) from Source/ over HTTP and opens the browser.
#   No compiler, no npm, no C++: the only toolchain is the browser (Chrome/Edge 113+, Firefox 141+, Safari 26).
#   Compatible with Windows PowerShell 5.1 and PowerShell 7+. Listens on http://localhost:<Port>/ (a non-admin prefix).
#
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1                   # serve + open http://localhost:8766/
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1 -Port 9001
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1 -NoBrowser
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1 -Proof            # opens the 6 s PASS/FAIL run
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1 -Dispersion       # single-wave dispersion proof
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1 -RunUp            # tier-2 solitary-wave run-up benchmark
#     powershell -File Projects\Project-Ocean\Build\ToolchainSequence.ps1 -Query 'tier=rtx&perkernel=1'
#
#   Stop with Ctrl-C. -Check only validates the source tree (files present, WGSL headers 142 wide) and exits.

[CmdletBinding()]
param(
    [int]    $Port      = 8766,
    [switch] $NoBrowser,
    [switch] $Proof,
    [switch] $Dispersion,
    [switch] $RunUp,
    [string] $Query     = '',
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
$SourceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Source'
if (-not (Test-Path (Join-Path $SourceRoot 'index.html')))
{
    Write-Error "Project-Ocean: $SourceRoot\index.html not found"
    exit 1
}

# ---- source check -----------------------------------------------------------------------------------------------------
$Required = @('index.html', 'GameExecution.js', 'SwellSolver.js', 'ShoalSolver.js', 'HorizonProjection.js', 'OceanStructure.js', 'TimingMetrics.js',
              'Shaders\SeaStructure.wgsl', 'Shaders\SwellSolver.wgsl', 'Shaders\FoamSolver.wgsl', 'Shaders\ShoalSolver.wgsl', 'Shaders\HorizonProjection.wgsl')
$Missing = @($Required | Where-Object { -not (Test-Path (Join-Path $SourceRoot $_)) })
if ($Missing.Count -gt 0)
{
    Write-Error ("Project-Ocean: missing " + ($Missing -join ', '))
    exit 1
}
foreach ($Relative in ($Required | Where-Object { $_ -match '\.(js|wgsl)$' }))
{
    $First = Get-Content -LiteralPath (Join-Path $SourceRoot $Relative) -TotalCount 1
    if ($First.Length -ne 142)
    {
        Write-Error "Project-Ocean: $Relative header is $($First.Length) characters, expected 142"
        exit 1
    }
}
Write-Host "Project-Ocean: $($Required.Count) source files present, headers 142 wide" -ForegroundColor Green
if ($Check) { exit 0 }

# ---- static server ----------------------------------------------------------------------------------------------------
$Mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.wgsl' = 'text/wgsl; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.csv'  = 'text/csv; charset=utf-8'
    '.md'   = 'text/markdown; charset=utf-8'
}

$Listener = New-Object System.Net.HttpListener
$Prefix   = "http://localhost:$Port/"
$Listener.Prefixes.Add($Prefix)
try
{
    $Listener.Start()
}
catch
{
    Write-Error "Project-Ocean: cannot listen on $Prefix ($($_.Exception.Message)). Try -Port with another number."
    exit 1
}

if ($Proof -and -not $Query) { $Query = 'seconds=6&proof=1&fixed=1&perkernel=1' }
if ($Dispersion -and -not $Query) { $Query = 'scene=mode&seconds=4&proof=1&fixed=1' }
if ($RunUp -and -not $Query) { $Query = 'scene=runup&seconds=60&proof=1&fixed=1&perkernel=1' }
$Url = $Prefix
if ($Query) { $Url = "$Prefix`?$Query" }
Write-Host "Project-Ocean: serving $SourceRoot at $Url  (Ctrl-C to stop)" -ForegroundColor Cyan
if (-not $NoBrowser)
{
    Start-Process $Url | Out-Null
}

try
{
    while ($Listener.IsListening)
    {
        $Context  = $Listener.GetContext()
        $Request  = $Context.Request
        $Response = $Context.Response
        $Path     = [Uri]::UnescapeDataString($Request.Url.AbsolutePath)
        if ($Path -eq '/') { $Path = '/index.html' }
        $Full = [IO.Path]::GetFullPath((Join-Path $SourceRoot ($Path.TrimStart('/') -replace '/', '\')))
        $Response.Headers['Cache-Control'] = 'no-store'
        if (-not $Full.StartsWith($SourceRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Full -PathType Leaf))
        {
            $Response.StatusCode = 404
            $Bytes = [Text.Encoding]::UTF8.GetBytes("404 $Path")
        }
        else
        {
            $Extension = [IO.Path]::GetExtension($Full).ToLowerInvariant()
            $Response.ContentType = if ($Mime.ContainsKey($Extension)) { $Mime[$Extension] } else { 'application/octet-stream' }
            $Bytes = [IO.File]::ReadAllBytes($Full)
        }
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
        $Response.OutputStream.Close()
        Write-Host ("{0} {1} {2}" -f $Response.StatusCode, $Request.HttpMethod, $Path)
    }
}
finally
{
    $Listener.Stop()
    $Listener.Close()
}
