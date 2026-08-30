import XCTest
@testable import Shirox

/// Tests for the cast session state machine.
///
/// THE REPORTED BUG: "when I last used chromecast I had to close it and open it again
/// 2 times in one movie."
///
/// Root cause: `CastManager` implemented only three of the Cast SDK's session callbacks —
/// `didStart`, `didEnd`, `didResume` — and only the Cast-typed half of each. The SDK
/// suspends a session whenever the app is backgrounded (screen lock, app switch) and tries
/// to resume on return; a resume that fails ends the session, and a connection that never
/// establishes reports `didFailToStart`. With those unhandled, `isConnected` stayed `true`
/// forever against a `currentCastSession` that was now nil. Every control is written as
/// `currentCastSession?.remoteMediaClient?.play()` — with the session gone those silently
/// no-op, so the app sat on the cast overlay with dead buttons and no way back except
/// killing it. Twice in one movie is exactly two lock/unlock cycles.
///
/// These tests pin the full lifecycle so a missing case can't silently mean "still casting".
final class CastSessionRecoveryTests: XCTestCase {

    // MARK: - THE BUG: failures must not read as connected

    /// A resume that fails after a screen lock. The Cast SDK has no `didFailToResume`
    /// callback — it ends the session instead — so this arrives as `.ended`, and the fix is
    /// that `didEndSession:` is now actually wired up (see CastSessionListenerSelectorTests).
    func testFailedResumeArrivesAsEndAndDisconnects() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .ended), .disconnected)
    }

    /// Tapping a device that never answers must not strand the UI on the cast overlay.
    func testFailedStartDisconnects() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .failedToStart), .disconnected)
    }

    /// The receiver reported a playback error. The session may still be alive, but the
    /// media is dead — the app has to hand playback back rather than show a frozen scrubber.
    func testReceiverErrorDisconnects() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .receiverError), .disconnected)
    }

    // MARK: - Transient states keep the session

    /// A suspend is the SDK's normal backgrounding behaviour and is usually followed by a
    /// successful resume. Tearing down here would kill casting every time the screen locks,
    /// so the UI stays up — but controls must know they're not live.
    func testSuspendIsReconnectingNotDisconnected() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .suspended), .reconnecting)
    }

    func testResumeReconnects() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .resumed), .connected)
    }

    func testStartConnects() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .started), .connected)
    }

    /// A deliberate disconnect (the app's own button, or the system Cast sheet).
    func testEndDisconnects() {
        XCTAssertEqual(CastSessionRecovery.outcome(for: .ended), .disconnected)
    }

    // MARK: - isConnected projection

    /// `reconnecting` must still read as connected to the UI layer — otherwise every screen
    /// lock bounces the user back to the local player mid-movie.
    func testReconnectingStillCountsAsConnectedForUI() {
        XCTAssertTrue(CastSessionOutcome.reconnecting.isConnected)
        XCTAssertTrue(CastSessionOutcome.connected.isConnected)
        XCTAssertFalse(CastSessionOutcome.disconnected.isConnected)
    }

    /// ...but commands must not be sent while reconnecting: the remote media client is
    /// detached, so a `play()` would vanish and leave the UI showing the wrong state.
    func testCommandsOnlyAcceptedWhileFullyConnected() {
        XCTAssertTrue(CastSessionOutcome.connected.acceptsCommands)
        XCTAssertFalse(CastSessionOutcome.reconnecting.acceptsCommands)
        XCTAssertFalse(CastSessionOutcome.disconnected.acceptsCommands)
    }

    // MARK: - Reloading media after a resume

    /// Resuming onto a receiver that is still playing our movie must NOT reload it — that
    /// would restart the video from the resume position with a visible stutter.
    func testResumeWithMediaStillOnReceiverDoesNotReload() {
        XCTAssertFalse(CastSessionRecovery.shouldReloadMedia(after: .resumed, receiverHasMedia: true))
    }

    /// Resuming onto a receiver that dropped the media (idle screen) must reload it,
    /// otherwise the user is left staring at the Chromecast backdrop with a live-looking
    /// scrubber in the app.
    func testResumeWithEmptyReceiverReloads() {
        XCTAssertTrue(CastSessionRecovery.shouldReloadMedia(after: .resumed, receiverHasMedia: false))
    }

    /// A fresh session always loads.
    func testStartAlwaysLoads() {
        XCTAssertTrue(CastSessionRecovery.shouldReloadMedia(after: .started, receiverHasMedia: false))
        XCTAssertTrue(CastSessionRecovery.shouldReloadMedia(after: .started, receiverHasMedia: true))
    }

    /// Nothing to load onto a session that is gone or still suspended.
    func testTerminalAndTransientEventsNeverLoad() {
        for event in [CastSessionEvent.ended, .failedToStart, .suspended, .receiverError] {
            XCTAssertFalse(CastSessionRecovery.shouldReloadMedia(after: event, receiverHasMedia: false),
                           "\(event) must not trigger a media load")
        }
    }

    // MARK: - Duration sanitising

    /// An HLS stream the receiver can't measure reports 0 or a non-finite duration. Feeding
    /// that to the scrubber makes it unusable; the app must keep its last good value.
    func testUnknownDurationIsRejected() {
        XCTAssertNil(CastSessionRecovery.usableDuration(0))
        XCTAssertNil(CastSessionRecovery.usableDuration(.nan))
        XCTAssertNil(CastSessionRecovery.usableDuration(.infinity))
        XCTAssertNil(CastSessionRecovery.usableDuration(-5))
        XCTAssertEqual(CastSessionRecovery.usableDuration(1440.5), 1440.5)
    }
}
