<#
.SYNOPSIS
    Put the sensor into the probe's EXE/Script folder.

.DESCRIPTION
    Run in an elevated PowerShell on the probe host, straight from GitHub:
      irm https://raw.githubusercontent.com/CC-Digital-Innovation/prtg-morning-check/v1.0.0/deploy/Install-MorningCheck.ps1 | iex

    or from a checkout of this repo:
      .\deploy\Install-MorningCheck.ps1

    Run from GitHub it downloads Get-MorningCheck.ps1 from the release tag
    named below and refuses to install it unless its SHA-256 matches the
    hash below, so a changed repo or a tampered download installs nothing.
    Run from a checkout it copies the file next to it, unchecked: that copy
    is the one you have in front of you. Re-running upgrades in place. No
    service restart: PRTG reads the file on every scan.

    Releasing a new sensor: update $ref and $sha256 here, tag, push the tag.

    Environment overrides:
      PRTG_CUSTOM_SENSORS  the Custom Sensors folder, if auto-detection fails.
      GITHUB_TOKEN         a GitHub token, needed only while the repo is private.
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$file   = 'Get-MorningCheck.ps1'
$ref    = 'v1.0.0'                                                              # the tag the sensor is fetched from
$sha256 = '246d5ceddeaf40fe784af091d913425826ce7c8b953a389c01012430489b13c4'   # SHA-256 of sensor/Get-MorningCheck.ps1 at that tag
$repo   = 'CC-Digital-Innovation/prtg-morning-check'
$local  = if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) "sensor\$file" } else { '' }

if ($env:PRTG_CUSTOM_SENSORS) { $root = $env:PRTG_CUSTOM_SENSORS }
else {
    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'PRTG Network Monitor\Custom Sensors') }
    if ($env:ProgramFiles)        { $candidates += (Join-Path $env:ProgramFiles 'PRTG Network Monitor\Custom Sensors') }
    $root = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $root) { throw "PRTG 'Custom Sensors' folder not found (checked: $($candidates -join '; ')). Set `$env:PRTG_CUSTOM_SENSORS and re-run." }
}
$dest = Join-Path $root 'EXEXML'
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

if ($local -and (Test-Path -LiteralPath $local)) {
    Copy-Item -LiteralPath $local -Destination (Join-Path $dest $file) -Force
    Write-Host "Copied $file from the checkout"
}
else {
    $url = "https://raw.githubusercontent.com/$repo/$ref/sensor/$file"
    $headers = @{}
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "token $($env:GITHUB_TOKEN)" }
    $tmp = Join-Path $env:TEMP "$file.download"
    Invoke-WebRequest $url -Headers $headers -OutFile $tmp -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $sha256) {
        Remove-Item -LiteralPath $tmp -Force
        throw "Downloaded $file does not match the hash this installer expects (got $got, expected $sha256). Nothing installed."
    }
    Move-Item -LiteralPath $tmp -Destination (Join-Path $dest $file) -Force
    Write-Host "Downloaded $file from $repo at $ref, hash verified"
}
Write-Host "Installed to $dest" -ForegroundColor Green
Write-Host ''
Write-Host 'Next: from any machine that reaches the core, create the PRTG objects:'
Write-Host "  irm https://raw.githubusercontent.com/$repo/$ref/deploy/Deploy-MorningCheck.ps1 | iex"
