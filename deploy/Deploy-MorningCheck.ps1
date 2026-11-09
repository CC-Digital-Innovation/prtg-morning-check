<#
.SYNOPSIS
    Create the Morning Check objects on a PRTG core: schedule, group, device,
    sensor, and optionally the device triggers.

.DESCRIPTION
    Every object is looked up by name first and only created when missing.
    The sensor's parameters, schedule and interval are re-applied on every
    run, so a re-run adds the triggers later or corrects the sensor. The
    schedule is named after its window and days: change either and the
    existing Morning Check schedule is renamed and its pauses rewritten in
    place, so the sensor keeps the same schedule object. Uses the classic
    API with username and passhash; no PrtgAPI module needed.

    Order: schedule (paused outside the daily window) -> group under the
    probe -> device with trigger inheritance off -> EXE/Script Advanced sensor
    with the schedule attached -> triggers, if notification ids are given.

    The sensor's API key is stored on the Morning Check device as its
    Windows password; the sensor's parameters pass it as
    -Token '%windowspassword' and PRTG fills it in at scan time. The key is
    not written to settings.json.

    The sensor must already be in the probe's Custom Sensors\EXEXML folder
    (Install-MorningCheck.ps1 does that). Run this script straight from
    GitHub for the interactive setup:
      irm https://raw.githubusercontent.com/CC-Digital-Innovation/prtg-morning-check/v1.0.2/deploy/Deploy-MorningCheck.ps1 | iex

.PARAMETER SettingsFile
    A JSON file with the same settings as the parameters, in plain words:
    see settings.example.json. Parameters given on the command line override
    the file.

    With no parameters and no file, the script asks for each setting, offers
    the probes and notification templates it finds on the server as numbered
    lists, shows the plan, and can save the answers to settings.json.

.PARAMETER Server
    PRTG core, e.g. https://prtg.example.com.

.PARAMETER UserName
    An administrator's login name.

.PARAMETER PassHash
    That administrator's passhash (PRTG > Setup > Account Settings > My Account).

.PARAMETER ApiKey
    A PRTG API key for the sensor's read-only user (log in as that user,
    Setup > Account Settings > API Keys, read access). Stored on the device
    as its Windows password. Needed when the device is first created; on a
    re-run, give it again only to replace the key. Not read from or saved
    to the settings file; interactively the prompt hides what you type.

.PARAMETER Probe
    The probe that will run the sensor, by name ("Local Probe") or object id.

.PARAMETER CoreUrl
    The address the sensor uses to query the core (-Server in the sensor's
    parameters). Defaults to -Server.

.PARAMETER WindowStart
    Start of the daily window in the core's local time, HH:mm. Default 06:00.

.PARAMETER WindowEnd
    End of the daily window, HH:mm. Default 06:10.

.PARAMETER Days
    Which days, as names in any form: "Mon Tue", "Monday,Tuesday", "weekdays",
    "every day". Default Monday to Saturday.

.PARAMETER ExcludeGroups
    Group name substrings to leave out, comma-separated. Passed to the sensor.

.PARAMETER ExcludeSensors
    The same for sensor names.

.PARAMETER ExcludeDevices
    The same for device names.

.PARAMETER ExcludeProbes
    The same for probe names.

.PARAMETER Notification
    Notification template for trigger 1 (the daily post), by name or id. Omit
    to create no trigger yet.

.PARAMETER RecoveryNotification
    Notification template sent when the sensor leaves Down (the pause at the
    end of the window), by name or id. Omit for none.

.PARAMETER HeartbeatNotification
    Notification template for trigger 2 (the dead-man ping), by name or id.
    Omit for none.

.PARAMETER IgnoreCertificate
    Pass -IgnoreCertificate to the sensor, for a core with a self-signed
    certificate. In the settings file: "ignoreCertificate": true.

.PARAMETER AcknowledgedIsClear
    Pass -AcknowledgedIsClear to the sensor: acknowledged sensors are listed
    but not counted. In the settings file: "acknowledgedIsClear": true.

.PARAMETER NamePrefix
    Prefix for every object name, for a test deployment. Default none.

.EXAMPLE
    .\Deploy-MorningCheck.ps1                      # interactive

.EXAMPLE
    .\Deploy-MorningCheck.ps1 -SettingsFile .\settings.json -WhatIf

