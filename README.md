# Zoom Scheduler

Native macOS app and CLI that control the installed Zoom client through Accessibility. Enter a topic/time and run one sequence: open Zoom’s tray menu → Schedule → fill and verify the fields/timezone → Save → retrieve the invitation.

## Build

Requires macOS 14+, Swift 6, and Zoom installed and signed in.

```sh
./scripts/build-app.sh
open "dist/Zoom Scheduler.app"
```

Built app: `dist/Zoom Scheduler.app`. No Xcode project or API credentials needed. The app is ad-hoc signed; use `SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh` for a stable signing identity. Local use only; distribution requires appropriate signing/notarization. Rebuilds can require removing/re-adding the app’s Accessibility grant.

## GUI

- Enter the meeting topic and start time, then click **Create meeting**.
- On first use, enable **Zoom Scheduler** under System Settings → Privacy & Security → Accessibility.
- Actions/errors appear in the log. The invitation appears below it; **Copy** copies it.
- While running, the same button becomes **Stop**. Stopping does not undo a submitted meeting.

Creation is immediate, for the selected future time. The timezone must match the Mac’s timezone. Duration, recurrence, security, and calendar settings remain as configured in Zoom. The app verifies the displayed timezone city/identifier; unrecognized labels stop submission. Keep Zoom available; do not operate its UI concurrently with automation.

Topic/time and submission attempts persist locally. Repeating the same topic/time after submission was attempted retrieves the invitation only, instead of risking a duplicate—even after a restart. Edit the topic/time to create a different meeting. Failed requests before submission can be retried normally. Attempts are retained for the latest 500 requests, not a server-side idempotency guarantee.

## CLI (no scheduler window)

Invoke the executable **inside the built app bundle**, not `open`:

```sh
ZOOM="$PWD/dist/Zoom Scheduler.app/Contents/MacOS/ZoomScheduler"

"$ZOOM" --cli \
  --topic "Planning discussion" \
  --at "2026-10-01T10:00:00+02:00" \
  > invitation.txt
```

- Invitation goes to **stdout**; action logs/errors go to **stderr**.
- Exit status: `0` success, `1` automation failure, `2` invalid arguments.
- `--at` requires ISO8601 with an explicit timezone. It is converted to the Mac’s local timezone for Zoom.
- `--duration-minutes 120` sets and verifies a two-hour meeting, including its end date/time. Accepted range: 1–10080 minutes. Without it, Zoom’s duration is retained.
- Same automation engine and duplicate-submission protection as the GUI.
- A lock prevents simultaneous GUI/CLI operations.

Retrieve only (does not create or save anything):

```sh
"$ZOOM" --cli --invitation-only --topic "Planning discussion" > invitation.txt
# Optionally specify --at to distinguish the exact start time.
```

Diagnostics/configuration:

```sh
"$ZOOM" --help
"$ZOOM" --cli --print-config > config.json
"$ZOOM" --cli --inspect > zoom-accessibility.txt
"$ZOOM" --cli --config config.json --topic "Planning discussion" --at "2026-10-01T10:00:00+02:00"
```

**No scheduler UI does not mean headless Zoom.** CLI mode still needs a logged-in, unlocked graphical macOS session, signed-in Zoom, and Accessibility permission. It activates and interacts with Zoom’s windows; calendar integration may also open Outlook or Calendar. It is not intended for locked sessions, a background server, or SSH without access to a graphical session. Your terminal may also need Accessibility permission. Set up permission via the GUI first.

## Invitation retrieval

With Outlook/iCal selected, Zoom creates an `.ics` file in `~/Library/Application Support/zoom.us/data/` and launches the calendar application. The scheduler reads the matching Zoom-generated export directly; it **does not import the event into Outlook/Calendar**. You may cancel the calendar import dialog without deleting the Zoom meeting.

Zoom may delete these temporary exports when the calendar handoff closes. Keep the import dialog open until retrieval completes; later retrieval may need Zoom’s Meetings UI instead.

Exports are matched by exact topic and, for creation, start time. Multiple distinct matching events are rejected. The parser handles line folding, escaped text, UTC/TZID dates, and nested alarm descriptions. The displayed message prepends topic/time to Zoom’s invitation description. Only the 200 most recently modified exports under 1 MB are considered.

If no export matches, retrieval falls back to Zoom’s Meetings UI and Copy invitation action. That fallback remains version-dependent and has not been validated end-to-end here. It does not paginate date filters or handle every overflow menu.

**Local exports can be stale if a meeting was subsequently changed or deleted.** They are not a server-side existence check. Use a unique topic and verify important changes in Zoom.

Retrieval replaces the clipboard. The scheduler does not persist invitation text or logs; redirected CLI output and Zoom’s own exports remain on disk. Topic/time, submission-attempt identifiers, and configuration persist in UserDefaults (`local.max.ZoomScheduler`). No telemetry or direct network API calls; Zoom performs its normal networking. Diagnostics can contain private meeting information.

## Compatibility

Zoom versions/languages expose different Accessibility labels. Defaults target the local English Zoom Workplace UI, including its web-based scheduling form and `Save, opens calendar invite window` label. Date/time defaults follow macOS regional settings. You can override exact labels/formats with CLI `--config`; existing GUI configuration from earlier versions is still honored.

Date combo boxes are operated through Zoom’s calendar picker using full date labels and bounded month navigation, rather than writing an ignored AXValue. An already-open picker is dismissed by selecting its current day before editing other fields.

Field writes explicitly verify focus ownership to avoid Zoom writing combo-box values into the previously focused topic. Each edit is checked; ambiguous controls, overlapping selectors, mismatched dates/times/timezones, and read-only fields stop automation. Status-menu AX timeouts are followed by observing the menu, never a blind duplicate click. No coordinate-based clicking.

If the submission-attempt ledger blocks a request that you have independently confirmed never created a meeting, use a new unique topic, or reset the entire local ledger with `defaults delete local.max.ZoomScheduler submissionAttempts` **only after checking for duplicates**.

## Tests

```sh
./scripts/test.sh    # Works with Command Line Tools
swift test          # XCTest requires a toolchain with XCTest (full Xcode)
```

Tests cover configuration, normalization, dates, ICS parsing/export matching, and CLI parsing. Local live tests have verified menu navigation, field filling, Save identification, and retrieval from a real Zoom-generated export. Live CLI runs have verified complete meeting creation, explicit duration, calendar date selection, Save, and invitation retrieval. The test scripts themselves do not create meetings.

## Files

- `ZoomSchedulerApp.swift` — minimal GUI and log
- `EntryPoint.swift` / `CommandLine.swift` — GUI/CLI entry and argument parsing
- `Workflow.swift` — shared sequence, locking, submission ledger
- `Accessibility.swift` — Zoom UI automation
- `CalendarInvitation.swift` — Zoom calendar-export retrieval
- `Configuration.swift` — selectors, formats, validation

All Swift sources are under `Sources/ZoomScheduler/`.
