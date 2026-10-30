import AppKit

/// Settings → Costs: spending this month, the monthly limit, recent requests and the price table.
final class CostsViewController: NSViewController {
    private let summary = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let limitCheckbox = NSButton(checkboxWithTitle: "Monthly spending limit:", target: nil, action: nil)
    private let limitField = NSTextField()
    private var byModel: [(model: String, requests: Int, cost: Double)] = []
    private var recent: [UsageRecord] = []
    private lazy var modelTable = SimpleTable(columns: [
        .init(title: "Model", width: 260) { self.byModel[$0].model },
        .init(title: "Requests", width: 80, alignRight: true) { "\(self.byModel[$0].requests)" },
        .init(title: "Cost", width: 100, alignRight: true) { self.byModel[$0].cost.dollars },
    ], rowCount: { self.byModel.count })
    private lazy var recentTable = SimpleTable(columns: [
        .init(title: "When", width: 120) { Self.dateFormatter.string(from: self.recent[$0].date) },
        .init(title: "Model", width: 170) { "\(self.recent[$0].provider) · \(self.recent[$0].model)" },
        .init(title: "In / cached / out", width: 140, alignRight: true) {
            let r = self.recent[$0]
            return "\(r.inputTokens) / \(r.cachedTokens) / \(r.outputTokens)"
        },
        .init(title: "Cost", width: 80, alignRight: true) { self.recent[$0].cost?.dollars ?? "?" },
    ], rowCount: { self.recent.count })
    private lazy var priceTable = SimpleTable(columns: [
        .init(title: "Model (or prefix)", width: 200, value: { self.prices[$0].model },
              edit: { row, text in self.updatePrice(row, text) { price, text in price.model = text } }),
        .init(title: "Input $/1M", width: 90, alignRight: true, value: { Self.number(self.prices[$0].input) },
              edit: { row, text in self.updatePrice(row, text) { price, text in price.input = Double(text) ?? price.input } }),
        .init(title: "Cached $/1M", width: 90, alignRight: true, value: { self.prices[$0].cachedInput.map(Self.number) ?? "" },
              edit: { row, text in self.updatePrice(row, text) { price, text in price.cachedInput = Double(text) } }),
        .init(title: "Output $/1M", width: 90, alignRight: true, value: { Self.number(self.prices[$0].output) },
              edit: { row, text in self.updatePrice(row, text) { price, text in price.output = Double(text) ?? price.output } }),
    ], rowCount: { self.prices.count })

    private var tracker: CostTracker { .shared }
    private var prices: [ModelPrice] { tracker.prices }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func number(_ value: Double) -> String {
        String(format: "%g", value)
    }

