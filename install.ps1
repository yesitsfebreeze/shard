# Shard installer for Windows — downloads the latest release binary and installs it.
#
# Usage:
#   irm https://raw.githubusercontent.com/yesitsfebreeze/shard/main/install.ps1 | iex
#
# Options (env vars):
#   $env:SHARD_VERSION = "v0.1.0"              Install a specific version
#   $env:SHARD_INSTALL_DIR = "C:\tools\shard"  Install directory

$ErrorActionPreference = "Stop"

$Repo = "yesitsfebreeze/shard"
$Target = "windows-amd64"
$Archive = "shard-${Target}.zip"
$Bin = "shard.exe"

# --- Resolve install directory ---

$InstallDir = $env:SHARD_INSTALL_DIR
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "shard\bin"
}

# --- Resolve version ---

$Version = $env:SHARD_VERSION
if (-not $Version) {
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction SilentlyContinue
        $Version = $release.tag_name
    } catch {}

    if (-not $Version -or $Version -eq "main") {
        $Version = "main"
    }
}

$DownloadUrl = "https://github.com/$Repo/releases/download/$Version/$Archive"

# --- Download and install ---

Write-Host "shard installer"
Write-Host "  platform: $Target"
Write-Host "  version:  $Version"
Write-Host "  install:  $InstallDir\$Bin"
Write-Host ""

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "shard-install-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    Write-Host "downloading ${Archive}..."
    $ArchivePath = Join-Path $TmpDir $Archive
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "error: no release found for $Target ($Version)"
        Write-Host ""
        Write-Host "available platforms: linux-amd64, linux-arm64, macos-amd64, macos-arm64, windows-amd64"
        Write-Host "check releases: https://github.com/$Repo/releases"
        exit 1
    }

    Write-Host "extracting..."
    Expand-Archive -Path $ArchivePath -DestinationPath $TmpDir -Force

    Write-Host "installing to ${InstallDir}..."
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Move-Item -Path (Join-Path $TmpDir $Bin) -Destination (Join-Path $InstallDir $Bin) -Force

    # --- Add to PATH if needed ---

    $UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($UserPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("PATH", "$InstallDir;$UserPath", "User")
        $env:PATH = "$InstallDir;$env:PATH"
        Write-Host ""
        Write-Host "added $InstallDir to user PATH (restart terminal to take effect)"
    }

    Write-Host ""
    Write-Host "done! shard installed to $InstallDir\$Bin"

} finally {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
