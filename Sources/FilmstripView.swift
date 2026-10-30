import AppKit

/// Never takes keyboard focus (arrow keys stay with the image); a click picks an image.
final class FilmstripCollectionView: NSCollectionView {
    var onClick: ((Int) -> Void)?
    var contextMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return contextMenu?(indexPath.item)
    }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onClick?(indexPath.item)
        }
    }
}

/// Single row of small thumbnails under the image, centered on the one being viewed.
final class FilmstripView: NSView, NSCollectionViewDataSource {
    static let height: CGFloat = 78
    var onSelect: ((Int) -> Void)?
    var contextMenu: ((Int) -> NSMenu?)? {
        get { collectionView.contextMenu }
        set { collectionView.contextMenu = newValue }
    }

    private let collectionView = FilmstripCollectionView()
    private var urls: [URL] = []
    private var current = 0
    private static let side: CGFloat = 58

    override init(frame: NSRect) {
        super.init(frame: frame)
        let background = NSColor(white: 0.11, alpha: 1)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: Self.side + 10, height: Self.side + 10)
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [background]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.onClick = { [weak self] index in self?.onSelect?(index) }

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload(urls: [URL], current: Int) {
        self.urls = urls
        self.current = current
        collectionView.reloadData()
        scrollToCurrent()
    }

    /// Re-render thumbnails (crop setting changed).
    func reloadThumbnails() {
        collectionView.reloadData()
    }

    func setCurrent(_ index: Int) {
        (collectionView.item(at: current) as? ThumbnailItem)?.isCurrent = false
        current = index
        (collectionView.item(at: current) as? ThumbnailItem)?.isCurrent = true
        scrollToCurrent()
    }

    private func scrollToCurrent() {
        guard urls.indices.contains(current) else { return }
        collectionView.layoutSubtreeIfNeeded()
        collectionView.scrollToItems(at: [IndexPath(item: current, section: 0)], scrollPosition: .centeredHorizontally)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as! ThumbnailItem
        item.configure(url: urls[indexPath.item], side: Self.side, cropped: Settings.cropThumbnails, showsLabel: false)
        item.isCurrent = indexPath.item == current
        return item
    }
}
