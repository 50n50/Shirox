import XCTest
@testable import Shirox

/// Tests for parsing the HTTP request head `CastProxyServer` receives from the Chromecast.
///
/// The reported bug: casting dies part-way through a movie. Two causes live here.
///
/// 1. The old code called `receive` once and assumed the whole request had arrived in that
///    one chunk. A request split across TCP segments — routine once cookies/headers grow —
///    parsed as garbage and the connection was dropped, stalling the stream.
/// 2. It never looked at `Range:` at all. A Chromecast range-requests an MP4 to seek and to
///    resume after a rebuffer; answering every one of those with the whole file from byte 0
///    is why a seek re-starts the movie and why memory balloons until the app is jetsammed.
final class HTTPRequestHeadTests: XCTestCase {

    private func head(_ raw: String) -> HTTPRequestHead? {
        HTTPRequestHead.parse(Data(raw.utf8))
    }

    // MARK: - Framing (THE BUG: single-read parsing)

    /// A head that hasn't reached the blank-line terminator yet is *incomplete*, not
    /// invalid — the caller must keep reading rather than drop the connection.
    func testIncompleteHeadReturnsNil() {
        XCTAssertNil(head("GET /proxy?url=https://a.example/v.m3u8 HTTP/1.1\r\nHost: 192.168.1.50\r\n"))
        XCTAssertNil(head("GET /pro"))
        XCTAssertNil(head(""))
    }

    func testCompleteHeadParses() {
        let h = head("GET /proxy?url=x HTTP/1.1\r\nHost: 192.168.1.50\r\n\r\n")
        XCTAssertEqual(h?.method, "GET")
        XCTAssertEqual(h?.path, "/proxy?url=x")
    }

    /// The body (or a pipelined next request) may arrive in the same read; the head parse
    /// must stop at the terminator and not choke on the trailing bytes.
    func testTrailingBytesAfterTerminatorAreIgnored() {
        let h = head("GET /proxy?url=x HTTP/1.1\r\nHost: h\r\n\r\nGET /proxy?url=y HTTP/1.1\r\n\r\n")
        XCTAssertEqual(h?.path, "/proxy?url=x")
    }

    // MARK: - Headers

    func testHeaderLookupIsCaseInsensitive() {
        let h = head("GET /p HTTP/1.1\r\nRaNgE: bytes=0-99\r\n\r\n")
        XCTAssertEqual(h?.value(for: "range"), "bytes=0-99")
        XCTAssertEqual(h?.value(for: "Range"), "bytes=0-99")
        XCTAssertNil(h?.value(for: "if-none-match"))
    }

    func testHeaderValueWhitespaceIsTrimmed() {
        XCTAssertEqual(head("GET /p HTTP/1.1\r\nRange:   bytes=5-  \r\n\r\n")?.value(for: "range"), "bytes=5-")
    }

    /// A value containing a colon (any absolute URL) must not be split at the wrong one.
    func testHeaderValueMayContainColons() {
        XCTAssertEqual(head("GET /p HTTP/1.1\r\nReferer: https://a.example:8443/x\r\n\r\n")?.value(for: "referer"),
                       "https://a.example:8443/x")
    }

    // MARK: - Methods

    /// A Chromecast probes with HEAD before it commits to streaming. The old server had no
    /// concept of HEAD and answered it with a full body, which some receivers reject.
    func testHeadMethodIsRecognised() {
        XCTAssertEqual(head("HEAD /proxy?url=x HTTP/1.1\r\n\r\n")?.method, "HEAD")
        XCTAssertEqual(head("HEAD /proxy?url=x HTTP/1.1\r\n\r\n")?.wantsBody, false)
        XCTAssertEqual(head("GET /proxy?url=x HTTP/1.1\r\n\r\n")?.wantsBody, true)
    }

    func testMalformedRequestLineIsRejected() {
        XCTAssertNil(head("GARBAGE\r\n\r\n"))
        XCTAssertNil(head("GET\r\n\r\n"))
    }

    // MARK: - Target extraction

    func testTargetURLIsExtractedFromQuery() {
        let raw = "https://cdn.example/v/index.m3u8?token=a%26b"
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let h = head("GET /proxy?url=\(encoded) HTTP/1.1\r\n\r\n")
        XCTAssertEqual(h?.targetURL?.absoluteString, raw)
    }

    func testTargetURLIsNilForUnknownPath() {
        XCTAssertNil(head("GET /favicon.ico HTTP/1.1\r\n\r\n")?.targetURL)
        XCTAssertNil(head("GET /proxy HTTP/1.1\r\n\r\n")?.targetURL)
    }

    /// Only http(s) may be proxied — the query is attacker-influencable in principle and
    /// `file://` would turn the LAN listener into a device file reader.
    func testNonHTTPTargetIsRejected() {
        let encoded = "file:///etc/passwd".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertNil(head("GET /proxy?url=\(encoded) HTTP/1.1\r\n\r\n")?.targetURL)
    }

    // MARK: - Range passthrough (THE BUG: seeking restarts the movie)

    func testRangeHeaderIsExposedForForwarding() {
        XCTAssertEqual(head("GET /p HTTP/1.1\r\nRange: bytes=1000-\r\n\r\n")?.value(for: "range"), "bytes=1000-")
        XCTAssertNil(head("GET /p HTTP/1.1\r\n\r\n")?.value(for: "range"))
    }
}
