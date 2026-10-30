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

/// The Settings… window (⌘,).
final class SettingsWindowController: NSWindowController {
    private let cropCheckbox = NSButton(checkboxWithTitle: "Crop thumbnails to fill square tiles", target: nil, action: nil)
    private let filmstripCheckbox = NSButton(checkboxWithTitle: "Show filmstrip below the image", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        cropCheckbox.target = self
        cropCheckbox.action = #selector(cropChanged(_:))
        filmstripCheckbox.target = self
        filmstripCheckbox.action = #selector(filmstripChanged(_:))
        let stack = NSStackView(views: [filmstripCheckbox, cropCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.center()

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Settings.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func refresh() {
        cropCheckbox.state = Settings.cropThumbnails ? .on : .off
        filmstripCheckbox.state = Settings.showFilmstrip ? .on : .off
    }

    @objc private func cropChanged(_ sender: NSButton) { Settings.cropThumbnails = sender.state == .on }
    @objc private func filmstripChanged(_ sender: NSButton) { Settings.showFilmstrip = sender.state == .on }
}
