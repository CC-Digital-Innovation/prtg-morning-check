# Opsgenie mapping

Sketched from the Opsgenie API; not built or tested here. The PRTG side is
the same as for any platform: trigger 1 fires the existing Opsgenie
notification template, trigger 2 pings the heartbeat.

## Title and priority

Either of these:

- **Alert policy** on the team that owns the PRTG integration. Conditions:
  alert field *Details* or *Description* contains the sitename, and *Message*
  contains `Morning Check`. Actions: rewrite the message to
  `Morning Check: {{message.extract(/(ALL CLEAR|\d+ to check[^|]*)/)}}`, set
  priority P4 for all clear and P3 otherwise (two policies, one per case).
  Opsgenie caps the message at 130 characters, which the header fits.
- **Integration alert fields** on the PRTG API integration, if the
  integration is dedicated to this server: the same message template, with
  the full sensor list in the description.

Keep the alert apart from real alerts with the integration's alias, which
already includes the device, and exclude device `Morning Check` from any
routing that would send it to another team.

## Recovery

The PRTG integration's default "close alert" action on the UP notification
would close the morning post when the window ends. Either add a condition to that action
so it skips device `Morning Check`, or leave the recovery notification off
trigger 1 on the PRTG device.

## Heartbeat

Create the heartbeat with the API
([`integrations/opsgenie/heartbeat.json`](../../integrations/opsgenie/heartbeat.json)):

```
POST https://api.opsgenie.com/v2/heartbeats
Authorization: GenieKey <api key>
```

Trigger 2's notification template is an Execute HTTP Action with

```
GET https://api.opsgenie.com/v2/heartbeats/<name>/ping?apiKey=<api key>
```

PRTG's HTTP action sends no custom headers, so the key goes on the query
string. Interval 24 hours plus 30 minutes.
