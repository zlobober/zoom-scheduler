import XCTest
@testable import ZoomScheduler

final class RecurrenceTests: XCTestCase {
    func testPresetsAndDefault() throws {
        let base = ["--topic", "Example", "--at", "2030-03-15T12:00:00Z"]
        XCTAssertEqual(try CLIOptions(arguments: base).recurrence, .none)
        for rule in Recurrence.allCases {
            XCTAssertEqual(try CLIOptions(arguments: base + ["--repeat", rule.rawValue]).recurrence, rule)
        }
        XCTAssertThrowsError(try CLIOptions(arguments: base + ["--repeat", "hourly"]))
        XCTAssertThrowsError(try CLIOptions(arguments: ["--invitation-only", "--topic", "Example", "--repeat", "weekly"]))
    }

    func testCustomIntervalsAndEndDates() throws {
        let start = try Recurrence.parseEndDate("2030-03-15").addingTimeInterval(12 * 3600)
        let until = try Recurrence.parseEndDate("2030-12-31")
        for interval in [2, 4] {
            XCTAssertNoThrow(try Recurrence.weekly.validate(start: start, every: interval, until: until))
        }
        XCTAssertNoThrow(try Recurrence.weekly.validate(start: start, until: Calendar.current.startOfDay(for: start)))
        XCTAssertThrowsError(try Recurrence.weekly.validate(start: start, until: start.addingTimeInterval(-86400)))
        XCTAssertThrowsError(try Recurrence.weekly.validate(start: start, every: 0))
        XCTAssertThrowsError(try Recurrence.none.validate(start: start, until: until))
        XCTAssertThrowsError(try Recurrence.parseEndDate("2030-02-29"))
        XCTAssertThrowsError(try Recurrence.parseEndDate("2030-2-03"))
        XCTAssertEqual(try Recurrence.dateString(Recurrence.parseEndDate("2032-02-29")), "2032-02-29")
        XCTAssertEqual(Recurrence.weekly.requestID(every: 1, until: nil), "weekly")
        XCTAssertNotEqual(Recurrence.weekly.requestID(every: 2, until: until), Recurrence.weekly.requestID(every: 4, until: until))
        let options = try CLIOptions(arguments: ["--topic", "Example", "--at", "2030-03-15T12:00:00Z", "--repeat", "weekly", "--repeat-every", "4", "--repeat-until", "2030-12-31"])
        XCTAssertEqual(options.repeatEvery, 4)
        XCTAssertEqual(options.repeatUntil, until)
    }

    func testMonthlyOrdinalAndWeekdayValidation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let config = Configuration()
        for (day, suffix) in [(1,"st"), (2,"nd"), (3,"rd"), (11,"th"), (12,"th"), (13,"th"), (21,"st"), (31,"st")] {
            let date = calendar.date(from: DateComponents(year: 2030, month: 3, day: day, hour: 12))!
            XCTAssertEqual(Recurrence.monthly.zoomLabel(start: date, config: config), "Monthly on the \(day)\(suffix)")
        }
        let friday = calendar.date(from: DateComponents(year: 2030, month: 3, day: 15, hour: 12))!
        let saturday = calendar.date(byAdding: .day, value: 1, to: friday)!
        XCTAssertNoThrow(try Recurrence.weekdays.validate(start: friday))
        XCTAssertThrowsError(try Recurrence.weekdays.validate(start: saturday))
    }
}
