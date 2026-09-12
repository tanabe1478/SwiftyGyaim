import Foundation

/// Main-thread input snapshot shared by the immediate and delayed passes.
struct FastContextPrefixInput {
    let searchResults: [SearchCandidate]
    let inputPat: String
    let hiragana: String
    let clipboard: String?
    let selected: String?
    let context: String
}

/// Immutable, bounded dictionary snapshot; no additional model calls for logging.
struct FastContextObservation: Equatable {
    let request: AIRerankRequest
    let response: AIRerankResponse
    let heuristicOrder: [Int]
}

/// One prefix request inside a composition. Identity survives the key that
/// cancels/commits it; a new controller gets a UUID to avoid cross-client joins.
struct FastContextTrace: Equatable {
    enum ModelState: String {
        case notScheduled = "not-scheduled"
        case pending
        case cancelled
        case appliedChanged = "applied-changed"
        case appliedUnchanged = "applied-unchanged"
        case skipped
        case unavailable
        case sync // Legacy payload compatibility; new sync passes have ranks too.
    }

    var controllerID: String = UUID().uuidString
    let compositionID: Int
    let generation: Int
    var heuristicWords: [String]?
    var proposedWords: [String]?
    var modelState: ModelState
    var deferred = true
    var observation: FastContextObservation?

    var tag: String { "controller=\(controllerID) composition=\(compositionID) gen=\(generation)" }

    func heuristicRank(of word: String) -> Int? { heuristicWords?.firstIndex(of: word) }
    func proposedRank(of word: String) -> Int? { proposedWords?.firstIndex(of: word) }

    mutating func cancel() {
        if modelState == .pending { modelState = .cancelled }
    }

    /// Ignore cancelled/old requests even if their input text happens to match.
    @discardableResult
    mutating func complete(words: [String], observation: FastContextObservation?, generation: Int) -> Bool {
        guard generation == self.generation, modelState == .pending else { return false }
        proposedWords = words
        self.observation = observation
        if observation?.response.review == nil {
            modelState = .skipped
        } else if observation?.response.review?.topDecision == "unavailable" {
            modelState = .unavailable
        } else {
            modelState = words == heuristicWords ? .appliedUnchanged : .appliedChanged
        }
        return true
    }

    /// Full lists stay in memory for rank lookup. Logged order heads are bounded
    /// and use baseline ranks, avoiding extra raw/clipboard text in diagnostics.
    func payload(chosenWord: String, displayedWords: [String]) -> [String: Any] {
        var result: [String: Any] = [
            "traceVersion": 2, "controller": controllerID,
            "composition": compositionID, "generation": generation,
            "modelState": modelState.rawValue, "deferred": deferred,
        ]
        result["heuristicRank"] = heuristicRank(of: chosenWord)
        result["proposedRank"] = proposedRank(of: chosenWord)
        if let heuristicWords {
            result["heuristicOrderHead"] = Array(heuristicWords.indices.prefix(32))
            result["displayedOrderHead"] = displayedWords.prefix(32).map { heuristicWords.firstIndex(of: $0) ?? -1 }
            if let proposedWords {
                result["proposedOrderHead"] = proposedWords.prefix(32).map { heuristicWords.firstIndex(of: $0) ?? -1 }
            }
        }
        if let observation {
            result["model"] = observation.response.model
            result["modelOutcome"] = GyaimController.fastContextRerankOutcome(model: observation.response.model ?? "unknown")
            result["modelContext"] = observation.request.context ?? ""
            result["dictionaryHeuristicOrder"] = observation.heuristicOrder
            result["dictionaryProposedOrder"] = observation.response.order
            // Request indices are local to this bounded dictionary snapshot.
            if let data = try? JSONEncoder().encode(observation.request.candidates),
               let candidates = try? JSONSerialization.jsonObject(with: data) {
                result["dictionaryCandidates"] = candidates
            }
            if let review = observation.response.review { result["review"] = reviewPayload(review) }
        }
        return result
    }

    private func reviewPayload(_ review: AIRerankReview) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(review),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        object["scoreOrder"] = review.candidateIndices.filter { review.scores[String($0)] != nil }.sorted {
            let lhs = review.scores[String($0)] ?? 0
            let rhs = review.scores[String($1)] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        return object
    }
}
