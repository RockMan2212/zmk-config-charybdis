param(
    [string]$Workspace = "C:\zmk-workspace",
    [string[]]$Shield = @("charybdis_left", "charybdis_right", "settings_reset"),
    [string]$Board = "nice_nano_v2",
    [switch]$SkipWestUpdate
)

$ErrorActionPreference = "Stop"

function Add-PathEntry {
    param([string]$PathEntry)

    if ((Test-Path -LiteralPath $PathEntry) -and
        -not (($env:Path -split ";") | Where-Object { $_.TrimEnd("\") -ieq $PathEntry.TrimEnd("\") })) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Assert-Command {
    param([string]$Command)

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }
}

$RepoRoot = $PSScriptRoot
$SourceConfig = Join-Path $RepoRoot "config"
$WorkspaceConfig = Join-Path $Workspace "config"

if (-not (Test-Path -LiteralPath $SourceConfig)) {
    throw "Config directory was not found: $SourceConfig"
}

Add-PathEntry "$env:APPDATA\Python\Python311\Scripts"
Add-PathEntry "$env:USERPROFILE\zephyr-sdk-0.16.8\arm-zephyr-eabi\bin"
Add-PathEntry "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\oss-winget.dtc_Microsoft.Winget.Source_8wekyb3d8bbwe\usr\bin"

if (-not $env:ZEPHYR_TOOLCHAIN_VARIANT) {
    $env:ZEPHYR_TOOLCHAIN_VARIANT = "zephyr"
}

if (-not $env:ZEPHYR_SDK_INSTALL_DIR) {
    $env:ZEPHYR_SDK_INSTALL_DIR = "$env:USERPROFILE\zephyr-sdk-0.16.8"
}

Assert-Command "west"
Assert-Command "cmake"
Assert-Command "ninja"
Assert-Command "dtc"
Assert-Command "arm-zephyr-eabi-gcc"

New-Item -ItemType Directory -Path $Workspace -Force | Out-Null

# Mirror config so removed files in the repo do not remain stale in the build workspace.
$resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path
$resolvedConfigParent = Split-Path -Parent $WorkspaceConfig
if (-not (Test-Path -LiteralPath $resolvedConfigParent)) {
    New-Item -ItemType Directory -Path $resolvedConfigParent -Force | Out-Null
}

if ((Test-Path -LiteralPath $WorkspaceConfig) -and
    -not ((Resolve-Path -LiteralPath $WorkspaceConfig).Path.StartsWith($resolvedWorkspace, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "Refusing to replace config outside workspace: $WorkspaceConfig"
}

robocopy $SourceConfig $WorkspaceConfig /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

Set-Location $Workspace

if (-not (Test-Path -LiteralPath (Join-Path $Workspace ".west\config"))) {
    west init -l config
}

if (-not $SkipWestUpdate) {
    west update --fetch-opt=--filter=tree:0
    west zephyr-export
}

$ZmkConfig = $WorkspaceConfig.Replace("\", "/")

foreach ($shieldName in $Shield) {
    $BuildDir = "build/$shieldName"
    Write-Host "Building $Board / $shieldName ..."
    $BuildArgs = @("build", "-p", "always", "-s", "zmk/app", "-d", $BuildDir, "-b", $Board)

    if ($shieldName -eq "charybdis_right") {
        $BuildArgs += @("-S", "studio-rpc-usb-uart")
    }

    $BuildArgs += @("--", "-DZMK_CONFIG=$ZmkConfig", "-DSHIELD=$shieldName")

    if ($shieldName -eq "charybdis_right") {
        $BuildArgs += "-DCONFIG_ZMK_STUDIO=y"
    }

    west @BuildArgs
}

Write-Host ""
Write-Host "Build artifacts:"
Get-ChildItem -Path (Join-Path $Workspace "build\*\zephyr\zmk.uf2") -ErrorAction SilentlyContinue |
    Sort-Object FullName |
    ForEach-Object {
        Write-Host ("  {0} ({1} bytes)" -f $_.FullName, $_.Length)
    }
