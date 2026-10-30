import AppKit

/// One window = one list of images (a folder, or a multi-selection from Finder),
/// with a collapsible folder sidebar for switching to other folders. The list is shown
/// either one image at a time (with an optional filmstrip) or as a grid of thumbnails.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private enum Mode { case single, grid }

    /// Identifies what this window is showing, so reopening the same folder reuses it.
    private(set) var sourceKey: String
    private var sourceName: String
    /// The folder being shown, if the list is a folder (not a multi-selection).
    private var sourceFolder: URL?
    private var urls: [URL]
    private var index: Int
    private var mode: Mode
    private let canvas = ImageCanvasView()
    private let filmstrip = FilmstripView()
    private let grid = ThumbnailGridView()
    private var canvasAboveFilmstrip: NSLayoutConstraint!
    private var canvasToBottom: NSLayoutConstraint!
    private let sidebar = SidebarViewController()
    private let sidebarItem: NSSplitViewItem
    private var sidebarObservation: NSKeyValueObservation?
    private let loader = ImageLoader()
    /// Image whose full-resolution version has been requested.
    private var detailURL: URL?
    var onClose: ((ViewerWindowController) -> Void)?

    private static let showSidebarKey = "ShowSidebar"
    private static let thumbnailsItem = NSToolbarItem.Identifier("Thumbnails")
    private static let zoomInItem = NSToolbarItem.Identifier("ZoomIn")
    private static let zoomOutItem = NSToolbarItem.Identifier("ZoomOut")

    init(urls: [URL], index: Int, sourceKey: String, sourceName: String, folder: URL?, startInGrid: Bool) {
        self.urls = urls
        self.index = index
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.sourceFolder = folder
        self.mode = startInGrid ? .grid : .single

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: visible.width * 0.7, height: visible.height * 0.8)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        for view in [canvas, filmstrip, grid] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        canvasAboveFilmstrip = canvas.bottomAnchor.constraint(equalTo: filmstrip.topAnchor)
        canvasToBottom = canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filmstrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: FilmstripView.height),
            grid.topAnchor.constraint(equalTo: content.topAnchor),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let contentController = NSViewController()
        contentController.view = content

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.showSidebarKey)
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: contentController))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(size)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "Viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.delegate = self
        window.center()

        canvas.onStep = { [weak self] delta in self?.step(delta) }
        canvas.onJump = { [weak self] toEnd in
            guard let self, !self.urls.isEmpty else { return }
            self.show(at: toEnd ? self.urls.count - 1 : 0)
        }
        canvas.onEscape = { [weak self] in self?.setMode(.grid) }
        canvas.onToggleThumbnails = { [weak self] in self?.toggleThumbnails(nil) }
        grid.onToggle = { [weak self] in self?.toggleThumbnails(nil) }
        canvas.onZoomChange = { [weak self] in self?.updateTitle() }
        canvas.onNeedsDetail = { [weak self] in self?.loadDetail() }
        filmstrip.onSelect = { [weak self] index in self?.show(at: index) }
        grid.onSelect = { [weak self] index in
            self?.index = index
            self?.updateTitle()
        }
        grid.onOpen = { [weak self] index in
            self?.index = index
            self?.setMode(.single)
        }

        sidebar.onSelectFolder = { [weak self] folder in self?.showFolder(folder) }
        sidebar.onFolderClicked = { [weak self] in self?.focusContent() }
        sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            UserDefaults.standard.set(!item.isCollapsed, forKey: Self.showSidebarKey)
            if !item.isCollapsed { self?.sidebar.reveal(self?.sourceFolder) }
        }
        if !sidebarItem.isCollapsed { sidebar.reveal(folder) }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)

        reloadLists()
        setMode(mode)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        focusContent()
    }

    /// Shows `url` in the single-image view (it was opened from Finder).
    func select(_ url: URL) {
        if let i = urls.firstIndex(where: { $0.lastPathComponent == url.lastPathComponent }) {
            index = i
        }
        setMode(.single)
    }

    /// Switches this window to the images in `folder` (chosen in the sidebar), as a grid.
    private func showFolder(_ folder: URL) {
        urls = ImageList.images(inFolder: folder)
        index = 0
        sourceKey = folder.path
        sourceName = folder.lastPathComponent
        sourceFolder = folder
        canvas.setImage(nil)
        reloadLists()
        setMode(.grid)
    }

    private func reloadLists() {
        grid.reload(urls: urls, selecting: index)
        filmstrip.reload(urls: urls, current: index)
    }

    // MARK: Modes

    private func setMode(_ newMode: Mode) {
        mode = newMode
        grid.isHidden = mode != .grid
        canvas.isHidden = mode == .grid
        updateFilmstrip()
        if mode == .grid {
            grid.select(index)
        } else {
            show(at: index)
        }
        focusContent()
        updateTitle()
    }

    private func updateFilmstrip() {
        let visible = mode == .single && Settings.showFilmstrip && urls.count > 1
        filmstrip.isHidden = !visible
        canvasToBottom.isActive = !visible
        canvasAboveFilmstrip.isActive = visible
    }

    private func focusContent() {
        if mode == .grid { grid.focus() } else { canvas.focus() }
    }

    @objc private func settingsChanged(_ notification: Notification) {
        updateFilmstrip()
        grid.reloadThumbnails()
        filmstrip.reloadThumbnails()
    }

    @objc func toggleThumbnails(_ sender: Any?) {
        setMode(mode == .grid ? .single : .grid)
    }

    // MARK: Navigation

    @objc func showPreviousImage(_ sender: Any?) { step(-1) }
    @objc func showNextImage(_ sender: Any?) { step(1) }
    @objc func showFirstImage(_ sender: Any?) { if !urls.isEmpty { show(at: 0) } }
    @objc func showLastImage(_ sender: Any?) { if !urls.isEmpty { show(at: urls.count - 1) } }

    @objc func revealInFinder(_ sender: Any?) {
        guard urls.indices.contains(index) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([urls[index]])
    }

    // MARK: Zoom (in the grid: thumbnail size)

    @objc func zoomIn(_ sender: Any?) { mode == .grid ? grid.resize(bigger: true) : canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { mode == .grid ? grid.resize(bigger: false) : canvas.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    @objc func zoomToActualSize(_ sender: Any?) { canvas.zoomToActualSize() }

    private func step(_ delta: Int) {
        guard urls.count > 1 else { return }
        // Wrap around at either end.
        show(at: (index + delta + urls.count) % urls.count)
    }

    private var currentURL: URL? { urls.indices.contains(index) ? urls[index] : nil }

    private func show(at newIndex: Int) {
        if mode == .grid {
            guard urls.indices.contains(newIndex) else { return }
            index = newIndex
            grid.select(newIndex)
            updateTitle()
            return
        }
        detailURL = nil
        guard urls.indices.contains(newIndex) else {
            index = 0
            canvas.setImage(nil)
            canvas.messageLabel.stringValue = "No images here"
            updateTitle()
            return
        }
        index = newIndex
        let url = urls[newIndex]
        canvas.messageLabel.stringValue = ""
        filmstrip.setCurrent(newIndex)
        updateTitle()

        loader.load(url) { [weak self] image in
            // Ignore results that arrive after the user has already moved on.
            guard let self, self.currentURL == url else { return }
            self.canvas.setImage(image)
            self.canvas.messageLabel.stringValue = image == nil ? "Can't display \(url.lastPathComponent)" : ""
        }
        if urls.count > 1 {
            loader.prefetch(urls[(newIndex + 1) % urls.count])
            loader.prefetch(urls[(newIndex - 1 + urls.count) % urls.count])
        }
    }

    /// Zoomed past the screen-sized decode: load the image at full resolution.
    private func loadDetail() {
        guard let url = currentURL, detailURL != url else { return }
        detailURL = url
        loader.loadFull(url) { [weak self] image in
            guard let self, let image, self.currentURL == url, self.detailURL == url else { return }
            self.canvas.replaceImage(image)
        }
    }

    private func updateTitle() {
        guard let window else { return }
        guard let url = currentURL else {
            window.title = sourceName
            window.subtitle = ""
            window.representedURL = nil
            return
        }
        window.title = url.lastPathComponent
        let zoom = mode == .single && canvas.hasImage ? " · \(Int((canvas.magnification * 100).rounded()))%" : ""
        window.subtitle = "\(index + 1) of \(urls.count)\(zoom)"
        window.representedURL = url
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.thumbnailsItem, Self.zoomOutItem, Self.zoomInItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let (label, symbol, action): (String, String, Selector)
        switch id {
        case Self.thumbnailsItem: (label, symbol, action) = ("Thumbnails", "square.grid.2x2", #selector(toggleThumbnails(_:)))
        case Self.zoomInItem: (label, symbol, action) = ("Zoom In", "plus.magnifyingglass", #selector(zoomIn(_:)))
        case Self.zoomOutItem: (label, symbol, action) = ("Zoom Out", "minus.magnifyingglass", #selector(zoomOut(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = id == Self.thumbnailsItem ? "Thumbnails (G)" : label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = self
        return item
    }
}

extension ViewerWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleThumbnails(_:)):
            menuItem.title = mode == .grid ? "Show Image" : "Show Thumbnails"
            return true
        case #selector(showPreviousImage(_:)), #selector(showNextImage(_:)):
            return urls.count > 1
        case #selector(showFirstImage(_:)), #selector(showLastImage(_:)), #selector(revealInFinder(_:)):
            return !urls.isEmpty
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return mode == .grid ? !urls.isEmpty : canvas.hasImage
        case #selector(zoomToFit(_:)), #selector(zoomToActualSize(_:)):
            return mode == .single && canvas.hasImage
        default:
            return true
        }
    }
}