.EXAMPLE
    .\Deploy-MorningCheck.ps1 -Server https://prtg.example.com -UserName admin -PassHash 1234567890 `
        -Probe 'Local Probe' -WindowStart 07:30 -WindowEnd 07:40 -Days weekdays -ExcludeGroups 'Lab'
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SettingsFile = '',
    [string]$Server = '',
    [string]$UserName = '',
    [string]$PassHash = '',
    [string]$ApiKey = '',
    [string]$Probe = '',
    [string]$CoreUrl = '',
    [string]$WindowStart = '',
    [string]$WindowEnd = '',
    [string]$Days = '',
    [string]$ExcludeGroups = '',
    [string]$ExcludeSensors = '',
    [string]$ExcludeDevices = '',
    [string]$ExcludeProbes = '',
    [string]$Notification = '',
    [string]$RecoveryNotification = '',
    [string]$HeartbeatNotification = '',
    [switch]$IgnoreCertificate,
    [switch]$AcknowledgedIsClear,
    [string]$NamePrefix = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------- settings ----
# The settings file uses the parameter names with a lower-case first letter.
$settingKeys = 'Server', 'UserName', 'PassHash', 'Probe', 'CoreUrl', 'WindowStart', 'WindowEnd', 'Days',
               'ExcludeGroups', 'ExcludeSensors', 'ExcludeDevices', 'ExcludeProbes',
               'Notification', 'RecoveryNotification', 'HeartbeatNotification',
               'IgnoreCertificate', 'AcknowledgedIsClear', 'NamePrefix'
$switchKeys  = 'IgnoreCertificate', 'AcknowledgedIsClear'   # true/false in the file
function ConvertTo-SettingKey([string]$Parameter) { $Parameter.Substring(0, 1).ToLower() + $Parameter.Substring(1) }

# A settings file fills in whatever the command line did not.
if ($SettingsFile) {
    $cfg = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
    foreach ($k in $settingKeys) {
        $v = $cfg.PSObject.Properties[(ConvertTo-SettingKey $k)]
        if (-not $v -or "$($v.Value)" -eq '' -or (Get-Variable $k -ValueOnly)) { continue }
        $value = if ($switchKeys -contains $k) { [System.Convert]::ToBoolean("$($v.Value)") } else { "$($v.Value)" }
        Set-Variable $k $value -WhatIf:$false -Confirm:$false
    }
}
# ------------------------------------------------------- interview ----
# Nothing given: ask, with defaults in brackets and lists to pick from.
$interactive = -not $SettingsFile -and -not ($Server -and $UserName -and $PassHash -and $Probe)
function Ask([string]$Prompt, [string]$Default = '', [switch]$Secret) {
    $shown = if ($Default) { " [$Default]" } else { '' }
    if ($Secret) {
        $sec = Read-Host "$Prompt$shown" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $answer = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    else { $answer = Read-Host "$Prompt$shown" }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}
function Pick([string]$Prompt, [object[]]$Rows, [string]$Default = '', [switch]$AllowNone) {
    # Rows have objid and name. Type a number, a name, or an id; empty keeps the default.
    for ($i = 0; $i -lt $Rows.Count; $i++) { Write-Host ("  {0,3}. {1}  (id {2})" -f ($i + 1), $Rows[$i].name, $Rows[$i].objid) }
    if ($AllowNone) { Write-Host '    0. none' }
    while ($true) {
        $a = Ask $Prompt $Default
        if ($AllowNone -and ($a -eq '0' -or $a -eq '' -or $a -eq 'none')) { return '' }
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Rows.Count) { return $Rows[[int]$a - 1].name }
        if ($Rows | Where-Object { $_.name -eq $a -or "$($_.objid)" -eq $a }) { return $a }
        Write-Host "  not in the list: $a"
    }
}
if ($interactive) {
    Write-Host 'Morning Check deployment. Enter accepts the value in brackets.'
    if (-not $Server)   { $Server   = Ask 'PRTG core URL' 'https://prtg.example.com' }
    if (-not $UserName) { $UserName = Ask 'Admin login name' }
    if (-not $PassHash) { $PassHash = Ask 'Passhash (PRTG > Setup > Account Settings > My Account)' -Secret }
}
foreach ($need in 'Server', 'UserName', 'PassHash') {
    if (-not (Get-Variable $need -ValueOnly)) { throw "$need is required (parameter, settings file, or answer)" }
}

$base = $Server.TrimEnd('/')

