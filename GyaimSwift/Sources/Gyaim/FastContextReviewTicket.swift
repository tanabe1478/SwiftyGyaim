import Foundation

/// One asynchronous model review of the current prefix candidates (ADR-029).
///
/// Created on the main thread when a keystroke produces new prefix candidates,
/// executed on `GyaimController.modelReviewQueue`, and applied back on the main
/// thread. The ticket is the only object shared between the two threads: the
/// worker stores its outcome here, and the main thread either receives it via
/// `DispatchQueue.main.async` or, when the user presses Space before the
/// worker has finished, waits for it briefly with `waitForResult`.
final class FastContextReviewTicket {
    struct Outcome {
        let candidates: [SearchCandidate]
        let observation: FastContextObservation?
    }

    let generation: Int
    let input: FastContextPrefixInput

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var cancelled = false
    private var outcome: Outcome?
    private var appliedFlag = false

    init(generation: Int, input: FastContextPrefixInput) {
        self.generation = generation
        self.input = input
    }

    /// Set by the main thread when a newer keystroke makes this review moot.
    /// The worker checks it before paying for the model call.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Worker side: publish the result exactly once.
    func store(_ result: Outcome) {
        lock.lock()
        outcome = result
        lock.unlock()
        semaphore.signal()
    }

    /// Result if the worker has already finished.
    var current: Outcome? {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    /// Main-thread side: block up to `timeout` for the worker to finish.
    /// Returns nil when the result is not ready in time (the caller proceeds
    /// with the heuristic order and the trace records the review as cancelled).
    func waitForResult(timeout: DispatchTimeInterval) -> Outcome? {
        if let ready = current { return ready }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return current
    }

    /// Guards against applying the same outcome twice (Space join + the
    /// worker's own main.async callback).
    func markApplied() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if appliedFlag { return false }
        appliedFlag = true
        return true
    }
}
