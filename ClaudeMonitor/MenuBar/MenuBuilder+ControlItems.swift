import AppKit

extension MenuBuilder {
    static func controlItems(state: MonitorState, target: any MenuActions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if let date = state.lastRefreshed {
            let title = updatedNextTitle(lastRefreshed: date, interval: state.polling.currentPollInterval)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = updatedTag
            item.isEnabled = false
            item.view = ControlRowView(title: title)
            items.append(item)
        }

        if let item = historyHealthItem(state: state) {
            items.append(item)
        }

        items.append(separator(tag: separatorControlsTag))

        let refresh = NSMenuItem(title: String(localized: "menu.refresh", bundle: .module),
                                 action: #selector(MenuActions.didSelectRefresh),
                                 keyEquivalent: "r")
        refresh.tag = refreshTag
        refresh.target = target
        items.append(refresh)

        let prefs = NSMenuItem(title: String(localized: "menu.preferences", bundle: .module),
                               action: #selector(MenuActions.didSelectPreferences),
                               keyEquivalent: ",")
        prefs.tag = preferencesTag
        prefs.target = target
        items.append(prefs)

        let about = NSMenuItem(title: String(localized: "menu.about", bundle: .module),
                               action: #selector(MenuActions.didSelectAbout),
                               keyEquivalent: "")
        about.tag = aboutTag
        about.target = target
        items.append(about)

        items.append(separator(tag: separatorQuitTag))

        let quit = NSMenuItem(title: String(localized: "menu.quit", bundle: .module),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.tag = quitTag
        items.append(quit)

        return items
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
