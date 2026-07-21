@testable import Gyaim
import XCTest

/// Property tests for BundledZenzRuntime.combineScores
/// (formal methods Phase 1).
///
/// BUG-029 was exactly a violation of these properties: raw negative log
/// probabilities were added to only the scored subset, systematically
/// penalizing scored candidates against unscored ones. Stated as properties,
/// the mistake is detectable for every weight and score distribution — not
/// just the seisansei example pinned in the regression test.
final class ScoreCombinationPropertyTests: XCTestCase {
    func testZenzContributionIsZeroSumOverScoredSet() {
        checkProperty("zenz contribution sums to zero over the scored set") { random in
            let candidateCount = random.int(in: 1...20)
            var heuristic: [Int: Double] = [:]
            var zenz: [Int: Double] = [:]
            for index in 0..<candidateCount {
                heuristic[index] = Double(random.int(in: -300...300)) / 100.0
                if random.int(in: 0...1) == 1 {
                    // Mean log probabilities are negative — generate that shape.
                    zenz[index] = Double(random.int(in: -1_000...0)) / 100.0
                }
            }
            let weight = Double(random.int(in: 1...100)) / 100.0

            let combined = BundledZenzRuntime.combineScores(heuristic: heuristic,
                                                            zenz: zenz,
                                                            weight: weight)

            let contribution = zenz.keys.reduce(0.0) { sum, index in
                sum + ((combined[index] ?? 0) - (heuristic[index] ?? 0))
            }
            guard abs(contribution) < 1e-9 else {
                return "contribution sum \(contribution) != 0 for zenz \(zenz), weight \(weight)"
            }
            return nil
        }
    }

    func testUnscoredCandidatesAreUntouched() {
        checkProperty("candidates outside the scored set keep their heuristic score") { random in
            let candidateCount = random.int(in: 1...20)
            var heuristic: [Int: Double] = [:]
            var zenz: [Int: Double] = [:]
            for index in 0..<candidateCount {
                heuristic[index] = Double(random.int(in: -300...300)) / 100.0
                if random.int(in: 0...2) == 0 {
                    zenz[index] = Double(random.int(in: -1_000...0)) / 100.0
                }
            }
            let weight = Double(random.int(in: 1...100)) / 100.0

            let combined = BundledZenzRuntime.combineScores(heuristic: heuristic,
                                                            zenz: zenz,
                                                            weight: weight)

            for index in 0..<candidateCount where zenz[index] == nil {
                if combined[index] != heuristic[index] {
                    return "unscored index \(index) changed: \(String(describing: heuristic[index])) -> \(String(describing: combined[index]))"
                }
            }
            return nil
        }
    }
}
