import Combine

#if os(iOS)
import Foundation
import Network
import Darwin
import UIKit

/// Local HTTP proxy bound to every interface (0.0.0.0) so a Chromecast — a separate LAN
/// device — can reach it, and so an AirPlay receiver can too. It injects the stream's auth
/// headers into every request and rewrites HLS manifests (see ``CastManifestRewriter``) so
/// segments, keys, init segments and alternate renditions all route back through here.
///
/// Design notes, each one a bug that used to end a cast mid-movie:
///
///   * **Streaming, not buffering.** Responses are pumped through in chunks. The old code
///     did `URLSession.data(for:)` first, which meant a direct MP4 was pulled entirely into
///     RAM before a single byte reached the TV — a multi-GB allocation the OS jetsams.
///   * **Range passthrough.** `Range:` is forwarded upstream and the upstream's `206` /
///     `Content-Range` come back verbatim. Without it a Chromecast's seek (and its
///     post-rebuffer resume) was answered with the whole file from byte 0.
///   * **Connection lifecycle.** Connections are tracked, idle-timed-out and closed. They
///     used to be left open forever, so a feature-length movie's worth of segment requests
///     slowly exhausted the socket budget.
///   * **Self-healing.** A failed listener re-arms instead of going quietly dead, and a
///     network change re-publishes the LAN address so a Wi-Fi hiccup doesn't strand the
///     receiver on an IP the phone no longer owns.
///   * **Not an open relay.** Every proxied URL is signed with a per-run token, so other
///     devices on the network can't use the phone as a relay — or harvest the auth headers
///     it attaches.
///
/// All mutable state is confined to `stateQueue`; the old code raced it across threads.
final class CastProxyServer: @unchecked Sendable {
    static let shared = CastProxyServer()

    // MARK: - Configuration

    private let port: NWEndpoint.Port = 8766
    /// How long a kept-alive connection may sit idle before it is reclaimed.
    private let idleTimeout: TimeInterval = 60
    /// Backoff before re-arming a listener that failed.
    private let restartDelay: TimeInterval = 1.0

    // MARK: - State (stateQueue only)

    private let stateQueue = DispatchQueue(label: "com.shirox.castproxy.state")
    private let connectionQueue = DispatchQueue(label: "com.shirox.castproxy.conn", attributes: .concurrent)

    private var listener: NWListener?
    private var proxyHeaders: [String: String] = [:]
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pathMonitor: NWPathMonitor?
    private var cachedIP: String?
    /// Who currently needs the proxy up. Reason-counted because Chromecast and AirPlay
    /// both use it: whichever finishes first must not pull the listener out from under the
    /// other. Also distinguishes a crash (re-arm) from a deliberate stop (stay down).
    private var reasons: Set<String> = []
    private var wanted: Bool { !reasons.isEmpty }
    private var running = false
    /// Signs proxy URLs so only URLs this app minted are honoured.
    private var token = CastProxyServer.makeToken()

    /// Called on the main queue when the device's LAN address changes while casting. Any
    /// URL already handed to the receiver now points at an address the phone has given up,
    /// so the caller must re-issue the media.
    var onLocalAddressChanged: (() -> Void)?

    var isRunning: Bool { stateQueue.sync { running } }

