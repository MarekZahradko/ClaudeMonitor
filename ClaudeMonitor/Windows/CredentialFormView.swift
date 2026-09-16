import AppKit

@MainActor
final class CredentialFormView: NSView {
    private let nameField = NSTextField()
    private let orgIdField = NSTextField()
    private let cookieTextView = NSTextView()
    private let cookieScrollView = NSScrollView()

    private let profileStore: ProfileStore
    /// The profile this form edits, or `nil` for the add form (creates a new profile).
    private let profileId: String?

    init(profileStore: ProfileStore, profileId: String? = nil) {
        self.profileStore = profileStore
        self.profileId = profileId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The profile this form edits — resolved from `profileId`; `nil` means add mode.
    private var editingProfile: Profile? {
        guard let profileId else { return nil }
        return profileStore.profiles.first { $0.id == profileId }
    }

    func loadSavedValues() {
        if let profile = editingProfile {
            nameField.stringValue = profile.name
            orgIdField.stringValue = profile.organizationId
            cookieTextView.string = profileStore.cookie(for: profile) ?? ""
        } else {
            nameField.stringValue = ""
            orgIdField.stringValue = ""
            cookieTextView.string = ""
        }
    }

    /// Validates and persists the form. Returns the saved profile's id on success (the existing id
    /// when editing, the newly-created id when adding), or `nil` on any validation/save failure.
    @discardableResult
    func validateAndSave(in window: NSWindow) -> String? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = cookieTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let orgId = orgIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !cookie.isEmpty, !orgId.isEmpty else {
            showAlert(
                in: window,
                title: String(localized: "credentials.alert.missing.title", bundle: .module),
                message: String(localized: "credentials.alert.missing.message", bundle: .module),
                style: .warning
            )
            return nil
        }

        guard UUID(uuidString: orgId) != nil else {
            showAlert(
                in: window,
                title: String(localized: "credentials.alert.invalid_org.title", bundle: .module),
                message: String(localized: "credentials.alert.invalid_org.message", bundle: .module),
                style: .warning
            )
            return nil
        }

        do {
            if let profile = editingProfile {
                try profileStore.updateProfile(id: profile.id, name: name, organizationId: orgId, cookie: cookie)
                return profile.id
            } else {
                let created = try profileStore.addProfile(name: name, organizationId: orgId, cookie: cookie)
                // The first-ever profile must become active, or nothing would be monitored.
                if profileStore.activeProfile == nil {
                    profileStore.setActive(id: created.id)
                }
                return created.id
            }
        } catch ProfileStoreError.duplicateOrganization {
            showAlert(
                in: window,
                title: String(localized: "credentials.alert.duplicate_org.title", bundle: .module),
                message: String(localized: "credentials.alert.duplicate_org.message", bundle: .module),
                style: .warning
            )
            return nil
        } catch {
            showAlert(
                in: window,
                title: String(localized: "credentials.alert.save_failed.title", bundle: .module),
                message: String(localized: "credentials.alert.save_failed.message", bundle: .module),
                style: .critical
            )
            return nil
        }
    }

    private func showAlert(in window: NSWindow, title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: String(localized: "credentials.alert.ok", bundle: .module))
        alert.beginSheetModal(for: window)
    }

    private func setupSubviews() {
        let nameLabel = NSTextField(labelWithString: String(localized: "credentials.field.name", bundle: .module))
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = String(localized: "credentials.field.name_placeholder", bundle: .module)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let orgInstructions = CredentialGuide.makeView(CredentialGuide.orgInstructions(), height: 105)

        let orgIdLabel = NSTextField(labelWithString: String(localized: "credentials.field.org_id", bundle: .module))
        orgIdLabel.translatesAutoresizingMaskIntoConstraints = false

        orgIdField.placeholderString = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        orgIdField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        orgIdField.translatesAutoresizingMaskIntoConstraints = false

        let cookieInstructions = CredentialGuide.makeView(CredentialGuide.cookieInstructions(), height: 16)

        let cookieLabel = NSTextField(labelWithString: String(localized: "credentials.field.cookie", bundle: .module))
        cookieLabel.translatesAutoresizingMaskIntoConstraints = false

        cookieScrollView.hasVerticalScroller = true
        cookieScrollView.borderType = .bezelBorder
        cookieScrollView.translatesAutoresizingMaskIntoConstraints = false
        cookieTextView.isEditable = true
        cookieTextView.isSelectable = true
        cookieTextView.isRichText = false
        cookieTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cookieTextView.isAutomaticQuoteSubstitutionEnabled = false
        cookieTextView.isAutomaticDashSubstitutionEnabled = false
        cookieTextView.isAutomaticTextReplacementEnabled = false
        cookieTextView.textContainer?.widthTracksTextView = true
        cookieTextView.autoresizingMask = [.width]
        cookieScrollView.documentView = cookieTextView

        for view in [nameLabel, nameField, orgInstructions, orgIdLabel, orgIdField, cookieInstructions, cookieLabel, cookieScrollView] as [NSView] {
            addSubview(view)
        }

        activateConstraints(nameLabel: nameLabel, orgInstructions: orgInstructions, orgIdLabel: orgIdLabel, cookieInstructions: cookieInstructions, cookieLabel: cookieLabel)
    }

    private func activateConstraints(nameLabel: NSView, orgInstructions: NSView, orgIdLabel: NSView, cookieInstructions: NSView, cookieLabel: NSView) {
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),

            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),

            orgInstructions.leadingAnchor.constraint(equalTo: leadingAnchor),
            orgInstructions.trailingAnchor.constraint(equalTo: trailingAnchor),
            orgInstructions.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),

            orgIdLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            orgIdLabel.topAnchor.constraint(equalTo: orgInstructions.bottomAnchor, constant: 10),

            orgIdField.leadingAnchor.constraint(equalTo: leadingAnchor),
            orgIdField.trailingAnchor.constraint(equalTo: trailingAnchor),
            orgIdField.topAnchor.constraint(equalTo: orgIdLabel.bottomAnchor, constant: 4),

            cookieInstructions.leadingAnchor.constraint(equalTo: leadingAnchor),
            cookieInstructions.trailingAnchor.constraint(equalTo: trailingAnchor),
            cookieInstructions.topAnchor.constraint(equalTo: orgIdField.bottomAnchor, constant: 16),

            cookieLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            cookieLabel.topAnchor.constraint(equalTo: cookieInstructions.bottomAnchor, constant: 10),

            cookieScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cookieScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cookieScrollView.topAnchor.constraint(equalTo: cookieLabel.bottomAnchor, constant: 4),
            cookieScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            cookieScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
