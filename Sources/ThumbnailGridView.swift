import AppKit

/// Collection view that opens the selected thumbnail on Return/Space/double-click
/// and resizes thumbnails with + / -.
final class GridCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onResize: ((_ bigger: Bool) -> Void)?
    var onToggle: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}", " ": onOpen?()
        case "+", "=": onResize?(true)
        case "-", "_": onResize?(false)
        case "g", "G": onToggle?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            onOpen?()
        }
    }
}

/// All images of the current list as a grid of thumbnails.
final class ThumbnailGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    /// The selection moved (arrow keys or click).
    var onSelect: ((Int) -> Void)?
    /// Open the selected image in the single-image view.
    var onOpen: ((Int) -> Void)?
    /// G pressed: back to the single-image view.
    var onToggle: (() -> Void)?

    private let collectionView = GridCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let emptyLabel = NSTextField(labelWithString: "No images here")
    private var urls: [URL] = []
    private static let sideRange: ClosedRange<CGFloat> = 80...400

    override init(frame: NSRect) {
        super.init(frame: frame)
        let background = NSColor(white: 0.08, alpha: 1)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor

        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [background]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.onOpen = { [weak self] in
            guard let self, let index = self.selectedIndex else { return }
            self.onOpen?(index)
        }
        collectionView.onResize = { [weak self] bigger in self?.resize(bigger: bigger) }
        collectionView.onToggle = { [weak self] in self?.onToggle?() }
        applyItemSize()

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selectedIndex: Int? { collectionView.selectionIndexPaths.first?.item }

    func reload(urls: [URL], selecting index: Int) {
        self.urls = urls
        emptyLabel.isHidden = !urls.isEmpty
        collectionView.reloadData()
        select(index)
    }

    /// Re-render thumbnails (size or crop setting changed), keeping the selection.
    func reloadThumbnails() {
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = selection
    }

    func select(_ index: Int) {
        guard urls.indices.contains(index) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.layoutSubtreeIfNeeded()
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
    }

    func focus() {
        window?.makeFirstResponder(collectionView)
    }

    func resize(bigger: Bool) {
        let side = Settings.gridThumbnailSide * (bigger ? 1.25 : 0.8)
        Settings.gridThumbnailSide = min(max(side, Self.sideRange.lowerBound), Self.sideRange.upperBound)
        applyItemSize()
        reloadThumbnails()
        if let selectedIndex { select(selectedIndex) }
    }

    private func applyItemSize() {
        let side = Settings.gridThumbnailSide
        layout.itemSize = NSSize(width: side + 10, height: side + 10 + 20)
    }

    // MARK: Data source & delegate

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as! ThumbnailItem
        item.configure(url: urls[indexPath.item], side: Settings.gridThumbnailSide,
                       cropped: Settings.cropThumbnails, showsLabel: true)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let index = indexPaths.first?.item { onSelect?(index) }
    }
}