function ConvertTo-FormString([hashtable]$Fields) {
    ($Fields.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
}

function Invoke-Prtg([string]$Path, [hashtable]$Query = @{}, [hashtable]$Form = $null) {
    # PRTG answers most writes with a 302 to the object's page. Treat any 3xx as success and
    # return nothing; return the response for reads.
    $url = "$base/$Path?" + (ConvertTo-FormString ($Query + @{ username = $UserName; passhash = $PassHash }))
    try {
        if ($null -eq $Form) {
            return Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0
        }
        return Invoke-WebRequest -Uri $url -Method Post -Body (ConvertTo-FormString $Form) -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 0
    }
    catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -ge 300 -and $code -lt 400) { return $null }
        throw
    }
}

function Get-Table([string]$Content, [hashtable]$Query) {
    $q = @{ content = $Content; output = 'json'; count = '500' } + $Query
    $r = Invoke-Prtg 'api/table.json' $q
    return ($r.Content | ConvertFrom-Json).$Content
}

function Find-ByName([string]$Content, [string]$Name, [int]$ParentId = -1, [int]$Retries = 0) {
    # A freshly created object takes a few seconds to appear in table.json.
    for ($try = 0; $try -le $Retries; $try++) {
        if ($try) { Start-Sleep -Seconds 3 }
        $rows = Get-Table $Content @{ columns = 'objid,name,parentid'; filter_name = $Name }
        $rows = @($rows | Where-Object { $_.name -eq $Name })
        if ($ParentId -ge 0) { $rows = @($rows | Where-Object { [int]$_.parentid -eq $ParentId }) }
        if ($rows.Count -gt 0) { return [int]$rows[0].objid }
    }
    return 0
}

function Set-Prop([int]$Id, [string]$Name, [string]$Value) {
    if ($PSCmdlet.ShouldProcess("object $Id", "set $Name")) {
        $null = Invoke-Prtg 'api/setobjectproperty.htm' @{ id = $Id; name = $Name; value = $Value }
    }
}

if ($interactive) {
    Write-Host ''
    Write-Host 'Probes on this server:'
    $probes = @(Get-Table 'probes' @{ columns = 'objid,name'; filter_parentid = '0' } | Where-Object { $_.name -and $_.name -ne 'PRTG Core Server' })
    if (-not $Probe) { $Probe = Pick 'Probe that runs the sensor (number or name)' $probes 'Local Probe' }
    if (-not $CoreUrl) { $CoreUrl = Ask 'Address the sensor uses to reach the core' $Server }
    if (-not $ApiKey)  { $ApiKey  = Ask "API key of the sensor's read-only user (blank keeps the one on the device)" -Secret }
    Write-Host ''
    Write-Host "Daily window, in the core server's local time."
    if (-not $WindowStart) { $WindowStart = Ask 'Window start (HH:mm)' '06:00' }
    if (-not $WindowEnd)   { $WindowEnd   = Ask 'Window end (HH:mm)' '06:10' }
    if (-not $Days)        { $Days        = Ask 'Days (e.g. Mon Tue, weekdays, every day)' 'Mon Tue Wed Thu Fri Sat' }
    Write-Host ''
    if (-not $ExcludeGroups)  { $ExcludeGroups  = Ask 'Group name substrings to leave out, comma-separated (blank for none)' }
    if (-not $ExcludeDevices) { $ExcludeDevices = Ask 'Device name substrings to leave out (blank for none)' }
    if (-not $ExcludeSensors) { $ExcludeSensors = Ask 'Sensor name substrings to leave out (blank for none)' }
    if (-not $ExcludeProbes)  { $ExcludeProbes  = Ask 'Probe name substrings to leave out (blank for none)' }
    Write-Host ''
    Write-Host 'Notification templates on this server:'
    $notifs = @(Get-Table 'notifications' @{ columns = 'objid,name' })
    if (-not $Notification)          { $Notification          = Pick 'Template that sends the daily post (0 = none yet)' $notifs '' -AllowNone }
    if ($Notification -and -not $RecoveryNotification) { $RecoveryNotification = Pick 'Template to send when the window ends (0 = none)' $notifs '' -AllowNone }
    if (-not $HeartbeatNotification) { $HeartbeatNotification = Pick 'Template that pings a heartbeat URL (0 = none)' $notifs '' -AllowNone }
    Write-Host ''
    Write-Host 'Plan:'
    Write-Host "  server        $Server  (probe: $Probe)"
    Write-Host "  api key       $(if ($ApiKey) { 'store on the device' } else { 'keep what the device has' })"
    Write-Host "  window        $WindowStart-$WindowEnd on $Days"
    Write-Host "  exclusions    groups='$ExcludeGroups' devices='$ExcludeDevices' sensors='$ExcludeSensors' probes='$ExcludeProbes'"
    Write-Host "  sensor flags  $(@(if ($IgnoreCertificate) { '-IgnoreCertificate' }; if ($AcknowledgedIsClear) { '-AcknowledgedIsClear' }) -join ' ')"
    Write-Host "  post          $(if ($Notification) { $Notification } else { '(no trigger yet)' })"
    Write-Host "  recovery      $(if ($RecoveryNotification) { $RecoveryNotification } else { 'none' })"
    Write-Host "  heartbeat     $(if ($HeartbeatNotification) { $HeartbeatNotification } else { 'none' })"
    $save = Ask 'Save these answers to settings.json for next time? (y/n)' 'y'
    if ($save -match '^y') {
        $out = [ordered]@{}
        foreach ($k in $settingKeys) {
            $val = Get-Variable $k -ValueOnly
            $out[(ConvertTo-SettingKey $k)] = if ($switchKeys -contains $k) { [bool]$val } else { $val }
        }
        $path = Join-Path (Get-Location) 'settings.json'
        $out | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8 -WhatIf:$false -Confirm:$false
        Write-Host "  saved $path (holds the passhash; keep it private)"
    }
    $go = Ask 'Create these objects now? (y/n)' 'y'
    if ($go -notmatch '^y') { Write-Host 'nothing changed'; exit 0 }
}
if (-not $Probe) { throw 'Probe is required (parameter, settings file, or answer)' }
if (-not $CoreUrl) { $CoreUrl = $base }

