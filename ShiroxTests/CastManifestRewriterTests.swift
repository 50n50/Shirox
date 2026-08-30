import XCTest
@testable import Shirox

/// Tests for rewriting HLS manifests so a Chromecast fetches every part through
/// `CastProxyServer` (which is what injects the stream's auth headers).
///
/// The reported bug: casting stalls part-way through a movie and only an app restart
/// clears it. One cause lives here — the old rewriter only touched bare URI *lines*, so
/// every URL that HLS carries inside a tag attribute (`#EXT-X-KEY` decryption keys,
/// `#EXT-X-MAP` fMP4 init segments, `#EXT-X-MEDIA` alternate audio) went to the origin
/// unproxied and therefore unauthenticated. It also joined relative URIs with
/// `appendingPathComponent`, which percent-escapes a `?` into the path and cannot walk
/// `../`, corrupting those URLs outright.
final class CastManifestRewriterTests: XCTestCase {

    private let base = URL(string: "https://cdn.example/video/hls/index.m3u8")!

    /// Stand-in for CastProxyServer.proxyURL(for:) — same shape, fixed host.
    private func proxy(_ url: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "192.168.1.50"
        c.port = 8766
        c.path = "/proxy"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return c.url
    }

    private func rewrite(_ manifest: String) -> String {
        CastManifestRewriter.rewrite(manifest, baseURL: base, proxy: proxy)
    }

