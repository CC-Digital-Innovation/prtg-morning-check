<#
.SYNOPSIS
    PRTG EXE/Script Advanced sensor: the morning check.

.DESCRIPTION
    Asks the local PRTG core for every sensor that is Unknown, Down,
    Down (Acknowledged) or Down (Partial), drops the ones you have chosen to
    ignore, and writes the list into this sensor's message.

    The sensor goes DOWN on every run, with or without findings, so the
    daily post is the proof that the check ran; an empty morning reads
    "ALL CLEAR". Pair the sensor with a PRTG schedule so it resumes once a
    day, and PRTG fires the Down notification on each resume.

.PARAMETER Server
    PRTG core URL. The default, https://127.0.0.1, is right only when the
    sensor runs on the core's local probe.

.PARAMETER Token
    A PRTG API key (Setup > Account Settings > API Keys) for a read-only
    user. Do not type the key here: store it as the Windows password on the
    sensor's parent device and pass "-Token '%windowspassword'". PRTG fills
    the placeholder in when it hands the scan to the probe, keeps the key
    in its own encrypted config, and shows it nowhere else.

.PARAMETER SelfSensorId
    This sensor's own object id, so it does not report itself as Down.
    In the sensor's Parameters field pass "-SelfSensorId %sensorid".

.PARAMETER ExcludeProbes
    Comma-separated, case-insensitive substrings of probe names. A sensor
    under a matching probe is left out of the report.

.PARAMETER ExcludeGroups
    The same for group names.

.PARAMETER ExcludeDevices
    The same for device names.

.PARAMETER ExcludeSensors
    The same for sensor names.

.PARAMETER AcknowledgedIsClear
    Treat Down (Acknowledged) sensors as already handled: they are still
    listed, but do not count towards "to check".

.PARAMETER MaxChars
    Message budget, counted on the escaped text PRTG reads (">" is "&gt;").
    PRTG cuts a sensor message at 2000 characters, so the header goes first
    and the list is cut with a "+N more" marker that also fits the budget.

.PARAMETER IgnoreCertificate
    Skip certificate validation, for a core with a self-signed certificate.

.PARAMETER FixtureFile
    Read a saved table.json response instead of calling PRTG. For tests.

.EXAMPLE
    Parameters field in PRTG:
      -Token '%windowspassword' -SelfSensorId %sensorid -ExcludeGroups 'Lab,Decommissioned' -ExcludeSensors 'Probe Health'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Server = 'https://127.0.0.1',
    [string]$Token = '',
    [int]$SelfSensorId = 0,
    [string]$ExcludeProbes = '',
    [string]$ExcludeGroups = '',
    [string]$ExcludeDevices = '',
    [string]$ExcludeSensors = '',
    [switch]$AcknowledgedIsClear,
    [int]$MaxChars = 1900,
    [switch]$IgnoreCertificate,
    [string]$FixtureFile = ''
)

$ErrorActionPreference = 'Stop'

# PRTG parses the output as UTF-8, but Windows PowerShell 5.1 writes it in the console
# code page, so one non-ASCII character in a sensor name (a ® in a service name is enough)
# arrives as an invalid byte and the whole result fails with PE231 "Structural error in xml
# file". Writing every non-ASCII character as a numeric reference keeps the output pure
# ASCII whatever the encoding, and PRTG shows the original character. Characters XML 1.0
# forbids become a space; so do line breaks, which PRTG rejects inside <text> (PE233).
function ConvertTo-PrtgText([string]$Text) {
    $escaped = [System.Security.SecurityElement]::Escape($Text)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $escaped.Length; $i++) {
        $c = $escaped[$i]
        $n = [int]$c
        if ([char]::IsHighSurrogate($c) -and ($i + 1) -lt $escaped.Length -and [char]::IsLowSurrogate($escaped[$i + 1])) {
            [void]$sb.Append("&#$([char]::ConvertToUtf32($c, $escaped[$i + 1]));"); $i++; continue
        }
        if ([char]::IsSurrogate($c) -or $n -eq 0xFFFE -or $n -eq 0xFFFF) { continue }
        if ($n -lt 0x20 -or $n -eq 0x7F) { [void]$sb.Append(' '); continue }
        if ($n -gt 0x7E) { [void]$sb.Append("&#$n;"); continue }
        [void]$sb.Append($c)
    }
    $sb.ToString()
}

function Write-PrtgResult([string]$Text) {
    "<prtg><error>1</error><text>$(ConvertTo-PrtgText $Text)</text></prtg>"
}

# For text that is already escaped: the list is budgeted on its escaped length, so it goes out as is.
function Write-PrtgEscaped([string]$Escaped) {
    "<prtg><error>1</error><text>$Escaped</text></prtg>"
}

