import AppKit
import QuickLookThumbnailing

/// Thumbnails from Quick Look (the same source Finder uses: fast, EXIF-rotated, HEIC/RAW aware),
/// cached in memory per size bucket.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private static let buckets: [CGFloat] = [128, 256, 512, 1024]

    private init() {
        cache.countLimit = 600
    }

    /// Calls `completion` on the main thread (immediately when cached). Returns the request so it can be cancelled.
    @discardableResult
    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat,
                   completion: @escaping (NSImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let pixels = Self.buckets.first { $0 >= side * scale } ?? Self.buckets.last!
        let key = "\(Int(pixels))|\(url.path)" as NSString
        if let image = cache.object(forKey: key) {
            completion(image)
            return nil
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels / scale, height: pixels / scale),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                if let image { self.cache.setObject(image, forKey: key) }
                completion(image)
            }
        }
        return request
    }

    func cancel(_ request: QLThumbnailGenerator.Request) {
        QLThumbnailGenerator.shared.cancel(request)
    }
}

/// Shows an image either whole (letterboxed) or cropped to fill its bounds.
final class ThumbnailView: NSView {
    var image: NSImage? {
        didSet { layer?.contents = image }
    }

    var cropped = false {
        didSet { layer?.contentsGravity = cropped ? .resizeAspectFill : .resizeAspect }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 4
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One tile in the thumbnail grid or the filmstrip.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private let thumbnailView = ThumbnailView()
    private let label = NSTextField(labelWithString: "")
    private var url: URL?
    private var request: QLThumbnailGenerator.Request?

    /// Highlight without being selected (the filmstrip marks the image being viewed).
    var isCurrent = false {
        didSet { updateHighlight() }
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        for subview in [thumbnailView, label] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor),
            label.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])
        self.view = view
    }

    func configure(url: URL, side: CGFloat, cropped: Bool, showsLabel: Bool) {
        cancelRequest()
        self.url = url
        label.stringValue = url.lastPathComponent
        label.isHidden = !showsLabel
        thumbnailView.cropped = cropped
        thumbnailView.image = nil
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Quick Look fits the thumbnail inside the size; cropping fills with the short side, so ask for more.
        request = ThumbnailCache.shared.thumbnail(for: url, side: cropped ? side * 2 : side, scale: scale) { [weak self] image in
            guard let self, self.url == url else { return }
            self.request = nil
            self.thumbnailView.image = image ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        url = nil
        thumbnailView.image = nil
        isCurrent = false
    }

    /// Scrolled away before it loaded: don't keep decoding it.
    private func cancelRequest() {
        if let request { ThumbnailCache.shared.cancel(request) }
        request = nil
    }

    private func updateHighlight() {
        view.layer?.backgroundColor = isSelected || isCurrent
            ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
            : nil
    }
}
