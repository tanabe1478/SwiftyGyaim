import Cocoa

/// Prefix-mode candidate assembly and fast-context rerank (ADR-016/017/020/021/026).
///
/// Everything here is a pure static function over `SearchCandidate` arrays and
/// settings; the instance-side scheduling of the deferred model review stays in
/// GyaimController.swift because it touches controller state.
extension GyaimController {
    // MARK: - External candidate validation

    /// Check if a string is a valid external candidate (not a Gyazo hash, URL, or code-like identifier).
    static func isValidExternalCandidate(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if ImageManager.isImageCandidate(trimmed) { return false }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http") { return false }
        if lowercased.contains("://") { return false }
        if isCodeLikeExternalCandidate(trimmed) { return false }
        return true
    }

    static func isExternalCandidateAllowed(forInput inputPat: String) -> Bool {
        !inputPat.contains { character in
            character == "?" || character == "？" || character == "!" || character == "！"
        }
    }

    private static func isCodeLikeExternalCandidate(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0.value == 0x5F }) else { return false } // "_"
        return scalars.allSatisfy { scalar in
            (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value)
                || (0x30...0x39).contains(scalar.value)
                || scalar.value == 0x5F
        }
    }

    /// Build prefix-mode candidate list with external candidates injected.
    /// Extracted for testability.
    static func buildPrefixCandidates(
        searchResults: [SearchCandidate],
        inputPat: String,
        clipboardCandidate: String?,
        selectedCandidate: String?,
        hiragana: String,
        context: String? = nil,
        fastContextRerankEnabled: Bool = true,
        allowModelReview: Bool = true
    ) -> [SearchCandidate] {
        var candidates: [SearchCandidate] = [SearchCandidate(word: inputPat, kind: .raw)]

        // Keep raw input as the selected candidate in prefix mode. This preserves the
        // historical safety behavior: plain Enter does not accidentally commit a long
        // prefix match such as "gu" -> "具体的" or "maeno" -> "前のめり".
        // External candidates follow raw input so they appear at the top of the
        // candidate window, matching the original Gyaim registration workflow.
        let externalAllowedForInput = isExternalCandidateAllowed(forInput: inputPat)
        if let clip = clipboardCandidate {
            if externalAllowedForInput && isValidExternalCandidate(clip) {
                candidates.append(SearchCandidate(word: clip, source: .external, kind: .exact))
            } else if isFastContextRerankLoggingEnabled {
                Log.input.info("External clipboard candidate rejected: \"\(clip.prefix(50))\"")
            }
        }

        if let sel = selectedCandidate {
            if externalAllowedForInput && isValidExternalCandidate(sel) {
                candidates.append(SearchCandidate(word: sel, source: .external, kind: .exact))
            } else if isFastContextRerankLoggingEnabled {
                Log.input.info("External selected-text candidate rejected: \"\(sel.prefix(50))\"")
            }
        }

        let shouldFastContextRerank = fastContextRerankEnabled && isFastContextRerankEnabled
        if isFastContextRerankLoggingEnabled, !shouldFastContextRerank {
            Log.input.info(
                "Fast context rerank skipped: input=\"\(inputPat)\" "
                    + "enabled=\(isFastContextRerankEnabled) testHook=\(fastContextRerankEnabled)"
            )
        }
        let dictionaryCandidates = shouldFastContextRerank
            ? fastContextRerank(searchResults, inputPat: inputPat, hiragana: hiragana, context: context,
                                allowModelReview: allowModelReview)
            : searchResults
        candidates.append(contentsOf: dictionaryCandidates)

        // Add hiragana if few candidates
        if candidates.count < CandidateDisplayMode.current.maxVisible, !hiragana.isEmpty {
            candidates.append(SearchCandidate(word: hiragana, reading: inputPat, kind: .kana))
        }

        // Deduplicate preserving order
        var seen: Set<String> = []
        candidates = candidates.filter { c in
            if seen.contains(c.word) { return false }
            seen.insert(c.word)
            return true
        }

        return candidates
    }

    private static func fastContextRerank(_ searchResults: [SearchCandidate],
                                          inputPat: String,
                                          hiragana: String,
                                          context: String?,
                                          allowModelReview: Bool = true) -> [SearchCandidate] {
        guard searchResults.count >= 2 else {
            if isFastContextRerankLoggingEnabled {
                Log.input.info(
                    "Fast context rerank skipped: input=\"\(inputPat)\" "
                        + "reason=too-few-dictionary-candidates count=\(searchResults.count)"
                )
            }
            return searchResults
        }

        let start = CFAbsoluteTimeGetCurrent()
        let maxFastRerankCandidates = Self.maxFastContextRerankCandidates()
        let head = Array(searchResults.prefix(maxFastRerankCandidates))
        let tail = Array(searchResults.dropFirst(maxFastRerankCandidates))
        let trimmedContext = limitedFastContext(context)
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: inputPat,
            hiragana: hiragana,
            context: trimmedContext.isEmpty ? nil : trimmedContext,
            candidates: head.enumerated().map { index, candidate in
                AIRerankCandidate(index: index,
                                  text: candidate.word,
                                  reading: candidate.reading,
                                  source: String(describing: candidate.source),
                                  kind: candidate.kind.rawValue,
                                  contextAffinity: ContextDict.shared.affinity(context: trimmedContext,
                                                                               reading: candidate.reading,
                                                                               word: candidate.word),
                                  studyFrequency: candidate.studyFrequency)
            }
        )
        let response = fastContextRerankResponse(for: request, allowModelReview: allowModelReview)
        let rerankedHead = AIReranker.apply(order: response.order, to: head)
        if isFastContextRerankLoggingEnabled {
            let elapsed = elapsedMilliseconds(since: start)
            let beforeTop = head.prefix(8).map(\.word)
            let afterTop = rerankedHead.prefix(8).map(\.word)
            let model = response.model ?? "unknown"
            Log.input.info(
                "Fast context rerank finished: input=\"\(inputPat)\" "
                    + "model=\(model) outcome=\(fastContextRerankOutcome(model: model)) "
                    + "topChanged=\(beforeTop != afterTop) candidates=\(head.count)/\(searchResults.count) "
                    + "context=\(trimmedContext.isEmpty ? "none" : "present") "
                    + "order=\(response.order) before=\(beforeTop) after=\(afterTop) "
                    + "latency=\(formatMilliseconds(elapsed))ms"
            )
        }
        return rerankedHead + tail
    }

    private static func fastContextRerankResponse(for request: AIRerankRequest,
                                                  allowModelReview: Bool) -> AIRerankResponse {
        if shouldUseModelForFastContextRerank(inputPat: request.inputPat) {
            if allowModelReview {
                return InProcessAIReranker.shared.rerank(request)
            }
            // The model pass is deferred (ADR-026); this synchronous result is
            // what the user sees while still typing.
            return AIReranker.localRerank(request, model: "swift-fast-context-heuristic-prereview")
        }
        return AIReranker.localRerank(request, model: "swift-fast-context-heuristic")
    }

    // MARK: - Deferred model review (ADR-026)

    /// Delay before the model reviews the current prefix candidates. 0 restores
    /// the synchronous per-keystroke review. Dogfood 2026-09-11: 760 homophone
    /// reviews (20-27 ms each) ran on intermediate inputs, but only 26 reached a
    /// commit; deferring past the inter-key interval removes most of them.
    static func modelReviewDelayMilliseconds() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextReviewDelayMs", default: 80)
        return min(max(configured, 0), 1000)
    }

    /// True when the model would review this input but should do so after a
    /// pause instead of inline with the keystroke.
    static func shouldDeferModelReview(inputPat: String) -> Bool {
        shouldUseModelForFastContextRerank(inputPat: inputPat) && modelReviewDelayMilliseconds() > 0
    }

    static var isFastContextRerankEnabled: Bool {
        GyaimSettings.bool(forKey: "aiRerankFastContextEnabled", default: true)
    }

    static func setFastContextRerankEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "aiRerankFastContextEnabled")
    }

    static var isFastContextRerankModelEnabled: Bool {
        GyaimSettings.bool(forKey: "aiRerankUseModelForFastContext")
    }

    static func setFastContextRerankModelEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "aiRerankUseModelForFastContext")
    }

    static var isBundledZenzEnabled: Bool {
        GyaimSettings.bool(forKey: BundledZenzAIRerankBackend.enabledDefaultsKey, default: true)
    }

    static func setBundledZenzEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: BundledZenzAIRerankBackend.enabledDefaultsKey)
    }

    static var isFastContextRerankLoggingEnabled: Bool {
        GyaimSettings.bool(forKey: "aiRerankFastContextLoggingEnabled")
    }

    static func setFastContextRerankLoggingEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "aiRerankFastContextLoggingEnabled")
    }

    private static func shouldUseModelForFastContextRerank(inputPat: String) -> Bool {
        guard isFastContextRerankModelEnabled else { return false }
        return inputPat.count >= minFastContextModelInputLength()
    }

    static func fastContextRerankOutcome(model: String) -> String {
        if model.contains("heuristic-prereview") { return "heuristic-prereview" }
        if model.contains("review-affinity-skipped") { return "affinity-skip" }
        if model.contains("review-length-skipped") { return "short-input-skip" }
        if model.contains("review-skipped") { return "protected-exact-skip" }
        if model.contains("review-exact-homophone-unavailable") { return "exact-homophone-unavailable" }
        if model.contains("review-exact-homophone-fixed") { return "exact-homophone-fixed" }
        if model.contains("review-exact-homophone-kept-local") { return "exact-homophone-kept-local" }
        if model.contains("review-exact-homophone-passed") { return "exact-homophone-passed" }
        if model.contains("review-unavailable") { return "review-unavailable" }
        if model.contains("review-fixed") { return "review-fixed" }
        if model.contains("review-kept-local") { return "review-kept-local" }
        if model.contains("review-passed") { return "review-passed" }
        if model.contains("review") { return "review-applied" }
        if model.contains("swift-fast-context-heuristic") { return "heuristic" }
        // Model backend disabled or unavailable → plain heuristic result.
        // Review-path model strings also contain this substring but are
        // matched by the earlier patterns, so this must stay last.
        if model.contains("swift-local-heuristic") { return "heuristic" }
        return "fallback"
    }

    private static func minFastContextModelInputLength() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextModelMinInputLength")
        guard configured > 0 else { return 4 }
        return min(max(configured, 1), 12)
    }

    static func limitedFastContext(_ context: String?) -> String {
        let trimmed = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextMaxContextLength")
        let limit = configured > 0 ? min(max(configured, 1), 200) : 20
        return String(trimmed.suffix(limit))
    }

    private static func maxFastContextRerankCandidates() -> Int {
        let configured = GyaimSettings.integer(forKey: "aiRerankFastContextCandidateLimit")
        guard configured > 0 else { return 24 }
        return min(max(configured, 2), 48)
    }

    // MARK: - Timing

    static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