    /// Pulls the `url` query item back out of a proxied URL, so assertions read as
    /// "which origin URL did this line end up pointing at".
    private func unproxied(_ line: String) -> String? {
        guard let comps = URLComponents(string: line.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard comps.path == "/proxy" else { return nil }
        return comps.queryItems?.first(where: { $0.name == "url" })?.value
    }

    // MARK: - Resolution (the `appendingPathComponent` bugs)

    func testRelativeSegmentResolvesAgainstManifestDirectory() {
        XCTAssertEqual(CastManifestRewriter.resolve("seg0.ts", relativeTo: base)?.absoluteString,
                       "https://cdn.example/video/hls/seg0.ts")
    }

    /// THE BUG: `appendingPathComponent` escapes the `?` into the path, producing
    /// `.../seg0.ts%3Ftoken=abc` — a 404 on every segment.
    func testRelativeSegmentKeepsQueryString() {
        XCTAssertEqual(CastManifestRewriter.resolve("seg0.ts?token=abc", relativeTo: base)?.absoluteString,
                       "https://cdn.example/video/hls/seg0.ts?token=abc")
    }

    /// THE BUG: `appendingPathComponent("../a.ts")` yields `.../hls/../a.ts` literally.
    func testParentRelativeSegmentWalksUp() {
        XCTAssertEqual(CastManifestRewriter.resolve("../seg0.ts", relativeTo: base)?.absoluteString,
                       "https://cdn.example/video/seg0.ts")
    }

    func testHostAbsoluteSegmentResolvesAgainstRoot() {
        XCTAssertEqual(CastManifestRewriter.resolve("/other/seg0.ts", relativeTo: base)?.absoluteString,
                       "https://cdn.example/other/seg0.ts")
    }

    func testAbsoluteSegmentIsUsedAsIs() {
        XCTAssertEqual(CastManifestRewriter.resolve("https://other.example/seg0.ts", relativeTo: base)?.absoluteString,
                       "https://other.example/seg0.ts")
    }

    // MARK: - Line rewriting (the path that already worked — must stay working)

    func testBareSegmentLinesAreProxied() {
        let out = rewrite("""
        #EXTM3U
        #EXTINF:9.009,
        seg0.ts
        #EXTINF:9.009,
        https://cdn.example/video/hls/seg1.ts
        #EXT-X-ENDLIST
        """)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(unproxied(lines[2]), "https://cdn.example/video/hls/seg0.ts")
        XCTAssertEqual(unproxied(lines[4]), "https://cdn.example/video/hls/seg1.ts")
    }

    func testNonURITagsAndBlankLinesAreUntouched() {
        let out = rewrite("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10

        #EXT-X-ENDLIST
        """)
        XCTAssertEqual(out, """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10

        #EXT-X-ENDLIST
        """)
    }

    // MARK: - THE BUG: URLs hidden in tag attributes

    /// An AES-128 key fetched without the stream's auth headers comes back 403, so the
    /// Chromecast can decrypt nothing and playback dies mid-stream.
    func testEncryptionKeyURIIsProxied() {
        let out = rewrite("""
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0123
        #EXTINF:9.009,
        seg0.ts
        """)
        let keyLine = out.components(separatedBy: "\n")[1]
        XCTAssertTrue(keyLine.hasPrefix("#EXT-X-KEY:METHOD=AES-128,URI=\""), "tag shape must survive: \(keyLine)")
        XCTAssertTrue(keyLine.hasSuffix(",IV=0x0123"), "trailing attributes must survive: \(keyLine)")
        let quoted = keyLine.components(separatedBy: "\"")[1]
        XCTAssertEqual(unproxied(quoted), "https://cdn.example/video/hls/key.bin")
    }

    /// The fMP4 init segment. Unproxied, the Chromecast gets no moov box and shows a
    /// black screen despite a healthy-looking manifest.
    func testMapInitSegmentURIIsProxied() {
        let out = rewrite("#EXT-X-MAP:URI=\"init.mp4\"")
        let quoted = out.components(separatedBy: "\"")[1]
        XCTAssertEqual(unproxied(quoted), "https://cdn.example/video/hls/init.mp4")
    }

    /// Alternate audio renditions live in their own playlists referenced by attribute.
    func testMediaRenditionURIIsProxied() {
        let out = rewrite("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a1\",NAME=\"English\",URI=\"audio/en.m3u8\"")
        let quoted = out.components(separatedBy: "\"").first(where: { $0.contains("/proxy") })
        XCTAssertNotNil(quoted, "audio rendition URI was left unproxied: \(out)")
        XCTAssertEqual(unproxied(quoted!), "https://cdn.example/video/hls/audio/en.m3u8")
        XCTAssertTrue(out.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a1\",NAME=\"English\",URI=\""),
                      "preceding attributes must survive verbatim: \(out)")
    }

    func testIFrameStreamURIIsProxied() {
        let out = rewrite("#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI=\"iframe.m3u8\"")
        let quoted = out.components(separatedBy: "\"")[1]
        XCTAssertEqual(unproxied(quoted), "https://cdn.example/video/hls/iframe.m3u8")
    }

    /// `METHOD=NONE` carries no URI — rewriting must not invent one.
    func testKeyMethodNoneIsUntouched() {
        XCTAssertEqual(rewrite("#EXT-X-KEY:METHOD=NONE"), "#EXT-X-KEY:METHOD=NONE")
    }

    // MARK: - Master playlists

    func testMasterPlaylistVariantsAreProxied() {
        let out = rewrite("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        720p/index.m3u8
        """)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(unproxied(lines[2]), "https://cdn.example/video/hls/360p/index.m3u8")
        XCTAssertEqual(unproxied(lines[4]), "https://cdn.example/video/hls/720p/index.m3u8")
    }

    // MARK: - Manifest detection

    func testManifestDetectedByMimeAndExtension() {
        XCTAssertTrue(CastManifestRewriter.isManifest(mime: "application/x-mpegURL", url: base))
        XCTAssertTrue(CastManifestRewriter.isManifest(mime: "application/vnd.apple.mpegurl", url: base))
        XCTAssertTrue(CastManifestRewriter.isManifest(mime: "text/plain", url: base), "extension alone is enough")
        XCTAssertFalse(CastManifestRewriter.isManifest(mime: "video/mp2t",
                                                       url: URL(string: "https://cdn.example/v/seg0.ts")!))
    }

    /// A `.ts` segment must never be run through the rewriter — binary data reinterpreted
    /// as UTF-8 lines would corrupt the stream.
    func testBinarySegmentIsNotAManifest() {
        XCTAssertFalse(CastManifestRewriter.isManifest(mime: "video/mp4",
                                                       url: URL(string: "https://cdn.example/v/movie.mp4")!))
    }
}