# --------------------------------------------- window and days ----
if (-not $WindowStart) { $WindowStart = '06:00' }
if (-not $WindowEnd)   { $WindowEnd = '06:10' }
if (-not $Days)        { $Days = 'Mon Tue Wed Thu Fri Sat' }
foreach ($t in $WindowStart, $WindowEnd) { if ($t -notmatch '^\d{2}:\d{2}$') { throw "time must be HH:mm, got '$t'" } }

# Days in any human form -> PRTG's codes (the first two letters), in week order.
$dayNames = 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'
$dayCodes = @($dayNames | ForEach-Object { $_.Substring(0, 2) })
$wanted = @()
$Days = $Days -replace '(?i)every\s+day', 'everyday'
foreach ($word in ($Days.ToLower() -split '[\s,;]+' | Where-Object { $_ })) {
    switch -Regex ($word) {
        '^(everyday|daily|all)$' { $wanted += $dayCodes }
        '^weekdays?$'            { $wanted += $dayCodes[0..4] }
        '^weekends?$'            { $wanted += $dayCodes[5..6] }
        default {
            $name = $dayNames | Where-Object { $word.Length -ge 2 -and $_.StartsWith($word) } | Select-Object -First 1
            if (-not $name) { throw "unknown day '$word'" }
            $wanted += $name.Substring(0, 2)
        }
    }
}
$activeDays = @($dayCodes | Where-Object { $wanted -contains $_ })
if (-not $activeDays.Count) { throw 'no days selected' }

# ------------------------------------------------------------ probe ----
$ProbeId = 0
if ($Probe -match '^\d+$') { $ProbeId = [int]$Probe }
else {
    $rows = @(Get-Table 'probes' @{ columns = 'objid,name'; filter_name = $Probe } | Where-Object { $_.name -eq $Probe })
    if (-not $rows.Count) { throw "probe '$Probe' not found" }
    $ProbeId = [int]$rows[0].objid
}
Write-Host "probe: $Probe (id $ProbeId)"

# ------------------------------------------------------------ names ----
$scheduleName = "${NamePrefix}Morning Check window ($($activeDays -join ' ') $WindowStart-$WindowEnd)"
$name         = "${NamePrefix}Morning Check"   # the group, the device and the sensor

