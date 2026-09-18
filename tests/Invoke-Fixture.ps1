<#
.SYNOPSIS
    Run the sensor against the synthetic fixtures and check the shape of what
    PRTG would receive. No PRTG needed.
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$sensor = Join-Path $root 'sensor\Get-MorningCheck.ps1'
$fail   = 0

function Check([string]$Name, [bool]$Ok, [string]$Got) {
    if ($Ok) { Write-Host "  ok   $Name" }
    else     { Write-Host "  FAIL $Name`n       got: $Got"; $script:fail++ }
}

Write-Host 'findings, default (Down every run, Lab excluded, self excluded)'
$out = & $sensor -FixtureFile (Join-Path $root 'fixtures\sensors-findings.json') -SelfSensorId 9001 -ExcludeGroups 'Lab' | Out-String
Check 'state is Down'                 ($out -match '<error>1</error>') $out
Check 'header counts 5 to check'      ($out -match '5 to check: 1 unknown, 1 down, 2 acknowledged, 1 partial') $out
Check 'self is not listed'            ($out -notmatch 'Morning Check > Morning Check') $out
Check 'Lab is excluded'               ($out -notmatch 'Bench Switch') $out
Check 'DOWN listed before ACK'        ($out.IndexOf('DOWN:') -lt $out.IndexOf('ACK:')) $out
Check 'ampersand is escaped'          ($out -match 'Backup &amp; Archive NAS') $out
Check 'no unescaped ampersand'        ($out -notmatch '&(?!amp;|lt;|gt;|quot;|apos;)') $out

Write-Host 'findings, acknowledged treated as clear'
$out = & $sensor -FixtureFile (Join-Path $root 'fixtures\sensors-findings.json') -SelfSensorId 9001 -ExcludeGroups 'Lab' -AcknowledgedIsClear | Out-String
Check 'header counts 3 to check'      ($out -match '3 to check:') $out
Check 'ACK lines still listed'        ($out -match 'ACK: ') $out

Write-Host 'findings, message budget'
$out = & $sensor -FixtureFile (Join-Path $root 'fixtures\sensors-findings.json') -SelfSensorId 9001 -MaxChars 160 | Out-String
Check 'list is cut with +N more'      ($out -match '\+\d+ more') $out
Check 'header survives the cut'       ($out -match 'to check:') $out

Write-Host 'clear morning, default (all-clear post)'
$out = & $sensor -FixtureFile (Join-Path $root 'fixtures\sensors-clear.json') -SelfSensorId 9001 | Out-String
Check 'state is Down'                 ($out -match '<error>1</error>') $out
Check 'message says ALL CLEAR'        ($out -match 'ALL CLEAR: 0 unknown, 0 down, 0 acknowledged, 0 partial') $out

Write-Host 'missing and unsubstituted token'
$out = & $sensor | Out-String
Check 'reports a missing key as a sensor error'      ($out -match '<error>1</error>.*No API key') $out
$out = & $sensor -Token '%windowspassword' | Out-String
Check 'reports an unfilled placeholder as an error'  ($out -match '<error>1</error>.*placeholder was not filled in') $out

Write-Host 'installer hash matches the sensor file'
$installer = Get-Content -LiteralPath (Join-Path $root 'deploy\Install-MorningCheck.ps1') -Raw
$pinned = [regex]::Match($installer, "\`$sha256\s*=\s*'([0-9a-f]{64})'").Groups[1].Value
$actual = (Get-FileHash -LiteralPath $sensor -Algorithm SHA256).Hash.ToLower()
Check 'a SHA-256 is pinned in the installer'  ($pinned.Length -eq 64) $pinned
Check 'pinned hash equals the file hash'       ($pinned -eq $actual) "pinned $pinned`n       file   $actual (update `$sha256 in the installer)"

if ($fail) { Write-Host "`n$fail check(s) failed"; exit 1 }
Write-Host "`nall checks passed"
