#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Sources/ZoomScheduler/Configuration.swift Sources/ZoomScheduler/CalendarInvitation.swift Sources/ZoomScheduler/CommandLine.swift Sources/ZoomScheduler/Recurrence.swift scripts/smoke-tests.swift -o "$TMP/tests"
"$TMP/tests"