    /// One shared session so TLS connections to the CDN are pooled across segments.
    /// Re-handshaking per segment visibly hurts HLS playback.
    private lazy var upstream: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        let queue = OperationQueue()
        // Concurrent so one exchange blocking for backpressure can't stall the others.
        queue.maxConcurrentOperationCount = 6
        return URLSession(configuration: config, delegate: exchanges, delegateQueue: queue)
    }()

    private let exchanges = ProxyExchangeRegistry()

    private init() {}

    // MARK: - Lifecycle

    /// Starts the server (if not already running) and suspends until the listener is ready.
    /// - Parameter reason: who needs it up; pass the same value to ``stop(reason:)``.
    func startAndWait(headers: [String: String], reason: String = "cast") async {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                self.proxyHeaders = headers
                self.reasons.insert(reason)
                if self.running {
                    continuation.resume()
                    return
                }
                self.readyContinuations.append(continuation)
                if self.listener == nil { self.startListenerLocked() }
            }
        }
    }

    func start(headers: [String: String], reason: String = "cast") {
        stateQueue.async {
            self.proxyHeaders = headers
            self.reasons.insert(reason)
            guard !self.running, self.listener == nil else { return }
            self.startListenerLocked()
        }
    }

    /// Releases one reason. The listener only comes down once nothing needs it.
    func stop(reason: String = "cast") {
        stateQueue.async {
            self.reasons.remove(reason)
            guard self.reasons.isEmpty else { return }
            self.teardownLocked()
            // A new token per run invalidates every URL from the previous cast, so a stale
            // receiver still replaying an old URL can't keep pulling through the proxy.
            self.token = CastProxyServer.makeToken()
            Logger.shared.log("[CastProxy] Stopped", type: "Stream")
        }
    }

    private func teardownLocked() {
        listener?.cancel()
        listener = nil
        running = false
        pathMonitor?.cancel()
        pathMonitor = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        endBackgroundTaskLocked()
        resumeWaitersLocked()
    }

    private func resumeWaitersLocked() {
        let waiting = readyContinuations
        readyContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func startListenerLocked() {
        beginBackgroundTaskLocked()
        startPathMonitorLocked()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.stateQueue.async {
                    switch state {
                    case .ready:
                        self.running = true
                        self.cachedIP = Self.currentLocalIP()
                        Logger.shared.log("[CastProxy] Ready on \(self.cachedIP ?? "?"):\(self.port.rawValue)",
                                          type: "Stream")
                        self.resumeWaitersLocked()
                    case .failed(let error), .waiting(let error):
                        Logger.shared.log("[CastProxy] Listener \(state): \(error)", type: "Error")
                        // THE BUG: this used to null the listener and give up, so every
                        // later segment request hit a closed port and the TV stalled for
                        // good. Re-arm instead, as long as a cast still wants us up.
                        self.scheduleRestartLocked()
                    case .cancelled:
                        self.running = false
                    default:
                        break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: stateQueue)
            listener = l
        } catch {
            Logger.shared.log("[CastProxy] Start failed: \(error)", type: "Error")
            scheduleRestartLocked()
        }
    }

    private func scheduleRestartLocked() {
        listener?.cancel()
        listener = nil
        running = false
        guard wanted else {
            endBackgroundTaskLocked()
            resumeWaitersLocked()
            return
        }
        stateQueue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self, self.wanted, self.listener == nil else { return }
            Logger.shared.log("[CastProxy] Re-arming listener", type: "Stream")
            self.startListenerLocked()
        }
    }

    // MARK: - Network path

    /// Watches for the LAN address changing under a live cast (Wi-Fi drop/reconnect, a
    /// hotspot switch). Every URL already on the receiver names the old address, so the
    /// media has to be re-issued or the TV simply stops fetching.
    private func startPathMonitorLocked() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                let fresh = Self.currentLocalIP()
                guard self.running, let fresh, fresh != self.cachedIP else { return }
                Logger.shared.log("[CastProxy] LAN address changed \(self.cachedIP ?? "?") → \(fresh)",
                                  type: "Stream")
                self.cachedIP = fresh
                let notify = self.onLocalAddressChanged
                DispatchQueue.main.async { notify?() }
            }
        }
        monitor.start(queue: stateQueue)
        pathMonitor = monitor
    }

    // MARK: - Background task

    /// Requests background execution time so the proxy survives the screen locking. The
    /// app's `audio` background mode (held by ``BackgroundKeepAlive`` during a cast) is what
    /// provides indefinite runtime; this covers the gap before that takes effect.
    private func beginBackgroundTaskLocked() {
        // THE BUG: this used to overwrite a live identifier on every start, leaking the
        // previous assertion — iOS eventually stops granting them.
        guard backgroundTaskID == .invalid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let id = UIApplication.shared.beginBackgroundTask(withName: "CastProxyServer") { [weak self] in
                self?.endBackgroundTask()
            }
            self.stateQueue.async {
                if self.backgroundTaskID == .invalid && self.wanted {
                    self.backgroundTaskID = id
                } else {
                    DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
                }
            }
        }
    }

    private func endBackgroundTask() { stateQueue.async { self.endBackgroundTaskLocked() } }

    private func endBackgroundTaskLocked() {
        let id = backgroundTaskID
        guard id != .invalid else { return }
        backgroundTaskID = .invalid
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
    }

    // MARK: - URL minting

    /// Returns a proxied URL on the device's LAN address, signed with this run's token.
    func proxyURL(for url: URL) -> URL? {
        stateQueue.sync {
            // Cached: a manifest rewrite calls this once per line, and `getifaddrs` per
            // segment on a long playlist is real work for a constant answer.
            let host = cachedIP ?? Self.currentLocalIP()
            cachedIP = host
            guard let host, host != "127.0.0.1" else { return nil }
            var c = URLComponents()
            c.scheme = "http"
            c.host = host
            c.port = Int(port.rawValue)
            c.path = "/proxy"
            c.queryItems = [
                URLQueryItem(name: "url", value: url.absoluteString),
                URLQueryItem(name: "t", value: token)
            ]
            return c.url
        }
    }

    private static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func validate(path: String) -> Bool {
        guard let comps = URLComponents(string: "http://localhost" + path),
              let supplied = comps.queryItems?.first(where: { $0.name == "t" })?.value
        else { return false }
        return stateQueue.sync { supplied == token }
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        let connection = ProxyConnection(
            connection: nwConnection,
            queue: connectionQueue,
            idleTimeout: idleTimeout,
            server: self
        )
        stateQueue.async { self.connections[ObjectIdentifier(connection)] = connection }
        connection.start()
    }

    fileprivate func retire(_ connection: ProxyConnection) {
        stateQueue.async { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    fileprivate func currentHeaders() -> [String: String] { stateQueue.sync { proxyHeaders } }

    /// Serves one parsed request onto `connection`. Returns once the response is fully
    /// written, so the connection can decide whether to read another request.
    fileprivate func serve(_ head: HTTPRequestHead, on connection: ProxyConnection) async {
        guard validate(path: head.path), let target = head.targetURL else {
            connection.writeStatus(head.targetURL == nil ? 400 : 403)
            return
        }

        var request = URLRequest(url: target)
        request.httpMethod = head.wantsBody ? "GET" : "HEAD"
        currentHeaders().forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // A manifest gets rewritten, which changes its length — so a range over it would be
        // a lie. Manifests are small and never usefully ranged, so ask for the whole thing.
        let expectManifest = target.pathExtension.lowercased() == "m3u8"
        if !expectManifest, let range = head.value(for: "range") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        await exchanges.run(request: request,
                            on: upstream,
                            connection: connection,
                            wantsBody: head.wantsBody,
                            rewriteManifestFrom: target,
                            proxy: { [weak self] in self?.proxyURL(for: $0) })
    }

    // MARK: - Local IP

    /// The device's current Wi-Fi address (en0) — the one a Chromecast or Apple TV can
    /// reach. Returns nil rather than 127.0.0.1 so callers can refuse to mint a URL that
    /// could never work off-device.
    private static func currentLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let iface = current.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  (iface.ifa_flags & UInt32(IFF_UP)) != 0,
                  let name = iface.ifa_name.map({ String(cString: $0) }),
                  name == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(iface.ifa_addr,
                              socklen_t(iface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            address = String(cString: hostname)
            break
        }
        return address
    }
}

// MARK: - Connection

/// One accepted TCP connection: reads request heads (across as many packets as it takes),
/// hands each to the server, and reclaims itself when idle or broken.
fileprivate final class ProxyConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let idleTimeout: TimeInterval
    private weak var server: CastProxyServer?

    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var idleTimer: DispatchSourceTimer?

    /// A head larger than this is not a real request — refuse it rather than buffer forever.
    private static let maxHeadBytes = 64 * 1024

    init(connection: NWConnection, queue: DispatchQueue, idleTimeout: TimeInterval, server: CastProxyServer) {
        self.connection = connection
        self.queue = queue
        self.idleTimeout = idleTimeout
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armIdleTimer()
        receive()
    }

    // MARK: Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && data == nil) { self.close(); return }
            guard let data, !data.isEmpty else {
                if isComplete { self.close() } else { self.receive() }
                return
            }

            self.lock.lock()
            self.buffer.append(data)
            let pending = self.buffer
            self.lock.unlock()

            guard pending.count <= Self.maxHeadBytes else {
                self.writeStatus(431); self.close(); return
            }

            // THE BUG this loop fixes: the old server parsed whatever a single `receive`
            // happened to deliver. A head split across TCP segments — routine — parsed as
            // garbage and the connection was dropped, stalling the cast with no error.
            guard let head = HTTPRequestHead.parse(pending) else {
                self.receive()   // incomplete, keep reading
                return
            }

            self.lock.lock(); self.buffer.removeAll(keepingCapacity: true); self.lock.unlock()
            self.armIdleTimer()

            Task { [weak self] in
                guard let self, let server = self.server else { return }
                await server.serve(head, on: self)
                guard !self.isClosed else { return }
                self.armIdleTimer()
                self.receive()   // HTTP/1.1 keep-alive: the receiver reuses this socket
            }
        }
    }

    // MARK: Writing

    /// Sends `data`, blocking the caller until the socket has taken it. That block is the
    /// backpressure: without it a fast CDN outruns a slow Wi-Fi link and the queued chunks
    /// become an unbounded buffer — which is how the old whole-file approach died.
    func writeBlocking(_ data: Data) -> Bool {
        guard !isClosed, !data.isEmpty else { return !isClosed }
        let semaphore = DispatchSemaphore(value: 0)
        var ok = true
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { ok = false }
            semaphore.signal()
        })
        semaphore.wait()
        if !ok { close() }
        return ok
    }

    func writeStatus(_ status: Int) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = writeBlocking(Data(head.utf8))
        close()
    }

    // MARK: Lifecycle

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func armIdleTimer() {
        lock.lock()
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.close() }
        idleTimer = timer
        timer.resume()
        lock.unlock()
    }

    /// Idempotent — every path (idle, peer hangup, send failure, server shutdown) lands here.
    /// The old server never closed anything, so a movie's worth of segment requests slowly
    /// used up the process's sockets.
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.retire(self)
    }
}

