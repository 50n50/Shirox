import XCTest
@testable import Shirox

#if os(iOS)
import MediaPlayer

/// Tests that the lock screen / Control Center transport controls are wired exactly once.
///
/// THE REPORTED BUG: "the pause/play button doesn't work as expected and sometimes isn't
/// affecting the iOS Control Center play/pause."
///
/// Root cause: registration lived at the end of `setupPlayer()` and called `addTarget` without
/// ever removing what was there before. `setupPlayer()` runs again on every stall recovery,
/// foreground re-resolve and AirPlay route swap — and `MPRemoteCommand` invokes **every**
/// registered handler. Two handlers on `togglePlayPauseCommand` means the first pauses and the
/// second immediately plays again: the button does visibly nothing. Two handlers on
/// `skipForwardCommand` skips twice as far as advertised. And the older handlers still captured
/// the previous, now-deallocated `AVPlayer`, so they returned `.commandFailed` and left Control
/// Center's state wrong.
///
/// Counting live targets is the direct regression test: registering N times must leave one
/// handler per command, never N.
@MainActor
final class RemoteCommandCoordinatorTests: XCTestCase {

    private var coordinator: RemoteCommandCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = RemoteCommandCoordinator()
    }

    override func tearDown() {
        coordinator.unregister()
        coordinator = nil
        super.tearDown()
    }

    private func register() {
        coordinator.register(
            skipInterval: 10,
            play: {}, pause: {}, toggle: {}, seek: { _ in }, skip: { _ in }
        )
    }

    /// THE BUG: this is the assertion that fails against the old code — every `setupPlayer()`
    /// stacked another full set of handlers.
    func testRepeatedRegistrationDoesNotAccumulateHandlers() {
        register()
        let afterFirst = coordinator.activeTargetCount
        XCTAssertGreaterThan(afterFirst, 0, "registration must actually install handlers")

        register()
        register()
        XCTAssertEqual(coordinator.activeTargetCount, afterFirst,
                       "handlers accumulated across re-registration: a toggle would fire "
                       + "\(coordinator.activeTargetCount / max(afterFirst, 1))x and cancel itself out")
    }

    func testUnregisterRemovesEverything() {
        register()
        coordinator.unregister()
        XCTAssertEqual(coordinator.activeTargetCount, 0)
    }

    func testUnregisterIsSafeWhenNothingRegistered() {
        coordinator.unregister()
        coordinator.unregister()
        XCTAssertEqual(coordinator.activeTargetCount, 0)
    }

    /// Every command the player offers must be enabled, or Control Center renders a dead
    /// control that silently ignores taps.
    func testAllTransportCommandsAreEnabled() {
        register()
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.playCommand.isEnabled)
        XCTAssertTrue(center.pauseCommand.isEnabled)
        XCTAssertTrue(center.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(center.changePlaybackPositionCommand.isEnabled)
        XCTAssertTrue(center.skipForwardCommand.isEnabled)
        XCTAssertTrue(center.skipBackwardCommand.isEnabled)
    }

    /// THE BUG: the handlers hardcoded a 10s jump while `preferredIntervals` advertised the
    /// user's configured value, so Control Center drew "15" on a button that moved 10.
    func testAdvertisedSkipIntervalMatchesTheConfiguredOne() {
        coordinator.register(
            skipInterval: 15,
            play: {}, pause: {}, toggle: {}, seek: { _ in }, skip: { _ in }
        )
        let center = MPRemoteCommandCenter.shared()
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals.first?.intValue, 15)
        XCTAssertEqual(center.skipBackwardCommand.preferredIntervals.first?.intValue, 15)
    }

    /// The skip handler must receive the same interval Control Center advertises, signed by
    /// direction.
    func testSkipHandlerReceivesAdvertisedInterval() {
        var received: [Double] = []
        coordinator.register(
            skipInterval: 15,
            play: {}, pause: {}, toggle: {}, seek: { _ in }, skip: { received.append($0) }
        )
        coordinator.performSkipForTesting(forward: true)
        coordinator.performSkipForTesting(forward: false)
        XCTAssertEqual(received, [15, -15])
    }
}
#endif
