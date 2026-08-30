import Foundation

/// A parsed HTTP/1.1 request head, as received by ``CastProxyServer`` from a Chromecast.
/// Pure value type with no networking, so the framing and header rules are unit-testable.
///
/// Background: the previous server read the socket once and assumed the entire request had
/// landed in that single chunk, then looked at nothing but the request line. That loses two
/// things that matter for a long cast:
///
///   * **Framing.** A head split across TCP segments parsed as garbage and the connection
///     was dropped — a stalled stream with no error anywhere.
///   * **`Range:`.** A Chromecast range-requests progressive media to seek and to resume
///     after a rebuffer. Ignoring the header and answering with the whole file from byte 0
///     makes seeking restart the movie and makes memory grow without bound.
struct HTTPRequestHead: Equatable {
    let method: String
    /// Request target as sent, e.g. `/proxy?url=https%3A%2F%2F…`.
    let path: String
    /// Header names lowercased; values trimmed. Duplicates keep the first occurrence.
    let headers: [String: String]

    /// The `\r\n\r\n` that ends a head. Also accepts bare `\n\n`, which some clients emit.
    private static let terminators = ["\r\n\r\n", "\n\n"]

    /// Parses a complete request head.
    ///
    /// - Returns: `nil` if the head is malformed **or** simply hasn't finished arriving.
    ///   The caller must keep reading on `nil` rather than close, since "incomplete" is the
    ///   overwhelmingly common case on a first read.
    static func parse(_ raw: Data) -> HTTPRequestHead? {
        guard let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1)
        else { return nil }

        // Stop at the terminator so a pipelined next request or a body can't leak into the
        // header map.
        var headText: String?
        for terminator in terminators {
            if let end = text.range(of: terminator) {
                let candidate = String(text[text.startIndex..<end.lowerBound])
                // Prefer whichever terminator appears first.
                if headText == nil || candidate.count < headText!.count { headText = candidate }
            }
        }
        guard let head = headText else { return nil }

        var lines = head.components(separatedBy: .newlines)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            // Split on the FIRST colon only — values routinely contain colons (any URL does).
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { continue }
            headers[name] = value
        }

        return HTTPRequestHead(method: requestLine[0].uppercased(), path: requestLine[1], headers: headers)
    }

    /// Case-insensitive header lookup.
    func value(for name: String) -> String? { headers[name.lowercased()] }

    /// Whether a response to this request carries a body. `HEAD` gets headers only — a
    /// Chromecast probes with it before committing to a stream, and some receivers reject
    /// the response outright if a body comes back.
    var wantsBody: Bool { method != "HEAD" }

    /// The origin URL this request wants proxied, from the `url` query item.
    ///
    /// Restricted to http(s): the listener is bound to every interface on the LAN, so
    /// honouring a `file://` target would turn it into a device file reader for anything
    /// else on the network.
    var targetURL: URL? {
        guard let components = URLComponents(string: "http://localhost" + path),
              components.path == "/proxy",
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
