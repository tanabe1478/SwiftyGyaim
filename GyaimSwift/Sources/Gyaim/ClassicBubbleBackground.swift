import Cocoa

// MARK: - Classic Background View

/// Which way the classic bubble's tail points: up when the window sits below
/// the caret (the original art), down when it was flipped above the caret.
enum BubbleTailDirection: Equatable {
    case up
    case down
}

struct ClassicBubbleMetrics {
    let bubbleSize = NSSize(width: 241, height: 126)
    /// Insets with the tail on top (the art as drawn). Flipped, top and bottom swap.
    let contentInsets = NSEdgeInsets(top: 27, left: 20, bottom: 20, right: 20)
    /// Distance from the bubble's left edge to the tail tip in candwin.png.
    static let tailTipOffsetX: CGFloat = 16

    func contentInsets(tail: BubbleTailDirection) -> NSEdgeInsets {
        switch tail {
        case .up: return contentInsets
        case .down: return NSEdgeInsets(top: contentInsets.bottom, left: contentInsets.left,
                                        bottom: contentInsets.top, right: contentInsets.right)
        }
    }
    let topCapHeight: CGFloat = 27
    let bottomCapHeight: CGFloat = 20

    var topSliceHeight: CGFloat { topCapHeight }
    var bottomSliceHeight: CGFloat { bottomCapHeight }
    var centerSliceHeight: CGFloat {
        bubbleSize.height - topSliceHeight - bottomSliceHeight
    }
    var minimumContentHeight: CGFloat {
        bubbleSize.height - contentInsets.top - contentInsets.bottom
    }
}

/// Draws the original bubble art with a stretchable middle section only.
final class ClassicBackgroundView: NSView {
    private let metrics: ClassicBubbleMetrics
    var tailDirection: BubbleTailDirection = .up {
        didSet { if tailDirection != oldValue { needsDisplay = true } }
    }
    private let bubbleImage: NSImage? = {
        if let img = NSImage(named: "candwin") { return img }
        // Bundle.main is the app; in unit tests it is the xctest runner, so also
        // look next to this class (the test bundle copies Resources too).
        for bundle in [Bundle.main, Bundle(for: ClassicBackgroundView.self)] {
            if let url = bundle.url(forResource: "candwin", withExtension: "png"),
               let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }()

    init(metrics: ClassicBubbleMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = bubbleImage, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if tailDirection == .down {
            // Mirror the art vertically so the tail at its top points down.
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        for (destination, source) in slices(for: bounds) {
            image.draw(in: destination, from: source, operation: .sourceOver, fraction: 1.0)
        }
    }

    /// Top and bottom caps are drawn at their native height; only the middle stretches.
    func slices(for bounds: NSRect) -> [(destination: NSRect, source: NSRect)] {
        let size = metrics.bubbleSize
        let top = metrics.topSliceHeight
        let bottom = metrics.bottomSliceHeight
        let stretchedCenterHeight = max(bounds.height - top - bottom, 0)
        return [
            (NSRect(x: 0, y: 0, width: bounds.width, height: bottom),
             NSRect(x: 0, y: 0, width: size.width, height: bottom)),
            (NSRect(x: 0, y: bottom, width: bounds.width, height: stretchedCenterHeight),
             NSRect(x: 0, y: bottom, width: size.width, height: metrics.centerSliceHeight)),
            (NSRect(x: 0, y: bounds.height - top, width: bounds.width, height: top),
             NSRect(x: 0, y: size.height - top, width: size.width, height: top)),
        ]
    }
}

// MARK: - Tail direction

extension CandidateWindow {
    /// Point the classic bubble's tail at the caret: up when the window is below
    /// the caret, down when the positioner flipped it above. The art is mirrored
    /// vertically and the content insets swap so the text keeps clear of the tail.
    func setBubbleTail(_ direction: BubbleTailDirection) {
        guard direction != bubbleTailDirection else { return }
        bubbleTailDirection = direction
        let insets = classicMetrics.contentInsets(tail: direction)
        classicTopInsetConstraint?.constant = insets.top
        classicBottomInsetConstraint?.constant = -insets.bottom
        classicBackgroundView?.tailDirection = direction
    }

    /// Content insets currently applied in classic mode (for tests).
    var classicContentInsets: NSEdgeInsets { classicMetrics.contentInsets(tail: bubbleTailDirection) }

    /// Background fills the container; the white content area matches the original
    /// XIB ({{20, 20}, {200, 79}} in a 241x126 bubble) and its top/bottom insets swap
    /// with the tail direction, so those two constraints are kept.
    func makeClassicConstraints(bgView: NSView, contentView: NSView,
                                        scrollView: NSView) -> [NSLayoutConstraint] {
        let topInset = contentView.topAnchor.constraint(
            equalTo: containerView.topAnchor, constant: classicMetrics.contentInsets.top)
        let bottomInset = contentView.bottomAnchor.constraint(
            equalTo: containerView.bottomAnchor, constant: -classicMetrics.contentInsets.bottom)
        classicTopInsetConstraint = topInset
        classicBottomInsetConstraint = bottomInset
        return [
            bgView.topAnchor.constraint(equalTo: containerView.topAnchor),
            bgView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bgView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            topInset,
            contentView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor,
                                                 constant: classicMetrics.contentInsets.left),
            contentView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor,
                                                  constant: -classicMetrics.contentInsets.right),
            bottomInset,
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ]
    }
}
