import AppKit

/// A folder in the sidebar tree; subfolders are listed the first time they are needed.
final class FolderNode {
    let url: URL
    let name: String
    private var cachedChildren: [FolderNode]?

    init(url: URL, name: String? = nil) {
        self.url = url.standardizedFileURL
        self.name = name ?? FileManager.default.displayName(atPath: url.path)
    }

    /// Unknown until listed: folders are only read when expanded, since listing a protected
    /// folder (Documents, Downloads…) blocks on a permission prompt and network volumes can be slow.
    var mayHaveChildren: Bool { cachedChildren.map { !$0.isEmpty } ?? true }

    var children: [FolderNode] {
        if let cachedChildren { return cachedChildren }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        let folders = items.filter {
            let values = try? $0.resourceValues(forKeys: keys)
            return values?.isDirectory == true && values?.isPackage != true
        }
        let nodes = ImageList.sorted(folders).map { FolderNode(url: $0) }
        cachedChildren = nodes
        return nodes
    }

    func contains(path: String) -> Bool {
        let own = url.path
        return path == own || path.hasPrefix(own.hasSuffix("/") ? own : own + "/")
    }
}

/// Folder tree for jumping to other directories. Selecting a folder shows its images.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelectFolder: ((URL) -> Void)?
    /// A folder was clicked with the mouse (as opposed to chosen with the keyboard).
    var onFolderClicked: (() -> Void)?
    /// Something was copied (message for the confirmation notice).
    var onCopied: ((String) -> Void)?

    private let outlineView = NSOutlineView()
    private var roots: [FolderNode] = []
    private var isRevealing = false
    private static let cellID = NSUserInterfaceItemIdentifier("FolderCell")

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView

        roots = Self.defaultRoots()
        outlineView.reloadData()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the column as wide as the sidebar so names only truncate when they really don't fit.
        outlineView.sizeLastColumnToFit()
    }

    private static func defaultRoots() -> [FolderNode] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = ["Desktop", "Documents", "Downloads", "Pictures"].map { FolderNode(url: home.appendingPathComponent($0)) }
        roots.append(FolderNode(url: home))
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        roots += volumes.filter { $0.path != "/" }.map { FolderNode(url: $0) }
        roots.append(FolderNode(url: URL(fileURLWithPath: "/")))
        return roots
    }

    /// Expands the tree down to `folder` and selects it, without triggering `onSelectFolder`.
    func reveal(_ folder: URL?) {
        _ = view
        isRevealing = true
        defer { isRevealing = false }
        let path = folder?.standardizedFileURL.path ?? ""
        guard folder != nil,
              var node = roots.filter({ $0.contains(path: path) }).max(by: { $0.url.path.count < $1.url.path.count })
        else {
            outlineView.deselectAll(nil)
            return
        }
        while node.url.path != path {
            outlineView.expandItem(node)
            guard let next = node.children.first(where: { $0.contains(path: path) }) else { break }
            node = next
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FolderNode else { return }
        for (title, action) in [("Copy Path", #selector(copyPath(_:))), ("Show in Finder", #selector(showInFinder(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node.url
        }
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Clipboard.copyPath(of: url)
        onCopied?("Folder path copied")
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func rowClicked(_ sender: Any?) {
        if outlineView.clickedRow >= 0 { onFolderClicked?() }
    }

    // MARK: Data source & delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderNode)?.mayHaveChildren ?? false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Expanded an empty folder: drop its disclosure triangle.
        if let node = notification.userInfo?["NSObject"] as? FolderNode, !node.mayHaveChildren {
            outlineView.reloadItem(node)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        cell.toolTip = node.url.path
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing, let node = outlineView.item(atRow: outlineView.selectedRow) as? FolderNode else { return }
        onSelectFolder?(node.url)
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellID
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
