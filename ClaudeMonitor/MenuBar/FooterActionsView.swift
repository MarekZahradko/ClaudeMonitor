import AppKit

/// One clickable icon in the dropdown's footer action bar. Uses the same `mouseUp` click path as
/// `UsageRowView` (which is proven to receive clicks inside a status-bar menu), triggering a direct
/// action — not a secondary menu, which AppKit refuses to open from inside a tracking menu.
@MainActor
final class FooterIconButton: NSView {
    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    init(symbol: String, help: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = help
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 26) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { imageView.contentTintColor = .labelColor }
    override func mouseExited(with event: NSEvent) { imageView.contentTintColor = .secondaryLabelColor }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
