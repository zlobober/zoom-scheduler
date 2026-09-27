import Foundation

struct CLIOptions {
    var topic: String?
    var start: Date?
    var configPath: String?
    var durationMinutes: Int?
    var recurrence: Recurrence = .none
    var repeatEvery = 1
    var repeatUntil: Date?
    var invitationOnly = false
    var inspect = false
    var help = false
    var printConfig = false

    static let usage = """
    ZoomScheduler --cli --topic TITLE --at ISO8601
    ZoomScheduler --cli --invitation-only --topic TITLE [--at ISO8601]
    ZoomScheduler --cli --inspect
    ZoomScheduler --cli --print-config

    Options:
      --at              Start time with explicit timezone, e.g. 2026-09-28T10:00:00+02:00
      --duration-minutes N  Set duration explicitly (1–10080 minutes)
      --repeat RULE     none (default), daily, weekly, weekdays, monthly
                        Monthly uses the same day of month
      --repeat-every N   Repeat every N days/weeks/months (1–99; default 1)
      --repeat-until DATE Inclusive last local date, YYYY-MM-DD (default: no end)
      --config PATH     Override Accessibility labels/formats using a JSON file
      --invitation-only Retrieve an existing invitation; never create a meeting
      --inspect         Print Zoom's Accessibility tree (may contain private data)
      --print-config    Print default configuration JSON without accessing Zoom
      --help            Show this help

    No scheduler window is opened. Zoom itself still uses the logged-in desktop.
    Requires Accessibility permission, an unlocked macOS session, and signed-in Zoom.
    Creation keeps Zoom's duration/security options and selects Other Calendars
    to avoid external calendar import. Previous app focus is restored. Invitation on
    stdout, action log on stderr. Exit codes: 0 success, 1 automation error, 2 usage.
    Repeating a previously attempted topic/time retrieves only to prevent duplicates.
    """

    init(arguments: [String]) throws {
        var index = 0
        var seen = Set<String>()
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw AutomationFailure("Repeated option: \(flag)") }
            switch flag {
            case "--cli": break
            case "--help", "-h": help = true
            case "--invitation-only": invitationOnly = true
            case "--inspect": inspect = true
            case "--print-config": printConfig = true
            case "--topic", "--at", "--config", "--duration-minutes", "--repeat", "--repeat-every", "--repeat-until":
                index += 1
                guard index < arguments.count else { throw AutomationFailure("Missing value for \(flag)") }
                let value = arguments[index]
                if flag == "--topic" { topic = value }
                else if flag == "--config" { configPath = value }
                else if flag == "--repeat-every" {
                    guard let interval = Int(value), (1...99).contains(interval) else {
                        throw AutomationFailure("--repeat-every must be an integer from 1 to 99.")
                    }
                    repeatEvery = interval
                }
                else if flag == "--repeat-until" { repeatUntil = try Recurrence.parseEndDate(value) }
                else if flag == "--repeat" {
                    guard let rule = Recurrence(rawValue: value.lowercased()) else {
                        throw AutomationFailure("--repeat must be none, daily, weekly, weekdays, or monthly.")
                    }
                    recurrence = rule
                }
                else if flag == "--duration-minutes" {
                    guard let minutes = Int(value), (1...10080).contains(minutes) else {
                        throw AutomationFailure("--duration-minutes must be an integer from 1 to 10080.")
                    }
                    durationMinutes = minutes
                }
                else {
                    guard let date = ISO8601DateFormatter().date(from: value),
                          value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
                        throw AutomationFailure("--at requires ISO8601 with timezone, e.g. 2026-09-28T10:00:00+02:00")
                    }
                    start = date
                }
            default: throw AutomationFailure("Unknown option: \(flag)")
            }
            index += 1
        }
        if help { return }
        guard [invitationOnly, inspect, printConfig].filter({ $0 }).count <= 1 else {
            throw AutomationFailure("Choose only one of --invitation-only, --inspect, --print-config.")
        }
        let repeatFlags = !seen.isDisjoint(with: ["--repeat", "--repeat-every", "--repeat-until"])
        if repeatFlags && (invitationOnly || inspect || printConfig) {
            throw AutomationFailure("--repeat is only supported when creating a meeting, not with retrieval or diagnostics.")
        }
        if recurrence == .none && (seen.contains("--repeat-every") || seen.contains("--repeat-until")) {
            throw AutomationFailure("--repeat-every and --repeat-until require --repeat daily, weekly, weekdays, or monthly.")
        }
        if inspect || printConfig { return }
        guard let topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationFailure("--topic is required.")
        }
        guard invitationOnly || start != nil else { throw AutomationFailure("--at is required when creating a meeting.") }
        if let start, !invitationOnly { try recurrence.validate(start: start, every: repeatEvery, until: repeatUntil) }
    }
}
