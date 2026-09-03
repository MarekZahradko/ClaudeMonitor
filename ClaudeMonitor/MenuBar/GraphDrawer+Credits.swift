import AppKit

extension GraphDrawer {
    /// The on-screen geometry of a single visible credit event's marker — computed
    /// independently of any actual drawing so it can be unit-tested without a screen (see
    /// `xPosition`/`yPosition`, GraphDrawer's own coordinate helpers).
    struct CreditMarker: Equatable {
        let x: CGFloat
        let yFrom: CGFloat
        let yTo: CGFloat
    }

    /// Filters `events` down to the ones falling inside `timeRange` and resolves each to plot
    /// coordinates. An event whose `at` falls outside the visible range is dropped entirely,
    /// never clamped to an edge — clamping would misrepresent when the credit actually
    /// happened.
    func visibleCreditMarkers(in rect: NSRect, timeRange: ClosedRange<Date>) -> [CreditMarker] {
        events.filter { timeRange.contains($0.at) }.map { event in
            CreditMarker(
                x: xPosition(for: event.at, in: rect, timeRange: timeRange),
                yFrom: yPosition(for: Double(event.from), in: rect),
                yTo: yPosition(for: Double(event.to), in: rect)
            )
        }
    }

    /// Renders every mid-window usage credit (`UsageEvent`, see `UsageHistory.swift`) as an
    /// explicit event marker: a full-height dashed vertical line, a vertical step at the drop
    /// itself (never an interpolated decline), and a filled dot at the landing value.
    func drawCreditEvents(in rect: NSRect, timeRange: ClosedRange<Date>) {
        for marker in visibleCreditMarkers(in: rect, timeRange: timeRange) {
            drawCreditLine(at: marker.x, in: rect)
            drawCreditStep(at: marker.x, yFrom: marker.yFrom, yTo: marker.yTo)
            drawCreditMarker(at: marker.x, y: marker.yTo)
        }
    }

    private func drawCreditLine(at x: CGFloat, in rect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = Layout.creditLineWidth
        path.setLineDash(Layout.creditLineDashPattern, count: Layout.creditLineDashPattern.count, phase: 0)
        Layout.creditColor.withAlphaComponent(Layout.creditLineAlpha).setStroke()
        path.move(to: NSPoint(x: x, y: rect.minY))
        path.line(to: NSPoint(x: x, y: rect.maxY))
        path.stroke()
    }

    /// Draws the drop itself as a solid vertical segment between the pre-credit and
    /// post-credit utilization — a deliberate step, never blended into the curve's
    /// interpolated line, so it cannot read as gradual usage reduction.
    private func drawCreditStep(at x: CGFloat, yFrom: CGFloat, yTo: CGFloat) {
        guard yFrom != yTo else { return }
        let path = NSBezierPath()
        path.lineWidth = Layout.creditStepWidth
        Layout.creditColor.setStroke()
        path.move(to: NSPoint(x: x, y: yFrom))
        path.line(to: NSPoint(x: x, y: yTo))
        path.stroke()
    }

    private func drawCreditMarker(at x: CGFloat, y: CGFloat) {
        let radius = Layout.creditDotRadius
        let dotRect = NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        let dot = NSBezierPath(ovalIn: dotRect)
        Layout.creditColor.setFill()
        dot.fill()
    }
}
