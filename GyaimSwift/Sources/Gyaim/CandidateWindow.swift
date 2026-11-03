import Cocoa

/// Display mode for the candidate window.
enum CandidateDisplayMode: Int {
    case list = 0     // 現行の縦リスト (Google IME風)
    case classic = 1  // オリジナルGyaim風横並び (candwin.png背景)

    /// Current display mode from settings file (default: .classic).
    static var current: CandidateDisplayMode {
        let raw = GyaimSettings.integer(forKey: "candidateDisplayMode", default: 1)
        return CandidateDisplayMode(rawValue: raw) ?? .classic
    }

    /// Persist the display mode to settings file.
    static func setCurrent(_ mode: CandidateDisplayMode) {
        GyaimSettings.set(mode.rawValue, forKey: "candidateDisplayMode")
    }

    /// Maximum number of visible candidates for this mode.
    var maxVisible: Int {
        switch self {
        case .list: return 9
        case .classic: return 11
        }
    }
}

/// Candidate display window — non-activating panel that never steals focus.
/// Supports two display modes: vertical list (default) and classic horizontal.
class CandidateWindow: NSPanel {
    static var shared: CandidateWindow?

    // MARK: - List mode views
    private let stackView = NSStackView()
    let containerView = NSView()
    private var candidateLabels: [NSTextField] = []

    // MARK: - Classic mode views
    var classicBackgroundView: ClassicBackgroundView?
    private var classicContentView: NSView?
    private var classicScrollView: NSScrollView?
    var classicTopInsetConstraint: NSLayoutConstraint?
    var classicBottomInsetConstraint: NSLayoutConstraint?
    var bubbleTailDirection: BubbleTailDirection = .up
    private var classicTextView: NSTextView?

    // MARK: - Constraint groups (toggled per mode)
    private var listConstraints: [NSLayoutConstraint] = []
    private var classicConstraints: [NSLayoutConstraint] = []

    private var initialLocation: NSPoint = .zero

    private let rowHeight: CGFloat = 22
    private let padding: CGFloat = 6
    private let windowWidth: CGFloat = 260
    let classicMetrics = ClassicBubbleMetrics()

    init() {
        let frame = NSRect(x: 0, y: 0, width: 260, height: 30)

        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        becomesKeyOnlyIfNeeded = true

        backgroundColor = .clear
        level = .statusBar
        alphaValue = 1.0
        isOpaque = false
        hasShadow = true
        canHide = true
        hidesOnDeactivate = false

        containerView.wantsLayer = true
        contentView = containerView

        setupListMode()
        setupClassicMode()
        applyDisplayMode()

        CandidateWindow.shared = self
    }

    // MARK: - Mode Setup

    private func setupListMode() {
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stackView)

