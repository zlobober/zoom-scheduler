import Foundation

/// Zoom's built-in repeat presets. Monthly means the start's day of month.
enum Recurrence: String, CaseIterable, Identifiable {
    case none, daily, weekly, weekdays, monthly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Never"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .weekdays: "Every weekday"
        case .monthly: "Monthly (same date)"
        }
    }

    func zoomLabel(start: Date, config: Configuration) -> String {
        switch self {
        case .none: return "Never"
        case .daily: return "Daily at \(config.formatted(start, format: config.timeFormat))"
        case .weekly: return "Weekly on \(config.formatted(start, format: "EEEE"))"
        case .weekdays: return "Every weekday (Monday to Friday)"
        case .monthly:
            let day = Calendar(identifier: .gregorian).component(.day, from: start)
            let suffix: String
            if (11...13).contains(day) { suffix = "th" }
            else { suffix = [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th" }
            return "Monthly on the \(day)\(suffix)"
        }
    }

    var intervalUnit: String {
        switch self {
        case .daily: "day(s)"
        case .monthly: "month(s)"
        default: "week(s)"
        }
    }
    var intervalControl: String {
        switch self {
        case .daily: "Days to repeat"
        case .monthly: "Months to repeat"
        default: "Weeks to repeat"
        }
    }
    var customFrequency: String {
        switch self {
        case .daily: "Daily"
        case .monthly: "Monthly"
        default: "Weekly"
        }
    }
    func requestID(every: Int, until: Date?) -> String {
        guard every != 1 || until != nil else { return rawValue }
        return "\(rawValue)|\(every)|\(until.map(Self.dateString) ?? "never")"
    }
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func parseEndDate(_ string: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = formatter.date(from: string), dateString(date) == string else {
            throw AutomationFailure("--repeat-until requires a valid YYYY-MM-DD date in the meeting's local timezone.")
        }
        return date
    }

    func validate(start: Date, every: Int = 1, until: Date? = nil) throws {
        guard (1...99).contains(every) else { throw AutomationFailure("Repeat interval must be 1–99.") }
        if self == .none && (every != 1 || until != nil) {
            throw AutomationFailure("A repeat interval or end date requires a repeating rule.")
        }
        if let until, Calendar.current.startOfDay(for: until) < Calendar.current.startOfDay(for: start) {
            throw AutomationFailure("The repeat end date must be on or after the first meeting's local date.")
        }
        // Avoid a first occurrence that contradicts the requested start date.
        if self == .weekdays {
            let weekday = Calendar(identifier: .gregorian).component(.weekday, from: start)
            guard weekday != 1 && weekday != 7 else {
                throw AutomationFailure("Weekday recurrence requires a Monday–Friday start date.")
            }
        }
    }
}
