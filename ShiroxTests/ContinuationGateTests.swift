import XCTest
@testable import Shirox

/// Tests for the resume-once gate that bridges untrusted module JS promises into async/await.
///
/// The bugs it exists for:
///  * A promise that never settles suspended the calling continuation forever — the stream
///    picker spun with no way out, `refetchStream` never cleared `isRefetchingStream` (blocking
///    every later recovery), and cancelling the enclosing Task did nothing, because cancelling
///    a Task does not resume a continuation.
///  * A thenable that invokes both its resolve and reject callbacks would resume the same
///    continuation twice, which traps at runtime.
final class ContinuationGateTests: XCTestCase {

    /// The first outcome is the one delivered.
    func testDeliversFirstOutcome() async throws {
        let gate = ContinuationGate()
        let value: String = try await withCheckedThrowingContinuation { cont in
            gate.attach(cont)
            gate.settle(.success("first"))
        }
        XCTAssertEqual(value, "first")
    }

    /// THE CRASH: a promise firing both callbacks must not resume the continuation twice.
    func testLaterOutcomesAreDropped() async throws {
        let gate = ContinuationGate()
        let value: String = try await withCheckedThrowingContinuation { cont in
            gate.attach(cont)
            gate.settle(.success("winner"))
            gate.settle(.success("ignored"))
            gate.settle(.failure(JSEngineError.nullResult))
        }
        XCTAssertEqual(value, "winner")
    }

    /// A failure delivered first wins, and a later success can't override it.
    func testFailureWinsWhenFirst() async {
        let gate = ContinuationGate()
        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                gate.attach(cont)
                gate.settle(.failure(JSEngineError.timedOut("extractStreamUrl")))
                gate.settle(.success("too late"))
            }
            XCTFail("expected the first (failure) outcome to be delivered")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    /// THE HANG: an outcome that arrives before `attach` (cancellation can fire before the
    /// continuation body runs) must be held and delivered, not dropped — dropping it is exactly
    /// the forever-suspended continuation this gate was added to prevent.
    func testOutcomeArrivingBeforeAttachIsStillDelivered() async throws {
        let gate = ContinuationGate()
        let value: String = try await withCheckedThrowingContinuation { cont in
            gate.settle(.success("early"))
            gate.attach(cont)
        }
        XCTAssertEqual(value, "early")
    }

    /// Concurrent settles from different queues must still resume exactly once.
    func testConcurrentSettlesResumeOnce() async throws {
        let gate = ContinuationGate()
        let value: String = try await withCheckedThrowingContinuation { cont in
            gate.attach(cont)
            DispatchQueue.concurrentPerform(iterations: 64) { i in
                gate.settle(.success("v\(i)"))
            }
        }
        XCTAssertTrue(value.hasPrefix("v"))
    }
}
