# Compiles the PocketTerm server (apps/pocketterm-server) into the binary the Windows app bundles for the
# built-in server: <out>\windows-<arch>\pocketterm-server.exe. Same as tool/server-sidecar.sh, for Windows runners.
#
#   pwsh tool/server-sidecar.ps1 [-Out <dir>]          (default -Out: build/server-sidecar)
#
# Uses fvm's Dart when fvm is installed, else the Dart on PATH (CI's, from the pinned Flutter: the workspace has
# Flutter packages, so `flutter pub get` resolves it).
param([string]$Out = 'build/server-sidecar')
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
  'Arm64' { 'arm64' }
  'X64' { 'x64' }
  default { throw "unsupported architecture: $_" }
}
$dir = Join-Path $Out "windows-$arch"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$fvm = [bool](Get-Command fvm -ErrorAction SilentlyContinue)
if ($fvm) { fvm dart pub get | Out-Null }
elseif (Get-Command flutter -ErrorAction SilentlyContinue) { flutter pub get | Out-Null }
else { dart pub get | Out-Null }
if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
$exe = Join-Path $dir 'pocketterm-server.exe'
if ($fvm) { fvm dart compile exe apps/pocketterm-server/bin/pocketterm_server.dart -o $exe }
else { dart compile exe apps/pocketterm-server/bin/pocketterm_server.dart -o $exe }
if ($LASTEXITCODE -ne 0) { throw 'dart compile exe failed' }
Write-Host "built $exe"
