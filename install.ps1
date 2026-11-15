# Kurir — install the latest release on Windows, no admin required.
#
#   irm https://raw.githubusercontent.com/ginwa123/kurirw/main/install.ps1 | iex
#
# It downloads kurirw-windows-x86_64.zip from the latest GitHub release, unpacks it into
# %LOCALAPPDATA%\Kurir, and adds that folder to your user PATH. Set $env:KURIR_VERSION = "v0.1.0"
# to pin a release instead of taking the latest.
$ErrorActionPreference = "Stop"

$repo = "ginwa123/kurirw"
$version = if ($env:KURIR_VERSION) { $env:KURIR_VERSION } else { "latest" }
$dest = Join-Path $env:LOCALAPPDATA "Kurir"

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x86_64" }
if ($arch -ne "x86_64") {
    throw "Kurir has no $arch Windows build yet. Build it with: zig build -Doptimize=ReleaseSafe"
}

$asset = "kurirw-windows-$arch.zip"
$url = if ($version -eq "latest") {
    "https://github.com/$repo/releases/latest/download/$asset"
} else {
    "https://github.com/$repo/releases/download/$version/$asset"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("kurir-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    Write-Host "Kurir: downloading $asset"
    $zip = Join-Path $tmp $asset
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Write-Host ""
    Write-Host "installed  $dest\kurirw.exe"

    # The app goes on the USER PATH, so no elevation is needed to install it.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $entries = $userPath.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
    if (-not ($entries -contains $dest)) {
        $joined = if ($userPath.Trim().Length -eq 0) { $dest } else { ($userPath.TrimEnd(";") + ";" + $dest) }
        [Environment]::SetEnvironmentVariable("Path", $joined, "User")
        Write-Host ""
        Write-Host "note: added $dest to your user PATH — open a new terminal to pick it up."
    }

    Write-Host ""
    Write-Host "run it with:  $dest\kurirw.exe"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