// MARK: - Upstream exchange

/// Pumps one upstream response into one client connection.
///
/// Streams by default. Only a manifest is buffered — it has to be complete before its URLs
/// can be rewritten — and manifests are kilobytes.
fileprivate final class ProxyExchangeRegistry: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private final class Exchange {
        let connection: ProxyConnection
        let wantsBody: Bool
        let manifestBase: URL
        let proxy: (URL) -> URL?
        var isManifest = false
        var manifestBuffer = Data()
        var headerSent = false
        var failed = false
        var finish: ((Void) -> Void)?

        init(connection: ProxyConnection, wantsBody: Bool, manifestBase: URL, proxy: @escaping (URL) -> URL?) {
            self.connection = connection
            self.wantsBody = wantsBody
            self.manifestBase = manifestBase
            self.proxy = proxy
        }
    }

    private let lock = NSLock()
    private var active: [Int: Exchange] = [:]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func run(request: URLRequest,
             on session: URLSession,
             connection: ProxyConnection,
             wantsBody: Bool,
             rewriteManifestFrom base: URL,
             proxy: @escaping (URL) -> URL?) async {
        let task = session.dataTask(with: request)
        let exchange = Exchange(connection: connection, wantsBody: wantsBody, manifestBase: base, proxy: proxy)
        lock.lock(); active[task.taskIdentifier] = exchange; lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock(); continuations[task.taskIdentifier] = continuation; lock.unlock()
            task.resume()
        }
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.lock(); defer { lock.unlock() }
        return active[task.taskIdentifier]
    }

    private func complete(_ task: URLSessionTask) {
        lock.lock()
        active.removeValue(forKey: task.taskIdentifier)
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        continuation?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let exchange = exchange(for: dataTask) else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let mime = http?.value(forHTTPHeaderField: "Content-Type")
            ?? response.mimeType
            ?? Self.mimeType(for: exchange.manifestBase.pathExtension)

        exchange.isManifest = CastManifestRewriter.isManifest(mime: mime, url: exchange.manifestBase)

        if exchange.isManifest {
            // Length is unknown until the rewrite is done, so the head waits.
            completionHandler(.allow)
            return
        }

        // Pass the upstream's own status and framing through untouched: a 206 with its
        // Content-Range is exactly what lets the receiver seek.
        let status = http?.statusCode ?? 200
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        head += "Content-Type: \(mime)\r\n"
        if let range = http?.value(forHTTPHeaderField: "Content-Range") { head += "Content-Range: \(range)\r\n" }
        if let length = http?.value(forHTTPHeaderField: "Content-Length") { head += "Content-Length: \(length)\r\n" }
        // Advertised unconditionally: the receiver only attempts a seek if it believes
        // ranges are available, and the upstream honours them.
        head += "Accept-Ranges: bytes\r\n"
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"

        exchange.headerSent = true
        if !exchange.connection.writeBlocking(Data(head.utf8)) {
            exchange.failed = true
            completionHandler(.cancel)
            return
        }
        completionHandler(exchange.wantsBody ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask), !exchange.failed else { return }
        guard exchange.wantsBody else { return }

        if exchange.isManifest {
            exchange.manifestBuffer.append(data)
            return
        }
        // Blocks until the socket accepts it — see ProxyConnection.writeBlocking.
        if !exchange.connection.writeBlocking(data) {
            exchange.failed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(for: task) else { complete(task); return }
        defer { complete(task) }

        if exchange.failed { exchange.connection.close(); return }

        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            if !cancelled && !exchange.headerSent {
                Logger.shared.log("[CastProxy] Upstream failed: \(error.localizedDescription)", type: "Error")
                exchange.connection.writeStatus(502)
            } else if !cancelled {
                // Already streaming when it broke — the framing is unrecoverable, so drop
                // the socket and let the receiver re-request.
                exchange.connection.close()
            }
            return
        }

        guard exchange.isManifest else { return }

        let body: Data
        if let text = String(data: exchange.manifestBuffer, encoding: .utf8) {
            let rewritten = CastManifestRewriter.rewrite(text,
                                                         baseURL: exchange.manifestBase,
                                                         proxy: exchange.proxy)
            body = Data(rewritten.utf8)
        } else {
            body = exchange.manifestBuffer
        }

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/x-mpegURL\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        guard exchange.connection.writeBlocking(Data(head.utf8)) else { return }
        if exchange.wantsBody { _ = exchange.connection.writeBlocking(body) }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/x-mpegURL"
        case "ts":   return "video/mp2t"
        case "mp4", "m4s": return "video/mp4"
        case "vtt":  return "text/vtt"
        default:     return "application/octet-stream"
        }
    }
}
#endif
