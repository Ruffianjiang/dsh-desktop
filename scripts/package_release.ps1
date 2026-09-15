# package_release.ps1
# Build the Flutter Windows release and package it as a distributable zip.
# Spec: docs/06-迭代开发/20260904-M3对话工作台与系统集成/详细设计.md §6.1
#
# Requirements on the build machine:
#   - Flutter SDK >= 3.13 (in PATH, or pass -FlutterPath)
#   - Visual Studio 2022 + "Desktop development with C++" workload
#     (MSVC v143, Windows 10/11 SDK)  -> required by `flutter build windows`
#   - Enough free disk on the drive holding the repo (a clean Release build
#     needs several GB under build/windows/x64).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/package_release.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/package_release.ps1 -FlutterPath "C:\tools\flutter\bin\flutter.bat"
#
# Note: this script only packages. It does NOT bump pubspec.yaml; the product
# version is owned by apps/desktop_flutter/pubspec.yaml (0.4.0+1) and can be
# overridden here via -BuildName / -BuildNumber.

param(
  [string]$FlutterPath = "",
  [string]$BuildName   = "0.4.0",
  [int]   $BuildNumber = 1,
  [string]$OutDir      = ""
)

$ErrorActionPreference = "Stop"

# --- Resolve repo root (parent of scripts/) ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir "..")
$AppDir    = Join-Path $RepoRoot "apps/desktop_flutter"
$ReleaseOutDir = if ($OutDir) { $OutDir } else { Join-Path $RepoRoot "release" }
$ZipName  = "dsh-desktop-v$BuildName-mvp-windows-x64.zip"
$ZipPath  = Join-Path $ReleaseOutDir $ZipName

# --- Resolve flutter executable ---
if (-not $FlutterPath) {
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if ($flutter) { $FlutterPath = $flutter.Source }
  else {
    # common managed locations
    $candidates = @(
      "$env:USERPROFILE\.workbuddy\binaries\flutter\bin\flutter.bat",
      "$env:LOCALAPPDATA\flutter\bin\flutter.bat",
      "C:\tools\flutter\bin\flutter.bat"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $FlutterPath = $c; break } }
  }
}
if (-not $FlutterPath -or -not (Test-Path $FlutterPath)) {
  Write-Error "flutter not found. Install Flutter or pass -FlutterPath."
  exit 1
}
Write-Host "[1/4] flutter: $FlutterPath"

# --- Build (must run from the Flutter app root, not the monorepo root) ---
Write-Host "[2/4] flutter build windows --release (build-name=$BuildName build-number=$BuildNumber)"
Write-Host "      cwd: $AppDir"
Push-Location $AppDir
try {
  & $FlutterPath build windows --release --build-name=$BuildName --build-number=$BuildNumber
  if ($LASTEXITCODE -ne 0) {
    Write-Error "flutter build failed (exit $LASTEXITCODE). Ensure Visual Studio 'Desktop development with C++' is installed."
    exit $LASTEXITCODE
  }
} finally {
  Pop-Location
}

$ReleaseDir = Join-Path $AppDir "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $ReleaseDir "dsh_desktop.exe"))) {
  Write-Error "Expected build output not found: $ReleaseDir\dsh_desktop.exe"
  exit 1
}

# --- Embed distribution README (tracked template, lives next to this script) ---
$ReadmeTemplate = Join-Path $ScriptDir "dist-readme.md"
$DestReadme = Join-Path $ReleaseDir "README.md"
if (Test-Path $ReadmeTemplate) {
  Copy-Item $ReadmeTemplate $DestReadme -Force
  Write-Host "      embedded README.md"
}

# --- Package zip ---
Write-Host "[3/4] packaging $ZipName"
if (-not (Test-Path $ReleaseOutDir)) { New-Item -ItemType Directory -Path $ReleaseOutDir | Out-Null }
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
# Compress from inside Release so the zip root contains the app files directly.
Push-Location $ReleaseDir
Compress-Archive -Path * -DestinationPath $ZipPath -Force
Pop-Location

# --- Done ---
$ZipSizeMB = [math]::Round((Get-Item $ZipPath).Length / 1MB, 1)
Write-Host "[4/4] done -> $ZipPath ($ZipSizeMB MB)"
Write-Host "Distribute: unzip on target Windows x64; user must have Node.js >= dsh requirement preinstalled (see README.md)."
