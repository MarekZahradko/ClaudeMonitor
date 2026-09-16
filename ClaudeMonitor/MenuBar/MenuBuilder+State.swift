import AppKit

extension MenuBuilder {
    @discardableResult
    static func populate(menu: NSMenu, state: MonitorState, target: any MenuActions) -> UsageCache {
        let (desired, cache) = buildDesiredItems(state: state, target: target)
        if menu.numberOfItems == 0 {
            for item in desired { menu.addItem(item) }
        } else {
            reconcile(menu: menu, desired: desired)
            if let usageHeaderItem = menu.item(withTag: usageSectionTag) {
                let usageTitle = String(localized: "menu.section.usage", bundle: .module)
                let switcher = accountSwitcher(state: state, target: target)
                if state.polling.isAnyServiceStale {
                    if usageHeaderItem.view != nil { usageHeaderItem.view = nil }
                } else if let toggle = findAccountToggle(in: usageHeaderItem.view),
                          let switcher, toggle.currentLabels == switcher.names {
                    // Same accounts, only the active one may have changed — update the selection in
                    // place. Rebuilding the header view here would re-measure and shift the open menu.
                    toggle.configure(names: switcher.names, selectedIndex: switcher.activeIndex)
                } else {
                    usageHeaderItem.view = makeHeaderView(title: usageTitle, subtitle: "Claude Monitor", switcher: switcher)
                }
            }
            if let servicesHeaderItem = menu.item(withTag: servicesSectionTag) {
                let servicesTitle = String(localized: "menu.section.services", bundle: .module)
                let comps = state.service.currentStatus?.components ?? []
                let allOp = !comps.isEmpty && comps.allSatisfy { $0.status == .operational }
                if state.compactServices && allOp {
                    servicesHeaderItem.view = makeHeaderView(title: servicesTitle, subtitle: String(localized: "services.all_operational", bundle: .module))
                } else if servicesHeaderItem.view != nil {
                    servicesHeaderItem.view = nil
                }
            }
            if state.polling.isAnyServiceStale,
               let bannerItem = menu.item(withTag: connectivityBannerTag) {
                let bannerText = bannerItem.title
                bannerItem.view = makeHeaderView(title: bannerText, subtitle: "Claude Monitor")
            }
        }
        refreshGraph(in: menu, analyses: state.usage.windowAnalyses)
        return cache
    }

    static func buildDesiredItems(state: MonitorState, target: any MenuActions) -> ([NSMenuItem], UsageCache) {
        var items: [NSMenuItem] = []

        if state.polling.isAnyServiceStale {
            let bannerText = state.polling.isOnline
                ? String(localized: "connectivity.connectionError", bundle: .module)
                : String(localized: "connectivity.offline", bundle: .module)
            let bannerItem = NSMenuItem(title: bannerText, action: nil, keyEquivalent: "")
            bannerItem.isEnabled = false
            bannerItem.tag = connectivityBannerTag
            bannerItem.view = makeHeaderView(title: bannerText, subtitle: "Claude Monitor")
            items.append(bannerItem)
            items.append(separator(tag: separatorAfterConnectivityTag))
        }

        let usageSubtitle = state.polling.isAnyServiceStale ? nil : "Claude Monitor"
        items.append(sectionHeader(String(localized: "menu.section.usage", bundle: .module), subtitle: usageSubtitle, tag: usageSectionTag, switcher: accountSwitcher(state: state, target: target)))
        let (usageMenuItems, cache) = usageItems(state: state, target: target)
        items.append(contentsOf: usageMenuItems)


        if state.showGraph {
            items.append(usageGraphPlaceholder())
        }
        items.append(separator(tag: separatorAfterUsageTag))

        let components = state.service.currentStatus?.components ?? []
        let allOperational = !components.isEmpty && components.allSatisfy { $0.status == .operational }
        let servicesSubtitle = (state.compactServices && allOperational)
            ? String(localized: "services.all_operational", bundle: .module) : nil
        items.append(sectionHeader(String(localized: "menu.section.services", bundle: .module), subtitle: servicesSubtitle, tag: servicesSectionTag))
        items.append(contentsOf: serviceItems(state: state))

        if let incidents = state.service.currentStatus?.incidents, !incidents.isEmpty {
            items.append(separator(tag: separatorIncidentsTag))
            items.append(sectionHeader(String(localized: "menu.section.incidents", bundle: .module), tag: incidentsSectionTag))
            for (index, incident) in incidents.enumerated() {
                items.append(incidentItem(incident: incident, tag: incidentBaseTag + index, target: target))
            }
        }

        items.append(separator(tag: separatorAfterServicesTag))
        items.append(contentsOf: controlItems(state: state))

        // The action items (Refresh / Preferences / About / Quit) live in a native submenu behind a
        // "⋯" row — a status-bar dropdown reliably expands a submenu item, unlike a button popping
        // its own menu from inside the tracking menu.
        items.append(separator(tag: separatorControlsTag))
        items.append(footerActionsItem(target: target))

        return (items, cache)
    }

    static func refreshGraph(in menu: NSMenu, analyses: [WindowAnalysis]) {
        guard let item = menu.item(withTag: usageGraphTag),
              let graphView = item.view as? UsageGraphView else { return }
        graphView.update(analyses: analyses)
        syncUsageCheckmarks(in: menu, selectedIndex: graphView.currentSelectedIndex)
    }

    static func refreshTimes(in menu: NSMenu, cache: UsageCache) {
        for (tag, _, window) in cache.labels {
            guard let resetsAt = window?.resetsAt,
                  let prefix = cache.prefixes[tag],
                  let item = menu.item(withTag: tag) else { continue }
            let text = appendTime(to: prefix, resetsAt: resetsAt, style: cache.style)
            if let rowView = item.view as? UsageRowView {
                rowView.updateTitle(text)
            } else {
                item.attributedTitle = text
            }
        }
    }

    static func serviceItems(state: MonitorState) -> [NSMenuItem] {
        guard let components = state.service.currentStatus?.components else {
            return [staticItem("  " + String(localized: "menu.loading", bundle: .module), tag: servicesPlaceholderTag)]
        }
        // Full mode: every component, a row each. Compact mode: nothing when all healthy (the
        // section header carries an "all operational" subtitle) and only the affected ones otherwise.
        let rows = state.compactServices ? components.filter { $0.status != .operational } : components
        return rows.sorted(by: { $0.name < $1.name }).enumerated().map { index, component in
            let name = truncatedName(component.name)
            return staticItem("  \(component.status.dot)  \(name)  –  \(component.status.label)",
                              tag: serviceBaseTag + index)
        }
    }

    static func incidentItem(incident: Incident, tag: Int, target: any MenuActions) -> NSMenuItem {
        let item = NSMenuItem(title: "  ⚠︎  \(incident.name)",
                              action: #selector(MenuActions.openIncident(_:)),
                              keyEquivalent: "")
        item.tag = tag
        item.target = target
        item.representedObject = incident.shortlink
        return item
    }
}
