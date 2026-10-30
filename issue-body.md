> [!NOTE]
> **This issue was raised by Claude** (Anthropic's AI assistant, via Claude Code) on behalf of a Trio user. Claude did the analysis from the user's exported log and screenshots, the code it links to, and two open-source Libre 3 decoders (DiaBLE and Juggluco). The findings were checked against the log and source, but not reproduced on hardware or confirmed by a maintainer.

## Describe the bug

With a FreeStyle Libre 3 Plus connected through LibreLoop, Trio showed **Replace Sensor** on the home screen and **Sensor failed / Replace sensor** on the CGM page for **2 h 33 min** (13:36 → 16:09 AEDT, 30 Oct 2026). For that whole time the sensor:

- reported `patchState` **4 (active)** in every status packet,
- kept sending readings (117 `dq=good` readings after 13:36), and
- Trio kept looping normally.

The warning never cleared on its own; only pairing a new sensor cleared it. I removed a working sensor at 5.6 of its 15 days.

> [!IMPORTANT]
> **Root cause in short:** bytes 0–6 of the Libre 3 patch-status packet are the sensor's **most recent event-log entry**, not its live condition. Around 13:22 the sensor logged an entry with `errorData = 8`. RoundWhiteDiscKit maps `errorData 8` → `replaceSensor` without looking at the entry's age or at `patchState`, and LibreLoop persists `sensorNeedsReplacement`. Every later packet repeats the same entry, and LibreLoop only re-evaluates when the attention value *changes*, so the latch can't clear until the sensor logs a different event or a new sensor is paired.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/aidanlane/Trio/2eb898e1e916007f29854f6f72d294c83781e42a/libreloop-timeline-dark.png">
  <img alt="Timeline 13:00 to 16:20. Sensor state is active the whole time. Glucose readings have gaps during Bluetooth dropouts between 13:22 and 14:03, then flow steadily. LibreLoop status shows Sensor failed / Replace Sensor from 13:36 until the new sensor is paired at 16:09." src="https://raw.githubusercontent.com/aidanlane/Trio/2eb898e1e916007f29854f6f72d294c83781e42a/libreloop-timeline-light.png">
</picture>

## Attach a Log

📎 [**trio-libreloop-2026-10-30-redacted.zip**](https://raw.githubusercontent.com/aidanlane/Trio/2eb898e1e916007f29854f6f72d294c83781e42a/trio-libreloop-2026-10-30-redacted.zip) (1.2 MB zipped, 54,815 lines, 30 Oct 00:00–19:03 AEDT, exported with *Share logs*)

> [!NOTE]
> Redacted line-for-line, so every line number below matches the file. Removed: Nightscout host and server IPs, sensor serials (**`SENSOR-A`** = the flagged sensor, **`SENSOR-B`** = its replacement), pairing challenges, keys and PINs, receiver ID, Bluetooth addresses, and the app container ID. Glucose, insulin and carb data are kept.

## To Reproduce

Not deterministic: it needs the sensor to write an event-log entry with `errorData = 8` while it is still active. What happened here:

1. Libre 3 Plus paired via LibreLoop, active and streaming normally.
2. The sensor writes a new event-log entry with `errorData = 8` but stays at `patchState = 4`. Here that happened during minute 8083 (≈13:22), right after a ~5 min app suspension, two notification-off writes from LibreLoop's silence watchdog, and the sensor dropping an authenticated connection (13:22:20).
3. On the next successful patch-status read, LibreLoop raises a time-sensitive **Replace sensor** alert and latches **Sensor failed**.
4. Readings keep arriving, but the warning stays until a new sensor is paired.

It should be reproducible in a unit test: feed `notifySensorAttentionIfNeeded` repeated patch-status frames with `errorData = 8`, `patchState = 4`, while actionable glucose keeps arriving. Today the lifecycle stays `.failed`.

## Expected behavior

- A **Sensor failed** state needs corroboration that the sensor actually stopped: `patchState` leaving 4 (3/5/6/7/8), or glucose no longer arriving.
- An `errorData` code from an event-log entry while `patchState == 4` raises at most a soft, retractable **Check sensor** notice, as [`e0282d0`](https://github.com/loopandlearn/LibreLoop/commit/e0282d063323415b2ccec9906854e45d0c406195) already does for code 7.
- The same event entry doesn't re-alert when it repeats or after an app relaunch.

## Screenshots

| 15:57 Home | 15:57 CGM page | 16:09 Home |
|:---:|:---:|:---:|
| <img src="https://raw.githubusercontent.com/aidanlane/Trio/2eb898e1e916007f29854f6f72d294c83781e42a/home-1557.png" width="240" alt="Home screen at 15:57: 5.2 mmol/L, less than a minute old, loop green, Replace Sensor under the glucose ring"> | <img src="https://raw.githubusercontent.com/aidanlane/Trio/2eb898e1e916007f29854f6f72d294c83781e42a/cgm-settings-1557.png" width="240" alt="FreeStyle Libre 3 / 3+ page at 15:57: Sensor failed, Replace sensor, Bluetooth connected, activated 24 Oct 2026 10:39 pm"> | <img src="https://raw.githubusercontent.com/aidanlane/Trio/2eb898e1e916007f29854f6f72d294c83781e42a/home-1609.png" width="240" alt="Home screen at 16:09: 4.7 mmol/L, 2 minutes old, loop green, still Replace Sensor"> |
| 5.2 mmol/L, fresh, looping | *Sensor failed*, Bluetooth connected | 4.7 mmol/L, looping, still flagged |

## Setup Information (please complete the following information):

### Smartphone:
* Not recorded in the log. Not relevant to this bug, which is in LibreLoop's state logic and doesn't depend on the phone.

### Pump:
* Manufacturer: Insulet
* Model: Omnipod DASH

### CGM:
* Device: FreeStyle Libre 3 Plus (15-day)
* Manager app: LibreLoop (built in, direct Bluetooth): LibreLoop `c6e9cc1`, RoundWhiteDiscKit `e66da6c`

### Trio Version:
* Version Number: 1.0.2 (53)
* Repo: nightscout/trio (built from a fork whose `main` matches upstream)
* Git Reference: `0b29cd5` (v1.0.2 release merge)

## Technical Details

### Sequence

| Time (AEDT) | What happened | Log line |
|---|---|---|
| 13:16:51–13:21:45 | Phone suspended; nothing logged for 294 s | 38890–38891 |
| 13:21:45–13:22:05 | Silence watchdog sends the day's only two notification-off writes. The second comes from a monitor whose stream had already ended and lands on the new connection | 38891, 38895, 38975 |
| 13:22:01 | Patch status still carries the old entry: `currentLC=8083 lifeCount=8` | 38971 |
| 13:22:20 | Sensor drops a live authenticated connection itself (*"The specified device has disconnected from us"*). Only time all day | 38980 |
| **≈13:22** | **Sensor writes a new event-log entry at minute 8083 with `errorData = 8`** | inferred |
| 13:24–13:34 | Connect → no-stream cycles; patch-status reads time out | 39064–39719 |
| **13:36:12** | **First patch status after the event: `currentLC=8097 lifeCount=8083 state=active` → `sensor attention: replaceSensor (sensorError=terminated, patchState=active)`; alert issued** | 39952–39955 |
| 13:47–13:51 | 4 `notDisplayable` readings during a post-meal rise; no new event | 40619–40815 |
| 13:36–16:08 | 70 patch statuses, all `lifeCount=8083 state=active`; no further `sensor attention` lines | 39954–47615 |
| 16:08:48 | Last SENSOR-A reading (83 mg/dL) | 47626 |
| 16:09:30 → 16:10:37 | SENSOR-B scanned → paired; flag cleared | 47682, 47929 |
| 16:18:32 | SENSOR-B's entry moves `lifeCount 1 → 8` in the same packet its state goes `raw(2) → active`, then stays at 8 | 48205 |

### Why it latches

**1. Patch-status bytes 0–6 are the latest event-log entry.**

<details>
<summary>Evidence</summary>

- SENSOR-A: `lifeCount=8` in all 405 patch statuses from 00:01 to 13:22, then `lifeCount=8083` in all 70 from 13:36 to 16:08, while `currentLifeCount` kept advancing and `state=active` throughout.
- SENSOR-B: `lifeCount=1` while `state=raw(2)`, changing to 8 exactly when the state went active (line 48205), then frozen.
- RoundWhiteDiscKit's own docs say so: [`protocol.md` L426-L428](https://github.com/loopandlearn/RoundWhiteDiscKit/blob/e66da6cc34680fecbbb87812279163dcc1a842b4/protocol.md?plain=1#L426-L428).
- The kit's captured field frame `9d280000e0000704e4381300` decodes to `lifeCount 10397` with `currentLifeCount 14564` (bytes 8–9), an entry about 69 h old: [`DataPlaneTests.swift` L291-L293](https://github.com/loopandlearn/RoundWhiteDiscKit/blob/e66da6cc34680fecbbb87812279163dcc1a842b4/Tests/RoundWhiteDiscKitTests/DataPlaneTests.swift#L291-L293).
- DiaBLE (`Libre3.swift`, `parsePatchStatus`) labels these fields event life count, event error data, event data and last event index. Juggluco (`Libre3GattCallback.java`, `libre3processpatchstatus`) uses `index` to request missing event-log entries.

</details>

**2. RoundWhiteDiscKit treats that entry's `errorData` as a current condition.** [`Libre3SensorAttention.init`](https://github.com/loopandlearn/RoundWhiteDiscKit/blob/e66da6cc34680fecbbb87812279163dcc1a842b4/Sources/RoundWhiteDiscKit/DataPlane/PatchStatus.swift#L188-L224) maps `8 → .replaceSensor` regardless of `patchState`. The code describes the mapping as inferred ([L46-L55](https://github.com/loopandlearn/RoundWhiteDiscKit/blob/e66da6cc34680fecbbb87812279163dcc1a842b4/Sources/RoundWhiteDiscKit/DataPlane/PatchStatus.swift#L46-L55)), and neither DiaBLE nor Juggluco assigns meanings to `errorData` values.

**3. LibreLoop's latch only re-evaluates on change.** [`notifySensorAttentionIfNeeded`](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/Pairing/LibreLoopCGMManager%2BPairing.swift#L346-L380) returns early when `attention == lastSensorAttention` (L356) and persists `sensorNeedsReplacement` (L372-L379). [`LibreLoopSensorLifecycle.compute`](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/Sensor/LibreLoopSensorLifecycle.swift#L61-L71) then returns `.failed` before rated wear. For the same sensor the only reset is a different attention value; otherwise only [`applyPairingOutcome`](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/Pairing/LibreLoopCGMManager%2BPairing.swift#L129-L136) clears it.

### Was the sensor actually failing?

Not terminated, by every measure in the log: `patchState 4` in all 70 packets after the event, 117 good readings after 13:36 with a smooth 5-minute history, last reading at 16:08:48, and no further event logged. The Bluetooth trouble was phone-side: SENSOR-B hit the same connect → no-stream pattern 16:30–17:13, about 20 minutes after pairing.

> [!NOTE]
> The `errorData = 8` entry is authenticated sensor data, written in the same minute as the sensor's only self-initiated disconnect of the day, so *something* happened inside the sensor. LibreLoop doesn't log the entry's `eventData` or `index` and never fetches the event log, so what it was can't be determined from this log.

### Impact on Trio

Display plus one time-sensitive alert; dosing was not affected. Trio stores `hasValidSensorSession` but never reads it ([`PluginSource.swift` L244-L245](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/APS/CGM/PluginSource.swift#L244-L245)), never reads `isInoperable`, and LibreLoop kept forwarding glucose. The loop gaps 13:13–13:55 line up with the Bluetooth dropouts. The real cost is a working sensor removed ~9 days early, plus ~70 min of warm-up without closed loop.

### Suggested fix

1. **Don't latch on `errorData` while `patchState == 4`.** Downgrade to a retractable `.checkSensor`, as `e0282d0` does for code 7, and keep the hard latch for non-active patch states. A sensor that really dies stops sending glucose, which already shows *Signal loss* after 6 min ([L36](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/Sensor/LibreLoopSensorLifecycle.swift#L36)) and stops Trio looping on stale data.
2. **Persist the handled event identity** (`lifeCount` + `index`) so a repeated entry or an app relaunch doesn't re-alert. `lastSensorAttention` is in-memory only ([`LibreLoopCGMManager.swift` L70](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/LibreLoopCGMManager/LibreLoopCGMManager.swift#L70)). Optionally auto-clear once actionable readings newer than the event keep arriving.
3. *(RoundWhiteDiscKit, optional)* Expose the entry's age (`currentLifeCount − lifeCount`) and don't derive `sensorAttention` from `errorData` alone when `patchState` is active.

### Related problems found along the way

- [ ] [`discardSensor`](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/LibreLoopCGMManager/LibreLoopCGMManager.swift#L342-L382) doesn't clear `sensorNeedsReplacement` / `sensorEndedNormally`, so the *new* sensor shows **Sensor failed** between NFC scan (16:09:30, line 47682) and pairing outcome (16:10:37, line 47929).
- [ ] The [silence watchdog](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/Sensor/LibreLoopSensorMonitor.swift#L240-L293) only checks cancellation at the top of its loop, so a finished monitor's in-flight tick sent a patch-status read (13:22:00) and a glucose notify-off (13:22:05, line 38975) onto the new connection, 15 s before the sensor dropped it. Possibly what provoked the event; not proven.
- [ ] The [patch-status log line](https://github.com/loopandlearn/LibreLoop/blob/c6e9cc158b1922edb147a0ac3bd2ccc8e8541aa9/LibreLoop/Sensor/LibreLoopSensorMonitor.swift#L460) omits `errorData`, `eventData`, `index` and the disconnect-reason bytes, which is why the 8083 entry can't be identified.

## Additional context

- **Precedent:** [`e0282d0`](https://github.com/loopandlearn/LibreLoop/commit/e0282d063323415b2ccec9906854e45d0c406195) (15 Jul) fixed the same false latch for code 7 and noted *"Terminal replace (code 8, terminated) is unchanged."* The only earlier field evidence for code 8 ([`16d74de`](https://github.com/loopandlearn/LibreLoop/commit/16d74defe1a16c217202ed85f1251e397224a5f2), 1 Aug) came from a sensor shutting down after a clean end of wear.
- **Open questions:** what does `errorData = 8` mean inside an event-log entry? Has anyone else seen `errorData 8` with `patchState 4` on a Libre 3 / 3 Plus, and what happened next?

---
_Generated by [Claude Code](https://claude.ai/code)_
