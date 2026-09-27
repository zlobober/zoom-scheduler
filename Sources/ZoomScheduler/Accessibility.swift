import AppKit
@preconcurrency import ApplicationServices

@MainActor
struct AXNode {
    let element: AXUIElement

    func attribute(_ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    func string(_ name: String) -> String { attribute(name) as? String ?? "" }
    var role: String { string(kAXRoleAttribute) }
    var value: String { string(kAXValueAttribute) }
    var enabled: Bool { (attribute(kAXEnabledAttribute) as? Bool) != false }
    var labels: [String] {
        var result = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                      "AXPlaceholderValue", kAXIdentifierAttribute].map { string($0) }
        if let title = attribute(kAXTitleUIElementAttribute), CFGetTypeID(title) == AXUIElementGetTypeID() {
            let node = AXNode(element: unsafeDowncast(title, to: AXUIElement.self))
            result += [node.value, node.string(kAXTitleAttribute)]
        }
        return result.filter { !$0.isEmpty }
    }
    func nodeAttribute(_ name: String) -> AXNode? {
        guard let raw = attribute(name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXNode(element: unsafeDowncast(raw, to: AXUIElement.self))
    }
    var children: [AXNode] {
        var elements = attribute(kAXChildrenAttribute) as? [AXUIElement] ?? []
        // Status-item menus may not appear in AXChildren on the application.
        for name in ["AXExtrasMenuBar", kAXMenuBarAttribute] {
            if let node = nodeAttribute(name), !elements.contains(where: { CFEqual($0, node.element) }) {
                elements.append(node.element)
            }
        }
        return elements.map { AXNode(element: $0) }
    }
    var parent: AXNode? {
        guard let raw = attribute(kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXNode(element: unsafeDowncast(raw, to: AXUIElement.self))
    }
    var actions: [String] {
        var result: CFArray?
        AXUIElementCopyActionNames(element, &result)
        return result as? [String] ?? []
    }
    func matches(_ names: [String], includeValue: Bool = false) -> Bool {
        let candidates = labels + (includeValue ? [value] : [])
        return candidates.contains { candidate in names.contains { normalized(candidate) == normalized($0) } }
    }
    func walk() -> [AXNode] {
        var result: [AXNode] = []
        var stack: [(AXNode, Int)] = [(self, 0)]
        var seen = Set<CFHashCode>()
        while let (node, depth) = stack.popLast(), result.count < 4000 {
            guard seen.insert(CFHash(node.element)).inserted else { continue }
            result.append(node)
            if depth < 35 { stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) }) }
        }
        return result
    }
    func press() throws {
        guard enabled else { throw AutomationFailure("Control is disabled: \(labels.joined(separator: ", ")).") }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw AutomationFailure("Cannot press \(labels): Accessibility error \(result.rawValue).") }
    }
    func setText(_ text: String) throws {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else {
            throw AutomationFailure("\(labels) is not an editable Accessibility text control. Set it manually in Zoom, then use Verify & create.")
        }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        guard result == .success else { throw AutomationFailure("Cannot set \(labels): Accessibility error \(result.rawValue).") }
    }
}