        listConstraints = [
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: padding),
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: padding),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -padding),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -padding),
        ]
    }

    private func setupClassicMode() {
        // Draw the original bubble art without stretching its corners or tail.
        let bgView = ClassicBackgroundView(metrics: classicMetrics)
        bgView.translatesAutoresizingMaskIntoConstraints = false
        bgView.isHidden = true
        containerView.addSubview(bgView)
        classicBackgroundView = bgView

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.isHidden = true
        containerView.addSubview(contentView)
        classicContentView = contentView

        // NSScrollView + NSTextView replicating original XIB structure
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.isHidden = true
        contentView.addSubview(scrollView)
        classicScrollView = scrollView

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor(white: 0.15, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scrollView.documentView = textView
        classicTextView = textView

        classicConstraints = makeClassicConstraints(bgView: bgView, contentView: contentView, scrollView: scrollView)
    }

    /// Switch between list and classic mode visibility and constraints.
    func applyDisplayMode() {
        let mode = CandidateDisplayMode.current
        let isList = mode == .list

        // Deactivate all constraints first, then activate only current mode
        NSLayoutConstraint.deactivate(listConstraints)
        NSLayoutConstraint.deactivate(classicConstraints)

        stackView.isHidden = !isList
        classicBackgroundView?.isHidden = isList
        classicContentView?.isHidden = isList
        classicScrollView?.isHidden = isList

        if isList {
            NSLayoutConstraint.activate(listConstraints)
            containerView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.95).cgColor
            containerView.layer?.cornerRadius = 6
            containerView.layer?.borderColor = NSColor(white: 0.8, alpha: 1.0).cgColor
            containerView.layer?.borderWidth = 0.5
            hasShadow = true
        } else {
            NSLayoutConstraint.activate(classicConstraints)
            containerView.layer?.backgroundColor = NSColor.clear.cgColor
            containerView.layer?.cornerRadius = 0
            containerView.layer?.borderWidth = 0
            // candwin.png has its own drop shadow; disable window shadow to avoid doubling
            hasShadow = false
        }
    }

    // MARK: - Update Candidates

    /// Update the candidate list. `selected` is the currently highlighted index within `words`.
    /// `hasMore` indicates more candidates exist after current page.
    /// `hasPrev` indicates candidates exist before current page.
    func updateCandidates(_ words: [String], selectedIndex: Int, hasMore: Bool = false, hasPrev: Bool = false) {
        let mode = CandidateDisplayMode.current
        switch mode {
        case .list:
            updateListMode(words, selectedIndex: selectedIndex, hasMore: hasMore, hasPrev: hasPrev)
        case .classic:
            updateClassicMode(words, selectedIndex: selectedIndex, hasMore: hasMore, hasPrev: hasPrev)
        }
    }

    private func updateListMode(_ words: [String], selectedIndex: Int, hasMore: Bool = false, hasPrev: Bool = false) {
        candidateLabels.forEach { $0.removeFromSuperview() }
        candidateLabels.removeAll()

        guard !words.isEmpty else {
            setContentSize(NSSize(width: windowWidth, height: 30))
            return
        }

        Log.ui.debug("updateCandidates(list): \(words.count) candidates")
        let maxVisible = CandidateDisplayMode.list.maxVisible
        let count = min(words.count, maxVisible)
        for i in 0..<count {
            let label = makeLabel(index: i, word: words[i], isSelected: i == selectedIndex)
            stackView.addArrangedSubview(label)
            candidateLabels.append(label)
        }

        // Page indicator
        if hasMore {
            let indicatorLabel = NSTextField(labelWithString: "▼")
            indicatorLabel.font = NSFont.systemFont(ofSize: 11)
            indicatorLabel.textColor = .secondaryLabelColor
            indicatorLabel.alignment = .center
            indicatorLabel.isBezeled = false
            stackView.addArrangedSubview(indicatorLabel)
            candidateLabels.append(indicatorLabel)
        }

        let indicatorRows = hasMore ? 1 : 0
        let totalRows = count + indicatorRows
        let totalHeight = padding * 2 + CGFloat(totalRows) * rowHeight + CGFloat(max(0, totalRows - 1)) * stackView.spacing
        setContentSize(NSSize(width: windowWidth, height: totalHeight))
    }

    private func updateClassicMode(_ words: [String], selectedIndex: Int, hasMore: Bool = false, hasPrev: Bool = false) {
        guard !words.isEmpty else {
            classicTextView?.string = ""
            resizeClassicToFit()
            return
        }

        Log.ui.debug("updateCandidates(classic): \(words.count) candidates")
        let maxVisible = CandidateDisplayMode.classic.maxVisible
        let count = min(words.count, maxVisible)
        let visibleWords = Array(words.prefix(count))
        var displayText = visibleWords.joined(separator: " ")
        if hasMore { displayText += " ▼" }
        classicTextView?.string = displayText
        resizeClassicToFit()
    }

    /// Calculate the text height and resize the classic window to fit.
    /// Window frame drives container size; 4-edge constraints keep scrollView inside.
    private func resizeClassicToFit() {
        guard let textView = classicTextView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let documentWidth = classicMetrics.bubbleSize.width
            - classicMetrics.contentInsets.left
            - classicMetrics.contentInsets.right
        let textWidth = documentWidth - textView.textContainerInset.width * 2
        textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
            + textView.textContainerInset.height * 2

        let scrollHeight = max(textHeight, classicMetrics.minimumContentHeight)
        textView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: scrollHeight)
        classicScrollView?.contentView.scroll(to: .zero)
        if let clipView = classicScrollView?.contentView {
            classicScrollView?.reflectScrolledClipView(clipView)
        }

        let windowHeight = scrollHeight
            + classicMetrics.contentInsets.top
            + classicMetrics.contentInsets.bottom

        let origin = frame.origin
        setFrame(NSRect(x: origin.x, y: origin.y,
                        width: classicMetrics.bubbleSize.width, height: windowHeight),
                 display: true)
    }

    private func makeLabel(index: Int, word: String, isSelected: Bool) -> NSTextField {
        let prefix = index < 9 ? "\(index + 1). " : "   "
        let label = NSTextField(labelWithString: "\(prefix)\(word)")
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = isSelected ? .white : .controlTextColor
        label.drawsBackground = isSelected
        label.backgroundColor = isSelected ? .controlAccentColor : .clear
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.heightAnchor.constraint(equalToConstant: rowHeight),
            label.widthAnchor.constraint(equalToConstant: windowWidth - padding * 2),
        ])
        if isSelected {
            label.wantsLayer = true
            label.layer?.cornerRadius = 3
        }
        return label
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let windowFrame = frame
        initialLocation = convertPoint(toScreen: event.locationInWindow)
        initialLocation.x -= windowFrame.origin.x
        initialLocation.y -= windowFrame.origin.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let windowFrame = frame

        let currentLocation = convertPoint(toScreen: event.locationInWindow)
        var newOrigin = NSPoint(x: currentLocation.x - initialLocation.x,
                                y: currentLocation.y - initialLocation.y)

        if newOrigin.y + windowFrame.height > screenFrame.origin.y + screenFrame.height {
            newOrigin.y = screenFrame.origin.y + screenFrame.height - windowFrame.height
        }

        setFrameOrigin(newOrigin)
    }
}

