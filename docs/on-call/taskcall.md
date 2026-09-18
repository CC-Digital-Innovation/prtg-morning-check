# TaskCall

The worked example of [README.md](README.md): what to add when the PRTG
notification on trigger 1 goes to TaskCall. Three objects per PRTG
server, created once in the web app. The PRTG side is unchanged; trigger 2
points at the heartbeat created here.

## 1 · Heartbeat

In the TaskCall web app: Automation > Heartbeats > Add. Ping type HTTP.
TaskCall shows the ping URL once the heartbeat is saved; that URL goes into
the PRTG notification template for trigger 2.
[`integrations/taskcall/heartbeat.json`](../../integrations/taskcall/heartbeat.json)
holds every field for reference. Interval and grace are seconds.

| Field | Value |
|---|---|
| Name | `Morning check <server>` |
| Service | the service the check reports to |
| Interval | 88200 (24 h 30 min) |
| Grace | 0 |
| Incident title | `Morning check missed` |
| Urgency | 4 (High) |

Grace stays 0: TaskCall does not evaluate a heartbeat that has a grace
period. The 30 minutes of slack live in the interval instead, so a ping is
due 30 minutes after the same window the next day.

> **Arm the heartbeat with one deliberate miss.** A heartbeat whose first
> evaluation passes is never evaluated again; one whose first evaluation fails
> is evaluated every interval from then on, passes when pinged, raises the
> incident when not, and auto-resolves that incident on the next ping. So:
> create it, do not ping it, wait for the first "missed" incident, resolve that
> incident, then put the ping URL into the PRTG notification.

## 2 · Routing rules

Two conditional-routing rules, in the web app under Automation >
Conditional Routing > Add. Each rule is self-contained: it routes to the
service, sets the dedup key, rewrites the title, sets urgency and tags.
[`integrations/taskcall/routing-rules.json`](../../integrations/taskcall/routing-rules.json)
holds every field of both rules, with the server's sitename, the target
service, the timezone and the start date left to fill in.

| Rule | Condition (all three) | Title | Urgency |
|---|---|---|---|
| Morning check: all clear | sitename equals the server · device equals `Morning Check` · message contains `ALL CLEAR` | `Morning Check: all clear` | 2 (Low) |
| Morning check: to check | sitename equals the server · device equals `Morning Check` · message contains `to check` | `Morning Check: 3 to check: 0 unknown, 1 down, 2 acknowledged, 0 partial` (header only) | 3 (Medium) |

> **The server's own PRTG route rule must exclude this device.** Add the
> condition `source_payload.device not_equals "Morning Check"` to it.
> Evaluation order between rules is not something to rely on; with the
> exclusion, only the morning-check rules can match this device.

How the rule fields work:

- The custom title accepts a regex after a pipe:
  `{{ source_payload.lastmessage | ^[^|\n]+[^ |\n] }}` keeps the text before
  the first line break or ` | `, so the title carries the counts.
- The custom description is set to the sensor message plus the sensor link,
  in place of the server's generic all-fields template. Line breaks in the
  template are kept.
- Every payload condition and template uses the `source_payload.` prefix.
  The rule editor can load the payload of a past incident to show the field
  names.
- The rule's valid-from date is evaluated in the rule's timezone; date it a
  day early when creating rules late in the UTC day.
- Routing actions apply at incident creation only. A second alert from the
  same device while the incident is open dedups into it and keeps the
  original title.

## 3 · What you do not need

- No custom integration or API key: the alert arrives through the PRTG
  integration the server already posts to.
- No new chat integration: the target service's existing integrations
  (Slack, Teams, email) carry the post like any other incident on that
  service.
- No incident workflow: if a workflow already opens tickets for incidents,
  its own condition decides whether a daily post should open one. Exclude
  device `Morning Check` there if it should not.