@MainActor
final class ZoomAutomation {
    var status: (String) -> Void = { _ in }
    // Set BEFORE pressing Save: a timeout must never encourage a duplicate meeting.
    var onSubmissionAttempt: () -> Void = {}

    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func connect(_ config: Configuration) async throws -> AXNode {
        guard Self.trusted else {
            throw AutomationFailure("Enable Zoom Scheduler in System Settings → Privacy & Security → Accessibility, then relaunch this app.")
        }
        var app = NSRunningApplication.runningApplications(withBundleIdentifier: config.zoomBundleID).first
        if app == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.zoomBundleID) else {
                throw AutomationFailure("Zoom is not installed (bundle ID: \(config.zoomBundleID)).")
            }
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        guard let app else { throw AutomationFailure("Could not launch Zoom.") }
        app.activate()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        try await pause()
        return AXNode(element: root)
    }

    func pause() async throws { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation() }

    func wait(_ description: String, seconds: Double = 12, find: () throws -> AXNode?) async throws -> AXNode {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            try Task.checkCancellation()
            if let node = try find() { return node }
            try await pause()
        } while Date() < end
        throw AutomationFailure("Could not find \(description). Sign in to Zoom, check the control labels in Settings, or inspect its Accessibility tree.")
    }

    func unique(_ root: AXNode, names: [String], roles: [String]? = nil, pressable: Bool = false) throws -> AXNode? {
        let matches = root.walk().filter {
            $0.enabled && $0.matches(names) && (roles == nil || roles!.contains($0.role)) &&
            (!pressable || $0.actions.contains(kAXPressAction))
        }
        guard matches.count <= 1 else {
            throw AutomationFailure("Ambiguous control: \(names.joined(separator: ", ")) (\(matches.count) matches). Use more specific labels in Settings or close extra Zoom windows.")
        }
        return matches.first
    }

    func field(_ root: AXNode, _ labels: [String]) throws -> AXNode? {
        try unique(root, names: labels, roles: [kAXTextFieldRole, kAXComboBoxRole, "AXDateField", "AXTimeField"])
    }

    func form(_ root: AXNode, _ config: Configuration) throws -> AXNode? {
        guard let topic = try field(root, config.topic) else { return nil }
        var node = topic.parent
        while let current = node {
            if current.role == kAXSheetRole || current.role == kAXWindowRole || current.role == "AXDialog" {
                return current
            }
            node = current.parent
        }
        return nil
    }

    func openSchedule(config: Configuration) async throws -> AXNode {
        status("Opening Zoom’s menu-bar icon…")
        let root = try await connect(config)
        if try form(root, config) != nil { return root }

        let extras = try await wait("Zoom’s menu-bar icon (enable it in Zoom’s settings if hidden)") {
            if let bar = root.nodeAttribute("AXExtrasMenuBar") { return bar }
            // Some clients expose a second AXMenuBar only through AXChildren.
            let main = root.nodeAttribute(kAXMenuBarAttribute)
            let bars = root.children.filter { node in
                node.role == kAXMenuBarRole && !(main.map { CFEqual($0.element, node.element) } ?? false)
            }
            guard bars.count <= 1 else { throw AutomationFailure("Zoom exposes multiple extra menu bars; inspect its Accessibility tree.") }
            return bars.first
        }
        let icons = extras.children.filter {
            $0.enabled && ($0.actions.contains(kAXPressAction) || $0.actions.contains("AXShowMenu"))
        }
        guard icons.count == 1, let icon = icons.first else {
            throw AutomationFailure("Expected one Zoom status icon, found \(icons.count). Inspect Zoom’s Accessibility tree. No menu item was clicked.")
        }
        let action = icon.actions.contains(kAXPressAction) ? kAXPressAction : "AXShowMenu"
        let result = AXUIElementPerformAction(icon.element, action as CFString)
        // Zoom's status-item AXPress can enter a modal menu-tracking loop. The
        // menu opens, but the synchronous AX request times out (.cannotComplete).
        // Do not press again: that could close it. Observe the menu instead.
        guard result == .success || result == .cannotComplete else {
            throw AutomationFailure("Cannot open Zoom’s status menu: Accessibility error \(result.rawValue).")
        }
        status("Looking for Schedule in Zoom’s open status menu…")
        // Only search menu items, never a Save/Schedule button in a meeting form.
        let schedule = try await wait("Schedule item in Zoom’s status menu") {
            let names = config.schedule.flatMap { [$0, $0 + "…", $0 + "..."] }
            if let item = try self.unique(extras, names: names, roles: [kAXMenuItemRole], pressable: true) { return item }
            // A popup can be exposed as a separate application child instead.
            return try self.unique(root, names: names, roles: [kAXMenuItemRole], pressable: true)
        }
        let selectionResult = AXUIElementPerformAction(schedule.element, kAXPressAction as CFString)
        guard selectionResult == .success || selectionResult == .cannotComplete else {
            throw AutomationFailure("Cannot select Schedule: Accessibility error \(selectionResult.rawValue).")
        }
        // Opening a window can also time out after the action was delivered.
        // Verify the visible result rather than retrying a potentially completed action.
        _ = try await wait("Zoom’s status menu to close after selecting Schedule") {
            let stillOpen = extras.walk().contains { $0.role == kAXMenuItemRole && $0.enabled && $0.matches(config.schedule.flatMap { [$0, $0 + "…", $0 + "..."] }) }
            return stillOpen ? nil : root
        }
        status("Selected Schedule. Waiting for Zoom’s form…")
        return root
    }

    func selectDate(_ date: Date, input: AXNode, dialog: AXNode, config: Configuration) async throws {
        let expected = config.formatted(date, format: config.dateFormat)
        if normalized(input.value) == normalized(expected) { return }
        // Zoom's date combo is a calendar selector, not a real text editor:
        // AXValue may report success while leaving its model unchanged.
        if try unique(dialog, names: ["Choose Date"], roles: [kAXGroupRole]) == nil {
            try input.press()
        }
        // Zoom briefly reuses the previous calendar's AX nodes while rendering
        // the new field's month; don't act on that stale snapshot.
        try await pause()
        let picker = try await wait("date picker") {
            try self.unique(dialog, names: ["Choose Date"], roles: [kAXGroupRole])
        }
        let day = config.formatted(date, format: "EEEE,MMMM d,yyyy")
        let names = [day, day + " selected", day + " not selected"]
        let monthParser = DateFormatter()
        monthParser.locale = Locale(identifier: "en_US_POSIX")
        monthParser.timeZone = .current
        monthParser.dateFormat = "MMMM yyyy"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for _ in 0..<121 {
            try Task.checkCancellation()
            if let button = try unique(picker, names: names, roles: [kAXButtonRole], pressable: true) {
                status("Selecting \(day) in Zoom’s calendar…")
                try button.press()
                _ = try await wait("selected date \(expected)", seconds: 4) {
                    normalized(input.value) == normalized(expected) ? input : nil
                }
                return
            }
            let tables = picker.walk().filter { $0.role == kAXTableRole }
            guard tables.count == 1,
                  let shown = tables[0].labels.compactMap({ monthParser.date(from: $0) }).first,
                  let month = calendar.dateInterval(of: .month, for: date)?.start else {
                throw AutomationFailure("Cannot read Zoom’s calendar month. Nothing was submitted.")
            }
            let direction = month > shown ? "Next month" : "Previous month"
            guard month != shown,
                  let navigate = try unique(picker, names: [direction], roles: [kAXButtonRole], pressable: true) else {
                throw AutomationFailure("Cannot select \(day) in Zoom’s calendar. Nothing was submitted.")
            }
            let previous = tables[0].labels
            status("Calendar: \(direction.lowercased())…")
            try navigate.press()
            _ = try await wait("calendar month to change", seconds: 4) {
                picker.walk().first { $0.role == kAXTableRole && $0.labels != previous }
            }
        }
        throw AutomationFailure("Date selection exceeded 120 calendar navigation steps. Nothing was submitted.")
    }

    func meetingInputs(topic: String, start: Date, config: Configuration, durationMinutes: Int?) throws -> [([String], String)] {
        var inputs: [([String], String)] = [
            (config.topic, topic),
            (config.date, config.formatted(start, format: config.dateFormat)),
            (config.time, config.formatted(start, format: config.timeFormat))
        ]
        if let minutes = durationMinutes {
            guard (1...10080).contains(minutes) else { throw AutomationFailure("Duration must be 1–10080 minutes.") }
            let end = start.addingTimeInterval(Double(minutes) * 60)
            inputs.append((["End date"], config.formatted(end, format: config.dateFormat)))
            inputs.append((["End time"], config.formatted(end, format: config.timeFormat)))
        }
        return inputs
    }

    func selectOption(_ expected: String, control: AXNode, dialog: AXNode) async throws {
        if normalized(control.value) == normalized(expected) { return }
        try control.press()
        let option = try await wait("option “\(expected)”") {
            try self.unique(dialog, names: [expected], roles: [kAXStaticTextRole, kAXMenuItemRole], pressable: true)
        }
        try option.press()
        _ = try await wait("selected option “\(expected)”", seconds: 4) {
            normalized(control.value) == normalized(expected) ? control : nil
        }
        try await pause()
    }

    func recurrenceEnd(_ dialog: AXNode) throws -> AXNode {
        let matches = dialog.walk().filter {
            $0.role == kAXComboBoxRole && $0.enabled && $0.labels.contains { normalized($0).hasPrefix("recurrence end") }
        }
        guard matches.count == 1 else { throw AutomationFailure("Cannot identify Zoom's recurrence end selector. Nothing was submitted.") }
        return matches[0]
    }

    func setRecurrence(_ recurrence: Recurrence, start: Date, dialog: AXNode, config: Configuration,
                       every: Int = 1, until: Date? = nil) async throws {
        try recurrence.validate(start: start, every: every, until: until)
        let expected = recurrence.zoomLabel(start: start, config: config)
        guard let repeatField = try field(dialog, ["Repeat"]) else {
            throw AutomationFailure("Zoom's Repeat control is unavailable. Nothing was submitted.")
        }
        status("Setting recurrence: \(recurrence.title), interval \(every), until \(until.map(Recurrence.dateString) ?? "never")…")
        // Seed the exact preset first: this establishes the correct weekday(s) or
        // day-of-month instead of inheriting a previous custom rule.
        try await selectOption(expected, control: repeatField, dialog: dialog)
        guard every != 1 || until != nil else { return }
        try await selectOption("Custom...", control: repeatField, dialog: dialog)
        let interval = try await wait("\(recurrence.intervalControl) control") {
            try self.unique(dialog, names: [recurrence.intervalControl], roles: [kAXIncrementorRole])
        }
        // AXIncrement/Decrement updates Zoom's model reliably; AXValue writes can
        // target the wrong editor or change only the displayed text.
        for _ in 0..<100 {
            guard let current = (interval.attribute(kAXValueAttribute) as? NSNumber)?.intValue else {
                throw AutomationFailure("Cannot read the recurrence interval. Nothing was submitted.")
            }
            if current == every { break }
            let action = current < every ? kAXIncrementAction : kAXDecrementAction
            guard AXUIElementPerformAction(interval.element, action as CFString) == .success else {
                throw AutomationFailure("Cannot adjust recurrence interval. Nothing was submitted.")
            }
            _ = try await wait("recurrence interval change", seconds: 3) {
                (interval.attribute(kAXValueAttribute) as? NSNumber)?.intValue != current ? interval : nil
            }
        }
        let end = try recurrenceEnd(dialog)
        try await selectOption(until == nil ? "Never" : "On...", control: end, dialog: dialog)
        if let until {
            let endDate = try await wait("End by date") { try self.field(dialog, ["End by date"]) }
            try await selectDate(until, input: endDate, dialog: dialog, config: config)
        }
        try verifyRecurrence(recurrence, start: start, dialog: dialog, config: config, every: every, until: until)
    }

    func verifyRecurrence(_ recurrence: Recurrence, start: Date, dialog: AXNode, config: Configuration,
                          every: Int = 1, until: Date? = nil) throws {
        let custom = every != 1 || until != nil
        let expected = custom ? "Custom..." : recurrence.zoomLabel(start: start, config: config)
        guard let control = try field(dialog, ["Repeat"]), normalized(control.value) == normalized(expected) else {
            throw AutomationFailure("Recurrence verification failed: expected “\(expected)”. Nothing was submitted.")
        }
        guard custom else { return }
        guard let frequency = try field(dialog, ["Recurrence"]), frequency.value == recurrence.customFrequency,
              let interval = try unique(dialog, names: [recurrence.intervalControl], roles: [kAXIncrementorRole]),
              (interval.attribute(kAXValueAttribute) as? NSNumber)?.intValue == every else {
            throw AutomationFailure("Custom recurrence frequency/interval verification failed. Nothing was submitted.")
        }
        if recurrence == .weekly || recurrence == .weekdays {
            let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let chosen = recurrence == .weekdays ? Array(weekdays.prefix(5)) : [config.formatted(start, format: "EEEE")]
            for day in weekdays {
                let label = "Occurs on \(day),\(chosen.contains(day) ? "checked" : "not checked")"
                guard try unique(dialog, names: [label], roles: [kAXButtonRole]) != nil else {
                    throw AutomationFailure("Repeat weekday verification failed for \(day). Nothing was submitted.")
                }
            }
        }
        if recurrence == .monthly {
            guard let byDate = try unique(dialog, names: ["On the Day of the month"], roles: [kAXRadioButtonRole]),
                  (byDate.attribute(kAXValueAttribute) as? NSNumber)?.intValue == 1 else {
                throw AutomationFailure("Monthly recurrence must use the same day of month. Nothing was submitted.")
            }
        }
        let end = try recurrenceEnd(dialog)
        guard end.value == (until == nil ? "Never" : "On...") else {
            throw AutomationFailure("Recurrence end mode verification failed. Nothing was submitted.")
        }
        if let until {
            let expectedDate = config.formatted(until, format: config.dateFormat)
            guard let endDate = try field(dialog, ["End by date"]), normalized(endDate.value) == normalized(expectedDate) else {
                throw AutomationFailure("Recurrence end date must be \(expectedDate). Nothing was submitted.")
            }
        }
    }

    func prepare(topic: String, start: Date, config: Configuration, durationMinutes: Int? = nil, recurrence: Recurrence = .none, repeatEvery: Int = 1, repeatUntil: Date? = nil) async throws {
        try validateMeeting(topic: topic, start: start)
        try recurrence.validate(start: start, every: repeatEvery, until: repeatUntil)
        let root = try await openSchedule(config: config)
        let dialog = try await wait("scheduling form") { try self.form(root, config) }
        if let picker = try unique(dialog, names: ["Choose Date"], roles: [kAXGroupRole]) {
            // A leftover popup owns keyboard focus even when AXFocused accepts a
            // write to Topic. Re-select its current day to close it without edits.
            let selected = picker.walk().filter { node in
                node.role == kAXButtonRole && node.enabled && node.labels.contains {
                    $0.hasSuffix(" selected") && !$0.hasSuffix(" not selected")
                }
            }
            guard selected.count == 1 else { throw AutomationFailure("Close Zoom’s open date picker and retry. Nothing was submitted.") }
            try selected[0].press()
            try await pause()
        }
        let inputs = try meetingInputs(topic: topic, start: start, config: config, durationMinutes: durationMinutes)
        // Resolve everything before editing, and reject overlapping selectors.
        let fields = try inputs.map { labels, _ -> AXNode in
            guard let input = try field(dialog, labels) else {
                throw AutomationFailure("No editable field found for \(labels). Fill it manually in Zoom; adjust Settings if needed.")
            }
            return input
        }
        for i in fields.indices {
            for j in fields.indices where j < i {
                guard !CFEqual(fields[i].element, fields[j].element) else {
                    throw AutomationFailure("Topic, date, and time must refer to distinct controls. Check Settings. Nothing was edited.")
                }
            }
        }
        for index in fields.indices {
            let input = fields[index]
            status("Filling \(inputs[index].0.first ?? "field")…")
            if (index == 1 || index == 3) && input.role == kAXComboBoxRole {
                let date = index == 1 ? start : start.addingTimeInterval(Double(durationMinutes!) * 60)
                try await selectDate(date, input: input, dialog: dialog, config: config)
            } else {
                // Zoom's combo-box AXValue setter can write to the currently focused
                // text editor instead of the target. Focus and verify ownership first.
                let focusResult = AXUIElementSetAttributeValue(input.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                guard focusResult == .success else {
                    throw AutomationFailure("Cannot focus \(input.labels). Nothing further was edited.")
                }
                _ = try await wait("keyboard focus on \(input.labels)", seconds: 3) {
                    guard let focused = root.nodeAttribute(kAXFocusedUIElementAttribute),
                          CFEqual(focused.element, input.element) else { return nil }
                    return input
                }
                try input.setText(inputs[index].1)
                try await pause()
                // Blur combo-box editors to commit/normalize their values.
                if index > 0 {
                    _ = AXUIElementSetAttributeValue(fields[0].element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    try await pause()
                }
            }
            for checked in 0...index {
                guard normalized(fields[checked].value) == normalized(inputs[checked].1) else {
                    throw AutomationFailure("Stopped after editing \(inputs[index].0[0]): \(inputs[checked].0[0]) reads “\(fields[checked].value)” instead of “\(inputs[checked].1)”. Check the field format in Settings. Nothing was submitted.")
                }
            }
        }
        // Move focus away so native controls can commit/normalize edited text.
        if let topicField = try field(dialog, config.topic) {
            _ = AXUIElementSetAttributeValue(topicField.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        try await pause()
        try await setRecurrence(recurrence, start: start, dialog: dialog, config: config, every: repeatEvery, until: repeatUntil)
        try verifyRecurrence(recurrence, start: start, dialog: dialog, config: config, every: repeatEvery, until: repeatUntil)
        try verify(dialog, topic: topic, start: start, config: config, durationMinutes: durationMinutes)
        status("Topic, date, time\(durationMinutes == nil ? "" : ", and duration") filled and verified.")
    }

    func verify(_ dialog: AXNode, topic: String, start: Date, config: Configuration, durationMinutes: Int? = nil) throws {
        for (labels, expected) in try meetingInputs(topic: topic, start: start, config: config, durationMinutes: durationMinutes) {
            guard let input = try field(dialog, labels), normalized(input.value) == normalized(expected) else {
                throw AutomationFailure("Verification failed for \(labels.joined(separator: "/")). Expected “\(expected)”. Nothing was submitted. Check Zoom’s field value and the configured format.")
            }
        }
    }

    func disableCalendarImport(_ dialog: AXNode) async throws {
        status("Selecting Other Calendars to prevent Outlook/Calendar import…")
        guard let other = try unique(dialog, names: ["Other Calendars"], roles: [kAXRadioButtonRole]) else {
            throw AutomationFailure("Cannot find Zoom's Other Calendars option. Stopping before Save to avoid opening an external calendar application.")
        }
        if (other.attribute(kAXValueAttribute) as? NSNumber)?.intValue != 1 {
            try other.press()
        }
        _ = try await wait("Other Calendars to be selected", seconds: 4) {
            (other.attribute(kAXValueAttribute) as? NSNumber)?.intValue == 1 ? other : nil
        }
        try await pause()
    }

    /// Other Calendars normally exposes the invitation in Zoom rather than an
    /// external .ics import. Read only a complete topic-matched invitation body.
    func visibleInvitation(_ root: AXNode, topic: String) throws -> String? {
        let roles = [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole]
        let texts = root.walk().filter { roles.contains($0.role) }.flatMap { [$0.value] + $0.labels }
        return try matchingInvitation(in: texts, topic: topic)
    }

    func copyVisibleConfirmation(_ root: AXNode, topic: String, config: Configuration) async throws -> String? {
        let windows = root.children.filter { $0.role == kAXWindowRole }
        var buttons: [AXNode] = []
        for window in windows {
            guard window.matches(["Schedule Meeting", "Meeting scheduled", "Meeting Invitation", topic]) else { continue }
            // Some versions render the topic separately from the invitation body.
            // Scope Copy to a window containing that exact topic, never a global button.
            guard window.walk().contains(where: { $0.matches([topic], includeValue: true) }) else { continue }
            if let copy = try unique(window, names: config.copyInvitation + ["Copy to Clipboard"], pressable: true) {
                buttons.append(copy)
            }
        }
        guard buttons.count <= 1 else { throw AutomationFailure("Multiple invitation windows match this topic. Nothing was copied.") }
        guard let copy = buttons.first else { return nil }
        let clipboard = NSPasteboard.general
        let previousCount = clipboard.changeCount
        try copy.press()
        let deadline = Date().addingTimeInterval(8)
        repeat {
            try await pause()
            if clipboard.changeCount != previousCount, let text = clipboard.string(forType: .string) {
                // Topic was verified separately in the source window. Preserve it
                // as metadata for customized invitations which omit the topic.
                let withTopic = text.localizedCaseInsensitiveContains(topic) ? text : "Topic: \(topic)\n\n\(text)"
                guard let verified = try matchingInvitation(in: [withTopic], topic: topic) else {
                    throw AutomationFailure("Zoom copied text without a valid Zoom invitation URL.")
                }
                return verified
            }
        } while Date() < deadline
        throw AutomationFailure("Zoom's invitation Copy control did not update the clipboard. The meeting may already exist; do not recreate it.")
    }

    func create(topic: String, start: Date, config: Configuration, durationMinutes: Int? = nil, recurrence: Recurrence = .none, repeatEvery: Int = 1, repeatUntil: Date? = nil) async throws -> String {
        try validateMeeting(topic: topic, start: start)
        let root = try await connect(config)
        guard let dialog = try form(root, config) else { throw AutomationFailure("Open and fill Zoom’s scheduling form first.") }
        try recurrence.validate(start: start, every: repeatEvery, until: repeatUntil)
        try verifyRecurrence(recurrence, start: start, dialog: dialog, config: config, every: repeatEvery, until: repeatUntil)
        try verify(dialog, topic: topic, start: start, config: config, durationMinutes: durationMinutes)
        // Without an interactive review step, require an identifiable matching timezone.
        let zone = try field(dialog, ["Time zone", "Timezone"])
        let city = TimeZone.current.identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? ""
        guard let zone, !city.isEmpty,
              zone.value.localizedCaseInsensitiveContains(city) || zone.value.localizedCaseInsensitiveContains(TimeZone.current.identifier) else {
            throw AutomationFailure("Zoom’s timezone could not be verified as \(TimeZone.current.identifier). Set that timezone in Zoom before retrying. Nothing was submitted.")
        }
        try await disableCalendarImport(dialog)
        // Re-check after changing the calendar option, in case Zoom re-rendered.
        try verify(dialog, topic: topic, start: start, config: config, durationMinutes: durationMinutes)
        try verifyRecurrence(recurrence, start: start, dialog: dialog, config: config, every: repeatEvery, until: repeatUntil)
        status("Fields, timezone, and no-import calendar option verified. Locating Save…")
        guard let save = try unique(dialog, names: config.submitLabels, roles: [kAXButtonRole], pressable: true) else {
            throw AutomationFailure("Could not identify a unique Save/Schedule control. Nothing was submitted.")
        }
        try Task.checkCancellation()
        onSubmissionAttempt()
        status("Submitting in Zoom… Do not submit again if invitation retrieval fails.")
        try save.press()
        // Wait for Zoom's confirmation/meeting details, not an external calendar.
        try await Task.sleep(for: .seconds(2))
        return try await invitation(topic: topic, config: config, expectedStart: start, waitForConfirmation: true)
    }

    func invitation(topic: String, config: Configuration, expectedStart: Date? = nil, waitForConfirmation: Bool = false) async throws -> String {
        status("Looking for the meeting’s invitation…")
        let root = try await connect(config)
        // Newly saved meetings can take a few seconds to render their invitation.
        let deadline = Date().addingTimeInterval(waitForConfirmation ? 10 : 0)
        repeat {
            if try form(root, config) == nil {
                let direct = try visibleInvitation(root, topic: topic)
                let text: String?
                if let direct { text = direct }
                else { text = try await copyVisibleConfirmation(root, topic: topic, config: config) }
                if let text {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    status("Invitation retrieved directly from Zoom. No external calendar import.")
                    return text
                }
            }
            if Date() >= deadline { break }
            try await pause()
        } while true
        guard try form(root, config) == nil else {
            throw AutomationFailure("Zoom’s scheduling/editing form is still open. Invitation retrieval only works for a saved meeting. For a new meeting, use Create meeting. If you already attempted submission, check Zoom for errors or an existing meeting before retrying. Invitation-only retrieval did not save anything.")
        }
        // With Outlook/iCal selected, Zoom exports the invitation to its own data
        // directory and launches the calendar app instead of showing Copy Invitation.
        if config.zoomBundleID == "us.zoom.xos",
           let exported = try CalendarInvitation.find(topic: topic, start: expectedStart) {
            let text = exported.message
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status("Invitation retrieved from Zoom’s calendar export. No calendar event was imported. Exported invitations can be stale if the meeting was later edited or deleted.")
            return text
        }
        // Never copy from an arbitrary existing meeting detail view. First select the requested topic.
        if let meetings = try unique(root, names: config.meetings, pressable: true) {
            try meetings.press()
            try await pause()
        }
        let meeting = try await wait("meeting named “\(topic)” in Zoom’s Meetings view", seconds: 20) {
            let matches = root.walk().filter {
                $0.matches([topic], includeValue: true) && $0.role != kAXTextFieldRole
            }
            // Prefer the row if both a row and its title expose the same name.
            let rows = matches.filter { $0.role == kAXRowRole }
            if rows.count == 1 { return rows[0] }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw AutomationFailure("Multiple controls/meetings match this topic. Select the intended meeting in Zoom and use a unique topic.") }
            return nil
        }
        var target: AXNode? = meeting
        var selected = false
        for _ in 0..<5 {
            guard let current = target else { break }
            if current.actions.contains(kAXPressAction) { try current.press(); selected = true; break }
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(current.element, kAXSelectedAttribute as CFString, &settable)
            if settable.boolValue,
               AXUIElementSetAttributeValue(current.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                selected = true; break
            }
            target = current.parent
        }
        guard selected else { throw AutomationFailure("Zoom does not expose a selectable meeting row. Open the meeting manually and copy its invitation in Zoom.") }
        try await pause()
        let copy = try await wait("Copy invitation button") { try self.unique(root, names: config.copyInvitation, pressable: true) }
        let clipboard = NSPasteboard.general
        let previousCount = clipboard.changeCount
        try copy.press()
        let end = Date().addingTimeInterval(8)
        repeat {
            try await pause()
            if clipboard.changeCount != previousCount,
               let text = clipboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard text.localizedCaseInsensitiveContains(topic),
                      text.range(of: #"https?://[^\s]*zoom\.[^\s]+"#, options: .regularExpression) != nil else {
                    throw AutomationFailure("Zoom changed the clipboard, but its text did not contain the requested topic and a Zoom URL. Inspect the invitation in Zoom manually.")
                }
                status("Invitation retrieved. It is also on your clipboard.")
                return text
            }
        } while Date() < end
        throw AutomationFailure("Zoom did not put an invitation on the clipboard. The meeting may already exist; do not recreate it.")
    }

    func snapshot(config: Configuration) async throws -> String {
        let root = try await connect(config)
        return root.walk().map { node in
            "\(node.role) labels=\(node.labels) value=\(String(node.value.prefix(500))) actions=\(node.actions)"
        }.joined(separator: "\n")
    }
}