function Split-List([string]$Csv) {
    if ([string]::IsNullOrWhiteSpace($Csv)) { return @() }
    return @($Csv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# $Rules maps a sensor field (probe, group, device, name) to its exclusion substrings.
function Test-Excluded($Sensor, [hashtable]$Rules) {
    foreach ($field in $Rules.Keys) {
        $value = [string]$Sensor.$field
        foreach ($needle in $Rules[$field]) {
            if ($value.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}

function Format-Line($s) { "$($s.probe) > $($s.group) > $($s.device) > $($s.name)" }

# ---------------------------------------------------------------- fetch ----
try {
    if ($FixtureFile) {
        $table = Get-Content -LiteralPath $FixtureFile -Raw | ConvertFrom-Json
    }
    else {
        # PRTG replaces %windowspassword before the script runs. An empty value means the
        # device has no Windows password (or inherits an empty one); a value still starting
        # with % means the placeholder was never substituted.
        $Token = $Token.Trim()
        if (-not $Token) { throw "No API key: set the device's Windows password to the key and pass -Token '%windowspassword'" }
        if ($Token.StartsWith('%')) { throw "API key placeholder was not filled in ($Token): check the device's Windows credentials" }
        $auth = "apitoken=$([uri]::EscapeDataString($Token))"

        $query = 'content=sensors&columns=objid,probe,group,device,name,status' +
                 '&filter_status=1&filter_status=5&filter_status=13&filter_status=14' +
                 '&count=50000&output=json'
        $url = "$($Server.TrimEnd('/'))/api/table.json?$query&$auth"

        # Windows PowerShell 5.1 can leave TLS 1.2 out of its defaults, and the core refuses the rest.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $params = @{ Uri = $url; TimeoutSec = 60; UseBasicParsing = $true }
        if ($IgnoreCertificate) {
            # A scriptblock callback dies on 5.1 (no runspace on the validating thread); a compiled policy works.
            if (-not ('MorningCheck.TrustAll' -as [type])) {
                Add-Type -TypeDefinition @'
using System.Net; using System.Security.Cryptography.X509Certificates;
namespace MorningCheck {
  public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
  }
}
'@
            }
            [Net.ServicePointManager]::CertificatePolicy = New-Object MorningCheck.TrustAll
        }

        $table = (Invoke-WebRequest @params).Content | ConvertFrom-Json
    }
    if ($null -eq $table.sensors) { throw 'the response has no sensor table' }
}
catch {
    Write-PrtgResult "Morning check could not read PRTG: $($_.Exception.Message)"
    exit 0
}

# --------------------------------------------------------------- filter ----
$exclude = @{
    probe  = Split-List $ExcludeProbes
    group  = Split-List $ExcludeGroups
    device = Split-List $ExcludeDevices
    name   = Split-List $ExcludeSensors
}

$unknown = @(); $down = @(); $acked = @(); $partial = @()
foreach ($s in $table.sensors) {
    if ($SelfSensorId -and [int]$s.objid -eq $SelfSensorId) { continue }
    if (Test-Excluded $s $exclude) { continue }
    switch ([int]$s.status_raw) {
        5       { $down    += $s }
        13      { $acked   += $s }
        14      { $partial += $s }
        default { $unknown += $s }   # 1 = Unknown, and anything unexpected
    }
}

$toCheck = $unknown.Count + $down.Count + $partial.Count
if (-not $AcknowledgedIsClear) { $toCheck += $acked.Count }

# -------------------------------------------------------------- message ----
$counts = "$($unknown.Count) unknown, $($down.Count) down, $($acked.Count) acknowledged, $($partial.Count) partial"
$header = if ($toCheck -eq 0) { "ALL CLEAR: $counts" } else { "$toCheck to check: $counts" }

$sections = @(
    @{ Tag = 'DOWN';    Items = $down    },
    @{ Tag = 'UNKNOWN'; Items = $unknown },
    @{ Tag = 'PARTIAL'; Items = $partial },
    @{ Tag = 'ACK';     Items = $acked   }
)

# One line: PRTG rejects line breaks inside <text> (error PE233), so the
# entries are joined with " | ". The list is cut at the first entry that
# does not fit, so the Down entries at the front always make it.
# The budget counts the ESCAPED text, the characters PRTG actually reads: every " > " is
# " &gt; " on the wire, and PRTG cuts <text> at 2000 characters, so a list sized on the raw
# text ran past it, lost "</text></prtg>" and failed with PE231 "2 open items". That
# happened exactly when a site probe was offline and all its sensors were listed.
$sep = ' | '
$lines = @(foreach ($sec in $sections) { foreach ($s in $sec.Items) { ConvertTo-PrtgText "$sep$($sec.Tag): $(Format-Line $s)" } })
$text = ConvertTo-PrtgText $header
for ($i = 0; $i -lt $lines.Count; $i++) {
    $more = ConvertTo-PrtgText "$sep+$($lines.Count - $i) more"
    $room = if ($i -lt $lines.Count - 1) { $MaxChars - $more.Length } else { $MaxChars }
    if (($text.Length + $lines[$i].Length) -gt $room) { $text += $more; break }
    $text += $lines[$i]
}

Write-PrtgEscaped $text
