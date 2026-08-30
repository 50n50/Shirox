import Foundation

/// A Cast session lifecycle event, one per SDK callback the app reacts to.
enum CastSessionEvent: Equatable {
    /// A session was established.
    case started
    /// The session ended — the app's own disconnect, the system Cast sheet, or the receiver.
    case ended
    /// The SDK put the session on hold, normally because the app was backgrounded.
    case suspended
    /// A suspended session came back.
    case resumed
    /// Connecting to the device never completed.
    case failedToStart
    /// The session lives but the receiver reported a playback error (`idleReason == .error`).
    case receiverError
}

/// What the app's cast state should become.
enum CastSessionOutcome: Equatable {
    /// Session live; commands go through.
    case connected
    /// Session temporarily on hold. Keep the cast UI — the SDK usually gets it back — but
    /// don't pretend commands work.
    case reconnecting
    /// No usable session. Tear down and hand playback back to the local player.
    case disconnected

    /// Whether the UI should still present itself as casting.
    var isConnected: Bool { self != .disconnected }

    /// Whether it is safe to send transport commands to the receiver. `reconnecting` is
    /// deliberately false: the remote media client is detached, so a `play()` would vanish
    /// and leave the UI asserting a state the TV isn't in.
    var acceptsCommands: Bool { self == .connected }
}

/// Pure state machine for a Chromecast session — no SDK types, fully unit-testable.
///
/// THE BUG THIS EXISTS FOR: `CastManager` handled only `didStart`, `didEnd` and `didResume`.
/// The Cast SDK suspends a session whenever the app backgrounds (screen lock, app switch)
/// and attempts a resume on return; a resume that fails ends the session, and a connection
/// that never lands reports `didFailToStart`. With neither handled, `isConnected` stayed
/// `true` against a `currentCastSession` that was already nil — and since every control is
/// written `currentCastSession?.remoteMediaClient?.play()`, they all silently no-opped. The
/// result was a cast overlay with dead buttons that only relaunching cleared.
enum CastSessionRecovery {

    /// The app-level state each lifecycle event implies. Exhaustive over `CastSessionEvent`
    /// on purpose: a new event can't default to "still casting".
    static func outcome(for event: CastSessionEvent) -> CastSessionOutcome {
        switch event {
        case .started, .resumed:
            return .connected
        case .suspended:
            return .reconnecting
        case .ended, .failedToStart, .receiverError:
            return .disconnected
        }
    }

    /// Whether the media must be (re)loaded onto the receiver after `event`.
    ///
    /// A resume onto a receiver still playing our movie must not reload — that would restart
    /// the video with a visible stutter every time the phone unlocks. A resume onto a
    /// receiver that dropped to its idle backdrop must, or the user watches a screensaver
    /// while the app shows a live scrubber.
    static func shouldReloadMedia(after event: CastSessionEvent, receiverHasMedia: Bool) -> Bool {
        switch event {
        case .started:  return true
        case .resumed:  return !receiverHasMedia
        default:        return false
        }
    }

    /// Sanitises a duration reported by the receiver.
    ///
    /// A stream the receiver can't measure (live, or HLS it hasn't parsed yet) reports 0 or
    /// a non-finite value. Publishing that collapses the scrubber to an unusable zero-length
    /// track, so callers keep their last good value on `nil`.
    static func usableDuration(_ raw: Double) -> Double? {
        guard raw.isFinite, raw > 0 else { return nil }
        return raw
    }
}
