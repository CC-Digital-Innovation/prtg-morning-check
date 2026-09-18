# On-call platforms

The morning check reaches an on-call platform the same way every other PRTG
alert does: trigger 1 on the device fires the notification template that
already posts PRTG's fields to the platform's inbound URL. Nothing in the
sensor or the PRTG objects is platform-specific.

The platform does the same jobs everywhere; only the objects differ.

| Job | What it needs from the alert | TaskCall | Opsgenie |
|---|---|---|---|
| Recognise the check | device name `Morning Check`, the server's sitename, and whether the message starts with `ALL CLEAR` or `N to check` | two conditional-routing rules | an alert policy, or the PRTG integration's alert fields |
| Title and priority | the message header before the first ` \| ` | rule actions: title template with a regex, urgency 2 or 3 | policy: message template, priority P4 or P3 |
| Keep it apart from real alerts | the device id | dedup key `sitename:deviceid`; the server's route rule excludes the device | alias on the integration; the server's routing excludes the device |
| Dead-man switch | an HTTP GET or POST from trigger 2 | heartbeat, pinged by URL | heartbeat, pinged by URL with the API key |
| Recovery at the end of the window | the "Down ended (now: Paused)" notification | attached to the open incident, incident stays open | closes the alert unless the integration ignores the recovery |

## The two decisions

**Keep the recovery from closing the post.** At the end of the window the
schedule pauses the sensor and PRTG sends the trigger's "Down ended"
notification. A platform that treats that as a resolve closes the post ten
minutes after it arrived. Either leave the recovery notification off
trigger 1, or make the platform ignore it for this device. In TaskCall that is a conditional-routing rule with a resolve action and
a minimum incident age; Opsgenie's PRTG integration closes the alert
on "sensor status up" by default.

**Let the platform's heartbeat evaluate the ping.** The ping is an HTTP
call from PRTG's notification engine, so the platform's own heartbeat
feature is the dead-man switch. Each platform has its own arming rule:
TaskCall needs one deliberate miss and a grace of 0.

## Worked examples

- [taskcall.md](taskcall.md): the objects, payloads in
  `integrations/taskcall/`, and [taskcall-end-to-end.md](taskcall-end-to-end.md)
  for proving the chain without paging anyone.
- [opsgenie.md](opsgenie.md): the equivalent objects, sketched from the
  API, not built.
