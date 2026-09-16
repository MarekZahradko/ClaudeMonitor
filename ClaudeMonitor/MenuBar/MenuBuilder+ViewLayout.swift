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
    static let maxDisplayLength = 40
    static let truncatedPrefixLength = 30
    /// Account names in the header switcher are kept short so two of them fit centered in the row.
    static let switcherNameMaxLength = 14

    /// Both header labels share one shade — the section word ("Usage", "Services") and the trailing
    /// text ("Claude Monitor", "All systems operational") read as a single row. They used to sit on
    /// `disabledControlTextColor` and `tertiaryLabelColor`, which rendered them near-invisible and
    /// mismatched against each other.
    static let headerTextColor = NSColor.secondaryLabelColor

    static func makeHeaderView(title: String, subtitle: String, switcher: HeaderAccountSwitcher? = nil) -> NSView {
        let font = NSFont.menuFont(ofSize: 0)
        let height: CGFloat = 22
        let edgePadding: CGFloat = 14

        let leftLabel = NSTextField(labelWithString: title)
        leftLabel.font = font
        leftLabel.textColor = headerTextColor
        leftLabel.sizeToFit()
        leftLabel.frame.origin = NSPoint(x: edgePadding, y: (height - leftLabel.frame.height) / 2)

        let rightLabel = NSTextField(labelWithString: subtitle)
        rightLabel.font = font
        rightLabel.textColor = headerTextColor
        rightLabel.sizeToFit()
        rightLabel.autoresizingMask = .minXMargin

        var toggle: AccountToggleView?
        var toggleSize = NSSize.zero
        if let switcher {
            let control = AccountToggleView(frame: .zero)
            control.configure(names: switcher.names, selectedIndex: switcher.activeIndex)
            control.onSelect = switcher.onSelect
            toggleSize = control.fittingSize
            control.autoresizingMask = [.minXMargin, .maxXMargin]
            toggle = control
        }

        // Ensure the row is wide enough that the centered toggle never overlaps either label at the
        // menu's minimum width; the real menu is usually wider and the toggle floats centered.
        let toggleReserve = toggleSize.width > 0 ? toggleSize.width + 20 : 0
        let minWidth = edgePadding + leftLabel.frame.width + 20 + toggleReserve + rightLabel.frame.width + edgePadding

        rightLabel.frame.origin = NSPoint(
            x: minWidth - edgePadding - rightLabel.frame.width,
            y: (height - rightLabel.frame.height) / 2
        )

        let view = NSView(frame: NSRect(x: 0, y: 0, width: minWidth, height: height))
        view.autoresizingMask = .width
        view.addSubview(leftLabel)
        view.addSubview(rightLabel)
        if let toggle {
            toggle.frame = NSRect(
                x: (minWidth - toggleSize.width) / 2,
                y: (height - toggleSize.height) / 2,
                width: toggleSize.width,
                height: toggleSize.height
            )
            view.addSubview(toggle)
        }
        return view
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
