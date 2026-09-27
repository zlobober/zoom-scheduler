import XCTest
@testable import ZoomScheduler

final class InvitationTests: XCTestCase {
    let body = "Topic: Example\nJoin Zoom Meeting\nhttps://example.zoom.us/j/12345"

    func testCompleteTopicMatchedInvitation() throws {
        XCTAssertEqual(try matchingInvitation(in: [body, body], topic: "Example"), body)
        XCTAssertNil(try matchingInvitation(in: [body], topic: "Other"))
        XCTAssertNil(try matchingInvitation(in: [body], topic: ""))
        XCTAssertNil(try matchingInvitation(in: ["Example https://zoom.us.evil.example/j/12345"], topic: "Example"))
    }

    func testNestedAndConflictingTexts() throws {
        let longer = body + "\nAdditional details"
        XCTAssertEqual(try matchingInvitation(in: [body, longer], topic: "Example"), longer)
        XCTAssertThrowsError(try matchingInvitation(in: [body, body.replacingOccurrences(of: "12345", with: "67890")], topic: "Example"))
    }
}