# --------------------------------------------------------- schedule ----
# PRTG schedules list the INACTIVE periods: one pause from the end of each
# day's window to the start of the next window.
$lines = for ($i = 0; $i -lt $activeDays.Count; $i++) {
    $next = $activeDays[($i + 1) % $activeDays.Count]
    "$($activeDays[$i]):$WindowEnd-$($next):$WindowStart"
}
# The schedule is found by its prefix, not its full name, so a changed window
# or day set edits the one schedule in place instead of leaving the old one
# behind. The pauses are re-applied on every run.
$schedulePrefix = "${NamePrefix}Morning Check window ("
$existing = @(Get-Table 'schedules' @{ columns = 'objid,name' } | Where-Object { $_.name -and $_.name.StartsWith($schedulePrefix) })
$scheduleId = if ($existing.Count) { [int]$existing[0].objid } else { 0 }
if ($scheduleId) {
    $oldName = $existing[0].name
    $what = if ($oldName -eq $scheduleName) { 'schedule exists' } else { "schedule renamed from '$oldName'" }
    if ($PSCmdlet.ShouldProcess($scheduleName, 'update schedule')) {
        $null = Invoke-Prtg 'editsettings' @{} @{
            id = $scheduleId; name_ = $scheduleName; tags_ = 'morning-check'
            fineschedmode_ = '1'; fineschedlist_ = ($lines -join "`n")
            targeturl = '/schedules.htm'
        }
    }
    Write-Host "${what}: $scheduleId $scheduleName"
    $lines | ForEach-Object { Write-Host "  pause $_" }
}
elseif ($PSCmdlet.ShouldProcess($scheduleName, 'create schedule')) {
    $null = Invoke-Prtg 'editsettings' @{} @{
        objecttype = 'schedule'; id = 'new'; name_ = $scheduleName; tags_ = 'morning-check'
        fineschedmode_ = '1'; fineschedlist_ = ($lines -join "`n"); accessrights_ = '1'; comments = ''
        targeturl = '/schedules.htm'
    }
    $scheduleId = Find-ByName 'schedules' $scheduleName -Retries 5
    if (-not $scheduleId) { throw "schedule was not created" }
    Write-Host "schedule created: $scheduleId $scheduleName"
    $lines | ForEach-Object { Write-Host "  pause $_" }
}

# ------------------------------------------------------------ group ----
$groupId = Find-ByName 'groups' $name $ProbeId
if ($groupId) { Write-Host "group exists: $groupId" }
elseif ($PSCmdlet.ShouldProcess("$name under probe $ProbeId", 'create group')) {
    $null = Invoke-Prtg 'addgroup2.htm' @{ id = $ProbeId; name_ = $name }
    $groupId = Find-ByName 'groups' $name $ProbeId -Retries 5
    if (-not $groupId) { throw "group was not created" }
    Write-Host "group created: $groupId"
}

# ----------------------------------------------------------- device ----
$deviceId = if ($groupId) { Find-ByName 'devices' $name $groupId } else { 0 }
if ($deviceId) { Write-Host "device exists: $deviceId" }
elseif ($PSCmdlet.ShouldProcess("$name in group $(if ($groupId) { $groupId } else { '(new)' })", 'create device')) {
    $null = Invoke-Prtg 'adddevice2.htm' @{ id = $groupId; name_ = $name; host_ = '127.0.0.1'; ipversion_ = '0' }
    $deviceId = Find-ByName 'devices' $name $groupId -Retries 5
    if (-not $deviceId) { throw "device was not created" }
    Write-Host "device created: $deviceId"
}
if ($deviceId) { Set-Prop $deviceId 'inherittriggers' '0' }

# The API key goes into the device's Windows credentials. The inherit toggle
# (windowsconnection) only changes through the settings form, not through
# setobjectproperty, so the whole section is posted at once. The user name
# is a label; the sensor only reads the password.
if ($deviceId -and $ApiKey -and $PSCmdlet.ShouldProcess("device $deviceId", 'store the API key as the Windows password')) {
    $null = Invoke-Prtg 'editsettings' @{} @{
        id = $deviceId; windowsconnection = '0'; windowslogindomain_ = ''
        windowsloginusername_ = 'morning-check'; windowsloginpassword_ = $ApiKey
        targeturl = "/device.htm?id=$deviceId"
    }
    Write-Host 'api key stored on the device'
}
elseif (-not $ApiKey -and $deviceId -and -not (Find-ByName 'sensors' $name $deviceId)) {
    Write-Warning 'no -ApiKey given: the sensor will report "No API key" until one is stored on the device'
}

