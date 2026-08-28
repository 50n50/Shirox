import XCTest
@testable import Shirox

/// Tests for the log redaction that keeps credentials out of `logs.txt`.
///
/// The bugs it exists for: the AniList OAuth flow is an implicit grant, so its callback URL
/// carries `#access_token=…`, and it was logged verbatim. Jellyfin puts a long-lived `api_key`
/// in every stream URL, and those were logged verbatim too. Both land in logs.txt, which users
/// export from Settings → App Logs and paste into bug reports.
final class LoggerRedactionTests: XCTestCase {

    /// THE LEAK (AniList): the implicit-grant token lives in the fragment.
    func testFragmentIsRedacted() throws {
        let url = try XCTUnwrap(URL(string: "shirox://auth#access_token=SECRET123&token_type=Bearer"))
        let out = Logger.redact(url)
        XCTAssertFalse(out.contains("SECRET123"), "access token leaked: \(out)")
        XCTAssertTrue(out.contains(Logger.redactionMarker), "expected redaction marker in: \(out)")
    }

    /// THE LEAK (Jellyfin): api_key rides in the query of every stream URL.
    func testSensitiveQueryValuesAreRedacted() throws {
        let url = try XCTUnwrap(URL(string: "https://jf.example.com/Videos/abc/stream.m3u8?api_key=SECRET456&static=true"))
        let out = Logger.redact(url)
        XCTAssertFalse(out.contains("SECRET456"), "api key leaked: \(out)")
        XCTAssertTrue(out.contains("api_key=\(Logger.redactionMarker)"), "expected redacted api_key in: \(out)")
    }

    /// Redaction must not destroy the diagnostic value of the log line.
    func testNonSensitivePartsArePreserved() throws {
        let url = try XCTUnwrap(URL(string: "https://jf.example.com/Videos/abc/stream.m3u8?api_key=SECRET&static=true"))
        let out = Logger.redact(url)
        XCTAssertTrue(out.contains("jf.example.com"))
        XCTAssertTrue(out.contains("/Videos/abc/stream.m3u8"))
        XCTAssertTrue(out.contains("static=true"))
    }

    /// Key matching is case-insensitive — providers vary on casing.
    func testSensitiveKeyMatchIsCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "https://x.example.com/a?API_KEY=SECRET&Token=SECRET2"))
        let out = Logger.redact(url)
        XCTAssertFalse(out.contains("SECRET"), "leaked: \(out)")
    }

    /// A plain URL with nothing sensitive should come back intact.
    func testCleanURLIsUnchanged() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/video/ep1.m3u8"))
        XCTAssertEqual(Logger.redact(url), "https://cdn.example.com/video/ep1.m3u8")
    }

    /// A local file URL has no credentials and must stay readable for debugging.
    func testFileURLIsReadable() {
        let url = URL(fileURLWithPath: "/var/mobile/Containers/Downloads/ep1.mp4")
        XCTAssertTrue(Logger.redact(url).contains("ep1.mp4"))
    }
}
