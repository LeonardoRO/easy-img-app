import AppKit

/// Keeps the image centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width { rect.origin.x = doc.midX - rect.width / 2 }
        if rect.height > doc.height { rect.origin.y = doc.midY - rect.height / 2 }
        return rect
    }
}

/// The scroll view's document: the image at its natural size. Drag to pan when zoomed in.
final class ImageDocumentView: NSImageView {
    var onMouseDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    private var canPan: Bool {
        guard let clip = superview as? NSClipView else { return false }
        return frame.width > clip.bounds.width + 0.5 || frame.height > clip.bounds.height + 0.5
    }

    override func resetCursorRects() {
        if canPan { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        guard canPan, let window, let clip = superview as? NSClipView, let scrollView = enclosingScrollView else { return }
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        var last = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let point = next.locationInWindow
            var bounds = clip.bounds
            bounds.origin.x -= (point.x - last.x) / scrollView.magnification
            bounds.origin.y -= (point.y - last.y) / scrollView.magnification
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clip)
            last = point
        }
    }
}

/// Scrollable, zoomable image display with a minimap; turns keys into navigation and zoom.
final class ImageCanvasView: NSView {
    let messageLabel = NSTextField(labelWithString: "")
    var onStep: ((Int) -> Void)?
    var onJump: ((_ toEnd: Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onToggleThumbnails: (() -> Void)?
    var onZoomChange: (() -> Void)?
    /// Called when the zoom needs more pixels than the (screen-sized) decoded image has.
    var onNeedsDetail: (() -> Void)?

    private let scrollView = NSScrollView()
    private let clipView = CenteringClipView()
    private let imageView = ImageDocumentView()
    private let minimap = MinimapView()
    private var minimapWidth: NSLayoutConstraint!
    private var minimapHeight: NSLayoutConstraint!
    private var isFitting = true

    private static let background = NSColor(white: 0.08, alpha: 1)
    private static let zoomStep = sqrt(2.0)
    private static let maxMagnification: CGFloat = 16
    private static let minimapMaxSide: CGFloat = 180

    var hasImage: Bool { imageView.image != nil }
    var magnification: CGFloat { scrollView.magnification }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor

        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.isEditable = false
        imageView.onMouseDown = { [weak self] in self?.focus() }

        clipView.backgroundColor = Self.background
        clipView.postsBoundsChangedNotifications = true
        scrollView.contentView = clipView
        scrollView.documentView = imageView
        scrollView.backgroundColor = Self.background
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = Self.maxMagnification
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        minimap.isHidden = true
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.onMove = { [weak self] point in self?.center(onUnitPoint: point) }

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(minimap)
        addSubview(messageLabel)
        minimapWidth = minimap.widthAnchor.constraint(equalToConstant: 0)
        minimapHeight = minimap.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            minimap.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            minimapWidth,
            minimapHeight,
            messageLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: clipView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Image

    /// Shows a new image, fitted to the window.
    func setImage(_ image: NSImage?) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        minimap.image = image.flatMap { Self.thumbnail(of: $0, maxSide: Self.minimapMaxSide * 2) }
        if let size = minimap.image?.size {
            let scale = Self.minimapMaxSide / max(size.width, size.height)
            minimapWidth.constant = (size.width * scale).rounded() + 2 * MinimapView.inset
            minimapHeight.constant = (size.height * scale).rounded() + 2 * MinimapView.inset
        }
        applyFit()
        zoomDidChange()
    }

    /// Swaps in a higher-resolution version of the current image, keeping zoom and position.
    func replaceImage(_ image: NSImage) {
        imageView.image = image
    }

    private static func thumbnail(of image: NSImage, maxSide: CGFloat) -> NSImage? {
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: NSSize(width: width, height: height))
        thumbnail.addRepresentation(rep)
        return thumbnail
    }

    // MARK: Zoom

    /// Largest magnification that shows the whole image, never enlarging small images.
    private var fitMagnification: CGFloat {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return 1 }
        let available = scrollView.frame.size
        guard available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / size.width, available.height / size.height)
    }

    func zoomIn() { zoom(to: magnification * Self.zoomStep) }
    func zoomOut() { zoom(to: magnification / Self.zoomStep) }
    func zoomToActualSize() { zoom(to: 1) }

    func zoomToFit() {
        applyFit()
        zoomDidChange()
    }

    private func zoom(to target: CGFloat) {
        guard hasImage else { return }
        let fit = fitMagnification
        let magnification = min(max(target, fit), Self.maxMagnification)
        if magnification <= fit * 1.001 {
            zoomToFit()
            return
        }
        isFitting = false
        scrollView.setMagnification(magnification, centeredAt: NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY))
        zoomDidChange()
    }

    private func applyFit() {
        isFitting = true
        let fit = fitMagnification
        scrollView.minMagnification = fit
        scrollView.magnification = fit
        clipView.scroll(to: clipView.constrainBoundsRect(clipView.bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func zoomDidChange() {
        updateMinimap()
        window?.invalidateCursorRects(for: imageView)
        onZoomChange?()
        if let image = imageView.image, let rep = image.representations.first {
            let scale = window?.backingScaleFactor ?? 2
            let needed = image.size.width * magnification * scale
            if CGFloat(rep.pixelsWide) < image.size.width, CGFloat(rep.pixelsWide) < needed * 0.95 {
                onNeedsDetail?()
            }
        }
    }

    @objc private func liveMagnifyEnded(_ notification: Notification) {
        isFitting = magnification <= fitMagnification * 1.001
        zoomDidChange()
    }

    override func layout() {
        super.layout()
        // Window resized: keep fitting, and never leave the image smaller than "fit".
        let fit = fitMagnification
        scrollView.minMagnification = fit
        if isFitting || magnification < fit {
            zoomToFit()
        } else {
            updateMinimap()
        }
    }

    // MARK: Minimap

    @objc private func visibleAreaChanged(_ notification: Notification) {
        updateMinimap()
    }

    private func updateMinimap() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            minimap.isHidden = true
            return
        }
        let visible = clipView.bounds
        let overflows = visible.width < size.width - 0.5 || visible.height < size.height - 0.5
        minimap.isHidden = !overflows
        guard overflows else { return }
        let shown = visible.intersection(NSRect(origin: .zero, size: size))
        minimap.viewport = NSRect(x: shown.minX / size.width, y: shown.minY / size.height,
                                  width: shown.width / size.width, height: shown.height / size.height)
    }

    /// Scrolls so that `point` (0...1 across the image, origin bottom-left) is centered.
    private func center(onUnitPoint point: NSPoint) {
        guard let size = imageView.image?.size else { return }
        var bounds = clipView.bounds
        bounds.origin = NSPoint(x: point.x * size.width - bounds.width / 2, y: point.y * size.height - bounds.height / 2)
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    func focus() {
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .upArrow?, .pageUp?: onStep?(-1)
        case .rightArrow?, .downArrow?, .pageDown?: onStep?(1)
        case .home?: onJump?(false)
        case .end?: onJump?(true)
        default:
            switch event.charactersIgnoringModifiers {
            case " ": onStep?(event.modifierFlags.contains(.shift) ? -1 : 1)
            case "+", "=": zoomIn()
            case "-", "_": zoomOut()
            case "0": zoomToFit()
            case "1": zoomToActualSize()
            case "g", "G": onToggleThumbnails?()
            default: super.keyDown(with: event)
            }
        }
    }

    // Esc leaves full screen first, then goes back to the thumbnails.
    override func cancelOperation(_ sender: Any?) {
        if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(sender)
        } else {
            onEscape?()
        }
    }
}
