import AppKit

extension MenuBuilder {
    /// The rows above the footer bar: the "Updated / Interval / Next" line and the history-health
    /// status. The action buttons themselves are `footerActionsItem`.
    static func controlItems(state: MonitorState) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if let date = state.lastRefreshed {
            let interval = state.polling.currentPollInterval
            let segments = updatedNextSegments(lastRefreshed: date, interval: interval)
            let item = NSMenuItem(title: segments.joined(separator: "        "), action: nil, keyEquivalent: "")
            item.tag = updatedTag
            item.isEnabled = false
            item.view = ControlRowView(segments: segments)
            items.append(item)
        }

        if let item = historyHealthItem(state: state) {
            items.append(item)
        }

        return items
    }

    /// The compact account switcher embedded in the Usage header, or `nil` with fewer than two
    /// accounts — there is nothing to toggle between. Selecting a segment drives `didSelectProfile`.
    static func accountSwitcher(state: MonitorState, target: any MenuActions) -> HeaderAccountSwitcher? {
        let profiles = state.profiles.profiles
        guard profiles.count >= 2 else { return nil }
        return HeaderAccountSwitcher(
            names: profiles.map { truncatedSwitcherName($0.name) },
            activeIndex: profiles.firstIndex { $0.id == state.profiles.activeId } ?? 0,
            onSelect: { [weak target] index in
                guard profiles.indices.contains(index) else { return }
                let sender = NSMenuItem()
                sender.representedObject = profiles[index].id
                target?.didSelectProfile(sender)
            }
        )
    }

    /// The dropdown's footer action bar: four evenly-spaced icon buttons — Refresh, Preferences,
    /// About, Quit — each firing its action directly on click.
    static func footerActionsItem(target: any MenuActions) -> NSMenuItem {
        let refresh = FooterIconButton(symbol: "arrow.clockwise", help: String(localized: "menu.refresh", bundle: .module))
        refresh.onClick = { [weak target] in target?.didSelectRefresh() }
        let prefs = FooterIconButton(symbol: "gearshape", help: String(localized: "menu.preferences", bundle: .module))
        prefs.onClick = { [weak target] in target?.didSelectPreferences() }
        let about = FooterIconButton(symbol: "info.circle", help: String(localized: "menu.about", bundle: .module))
        about.onClick = { [weak target] in target?.didSelectAbout() }
        let quit = FooterIconButton(symbol: "power", help: String(localized: "menu.quit", bundle: .module))
        quit.onClick = { NSApplication.shared.terminate(nil) }

        let stack = NSStackView(views: [refresh, prefs, about, quit])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        container.autoresizingMask = .width
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let item = NSMenuItem()
        item.tag = moreTag
        item.view = container
        return item
    }

    /// The overflow menu of the control actions — retained for wiring/documentation and tests.
    static func makeOverflowMenu(target: any MenuActions) -> NSMenu {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: String(localized: "menu.refresh", bundle: .module),
                                 action: #selector(MenuActions.didSelectRefresh), keyEquivalent: "r")
        refresh.tag = refreshTag
        refresh.target = target
        menu.addItem(refresh)

        let prefs = NSMenuItem(title: String(localized: "menu.preferences", bundle: .module),
                               action: #selector(MenuActions.didSelectPreferences), keyEquivalent: ",")
        prefs.tag = preferencesTag
        prefs.target = target
        menu.addItem(prefs)

        let about = NSMenuItem(title: String(localized: "menu.about", bundle: .module),
                               action: #selector(MenuActions.didSelectAbout), keyEquivalent: "")
        about.tag = aboutTag
        about.target = target
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "menu.quit", bundle: .module),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.tag = quitTag
        menu.addItem(quit)

        return menu
    }

    /// Finds the account toggle nested inside a header view, if present, so the reconciler can
    /// update its selection in place instead of rebuilding the whole header.
    static func findAccountToggle(in view: NSView?) -> AccountToggleView? {
        guard let view else { return nil }
        if let toggle = view as? AccountToggleView { return toggle }
        for subview in view.subviews {
            if let toggle = findAccountToggle(in: subview) { return toggle }
        }
        return nil
    }

    private static func truncatedSwitcherName(_ name: String) -> String {
        name.count > switcherNameMaxLength
            ? String(name.prefix(switcherNameMaxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : name
    }

    /// Status line reporting `UsageHistory`'s persistence-failure/quarantine state — `nil` when
    /// there is nothing to report (saving is succeeding and no files are quarantined), so it
    /// never appears as an empty row. Deliberately a plain disabled row, never an alert or sheet:
    /// this is ambient status, not something that should interrupt the user.
    static func historyHealthItem(state: MonitorState) -> NSMenuItem? {
        var lines: [String] = []
        if !state.history.lastSaveSucceeded, let since = state.history.persistenceFailingSince {
            let timeStr = Formatting.absoluteTime(since, .hourMinute)
            lines.append(String(format: String(localized: "menu.history.saveFailing", bundle: .module), timeStr))
        }
        if state.history.quarantinedFileCount > 0 {
            let template = String(localized: "menu.history.quarantinedCount", bundle: .module)
            lines.append(String(format: template, locale: .current, state.history.quarantinedFileCount))
        }
        guard !lines.isEmpty else { return nil }
        return staticItem("  ⚠︎  " + lines.joined(separator: "  ·  "), tag: historyHealthTag)
    }
}
