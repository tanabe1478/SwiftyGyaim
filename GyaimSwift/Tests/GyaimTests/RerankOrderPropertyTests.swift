@testable import Gyaim
import XCTest

/// Property tests for AIReranker.validatedOrder (formal methods Phase 1).
///
/// The existing example tests pin single inputs; these state the invariants
/// that must hold for EVERY input. validatedOrder is the safety valve between
/// any AI backend's response and the candidate list — if these properties
/// break, candidates can vanish or duplicate no matter how good the model is.
final class RerankOrderPropertyTests: XCTestCase {
    func testValidatedOrderIsAlwaysAPermutation() {
        checkProperty("validatedOrder returns a permutation of 0..<count for arbitrary input") { random in
            let count = random.int(in: 0...30)
            // Arbitrary garbage a backend could return: wrong length,
            // duplicates, negatives, out-of-range indexes.
            let proposed = random.intArray(count: 0...60, element: -5...40)

            let order = AIReranker.validatedOrder(proposed, candidateCount: count)

            guard order.count == count else {
                return "length \(order.count) != count \(count) for proposed \(proposed)"
            }
            guard Set(order) == Set(0..<count) else {
                return "not a permutation: \(order) for count \(count), proposed \(proposed)"
            }
            return nil
        }
    }

    func testValidatedOrderIsIdempotent() {
        checkProperty("re-validating a validated order changes nothing") { random in
            let count = random.int(in: 0...30)
            let proposed = random.intArray(count: 0...60, element: -5...40)

            let once = AIReranker.validatedOrder(proposed, candidateCount: count)
            let twice = AIReranker.validatedOrder(once, candidateCount: count)

            guard once == twice else {
                return "not idempotent: \(once) -> \(twice) for proposed \(proposed), count \(count)"
            }
            return nil
        }
    }
}
