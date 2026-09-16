import AppKit

/// Compact segmented account switcher embedded in the middle of the Usage section header, one
/// segment per account, active pre-selected. Selecting a segment reports the chosen index via
/// `onSelect`; the menu builder maps that back to a profile id and drives the switch. Deliberately
/// small (`.small` control size) so it sits inside the header row without disturbing the layout.
@MainActor
final class AccountToggleView: NSView {
    private let segmented = NSSegmentedControl()
    var onSelect: ((Int) -> Void)?
    /// The segment labels currently installed — lets the reconciler tell "same accounts, only the
    /// selection changed" (update in place) from "the account set changed" (rebuild the header).
    private(set) var currentLabels: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        segmented.controlSize = .small
        segmented.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        segmented.segmentDistribution = .fit
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: trailingAnchor),
            segmented.topAnchor.constraint(equalTo: topAnchor),
            segmented.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(names: [String], selectedIndex: Int) {
        if currentLabels != names {
            segmented.segmentCount = names.count
            for (index, name) in names.enumerated() {
                segmented.setLabel(name, forSegment: index)
            }
            currentLabels = names
        }
        if names.indices.contains(selectedIndex) {
            segmented.selectedSegment = selectedIndex
        }
    }

    @objc private func segmentChanged() {
        onSelect?(segmented.selectedSegment)
    }
}
