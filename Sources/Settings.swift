import AppKit

/// User options, stored in UserDefaults. Changing an option posts `didChange` so open windows update.
enum Settings {
    static let didChange = Notification.Name("EasyImgSettingsDidChange")

    private static let cropKey = "CropThumbnails"
    private static let filmstripKey = "ShowFilmstrip"
    private static let gridSideKey = "GridThumbnailSize"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [cropKey: false, filmstripKey: true, gridSideKey: 160.0])
    }

    /// Crop thumbnails to fill square tiles instead of showing the whole image.
    static var cropThumbnails: Bool {
        get { UserDefaults.standard.bool(forKey: cropKey) }
        set { UserDefaults.standard.set(newValue, forKey: cropKey); notify() }
    }

    /// Show a strip of thumbnails under the single-image view.
    static var showFilmstrip: Bool {
        get { UserDefaults.standard.bool(forKey: filmstripKey) }
        set { UserDefaults.standard.set(newValue, forKey: filmstripKey); notify() }
    }

    /// Thumbnail size in the grid, in points.
    static var gridThumbnailSide: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: gridSideKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: gridSideKey) }
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// Sizes the window to each tab's preferred size (the default keeps whatever size the last tab left).
final class SettingsTabsController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let size = tabViewItem?.viewController?.preferredContentSize, size != .zero, let window = view.window else { return }
        let contentHeight = window.contentLayoutRect.height
        var frame = window.frame
        let height = frame.height - contentHeight + size.height
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: size.width, height: height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// The Settings… window (⌘,): General, AI and Costs tabs.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int { case general, ai, costs }

    private let tabs = SettingsTabsController()

    init() {
        tabs.tabStyle = .toolbar
        for (title, symbol, controller) in [
            ("General", "gearshape", GeneralSettingsViewController()),
            ("AI", "sparkles", AISettingsViewController()),
            ("Costs", "dollarsign.circle", CostsViewController()),
        ] as [(String, String, NSViewController)] {
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class GeneralSettingsViewController: NSViewController {
    private let cropCheckbox = NSButton(checkboxWithTitle: "Crop thumbnails to fill square tiles", target: nil, action: nil)
    private let filmstripCheckbox = NSButton(checkboxWithTitle: "Show filmstrip below the image", target: nil, action: nil)

    override func loadView() {
        cropCheckbox.target = self
        cropCheckbox.action = #selector(cropChanged(_:))
        filmstripCheckbox.target = self
        filmstripCheckbox.action = #selector(filmstripChanged(_:))
        let stack = NSStackView(views: [filmstripCheckbox, cropCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        preferredContentSize = NSSize(width: 460, height: 110)
        stack.frame = NSRect(origin: .zero, size: preferredContentSize)
        view = stack
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Settings.didChange, object: nil)
        refresh()
    }

    @objc private func refresh() {
        cropCheckbox.state = Settings.cropThumbnails ? .on : .off
        filmstripCheckbox.state = Settings.showFilmstrip ? .on : .off
    }

    @objc private func cropChanged(_ sender: NSButton) { Settings.cropThumbnails = sender.state == .on }
    @objc private func filmstripChanged(_ sender: NSButton) { Settings.showFilmstrip = sender.state == .on }
}

/// Minimal table: text columns from closures, optionally editable.
final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Column {
        var title: String
        var width: CGFloat
        var alignRight = false
        var value: (Int) -> String
        var edit: ((Int, String) -> Void)? = nil
    }

    let tableView = NSTableView()
    let scrollView = NSScrollView()
    private let columns: [Column]
    private let rowCount: () -> Int

    init(columns: [Column], rowCount: @escaping () -> Int) {
        self.columns = columns
        self.rowCount = rowCount
        super.init()
        for (i, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
            tableColumn.title = column.title
            tableColumn.width = column.width
            // Text columns absorb width changes; number columns keep their size.
            tableColumn.resizingMask = column.alignRight ? .userResizingMask : [.autoresizingMask, .userResizingMask]
            tableView.addTableColumn(tableColumn)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        // Columns share the table's width, so nothing is cut off on the right.
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    func reload() { tableView.reloadData() }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let index = Int(id.rawValue) else { return nil }
        let column = columns[index]
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let field = NSTextField()
            field.identifier = id
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingMiddle
            field.font = .systemFont(ofSize: 12)
            field.alignment = column.alignRight ? .right : .left
            field.isEditable = column.edit != nil
            field.target = self
            field.action = #selector(edited(_:))
            return field
        }()
        field.stringValue = column.value(row)
        return field
    }

    @objc private func edited(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        guard row >= 0, let id = sender.identifier, let index = Int(id.rawValue) else { return }
        columns[index].edit?(row, sender.stringValue)
    }
}