    override func loadView() {
        summary.font = .systemFont(ofSize: 15, weight: .semibold)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor

        limitCheckbox.target = self
        limitCheckbox.action = #selector(limitToggled(_:))
        limitField.target = self
        limitField.action = #selector(limitChanged(_:))
        limitField.cell?.sendsActionOnEndEditing = true
        limitField.alignment = .right
        limitField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let limitNote = NSTextField(labelWithString: "USD · warns at 80%, asks before going over")
        limitNote.font = .systemFont(ofSize: 11)
        limitNote.textColor = .secondaryLabelColor
        let limitRow = NSStackView(views: [limitCheckbox, limitField, limitNote])

        let addPrice = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addPrice(_:)))
        let removePrice = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removePrice(_:)))
        let resetPrices = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetPrices(_:)))
        let clearHistory = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory(_:)))
        let priceButtons = NSStackView(views: [addPrice, removePrice, NSView(), resetPrices])
        let priceNote = NSTextField(wrappingLabelWithString:
            "Costs are estimates: tokens reported by each provider × these prices. Your provider's bill is the final word. Prices change; a model ID matches the longest entry it starts with.")
        priceNote.font = .systemFont(ofSize: 11)
        priceNote.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            summary, progress, warning, limitRow,
            section("This month by model"), modelTable.scrollView,
            section("Recent requests"), recentTable.scrollView,
            section("Prices"), priceTable.scrollView, priceButtons, priceNote,
            clearHistory,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [progress, warning, modelTable.scrollView, recentTable.scrollView, priceTable.scrollView, priceButtons, priceNote] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        // Recent requests takes whatever height the window has; the other parts keep their size.
        for view in stack.arrangedSubviews where view !== recentTable.scrollView {
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        recentTable.scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        modelTable.scrollView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        recentTable.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        priceTable.scrollView.heightAnchor.constraint(equalToConstant: 170).isActive = true
        stack.setCustomSpacing(16, after: limitRow)
        stack.setCustomSpacing(16, after: priceNote)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        preferredContentSize = NSSize(width: 720, height: min(860, screenHeight - 120))
        stack.frame = NSRect(origin: .zero, size: preferredContentSize)
        view = stack

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: CostTracker.didChange, object: nil)
        refresh()
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        return label
    }

    @objc private func refresh() {
        let month = tracker.monthTotal
        summary.stringValue = "This month: \(month.dollars)   ·   Today: \(tracker.todayTotal.dollars)"
        progress.isHidden = !tracker.limitEnabled
        progress.doubleValue = tracker.monthlyLimit > 0 ? min(1, month / tracker.monthlyLimit) : 1
        var notes: [String] = []
        if tracker.limitEnabled {
            switch tracker.limitState {
            case .reached: notes.append("Limit reached: new requests ask for confirmation.")
            case .warning: notes.append("Over 80% of the monthly limit.")
            case .ok: notes.append("\((tracker.monthlyLimit - month).dollars) left this month.")
            }
        }
        if tracker.unpricedThisMonth > 0 {
            notes.append("\(tracker.unpricedThisMonth) request(s) used models with no price below, so the total is incomplete.")
        }
        warning.stringValue = notes.joined(separator: " ")
        limitCheckbox.state = tracker.limitEnabled ? .on : .off
        limitField.stringValue = String(format: "%.2f", tracker.monthlyLimit)
        limitField.isEnabled = tracker.limitEnabled

        let start = Calendar.current.dateInterval(of: .month, for: Date())!.start
        var groups: [String: (Int, Double)] = [:]
        for record in tracker.records where record.date >= start {
            let key = "\(record.provider) · \(record.model)"
            let current = groups[key] ?? (0, 0)
            groups[key] = (current.0 + 1, current.1 + (record.cost ?? 0))
        }
        byModel = groups.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.cost > $1.cost }
        recent = Array(tracker.records.suffix(200).reversed())
        modelTable.reload()
        recentTable.reload()
        priceTable.reload()
    }

    @objc private func limitToggled(_ sender: NSButton) { tracker.limitEnabled = sender.state == .on }

    @objc private func limitChanged(_ sender: NSTextField) {
        if let value = Double(sender.stringValue.replacingOccurrences(of: ",", with: ".")) { tracker.monthlyLimit = value }
        refresh()
    }

    private func updatePrice(_ row: Int, _ text: String, _ change: (inout ModelPrice, String) -> Void) {
        guard tracker.prices.indices.contains(row) else { return }
        var price = tracker.prices[row]
        change(&price, text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        tracker.prices[row] = price
    }

    @objc private func addPrice(_ sender: Any?) {
        tracker.prices.append(ModelPrice(model: "new-model", input: 0, output: 0))
        let row = tracker.prices.count - 1
        priceTable.tableView.scrollRowToVisible(row)
        priceTable.tableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removePrice(_ sender: Any?) {
        let row = priceTable.tableView.selectedRow
        guard tracker.prices.indices.contains(row) else { return }
        tracker.prices.remove(at: row)
    }

    @objc private func resetPrices(_ sender: Any?) { tracker.resetPrices() }

    @objc private func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear the spending history?"
        alert.informativeText = "This resets this month's total, which the spending limit uses."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { tracker.clearHistory() }
    }
}
