import XCTest
@testable import Shirox

final class NotificationSentenceTests: XCTestCase {

    func testUsesTheUserNameAsSubject() {
        let s = NotificationSentence(userName: "xibrox", context: " liked your activity",
                                     fallbackAction: "interacted with your activity")
        XCTAssertEqual(s.subject, "xibrox")
        XCTAssertEqual(s.action, "liked your activity")
        XCTAssertNil(s.object)
    }

    func testContextWithoutLeadingSpaceReadsTheSame() {
        let padded = NotificationSentence(userName: "xibrox", context: " liked your activity",
                                          fallbackAction: "x")
        let bare = NotificationSentence(userName: "xibrox", context: "liked your activity",
                                        fallbackAction: "x")
        XCTAssertEqual(padded, bare)
    }

    func testFallsBackToSomeoneWhenTheUserIsMissing() {
        let missing = NotificationSentence(userName: nil, context: " followed you",
                                           fallbackAction: "x")
        let blank = NotificationSentence(userName: "   ", context: " followed you",
                                         fallbackAction: "x")
        XCTAssertEqual(missing.subject, "Someone")
        XCTAssertEqual(blank.subject, "Someone")
    }

    func testFallsBackToTheSuppliedActionWhenContextIsMissing() {
        let s = NotificationSentence(userName: "xibrox", context: nil,
                                     fallbackAction: "interacted with your activity")
        XCTAssertEqual(s.action, "interacted with your activity")
    }

    func testForumSentenceCarriesTheThreadTitle() {
        let s = NotificationSentence(userName: "xibrox", context: " liked your comment in ",
                                     fallbackAction: "liked your post in",
                                     objectTitle: "Best anime of the season")
        XCTAssertEqual(s.subject, "xibrox")
        XCTAssertEqual(s.action, "liked your comment in")
        XCTAssertEqual(s.object, "Best anime of the season")
    }

    func testMissingThreadTitleLeavesNoDanglingObject() {
        let s = NotificationSentence(userName: "xibrox", context: " liked your comment in ",
                                     fallbackAction: "liked your post in", objectTitle: "  ")
        XCTAssertNil(s.object)
    }
}
