# End-to-end test

How to prove the whole chain on a real PRTG server without paging anyone.

## Substitutions for the test

Everything the production chain uses, with two changes:

| Piece | Test value |
|---|---|
| TaskCall routing rules | the two rules from `integrations/taskcall/routing-rules.json`, routed to a **quiet test service** whose escalation policy notifies one person |
| TaskCall heartbeat | a short interval (300 s, grace 0) so the arming miss takes minutes, not a day |

The PRTG device already has trigger inheritance off, so the Root triggers
cannot fire from it during the test.

## Sequence

1. Create the test rules and the test heartbeat. Do not ping the heartbeat.
2. Wait for the heartbeat's first "missed" incident. That arms it.
3. Point the PRTG heartbeat notification template at the test heartbeat's
   URL and add both device triggers.
4. Lift the schedule from the sensor (`schedule_=-1|None|`), resume it, scan.
5. Reattach the schedule.
6. Resolve the test incident, delete the test rules and heartbeat, disable
   the test service, remove the heartbeat trigger until the real heartbeat
   exists.

## What to expect

| Step | Evidence |
|---|---|
| 2 | heartbeat unhealthy within seconds of its slot; incident "Morning check missed" on the test service |
| 4 | sensor Down with the report in its message; PRTG device log shows both state triggers "activated" and "sends HTTP" in the same second |
| 4 | one incident on the test service: title `Morning Check: all clear` or `Morning Check: N to check: …`, urgency 2 or 3, tags `PRTG`, `morning-check`, the sitename; dedup key `<sitename>:<deviceid>`; description carrying the sensor list |
| 4 | heartbeat last run updated, evaluation passed, the "missed" incident auto-resolved |
| 5 | "Paused by schedule"; trigger 1 sends the UP notification; TaskCall attaches it to the incident as a second alert (`Down ended (now: Paused)`) and the incident **stays open** |

If the incident does not appear on the test service and the integration
answered `instance_id: null`, another route rule claimed the alert first. Add
`source_payload.device not_equals "Morning Check"` to that rule.

If the heartbeat never goes unhealthy, check its grace period is 0.
