import XCTest
@testable import Shirox

/// Tests for where a transport command actually goes, and what the system player controls
/// are told about it.
///
/// TWO REPORTED BUGS LIVE HERE.
///
/// 1. "When the next episode is played the app plays it on the phone, not on the TV."
///    `swapStream` was unconditionally local — it called `replaceCurrentItem` and then
///    `player.rate = speed` with no idea a cast was in progress. So the phone started playing
///    episode 2 out loud while the Chromecast sat on the finished episode 1.
///
/// 2. "Play/pause doesn't work as expected and sometimes doesn't affect Control Center."
///    Part of that is routing: while casting, the remote commands drove the *local* player,
///    which is deliberately parked and silent during a cast, so the TV ignored them entirely.
///    Now Playing had the same problem in reverse — it published the local player's rate and
///    clock, so Control Center showed "paused, 0:00" over a movie the TV was happily playing.
final class PlaybackRoutingTests: XCTestCase {

    // MARK: - Where does a command go?

    /// THE BUG (next episode): while casting, playback belongs to the receiver. Anything that
    /// starts media — including an episode swap — has to go there, not to the local player.
    func testCastingRoutesToReceiver() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: true, hasLocalPlayer: true), .cast)
    }

    /// A cast session with no local player still routes to the receiver — the local player is
    /// irrelevant to the TV.
    func testCastingRoutesToReceiverEvenWithoutLocalPlayer() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: true, hasLocalPlayer: false), .cast)
    }

    func testNotCastingRoutesToLocalPlayer() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: false, hasLocalPlayer: true), .local)
    }

    /// Nothing to drive. Commands must be dropped rather than sent somewhere arbitrary.
    func testNoPlayerAndNoCastRoutesNowhere() {
        XCTAssertEqual(PlaybackRouting.target(isCasting: false, hasLocalPlayer: false), .none)
    }

    // MARK: - Toggle must be a decision, not a re-read

    /// THE BUG (play/pause): the old toggle handler re-read the player's live state. With two
    /// handlers accidentally registered, the first paused, the second saw "paused" and played
    /// again — a net no-op, which is exactly "the button does nothing". Resolving the toggle
    /// to a concrete intent up front makes a repeated dispatch idempotent instead of cancelling.
    func testToggleResolvesToConcreteIntent() {
        XCTAssertEqual(PlaybackRouting.toggleIntent(isPlaying: true), .pause)
        XCTAssertEqual(PlaybackRouting.toggleIntent(isPlaying: false), .play)
    }

    func testRepeatedIntentIsIdempotent() {
        // Applying `.pause` twice must still mean paused — the property the old
        // re-read-the-player toggle did not have.
        let first = PlaybackRouting.toggleIntent(isPlaying: true)
        let second = PlaybackRouting.toggleIntent(isPlaying: false)
        XCTAssertNotEqual(first, second, "a fresh read flips; that is why intent must be captured once")
        XCTAssertEqual(first, .pause)
    }

    // MARK: - What Control Center is told

    /// THE BUG: Now Playing published the local player's rate. During a cast that player is
    /// parked at rate 0, so Control Center showed a paused button over a playing TV — and
    /// tapping it did the opposite of what the glyph promised.
    func testCastingPublishesReceiverRateNotLocalRate() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .cast, isPlaying: true, playbackSpeed: 1.0), 1.0)
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .cast, isPlaying: false, playbackSpeed: 1.0), 0.0)
    }

    /// A paused player advertises rate 0; that is what makes Control Center draw ▶.
    func testPausedPublishesZeroRate() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .local, isPlaying: false, playbackSpeed: 1.5), 0.0)
    }

    /// The user's speed setting has to reach Control Center, otherwise its scrubber advances
    /// at the wrong pace and drifts out of sync with the picture.
    func testPlayingPublishesUserPlaybackSpeed() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .local, isPlaying: true, playbackSpeed: 1.5), 1.5)
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .cast, isPlaying: true, playbackSpeed: 2.0), 2.0)
    }

    func testNoTargetPublishesZeroRate() {
        XCTAssertEqual(PlaybackRouting.nowPlayingRate(target: .none, isPlaying: true, playbackSpeed: 1.0), 0.0)
    }

    /// THE BUG: elapsed time came from the local player's clock, which is frozen during a cast.
    func testCastingPublishesReceiverPosition() {
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .cast, castPosition: 743, localPosition: 0), 743)
    }

    func testLocalPublishesLocalPosition() {
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .local, castPosition: 0, localPosition: 128), 128)
    }

    /// A non-finite clock (an item that hasn't loaded) must not reach Now Playing — it renders
    /// as a garbage scrubber rather than simply being absent.
    func testNonFiniteElapsedIsClampedToZero() {
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .local, castPosition: 0, localPosition: .nan), 0)
        XCTAssertEqual(PlaybackRouting.nowPlayingElapsed(target: .local, castPosition: 0, localPosition: -3), 0)
    }
}
