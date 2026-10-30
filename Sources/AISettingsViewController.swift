import AppKit

/// Settings → AI: assistant model, API keys and server addresses.
final class AISettingsViewController: NSViewController, NSComboBoxDelegate {
    private let providerPopup = NSPopUpButton()
    private let modelCombo = NSComboBox()
    private let refreshButton = NSButton(title: "Load Models", target: nil, action: nil)
    private let modelStatus = NSTextField(wrappingLabelWithString: "")
    private let quickPicker = NSButton(checkboxWithTitle: "Show a model picker in the chat panel", target: nil, action: nil)
    private let customVision = NSButton(checkboxWithTitle: "The custom server's model can see images", target: nil, action: nil)
    private var keyFields: [ProviderKind: NSSecureTextField] = [:]
    private var urlFields: [ProviderKind: NSTextField] = [:]

    override func loadView() {
        for provider in ProviderKind.allCases {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        modelCombo.isEditable = true
        modelCombo.completes = true
        modelCombo.numberOfVisibleItems = 15
        modelCombo.delegate = self
        modelCombo.target = self
        modelCombo.action = #selector(modelChanged(_:))
        modelCombo.widthAnchor.constraint(equalToConstant: 260).isActive = true
        refreshButton.target = self
        refreshButton.action = #selector(loadModels(_:))
        refreshButton.bezelStyle = .rounded
        modelStatus.font = .systemFont(ofSize: 11)
        modelStatus.textColor = .secondaryLabelColor
        modelStatus.preferredMaxLayoutWidth = 380
        quickPicker.target = self
        quickPicker.action = #selector(quickPickerChanged(_:))
        customVision.target = self
        customVision.action = #selector(customVisionChanged(_:))

        var rows: [[NSView]] = [
            [label("Assistant:"), providerPopup],
            [label("Model:"), NSStackView(views: [modelCombo, refreshButton])],
            [NSGridCell.emptyContentView, modelStatus],
            [NSGridCell.emptyContentView, quickPicker],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [header("API Keys"), NSGridCell.emptyContentView],
        ]
        for provider in ProviderKind.allCases {
            let key = NSSecureTextField()
            key.placeholderString = provider.requiresKey ? "API key" : "API key (optional)"
            key.stringValue = AISettings.apiKey(for: provider) ?? ""
            key.target = self
            key.action = #selector(keyChanged(_:))
            key.cell?.sendsActionOnEndEditing = true
            key.tag = ProviderKind.allCases.firstIndex(of: provider)!
            key.widthAnchor.constraint(equalToConstant: 360).isActive = true
            keyFields[provider] = key
            rows.append([label("\(provider.displayName):"), key])
            if provider.hasEditableBaseURL {
                let url = NSTextField()
                url.placeholderString = provider.defaultBaseURL
                url.stringValue = provider == .custom || AISettings.baseURL(for: provider) != provider.defaultBaseURL
                    ? (UserDefaults.standard.string(forKey: "BaseURL.\(provider.rawValue)") ?? "") : ""
                url.target = self
                url.action = #selector(urlChanged(_:))
                url.cell?.sendsActionOnEndEditing = true
                url.tag = key.tag
                url.font = .systemFont(ofSize: 11)
                urlFields[provider] = url
                rows.append([label("Address:", small: true), url])
            }
        }
        rows.append([NSGridCell.emptyContentView, customVision])
        let note = NSTextField(wrappingLabelWithString:
            "Keys are stored in your macOS Keychain. Custom works with any OpenAI-compatible server (OpenRouter, Ollama, LM Studio…): set its address, then type its model name above.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        rows.append([NSGridCell.emptyContentView, note])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        view = container
        preferredContentSize = NSSize(width: 580, height: grid.fittingSize.height + 40)
        refresh()
    }

    private func label(_ text: String, small: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if small {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        return label
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private var selectedProvider: ProviderKind {
        (providerPopup.selectedItem?.representedObject as? String).flatMap(ProviderKind.init) ?? .anthropic
    }

    private func refresh() {
        let provider = AISettings.assistantProvider
        providerPopup.selectItem(at: ProviderKind.allCases.firstIndex(of: provider)!)
        modelCombo.stringValue = AISettings.model(for: provider)
        quickPicker.state = AISettings.showQuickPicker ? .on : .off
        customVision.state = AISettings.customSendsImages ? .on : .off
        updateModelStatus()
    }

    private func updateModelStatus(_ extra: String? = nil) {
        let choice = AISettings.assistant
        var text = AISettings.sendsImages(choice)
            ? "Sees the image you're viewing."
            : "Text-only: gets an on-device description of the image (objects, text) instead."
        if !AISettings.isConfigured(choice.provider) { text = "Add an API key for \(choice.provider.displayName) below. " + text }
        if let extra { text = extra + " " + text }
        modelStatus.stringValue = text
    }

    @objc private func providerChanged(_ sender: Any?) {
        AISettings.assistantProvider = selectedProvider
        modelCombo.removeAllItems()
        refresh()
    }

    @objc private func modelChanged(_ sender: Any?) {
        AISettings.setModel(modelCombo.stringValue, for: selectedProvider)
        updateModelStatus()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The combo box updates its string value after this notification.
        DispatchQueue.main.async { self.modelChanged(nil) }
    }

    @objc private func loadModels(_ sender: Any?) {
        let provider = selectedProvider
        guard let client = AISettings.client(for: provider) else {
            updateModelStatus("Add an API key first.")
            return
        }
        refreshButton.isEnabled = false
        modelStatus.stringValue = "Loading models…"
        Task {
            do {
                let models = try await client.listModels()
                AISettings.remember(models, for: provider)
                modelCombo.removeAllItems()
                modelCombo.addItems(withObjectValues: models.map(\.id))
                updateModelStatus("\(models.count) models available.")
            } catch {
                updateModelStatus("Couldn't load models: \(error.localizedDescription)")
            }
            refreshButton.isEnabled = true
        }
    }

    @objc private func quickPickerChanged(_ sender: NSButton) { AISettings.showQuickPicker = sender.state == .on }

    @objc private func customVisionChanged(_ sender: NSButton) {
        AISettings.customSendsImages = sender.state == .on
        updateModelStatus()
    }

    @objc private func keyChanged(_ sender: NSSecureTextField) {
        let provider = ProviderKind.allCases[sender.tag]
        guard sender.stringValue != (AISettings.apiKey(for: provider) ?? "") else { return }
        AISettings.setAPIKey(sender.stringValue, for: provider)
        updateModelStatus()
    }

    @objc private func urlChanged(_ sender: NSTextField) {
        AISettings.setBaseURL(sender.stringValue, for: ProviderKind.allCases[sender.tag])
        updateModelStatus()
    }
}
