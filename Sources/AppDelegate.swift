import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ViewerWindowController] = []
    private var didOpenAtLaunch = false
    private lazy var settingsWindow = SettingsWindowController()
    private lazy var helpWindow = HelpWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NSApp.mainMenu = makeMainMenu()
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files passed by Finder arrive via application(_:open:) around launch; give them a moment.
        DispatchQueue.main.async {
            if !self.didOpenAtLaunch && self.controllers.isEmpty {
                self.openDocument(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openDocument(nil) }
        return true
    }

    /// Finder "Open With", double-click (when default app), drag onto Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        didOpenAtLaunch = true
        open(urls)
    }

    /// Finder right-click > Services / Quick Actions > "Open in Easy Img".
    @objc func openFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        didOpenAtLaunch = true
        open(urls)
        NSApp.activate()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Choose an image or a folder"
        NSApp.activate()
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    // MARK: Opening

    private func open(_ urls: [URL]) {
        let urls = urls.map(\.standardizedFileURL)
        guard let first = urls.first else { return }

        if urls.count == 1 {
            if ImageList.isDirectory(first) {
                show(images: ImageList.images(inFolder: first), index: 0,
                     sourceKey: first.path, sourceName: first.lastPathComponent, folder: first, startInGrid: true, selecting: nil)
            } else {
                // A single image: browse its whole folder, starting at that image.
                let folder = first.deletingLastPathComponent()
                var images = ImageList.images(inFolder: folder)
                if !images.contains(where: { $0.lastPathComponent == first.lastPathComponent }) {
                    images = ImageList.sorted(images + [first])
                }
                let index = images.firstIndex { $0.lastPathComponent == first.lastPathComponent } ?? 0
                show(images: images, index: index,
                     sourceKey: folder.path, sourceName: folder.lastPathComponent, folder: folder, startInGrid: false, selecting: first)
            }
            return
        }

        // Several items selected in Finder: browse just those (folders expanded to their images).
        var images: [URL] = []
        for url in urls {
            if ImageList.isDirectory(url) {
                images += ImageList.images(inFolder: url)
            } else if ImageList.isImage(url) {
                images.append(url)
            }
        }
        let key = urls.map(\.path).sorted().joined(separator: "\n")
        show(images: images, index: 0, sourceKey: key, sourceName: "\(urls.count) items", folder: nil, startInGrid: true, selecting: nil)
    }

    private func show(images: [URL], index: Int, sourceKey: String, sourceName: String, folder: URL?, startInGrid: Bool, selecting url: URL?) {
        // Same folder already open: bring that window forward instead of opening another.
        if let existing = controllers.first(where: { $0.sourceKey == sourceKey }) {
            if let url { existing.select(url) }
            existing.showWindow(nil)
            return
        }
        let controller = ViewerWindowController(urls: images, index: index, sourceKey: sourceKey, sourceName: sourceName, folder: folder, startInGrid: startInGrid)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        if let front = controllers.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    // MARK: Settings

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.show(.general)
    }

    func showSettings(tab: SettingsWindowController.Tab) {
        settingsWindow.show(tab)
    }

    @objc func toggleFilmstrip(_ sender: Any?) { Settings.showFilmstrip.toggle() }
    @objc func toggleCropThumbnails(_ sender: Any?) { Settings.cropThumbnails.toggle() }

    // MARK: About & Help

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "A fast, keyboard-driven image viewer for macOS.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "github.com/LeonardoRO/easy-img-app", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/LeonardoRO/easy-img-app")!,
        ]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Easy Img",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 Leonardo Ribeiro Oliveira. Released under the MIT License.",
        ])
        NSApp.activate()
    }

    @objc func showEasyImgHelp(_ sender: Any?) {
        helpWindow.showWindow(sender)
        helpWindow.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: Menu

    private func makeMainMenu() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Easy Img"
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: appName)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Show in Finder", action: #selector(ViewerWindowController.revealInFinder(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu, title: "File")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        // In text fields this copies text; in the viewer, the image.
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyPath = editMenu.addItem(withTitle: "Copy Path", action: #selector(ViewerWindowController.copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        let copyFolder = editMenu.addItem(withTitle: "Copy Folder Path", action: #selector(ViewerWindowController.copyFolderPath(_:)), keyEquivalent: "c")
        copyFolder.keyEquivalentModifierMask = [.command, .option, .shift]
        main.addItem(submenu: editMenu, title: "Edit")

        let goMenu = NSMenu(title: "Go")
        // ← and → are handled by the image and grid views: as menu shortcuts they'd take the arrows from text fields.
        goMenu.addItem(withTitle: "Previous Image", action: #selector(ViewerWindowController.showPreviousImage(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Next Image", action: #selector(ViewerWindowController.showNextImage(_:)), keyEquivalent: "]")
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "First Image", action: #selector(ViewerWindowController.showFirstImage(_:)), keyEquivalent: "{")
        goMenu.addItem(withTitle: "Last Image", action: #selector(ViewerWindowController.showLastImage(_:)), keyEquivalent: "}")
        main.addItem(submenu: goMenu, title: "Go")

        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        // Plain G (no ⌘) is handled by the image and grid views; menus only match letter keys with ⌘.
        viewMenu.addItem(withTitle: "Show Thumbnails", action: #selector(ViewerWindowController.toggleThumbnails(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Show Filmstrip", action: #selector(toggleFilmstrip(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Crop Thumbnails to Squares", action: #selector(toggleCropThumbnails(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Ask AI", action: #selector(ViewerWindowController.toggleChat(_:)), keyEquivalent: "k")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(ViewerWindowController.zoomToFit(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(ViewerWindowController.zoomToActualSize(_:)), keyEquivalent: "1")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: viewMenu, title: "View")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        main.addItem(submenu: windowMenu, title: "Window")

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "\(appName) Help", action: #selector(showEasyImgHelp(_:)), keyEquivalent: "?")
        NSApp.helpMenu = helpMenu
        main.addItem(submenu: helpMenu, title: "Help")

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFilmstrip(_:)): menuItem.state = Settings.showFilmstrip ? .on : .off
        case #selector(toggleCropThumbnails(_:)): menuItem.state = Settings.cropThumbnails ? .on : .off
        default: break
        }
        return true
    }
}
