import AppKit

/// One line of the chat transcript.
struct ChatEntry {
    enum Kind { case user, assistant, note }
    var kind: Kind
    var text: String
    /// What is sent back to the model on later requests (nil for notes and for answers still streaming).
    var turn: ChatTurn?
    /// Shown under an answer: model and cost.
    var footer: String?
}

/// The conversation about one image.
final class Conversation {
    var entries: [ChatEntry] = []
    var turns: [ChatTurn] { entries.compactMap(\.turn) }
}

/// "Ask AI" side panel: chat about the image currently shown in the window.
final class ChatPanelController: NSViewController, NSTextFieldDelegate {
    var onOpenSettings: ((SettingsWindowController.Tab) -> Void)?

    private let modelPicker = NSPopUpButton()
    private let modelLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "Open AI Settings…", target: nil, action: nil)
    private let input = NSTextField()
    private let sendButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private var imageURL: URL?
    /// Conversations per image for this window, so going back to an image shows its chat again.
    private var conversations: [URL: Conversation] = [:]
    private var task: Task<Void, Never>?
    private var renderScheduled = false
    private var isStreaming: Bool { task != nil }

    private var conversation: Conversation? {
        guard let imageURL else { return nil }
        if let existing = conversations[imageURL] { return existing }
        let created = Conversation()
        conversations[imageURL] = created
        return created
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 600))

        let title = NSTextField(labelWithString: "Ask AI")
        title.font = .boldSystemFont(ofSize: 13)
        modelPicker.controlSize = .small
        modelPicker.font = .systemFont(ofSize: 11)
        modelPicker.target = self
        modelPicker.action = #selector(modelPicked(_:))
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingTail
        let newChat = NSButton(image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")!,
                               target: self, action: #selector(newChat(_:)))
        newChat.isBordered = false
        newChat.toolTip = "New chat about this image"
        let header = NSStackView(views: [title, modelLabel, modelPicker, NSView(), newChat])
        header.spacing = 8
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
        settingsButton.bezelStyle = .rounded
        let empty = NSStackView(views: [emptyLabel, settingsButton])
        empty.orientation = .vertical
        empty.spacing = 10

        input.placeholderString = "Ask about this image…"
        input.delegate = self
        input.target = self
        input.action = #selector(send(_:))
        input.usesSingleLineMode = false
        input.cell?.wraps = true
        input.cell?.isScrollable = false
        input.maximumNumberOfLines = 6
        input.lineBreakMode = .byWordWrapping
        input.bezelStyle = .roundedBezel
        sendButton.bezelStyle = .regularSquare
        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(sendOrStop(_:))
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        let inputRow = NSStackView(views: [input, sendButton])
        inputRow.spacing = 6
        inputRow.alignment = .bottom

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for subview in [header, scrollView, empty, inputRow, statusLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: inputRow.topAnchor, constant: -8),
            empty.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            inputRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            inputRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            inputRow.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        self.view = view

        NotificationCenter.default.addObserver(self, selector: #selector(refreshChrome), name: AISettings.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshChrome), name: CostTracker.didChange, object: nil)
        refreshChrome()
        render()
    }

    func focusInput() {
        view.window?.makeFirstResponder(input)
    }

    /// The window moved to another image (nil: nothing to show).
    func setImage(_ url: URL?) {
        guard url != imageURL else { return }
        task?.cancel()
        imageURL = url
        render()
        refreshChrome()
    }

    // MARK: Header & status

    @objc private func refreshChrome() {
        guard isViewLoaded else { return }
        let choice = AISettings.assistant
        let configured = AISettings.isConfigured(choice.provider)

        modelPicker.isHidden = !AISettings.showQuickPicker
        modelLabel.isHidden = AISettings.showQuickPicker
        modelLabel.stringValue = "\(choice.provider.displayName) · \(choice.model)"
        modelPicker.removeAllItems()
        for provider in ProviderKind.allCases where AISettings.isConfigured(provider) {
            modelPicker.addItem(withTitle: "\(provider.displayName) · \(AISettings.model(for: provider))")
            modelPicker.lastItem?.representedObject = provider.rawValue
        }
        if let item = modelPicker.itemArray.first(where: { $0.representedObject as? String == choice.provider.rawValue }) {
            modelPicker.select(item)
        }

        let hasEntries = !(conversation?.entries.isEmpty ?? true)
        emptyLabel.stringValue = !configured
            ? "Add an API key for \(choice.provider.displayName) in Settings → AI to start chatting about your images."
            : imageURL == nil ? "Open an image to ask about it." : "Ask anything about this image: what's in it, the text it contains, where it might be…"
        settingsButton.isHidden = configured
        emptyLabel.superview?.isHidden = hasEntries
        input.isEnabled = configured && imageURL != nil

        sendButton.image = NSImage(systemSymbolName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill",
                                   accessibilityDescription: isStreaming ? "Stop" : "Send")
        sendButton.contentTintColor = isStreaming ? .secondaryLabelColor : .controlAccentColor
        sendButton.symbolConfiguration = .init(pointSize: 20, weight: .regular)

        let tracker = CostTracker.shared
        var status = "This month \(tracker.monthTotal.dollars)"
        if tracker.limitEnabled {
            status += " of \(tracker.monthlyLimit.dollars)"
            switch tracker.limitState {
            case .warning: status = "⚠︎ " + status
            case .reached: status = "⛔︎ Limit reached · " + status
            case .ok: break
            }
        }
        if !AISettings.sendsImages(choice) { status += " · text-only model (sees a description)" }
        statusLabel.stringValue = status
    }

    @objc private func modelPicked(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let provider = ProviderKind(rawValue: raw) else { return }
        AISettings.assistantProvider = provider
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?(.ai)
    }

    @objc private func newChat(_ sender: Any?) {
        task?.cancel()
        guard let imageURL else { return }
        conversations[imageURL] = nil
        render()
        refreshChrome()
    }

    // MARK: Sending

    @objc private func sendOrStop(_ sender: Any?) {
        if isStreaming { task?.cancel() } else { send(sender) }
    }

    @objc private func send(_ sender: Any?) {
        let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming, let imageURL, let conversation else { return }
        let choice = AISettings.assistant
        guard let client = AISettings.client(for: choice.provider) else {
            onOpenSettings?(.ai)
            return
        }
        guard confirmWithinLimit() else { return }

        input.stringValue = ""
        let isFirstQuestion = conversation.turns.isEmpty
        let sendsImage = AISettings.sendsImages(choice)
        conversation.entries.append(ChatEntry(kind: .user, text: question))
        let userIndex = conversation.entries.count - 1
        conversation.entries.append(ChatEntry(kind: .assistant, text: ""))
        let answerIndex = conversation.entries.count - 1

        task = Task { [weak self] in
            // Prepare the image (or its on-device description) off the main thread.
            var turn = ChatTurn(role: .user, text: question)
            if isFirstQuestion {
                if sendsImage {
                    turn.image = await Task.detached { ChatImage.load(from: imageURL) }.value
                } else {
                    let description = await Task.detached { ImageDescriber.describe(imageURL) }.value
                    turn.text = "On-device description of the image (you can't see it directly):\n\(description)\n\nQuestion: \(question)"
                }
            }
            guard let self else { return }
            conversation.entries[userIndex].turn = turn
            let request = ChatRequest(model: choice.model,
                                      system: self.systemPrompt(for: imageURL, sendsImage: sendsImage),
                                      turns: conversation.turns)
            do {
                var result: ChatResult?
                for try await event in client.stream(request) {
                    switch event {
                    case .text(let text):
                        conversation.entries[answerIndex].text += text
                        self.scheduleRender()
                    case .finished(let finished):
                        result = finished
                    }
                }
                guard let result else { throw AIError.badResponse("the answer ended early") }
                let record = CostTracker.shared.record(provider: choice.provider.displayName, model: result.model,
                                                       kind: "chat", usage: result.usage)
                let answer = conversation.entries[answerIndex].text
                conversation.entries[answerIndex].turn = ChatTurn(
                    role: .assistant, text: answer,
                    anthropicBlocks: choice.provider == .anthropic ? result.anthropicBlocks : nil,
                    reasoning: result.reasoning)
                conversation.entries[answerIndex].footer = "\(result.model) · \(record.cost?.dollars ?? "price unknown")"
                if result.refused {
                    conversation.entries.append(ChatEntry(kind: .note, text: "The model declined to answer this request."))
                }
            } catch {
                let partial = conversation.entries[answerIndex].text
                if Self.isCancellation(error), !partial.isEmpty {
                    // Keep what arrived before Stop was pressed.
                    conversation.entries[answerIndex].turn = ChatTurn(role: .assistant, text: partial)
                    conversation.entries[answerIndex].footer = "stopped"
                } else {
                    // Drop the unanswered question so the conversation stays consistent, and give the text back.
                    conversation.entries.removeSubrange(userIndex...answerIndex)
                    if self.conversations[imageURL] === conversation, self.input.stringValue.isEmpty {
                        self.input.stringValue = question
                    }
                    if !Self.isCancellation(error) {
                        conversation.entries.append(ChatEntry(kind: .note, text: error.localizedDescription))
                    }
                }
            }
            self.task = nil
            self.render()
            self.refreshChrome()
        }
        render()
        refreshChrome()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Spending limit: warn when reached, with the option to allow this one request.
    private func confirmWithinLimit() -> Bool {
        let tracker = CostTracker.shared
        guard tracker.limitState == .reached else { return true }
        let alert = NSAlert()
        alert.messageText = "Monthly spending limit reached"
        alert.informativeText = "You've spent \(tracker.monthTotal.dollars) of your \(tracker.monthlyLimit.dollars) limit this month."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow This Request")
        alert.addButton(withTitle: "Open Costs…")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return true
        case .alertThirdButtonReturn: onOpenSettings?(.costs); return false
        default: return false
        }
    }

    private func systemPrompt(for url: URL, sendsImage: Bool) -> String {
        let seeing = sendsImage
            ? "The image is attached to the user's first message."
            : "You cannot see the image. The first message includes an on-device description of it (detected contents and recognized text); if a question needs details the description doesn't have, say so."
        return """
        You are the assistant inside Easy Img, a macOS image viewer. The user is looking at the image "\(url.lastPathComponent)" \
        in the folder "\(url.deletingLastPathComponent().lastPathComponent)". \(seeing) \
        Answer in the user's language. Be concise and concrete. Light Markdown (bold, italics, inline code) is fine.
        """
    }

    // MARK: Transcript

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        let output = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        func add(_ string: String, _ font: NSFont, _ color: NSColor) {
            output.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }

        for (i, entry) in (conversation?.entries ?? []).enumerated() {
            if i > 0 { add("\n", small, .labelColor) }
            switch entry.kind {
            case .user:
                add("You\n", .boldSystemFont(ofSize: 11), .secondaryLabelColor)
                add(entry.text + "\n", body, .labelColor)
            case .assistant:
                add("AI\n", .boldSystemFont(ofSize: 11), .controlAccentColor)
                if entry.text.isEmpty && entry.turn == nil {
                    add("Thinking…\n", NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask), .secondaryLabelColor)
                } else {
                    output.append(Self.markdown(entry.text + "\n", font: body, paragraph: paragraph))
                }
                if let footer = entry.footer { add(footer + "\n", small, .tertiaryLabelColor) }
            case .note:
                add(entry.text + "\n", NSFontManager.shared.convert(small, toHaveTrait: .italicFontMask), .systemOrange)
            }
        }
        textView.textStorage?.setAttributedString(output)
        textView.scrollToEndOfDocument(nil)
        emptyLabel.superview?.isHidden = !(conversation?.entries.isEmpty ?? true)
    }

    /// Inline Markdown (bold, italics, code) rendered with fonts NSTextView understands.
    private static func markdown(_ text: String, font: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            // Answers can be steered by text inside an image, so only plain web links are made clickable
            // (no file://, custom app schemes or other URL types).
            if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
}
