# PRTG setup

Objects on the PRTG server, in build order. `deploy/Deploy-MorningCheck.ps1`
creates steps 2 to 4 and the triggers in step 5 in one run; the heartbeat
notification template in step 5 is made by hand. The sections below say what
each object is and the API call behind it, for doing it by hand or checking
the result. The API calls use `username` and `passhash` on the URL.

## 1 · Script on the probe

```
<PRTG install>\Custom Sensors\EXEXML\Get-MorningCheck.ps1
```

- The probe can be any probe that can reach the core over HTTPS.
- The sensor's API key is a PRTG API key (Setup > Account Settings > API
  Keys, read access) for a user made for this sensor: read-only, no
  acknowledge rights, no password change, in a read-only user group. It is
  stored on the device in step 3, not on the probe.
- No probe restart. PRTG executes the file on every scan, and the deploy
  script names the file directly. The add-sensor list is refreshed from
  Setup > System Administration > Administrative Tools > Load Lookups and
  File Lists, only needed when adding the sensor by hand.

## 2 · Schedule

The window is yours to pick: any start time, any length, any days, in the
core's local time. PRTG schedules define the *inactive* time, so in the
period-list mode a Monday to Saturday, 06:00 to 06:10 window (the deploy script's default; `windowStart`,
`windowEnd` and `days` in its settings file change it) is six pause lines:

```
mo:06:10-tu:06:00
tu:06:10-we:06:00
we:06:10-th:06:00
th:06:10-fr:06:00
fr:06:10-sa:06:00
sa:06:10-mo:06:00
```

API: `POST /editsettings` with `objecttype=schedule id=new name_=<name>
fineschedmode_=1 fineschedlist_=<the lines> accessrights_=1`. The deploy
script names the schedule after its days and window, and on a re-run with
a new window it finds the schedule by its `Morning Check window (` prefix
and posts the new name and lines to the same id, so the sensor keeps its
schedule and nothing is left behind.

PRTG applies the schedule about a minute after each boundary and runs the
first scan about three minutes after the resume. Ten minutes at a 5-minute
interval leaves a second scan if the first hits a transient API error; a
window under five minutes can close before the first scan.

## 3 · Group and device

- Group `Morning Check` directly under the probe. Its own group, not a
  monitored group and not the probe's system group.
  `/addgroup2.htm?id=<probe>&name_=Morning Check`
- Device `Morning Check`, address `127.0.0.1`. Its own device, so a
  downstream platform that dedups by device keeps it apart from real alerts.
  `/adddevice2.htm?id=<group>&name_=Morning Check&host_=127.0.0.1&ipversion_=0`
- Trigger inheritance off on the device
  (`setobjectproperty name=inherittriggers value=0`), so only the triggers in
  step 5 fire for it. A Root trigger with a latency longer than the window
  never fires for a sensor that is Down for ten minutes a day.
- The API key as the device's Windows password: Credentials for Windows
  Systems, inherit off, domain empty, user name `morning-check` (a label,
  the sensor ignores it), password = the key. The core substitutes
  `%windowspassword` in the sensor's parameters when it pushes each scan to
  the probe; the key is stored encrypted in the PRTG config and read back
  as `***`. The inherit switch cannot be turned off with
  `setobjectproperty`, so the section is posted as a form:
  `POST /editsettings` with `id=<device> windowsconnection=0
  windowslogindomain_= windowsloginusername_=morning-check
  windowsloginpassword_=<key>`. A changed key reaches the probe with the
  next task push, which the schedule's daily resume does.
- Where the key is visible: PRTG's classic API takes the key as a URL
  parameter, so the core's web server log records it with each scan's
  request, and for the seconds a scan runs it is on the sensor process's
  command line on the probe host. Both are true of any script sensor that
  takes a credential placeholder. The key is read-only, so treat the web
  log and probe host as places that can read your sensor tree.

## 4 · Sensor

EXE/Script Advanced:

| Field | Value |
|---|---|
| Name | `Morning Check` |
| Script | `Get-MorningCheck.ps1` |
| Parameters | `-Server https://<core> -Token '%windowspassword' -SelfSensorId %sensorid -ExcludeGroups 'Lab' -ExcludeSensors 'Probe Health,System Health'` |
| Security context | probe service |
| Timeout | 120 s |
| Interval | 5 minutes |
| If a scan fails | set to Down immediately (`errorintervalsdown=0`) |
| Schedule | the one from step 2 |

API: `/api/addsensor.htm?id=<device>&sensortype=exexml&name_=Morning Check&exefile_=Get-MorningCheck.ps1|Get-MorningCheck.ps1||&exeparams_=<parameters>&timeout_=120`,
then attach the schedule and give the sensor its own interval with `POST /editsettings`
fields `id=<sensor> scheduledependency=0 schedule_=<schedule id>|<schedule name>|
intervalgroup=0 interval_=300|5 minutes`. Both settings inherit from the
device until that post switches them off.

Parameter rules:

- `-Server` is the core's address. The default is `https://127.0.0.1`, which is
  only right when the sensor runs on the core's own probe.
- `-SelfSensorId %sensorid` keeps the sensor out of its own DOWN list. PRTG
  fills in the id.
- `-Token '%windowspassword'` is the key from step 3. Quoted, so an empty
  password still parses and the sensor can say "No API key" instead of
  failing on its arguments; a value that arrives still starting with `%`
  means the placeholder was not substituted, and the sensor says that too.
- Quote values with spaces. Single quotes keep PowerShell from expanding the
  value; PRTG accepts either kind.
- `-IgnoreCertificate` only if the core's certificate is self-signed.
- `-AcknowledgedIsClear` lists acknowledged sensors without counting them.

## 5 · Triggers on the device

One or two state triggers, both "when sensor is Down for at least 0 seconds":

| Trigger | On | When Down ends |
|---|---|---|
| 1 | the notification template the post should go out through | its recovery notification, if the target wants one |
| 2 (optional) | `Morning Check heartbeat`, below | none |

`Morning Check heartbeat` is a notification template of type Execute HTTP
Action: method GET, URL = a heartbeat endpoint, no body. Any dead-man
service works; `on-call/README.md` says what to check before adding it.

API: notification template `POST /editsettings` with `objecttype=notification
id=new name_=<name> active_9=1 httpmethod_9=0 url_9=<ping url>`; each trigger
`POST /editsettings` with `id=<device> subid=new objecttype=nodetrigger
class=state nodest_new=0 latency_new=0 onnotificationid_new=<id>|<name>|http:HTTP
offnotificationid_new=<id>|<name>|http:HTTP` (or `-1|None|`).

## 6 · First run

Lift the schedule (`schedule_=-1|None|`), resume the sensor, scan it, then
reattach the schedule. Expect, in order: the sensor Down with the report in
its message, both triggers logged as "sends HTTP", the post at its destination,
the heartbeat's last run updated if used, then "Paused by schedule" with the
recovery notification sent. `on-call/taskcall-end-to-end.md` lists what to look
for on that platform.
