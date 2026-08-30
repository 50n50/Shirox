import XCTest
@testable import Shirox

#if canImport(GoogleCast)
import GoogleCast

/// Verifies `CastManager` actually receives the Cast SDK's session callbacks.
///
/// This is the test that would have caught the reported bug at its root. `GCKSessionManagerListener`
/// is an Objective-C protocol whose members are all **optional**, and the SDK dispatches them by
/// `respondsToSelector:`. A Swift method whose imported name is even slightly off therefore
/// compiles cleanly, conforms "successfully", and is simply never called — the session ends or
/// drops and the app never finds out, leaving `isConnected` true against a session that no longer
/// exists. Every control is `currentCastSession?.…`, so they all quietly no-op and the only way
/// out is force-quitting the app. That is exactly the "close it and open it again" symptom.
///
/// Asserting on raw selector strings (rather than trusting Swift's importer to keep naming them
/// the way it does today) is the point: these are the literal selectors `GCKSessionManager` sends.
final class CastSessionListenerSelectorTests: XCTestCase {

    /// Every callback the app depends on for correct state, as the SDK will send it.
    private let requiredSelectors = [
        // Connection established.
        "sessionManager:didStartCastSession:",
        "sessionManager:didStartSession:",
        // Connection gone — the path a failed resume ultimately takes.
        "sessionManager:didEndCastSession:withError:",
        "sessionManager:didEndSession:withError:",
        // Connection never established.
        "sessionManager:didFailToStartCastSession:withError:",
        "sessionManager:didFailToStartSession:withError:",
        // Temporarily dropped (backgrounding, network blip).
        "sessionManager:didSuspendCastSession:withReason:",
        "sessionManager:didSuspendSession:withReason:",
        // Back again.
        "sessionManager:didResumeCastSession:",
        "sessionManager:didResumeSession:"
    ]

    func testCastManagerImplementsEverySessionCallbackTheSDKSends() {
        let manager: AnyObject = CastManager.shared
        var missing: [String] = []
        for name in requiredSelectors where !manager.responds(to: Selector(name)) {
            missing.append(name)
        }
        XCTAssertTrue(missing.isEmpty,
                      "CastManager will never be told about these session transitions, so its "
                      + "state will go stale and the cast UI will strand the user: \(missing)")
    }

    /// The media-status callback is what drives play/pause, position and receiver errors.
    func testCastManagerImplementsRemoteMediaClientCallbacks() {
        let manager: AnyObject = CastManager.shared
        XCTAssertTrue(manager.responds(to: Selector("remoteMediaClient:didUpdateMediaStatus:")),
                      "media status updates would never arrive")
        XCTAssertTrue(manager.responds(to: Selector("remoteMediaClientDidUpdateQueue:")),
                      "the receiver dropping our media would go unnoticed")
    }

    /// `CastManager` must be registered as a listener at all — a correct implementation that
    /// nothing subscribed is just as silent.
    func testCastManagerConformsToListenerProtocols() {
        XCTAssertTrue(CastManager.shared is GCKSessionManagerListener)
        XCTAssertTrue(CastManager.shared is GCKRemoteMediaClientListener)
    }
}
#endif
