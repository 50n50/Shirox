import Foundation

/// Rewrites HLS manifests so every URL a Chromecast will fetch points back at
/// ``CastProxyServer`` — pure string work, no app dependencies, fully unit-testable.
///
/// Background: the Chromecast is a separate LAN device with no access to the stream's auth
/// headers (Referer/User-Agent/Cookie). The proxy injects them, but only for URLs that
/// actually route through it. HLS hides URLs in two places and the manifest is only fully
/// authenticated if both are rewritten:
///
///   * bare URI lines — media segments and, in a master playlist, variant playlists;
///   * `URI="…"` attributes — `#EXT-X-KEY` (AES-128 key), `#EXT-X-MAP` (fMP4 init segment),
///     `#EXT-X-MEDIA` (alternate audio/subtitle renditions) and `#EXT-X-I-FRAME-STREAM-INF`.
///
/// Missing the second group is invisible in a master playlist and fatal in a media one: the
/// key or init segment 403s and the receiver stalls on a manifest that otherwise looks fine.
enum CastManifestRewriter {

    /// Tags whose `URI="…"` attribute addresses a resource the receiver must fetch.
    private static let uriAttributeTags = [
        "#EXT-X-KEY", "#EXT-X-SESSION-KEY", "#EXT-X-MAP",
        "#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT"
    ]

    /// Whether a response should be treated as a manifest and rewritten. Getting this wrong
    /// in the other direction matters more than a missed rewrite: running a binary `.ts`
    /// segment through the line rewriter would corrupt the stream, so detection is by
    /// media type or the `.m3u8` extension only — never by sniffing content.
    static func isManifest(mime: String, url: URL) -> Bool {
        let m = mime.lowercased()
        if m.contains("mpegurl") { return true }   // covers x-mpegURL and vnd.apple.mpegurl
        return url.pathExtension.lowercased() == "m3u8"
    }

    /// Resolves a manifest URI against the manifest's own URL.
    ///
    /// Uses `URL(string:relativeTo:)` rather than `appendingPathComponent`: the latter
    /// percent-escapes a `?` into the path (turning `seg.ts?token=a` into a 404) and cannot
    /// walk a `../` prefix, both of which are ordinary in CDN manifests.
    static func resolve(_ uri: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // `relativeTo:` resolves against the *directory* of the base for a bare name, which
        // is what HLS specifies. `.absoluteURL` collapses any `../` before we hand it on.
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    /// Rewrites every fetchable URL in `manifest` through `proxy`.
    ///
    /// - Parameter proxy: maps an origin URL to its proxied form; a `nil` return leaves that
    ///   URL untouched rather than dropping the line.
    static func rewrite(_ manifest: String, baseURL: URL, proxy: (URL) -> URL?) -> String {
        manifest.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if trimmed.hasPrefix("#") { return rewriteTag(line, baseURL: baseURL, proxy: proxy) }
            guard let resolved = resolve(trimmed, relativeTo: baseURL),
                  let proxied = proxy(resolved) else { return line }
            return proxied.absoluteString
        }.joined(separator: "\n")
    }

    /// Rewrites the `URI="…"` attribute of a tag, leaving every other byte of the line —
    /// including attributes that merely *contain* the substring `URI` — exactly as it was.
    private static func rewriteTag(_ line: String, baseURL: URL, proxy: (URL) -> URL?) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard uriAttributeTags.contains(where: { trimmed.hasPrefix($0 + ":") }) else { return line }

        // Match `URI="…"` at the start of an attribute (line start after the colon, or just
        // after a comma) so a value like `NAME="AUDIO URI"` can't be mistaken for one.
        guard let range = line.range(of: "(?<=[:,])URI=\"[^\"]*\"", options: .regularExpression) else {
            return line   // e.g. #EXT-X-KEY:METHOD=NONE, which carries no URI
        }
        let attribute = String(line[range])
        let value = String(attribute.dropFirst("URI=\"".count).dropLast())
        guard let resolved = resolve(value, relativeTo: baseURL),
              let proxied = proxy(resolved) else { return line }
        return line.replacingCharacters(in: range, with: "URI=\"\(proxied.absoluteString)\"")
    }
}
