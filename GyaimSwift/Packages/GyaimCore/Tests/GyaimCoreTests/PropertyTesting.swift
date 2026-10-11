import XCTest

/// Minimal property-based testing support (formal methods Phase 1).
///
/// A property test states an invariant that must hold for ALL inputs, then
/// searches for a counterexample with hundreds of generated inputs. This is
/// the lightest rung of the formal-methods ladder: the property is a formal
/// specification, and the test is a bounded check of it.
///
/// Deliberately dependency-free (~60 lines) instead of importing SwiftCheck:
/// the mechanism itself is a study artifact, and CI needs no network. The
/// main trade-off is no shrinking — failures report the seed and iteration
/// so the exact counterexample can be replayed deterministically.
struct PropertyRandom {
    /// SplitMix64: tiny, fast, deterministic. Not for cryptography — for
    /// reproducible test-input generation only.
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) &+ 1
        return range.lowerBound + Int(nextRaw() % span)
    }

    mutating func intArray(count: ClosedRange<Int>, element: ClosedRange<Int>) -> [Int] {
        let length = int(in: count)
        return (0..<length).map { _ in int(in: element) }
    }
}

/// Runs `body` against `iterations` generated inputs. `body` returns nil when
/// the property holds, or a description of the violation. On failure, the
/// seed and iteration are reported so the counterexample can be replayed by
/// passing the same seed.
func checkProperty(_ label: String,
                   iterations: Int = 300,
                   seed: UInt64 = 0x5EED_5EED_5EED_5EED,
                   file: StaticString = #filePath,
                   line: UInt = #line,
                   _ body: (inout PropertyRandom) -> String?) {
    for iteration in 0..<iterations {
        // Each iteration gets an independent, reproducible stream.
        var random = PropertyRandom(seed: seed &+ UInt64(iteration))
        if let violation = body(&random) {
            XCTFail("""
                property "\(label)" violated at iteration \(iteration) \
                (replay with seed: \(seed &+ UInt64(iteration))): \(violation)
                """,
                    file: file,
                    line: line)
            return
        }
    }
}
