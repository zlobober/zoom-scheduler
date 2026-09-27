import Foundation

// Run without XCTest/full Xcode: see scripts/test.sh.
@main
struct SmokeTests {
    static func main() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(Configuration.sample.utf8))
        precondition(config.zoomBundleID == "us.zoom.xos")
        precondition(config.submitLabels.contains("Save, opens calendar invite window"))
        var custom = config
        custom.submit = ["Custom submit"]
        precondition(custom.submitLabels == ["Custom submit"])
        precondition(normalized(" Start Date: \n") == "start date")
        precondition(normalized("1:30\u{202f}PM") == "1:30 pm")
        precondition(normalized("Start date") != normalized("End date"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (topic, offset) in [(" \n", 600.0), ("Test", 59.0), ("Test", -600.0)] {
            var rejected = false
            do { try validateMeeting(topic: topic, start: now.addingTimeInterval(offset), now: now) }
            catch { rejected = true }
            precondition(rejected)
        }
        try validateMeeting(topic: "Test", start: now.addingTimeInterval(60), now: now)
        let date = Calendar.current.date(from: DateComponents(year: 2030, month: 3, day: 15, hour: 14, minute: 30))!
        precondition(config.formatted(date, format: "MM/dd/yyyy") == "03/15/2030")
        precondition(config.formatted(date, format: "h:mm a") == "2:30 PM")
        precondition(config.formatted(date, format: "dd/MM/yyyy") == "15/03/2030")
        precondition(config.formatted(date, format: "HH:mm") == "14:30")
        precondition(config.dateFormat == DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .current))
        let legacy = try JSONDecoder().decode(Configuration.self, from: Data(Configuration.legacySample.utf8))
        precondition(legacy.dateFormat == "MM/dd/yyyy" && legacy.timeFormat == "h:mm a")
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Example\\, test
        UID:example-id
        DTSTART;TZID=Europe/Brussels:20300315T143000
        DESCRIPTION:Join\\nhttps://example.zoom.us/j/12
         345\\nEnd
        BEGIN:VALARM
        DESCRIPTION:Reminder
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """
        let parsed = CalendarInvitation.parse(ics)!
        precondition(parsed.topic == "Example, test")
        precondition(parsed.text == "Join\nhttps://example.zoom.us/j/12345\nEnd")
        precondition(CalendarInvitation.parse(ics.replacingOccurrences(of: "https://example.zoom.us", with: "https://example.com")) == nil)
        precondition(CalendarInvitation.parse(ics + "\n" + ics) == nil)
        let utc = CalendarInvitation.parse(ics.replacingOccurrences(of: "DTSTART;TZID=Europe/Brussels:20300315T143000", with: "DTSTART:20300315T133000Z"))!
        precondition(utc.start == parsed.start)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ics.write(to: folder.appendingPathComponent("one.ics"), atomically: true, encoding: .utf8)
        let found = try CalendarInvitation.find(topic: "Example, test", start: parsed.start, directory: folder)
        precondition(found?.uid == "example-id")
        let wrongDate = try CalendarInvitation.find(topic: "Example, test", start: parsed.start.addingTimeInterval(3600), directory: folder)
        precondition(wrongDate == nil)
        try ics.replacingOccurrences(of: "UID:example-id", with: "UID:other-id").write(to: folder.appendingPathComponent("two.ics"), atomically: true, encoding: .utf8)
        var ambiguous = false
        do { _ = try CalendarInvitation.find(topic: "Example, test", directory: folder) }
        catch { ambiguous = true }
        precondition(ambiguous)
        let cli = try CLIOptions(arguments: ["--cli", "--topic", "Example", "--at", "2030-03-15T14:30:00+01:00"])
        precondition(cli.topic == "Example" && cli.start == parsed.start)
        let retrieval = try CLIOptions(arguments: ["--cli", "--invitation-only", "--topic", "Example"])
        precondition(retrieval.invitationOnly && retrieval.start == nil)
        let timed = try CLIOptions(arguments: ["--topic", "Two hours", "--at", "2030-03-15T14:30:00+01:00", "--duration-minutes", "120"])
        precondition(timed.durationMinutes == 120)
        for arguments in [
            ["--cli"],
            ["--topic", "Example"],
            ["--topic", "Example", "--at", "2030-03-15T14:30:00"],
            ["--topic", "Example", "--at", "invalid"],
            ["--topic"],
            ["--unknown"],
            ["--duration-minutes", "0"],
            ["--duration-minutes", "-1"],
            ["--duration-minutes", "abc"],
            ["--duration-minutes", "10081"],
            ["--inspect", "--invitation-only"],
            ["--topic", "A", "--topic", "B"]
        ] {
            var rejected = false
            do { _ = try CLIOptions(arguments: arguments) } catch { rejected = true }
            precondition(rejected, "Should reject \(arguments)")
        }
        print("Passed: configuration, validation, formatting, ICS parsing/matching, and CLI argument validation.")
    }
}
