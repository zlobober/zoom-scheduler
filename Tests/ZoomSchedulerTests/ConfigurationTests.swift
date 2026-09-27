import XCTest
@testable import ZoomScheduler

final class ConfigurationTests: XCTestCase {
    func testDefaultConfigurationRoundTrip() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(Configuration.sample.utf8))
        XCTAssertEqual(config.zoomBundleID, "us.zoom.xos")
        XCTAssertTrue(config.copyInvitation.contains("Copy invitation"))
    }

    func testCalendarSaveAlias() {
        var config = Configuration()
        XCTAssertTrue(config.submitLabels.contains("Save, opens calendar invite window"))
        config.submit = ["Custom submit"]
        XCTAssertEqual(config.submitLabels, ["Custom submit"])
    }

    func testLabelNormalization() {
        XCTAssertEqual(normalized(" Start Date: \n"), "start date")
        XCTAssertEqual(normalized("1:30\u{202f}PM"), "1:30 pm")
        XCTAssertNotEqual(normalized("Start date"), normalized("End date"))
    }

    func testMeetingValidation() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertThrowsError(try validateMeeting(topic: " \n", start: now.addingTimeInterval(600), now: now))
        XCTAssertThrowsError(try validateMeeting(topic: "Test", start: now.addingTimeInterval(59), now: now))
        XCTAssertThrowsError(try validateMeeting(topic: "Test", start: now.addingTimeInterval(-600), now: now))
        XCTAssertNoThrow(try validateMeeting(topic: "Test", start: now.addingTimeInterval(60), now: now))
    }

    func testFormattingUsesLocalTimeZone() {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2030, month: 3, day: 15, hour: 14, minute: 30))!
        let config = Configuration()
        XCTAssertEqual(config.formatted(date, format: "MM/dd/yyyy"), "03/15/2030")
        XCTAssertEqual(config.formatted(date, format: "h:mm a"), "2:30 PM")
        XCTAssertEqual(config.formatted(date, format: "dd/MM/yyyy"), "15/03/2030")
        XCTAssertEqual(config.formatted(date, format: "HH:mm"), "14:30")
        XCTAssertEqual(config.dateFormat, DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .current))
    }
}
