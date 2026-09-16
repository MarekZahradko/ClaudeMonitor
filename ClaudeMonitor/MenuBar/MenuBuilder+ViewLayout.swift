import AppKit

/// Payload for the compact account switcher embedded in the Usage header: the (already truncated)
/// segment labels, which one is active, and what to do when a segment is chosen.
@MainActor
struct HeaderAccountSwitcher {
    let names: [String]
    let activeIndex: Int
    let onSelect: (Int) -> Void
}

extension MenuBuilder {
    /// Horizontal inset the dropdown's rows line up on — the header labels, the control row and the
    /// stats row all use it, so a row that picks its own number visibly steps out of the column.
    static let rowTrailingInset: CGFloat = 14

    static let maxDisplayLength = 40
    static let truncatedPrefixLength = 30
    /// Account names in the header switcher are kept short so two of them fit centered in the row.
    static let switcherNameMaxLength = 14

    /// Both header labels share one shade — the section word ("Usage", "Services") and the trailing
    /// text ("Claude Monitor", "All systems operational") read as a single row. They used to sit on
    /// `disabledControlTextColor` and `tertiaryLabelColor`, which rendered them near-invisible and
    /// mismatched against each other.
    static let headerTextColor = NSColor.secondaryLabelColor

    private static let headerHeight: CGFloat = 22
    /// Minimum clearance kept between the header's labels and the toggle floating between them.
    private static let headerToggleClearance: CGFloat = 20

    static func makeHeaderView(title: String, subtitle: String, switcher: HeaderAccountSwitcher? = nil) -> NSView {
        let left = headerLabel(title)
        let right = headerLabel(subtitle)
        right.autoresizingMask = .minXMargin
        let toggle = switcher.map { makeAccountToggle($0) }
        let width = headerMinWidth(left: left, right: right, toggle: toggle)
        return assembleHeader(width: width, left: left, right: right, toggle: toggle)
    }

    private static func headerLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = headerTextColor
        label.sizeToFit()
        return label
    }

    private static func makeAccountToggle(_ switcher: HeaderAccountSwitcher) -> AccountToggleView {
        let control = AccountToggleView(frame: .zero)
        control.configure(names: switcher.names, selectedIndex: switcher.activeIndex)
        control.onSelect = switcher.onSelect
        control.autoresizingMask = [.minXMargin, .maxXMargin]
        return control
    }

    /// The width at which a centered toggle still clears both labels. The real menu is usually
    /// wider than this, and the toggle floats centered inside whatever width it gets.
    private static func headerMinWidth(
        left: NSTextField, right: NSTextField, toggle: AccountToggleView?
    ) -> CGFloat {
        let toggleWidth = toggle?.fittingSize.width ?? 0
        let reserve = toggleWidth > 0 ? toggleWidth + headerToggleClearance : 0
        return rowTrailingInset + left.frame.width + headerToggleClearance
            + reserve + right.frame.width + rowTrailingInset
    }

    private static func assembleHeader(
        width: CGFloat, left: NSTextField, right: NSTextField, toggle: AccountToggleView?
    ) -> NSView {
        left.frame.origin = NSPoint(x: rowTrailingInset, y: centeredY(forHeight: left.frame.height))
        right.frame.origin = NSPoint(
            x: width - rowTrailingInset - right.frame.width,
            y: centeredY(forHeight: right.frame.height)
        )

        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: headerHeight))
        view.autoresizingMask = .width
        view.addSubview(left)
        view.addSubview(right)

        if let toggle {
            let size = toggle.fittingSize
            toggle.frame = NSRect(
                x: (width - size.width) / 2, y: centeredY(forHeight: size.height),
                width: size.width, height: size.height
            )
            view.addSubview(toggle)
        }
        return view
    }

    private static func centeredY(forHeight height: CGFloat) -> CGFloat {
        (headerHeight - height) / 2
    }

    static func sectionHeader(_ title: String, subtitle: String? = nil, tag: Int, switcher: HeaderAccountSwitcher? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.tag = tag
        if let subtitle {
            item.view = makeHeaderView(title: title, subtitle: subtitle, switcher: switcher)
        }
        return item
    }

    static func staticItem(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.tag = tag
        return item
    }

    static func separator(tag: Int) -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.tag = tag
        return item
    }

    static func truncatedName(_ name: String) -> String {
        name.count > maxDisplayLength ? String(name.prefix(truncatedPrefixLength)).trimmingCharacters(in: .whitespaces) + "…" : name
    }
}
