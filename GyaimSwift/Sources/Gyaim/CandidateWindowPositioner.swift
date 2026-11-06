import Cocoa

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