// MARK: - Testable Position Calculator

struct CandidateWindowPositioner {
    enum LineRectSource: Equatable {
        case reported
        /// A usable rect that `StaleCaretRectDetector` identified as the stale
        /// rect of a web editor; the last real caret rect is used (ADR-038).
        case repeatedStale
        case previousValid
        case mouseLocation
    }

    struct LineRectResolution: Equatable {
        let lineRect: NSRect
        let source: LineRectSource
    }

    /// Resolve an IMK-reported cursor rect into a usable screen-coordinate rect.
    ///
    /// Some clients (notably browser-based editors) return a local view coordinate near
    /// the window origin, such as `(13.75, 12.0, 1.0, 17.5)`, instead of a screen rect.
    /// Treat those origin-like tiny rects as suspicious and fall back to the last known
    /// good rect, or finally the current mouse location.
    static func resolveLineRect(
        reportedLineRect: NSRect,
        previousValidLineRect: NSRect?,
        mouseLocation: NSPoint,
        defaultLineHeight: CGFloat = 20,
        staleReplacement: NSRect? = nil
    ) -> LineRectResolution {
        if isUsableReportedLineRect(reportedLineRect) {
            if let staleReplacement {
                return LineRectResolution(lineRect: staleReplacement, source: .repeatedStale)
            }
            return LineRectResolution(lineRect: reportedLineRect, source: .reported)
        }

        if let previousValidLineRect {
            return LineRectResolution(lineRect: previousValidLineRect, source: .previousValid)
        }

        let height = reportedLineRect.height.isFinite && reportedLineRect.height > 0
            ? reportedLineRect.height
            : defaultLineHeight
        let fallbackRect = NSRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: height)
        return LineRectResolution(lineRect: fallbackRect, source: .mouseLocation)
    }

    static func isUsableReportedLineRect(_ lineRect: NSRect) -> Bool {
        guard lineRect.origin.x.isFinite,
              lineRect.origin.y.isFinite,
              lineRect.size.width.isFinite,
              lineRect.size.height.isFinite,
              !lineRect.isEmpty,
              lineRect.height > 0 else {
            return false
        }

        // Browser/WebView clients can report local coordinates near the origin instead
        // of screen coordinates. A 1px-wide caret rect at the lower-left origin is the
        // signature observed in Issue #10.
        let looksLikeClientLocalOriginRect = lineRect.minX >= 0
            && lineRect.minY >= 0
            && lineRect.minX < 64
            && lineRect.minY < 64
            && lineRect.width <= 2
            && lineRect.height >= 8
            && lineRect.height <= 40

        return !looksLikeClientLocalOriginRect
    }

    struct Placement: Equatable {
        let origin: NSPoint
        /// Where the classic bubble's tail should point; `.down` when flipped above the caret.
        let tail: BubbleTailDirection
    }

    /// Horizontal offset of the classic window so the bubble's tail tip sits on the caret.
    static let classicTailTipOffsetX: CGFloat = 16

    /// Calculate the window origin given cursor rect, window size, screen bounds, and display mode.
    ///
    /// - Parameters:
    ///   - lineRect: The cursor line rectangle in screen coordinates (macOS Y-up: origin.y = bottom of line).
    ///   - winSize: The candidate window size.
    ///   - screenFrame: The visible screen frame.
    ///   - mode: The current display mode.
    /// - Returns: The bottom-left origin point for the window.
    static func calculate(
        lineRect: NSRect,
        winSize: NSSize,
        screenFrame: NSRect,
        mode: CandidateDisplayMode
    ) -> NSPoint {
        place(lineRect: lineRect, winSize: winSize, screenFrame: screenFrame, mode: mode).origin
    }

    /// `calculate` plus which way the classic bubble's tail must point.
    static func place(
        lineRect: NSRect,
        winSize: NSSize,
        screenFrame: NSRect,
        mode: CandidateDisplayMode
    ) -> Placement {
        let gap: CGFloat = mode == .list ? 5 : 0
        var tail = BubbleTailDirection.up

        // Default: place window below cursor
        var y = lineRect.origin.y - winSize.height - gap

        // Flip above cursor if window would go below screen bottom
        if y < screenFrame.minY {
            y = lineRect.origin.y + lineRect.height + gap
            tail = .down
        }

        // Keep the window vertically on the target screen as much as possible.
        if y + winSize.height > screenFrame.maxY {
            y = screenFrame.maxY - winSize.height
        }
        if y < screenFrame.minY {
            y = screenFrame.minY
        }

        // X position: list mode sits slightly left of the caret; classic mode puts the tail tip on it
        var x = lineRect.origin.x - (mode == .list ? 5 : classicTailTipOffsetX)

        // Clamp to screen right edge
        if x + winSize.width > screenFrame.maxX {
            x = screenFrame.maxX - winSize.width
        }

        // Clamp to screen left edge
        if x < screenFrame.minX {
            x = screenFrame.minX
        }

        return Placement(origin: NSPoint(x: x, y: y), tail: tail)
    }
}