# ----------------------------------------------------------- sensor ----
# Single-quoted so PowerShell keeps the value as typed; a quote inside it is doubled.
function ConvertTo-Quoted([string]$Value) { "'" + ($Value -replace "'", "''") + "'" }
$params = "-Server $CoreUrl -Token '%windowspassword' -SelfSensorId %sensorid"
if ($ExcludeGroups)       { $params += " -ExcludeGroups $(ConvertTo-Quoted $ExcludeGroups)" }
if ($ExcludeSensors)      { $params += " -ExcludeSensors $(ConvertTo-Quoted $ExcludeSensors)" }
if ($ExcludeDevices)      { $params += " -ExcludeDevices $(ConvertTo-Quoted $ExcludeDevices)" }
if ($ExcludeProbes)       { $params += " -ExcludeProbes $(ConvertTo-Quoted $ExcludeProbes)" }
if ($IgnoreCertificate)   { $params += ' -IgnoreCertificate' }
if ($AcknowledgedIsClear) { $params += ' -AcknowledgedIsClear' }

$sensorId = if ($deviceId) { Find-ByName 'sensors' $name $deviceId } else { 0 }
if ($sensorId) { Write-Host "sensor exists: $sensorId" }
elseif ($PSCmdlet.ShouldProcess("$name on device $(if ($deviceId) { $deviceId } else { '(new)' })", 'create sensor')) {
    $null = Invoke-Prtg 'api/addsensor.htm' @{
        id = $deviceId; sensortype = 'exexml'; name_ = $name; priority_ = '3'; tags_ = 'morning-check'
        exefile_ = 'Get-MorningCheck.ps1|Get-MorningCheck.ps1||'; exeparams_ = $params
        timeout_ = '120'
    }
    $sensorId = Find-ByName 'sensors' $name $deviceId -Retries 5
    if (-not $sensorId) { throw "sensor was not created" }
    Write-Host "sensor created: $sensorId"
}
if ($sensorId) {
    Set-Prop $sensorId 'exeparams' $params
    Set-Prop $sensorId 'errorintervalsdown' '0'
    if ($PSCmdlet.ShouldProcess("sensor $sensorId", "attach schedule $(if ($scheduleId) { $scheduleId } else { '(new)' }), own 5-minute interval")) {
        # The schedule and the scan interval both default to "inherit from the device";
        # both are switched to the sensor's own values in one settings-form post.
        $null = Invoke-Prtg 'editsettings' @{} @{
            id = $sensorId; scheduledependency = '0'; schedule_ = "$scheduleId|$scheduleName|"
            intervalgroup = '0'; interval_ = '300|5 minutes'
            targeturl = "/sensor.htm?id=$sensorId"
        }
    }
}
Write-Host "sensor parameters: $params"

# --------------------------------------------------------- triggers ----
function Resolve-Notification([string]$NameOrId) {
    $hit = @(if ($NameOrId -match '^\d+$') { $allNotifications | Where-Object { [int]$_.objid -eq [int]$NameOrId } }
             else { $allNotifications | Where-Object { $_.name -eq $NameOrId } })
    if (-not $hit.Count) { throw "notification '$NameOrId' not found" }
    return $hit[0]
}
function Add-DownTrigger([string]$On, [string]$Off) {
    $onN  = Resolve-Notification $On
    $offN = if ($Off) { Resolve-Notification $Off }
    $existing = Get-Table 'triggers' @{ id = $deviceId; columns = 'content' }
    if (@($existing | Where-Object { $_.content.onnotificationid -like "$($onN.objid)|*" }).Count) {
        Write-Host "trigger exists for notification $($onN.name)"; return
    }
    $offValue = if ($offN) { "$($offN.objid)|$($offN.name)|http:HTTP" } else { '-1|None|' }
    if ($PSCmdlet.ShouldProcess("device $deviceId", "add Down trigger -> $($onN.objid)")) {
        $null = Invoke-Prtg 'editsettings' @{} @{
            id = $deviceId; subid = 'new'; objecttype = 'nodetrigger'; class = 'state'
            nodest_new = '0'; latency_new = '0'; esclatency_new = '300'; repeatival_new = '0'
            onnotificationid_new = "$($onN.objid)|$($onN.name)|http:HTTP"; offnotificationid_new = $offValue; escnotificationid_new = '-1|None|'
        }
        $msg = "trigger added: Down -> $($onN.name)"
        if ($offN) { $msg += ", recovery -> $($offN.name)" }
        Write-Host $msg
    }
}
if ($deviceId -and ($Notification -or $HeartbeatNotification)) {
    $allNotifications = @(Get-Table 'notifications' @{ columns = 'objid,name' })
    if ($Notification)          { Add-DownTrigger $Notification $RecoveryNotification }
    if ($HeartbeatNotification) { Add-DownTrigger $HeartbeatNotification '' }
}

Write-Host "done. schedule=$scheduleId group=$groupId device=$deviceId sensor=$sensorId"
