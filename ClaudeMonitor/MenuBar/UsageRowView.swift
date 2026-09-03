import AppKit

// MARK: - UsageRowView

/// A custom NSView used as an NSMenuItem's view for usage rows.
/// Because `.view` is set on the menu item, NSMenu does NOT auto-close on click.
final class UsageRowView: NSView {
    private let textField: NSTextField
    var onClick: (() -> Void)?
    /// Hover / keyboard highlight, written only by `MenuBuilder.syncHighlight` from
    /// `NSMenuDelegate.menu(_:willHighlight:)` — AppKit decides which row is highlighted.
    ///
    /// The row deliberately keeps no tracking area of its own. A self-tracked flag gets stuck
    /// on: AppKit delivers no `mouseExited` when the menu closes under the cursor or when the
    /// row is clicked, and `reconcile` reuses these views for the life of the app, so the stale
    /// highlight then reappears the next time the menu opens — alongside the row actually being
    /// hovered. `NSMenuItem.isHighlighted` is not KVO-compliant either (an observer on it never
    /// fires), which leaves the delegate callback as the one signal a view-based row can trust.
    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
        }
    }
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private static let selectionBarWidth: CGFloat = 3
    private static let leftPadding: CGFloat = 17  // standard menu item left margin
    private static let rightPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 3

    private static func requiredWidth(for attributedTitle: NSAttributedString) -> CGFloat {
        attributedTitle.size().width + leftPadding + rightPadding + selectionBarWidth
    }

    init(attributedTitle: NSAttributedString) {
        textField = NSTextField(labelWithAttributedString: attributedTitle)
        textField.isSelectable = false
        let textSize = attributedTitle.size()
        let height = textSize.height + UsageRowView.verticalPadding * 2
        let width = UsageRowView.requiredWidth(for: attributedTitle)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textField.frame = NSRect(
            x: UsageRowView.leftPadding + UsageRowView.selectionBarWidth,
            y: UsageRowView.verticalPadding,
            width: textSize.width + UsageRowView.rightPadding,
            height: textSize.height
        )
        autoresizingMask = .width
        addSubview(textField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func keyDown(with event: NSEvent) {
        // Do NOT call cancelTracking() — mouse clicks don't close the menu either.
        if let chars = event.charactersIgnoringModifiers, chars == "\r" || chars == " " {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Grows the row to fit `attributedTitle`, never shrinks it: the width reserved for the
    /// widest countdown text has to survive live updates, and the menu stretches the row to the
    /// full row width once it lays the item out.
    func ensureFrameWidth(for attributedTitle: NSAttributedString) {
        let needed = UsageRowView.requiredWidth(for: attributedTitle)
        guard needed > frame.size.width else { return }
        textField.frame.size.width += needed - frame.size.width
        frame.size.width = needed
    }

    func updateTitle(_ attributedTitle: NSAttributedString) {
        textField.attributedStringValue = attributedTitle
        textField.frame.size.width = attributedTitle.size().width + UsageRowView.rightPadding
        ensureFrameWidth(for: attributedTitle)
    }

    /// Returns the current attributed title of the row.
    var currentAttributedTitle: NSAttributedString { textField.attributedStringValue }

    /// Returns the plain string content of the row (for testing).
    var textContent: String { textField.attributedStringValue.string }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }
        if isSelected {
            NSColor.controlAccentColor.setFill()
            NSRect(x: UsageRowView.leftPadding, y: 0,
                   width: UsageRowView.selectionBarWidth, height: bounds.height).fill()
        }
    }
}
