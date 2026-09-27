import Foundation

struct Configuration: Codable {
    var zoomBundleID = "us.zoom.xos"
    var schedule = ["Schedule", "Schedule a meeting", "Schedule Meeting"]
    var topic = ["Topic", "Meeting topic", "Enter meeting topic"]
    var date = ["Start date", "Date", "Meeting date"]
    var time = ["Start time", "Time"]
    var submit = ["Save", "Schedule", "Schedule Meeting"]
    var submitLabels: [String] {
        // Zoom's web-based scheduler appends the calendar action to the AX name.
        // Keep this exact alias compatible with already-persisted configurations.
        submit + (submit.contains { normalized($0) == "save" } ? ["Save, opens calendar invite window"] : [])
    }
    var meetings = ["Meetings"]
    var copyInvitation = ["Copy invitation", "Copy Invitation", "Copy meeting invitation"]
    // These must match the date/time representation displayed by your Zoom client.
    var dateFormat = DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .current) ?? "yyyy-MM-dd"
    var timeFormat = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: .current) ?? "HH:mm"

    static var sample: String { Self().json }
    static var legacySample: String {
        var config = Self()
        config.dateFormat = "MM/dd/yyyy"
        config.timeFormat = "h:mm a"
        return config.json
    }
    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try! encoder.encode(self), encoding: .utf8)!
    }

    func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .replacingOccurrences(of: "\u{202f}", with: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        .lowercased()
}

struct AutomationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func validateMeeting(topic: String, start: Date, now: Date = Date()) throws {
    guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AutomationFailure("Enter a meeting topic.")
    }
    guard start.timeIntervalSince(now) >= 60 else {
        throw AutomationFailure("Choose a start time at least one minute in the future.")
    }
}
