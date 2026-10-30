import AppKit

/// Small overview of the whole image with a frame marking the part currently visible.
/// Click or drag in it to move the view.
final class MinimapView: NSView {
    static let inset: CGFloat = 4

    var image: NSImage? { didSet { needsDisplay = true } }
    /// Visible part of the image in unit coordinates (0...1, origin bottom-left).
    var viewport = NSRect.zero { didSet { needsDisplay = true } }
    var onMove: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var imageRect: NSRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = imageRect
        image.draw(in: rect)

        let visible = NSRect(x: rect.minX + viewport.minX * rect.width, y: rect.minY + viewport.minY * rect.height,
                             width: viewport.width * rect.width, height: viewport.height * rect.height)
        let dim = NSBezierPath(rect: rect)
        dim.append(NSBezierPath(rect: visible))
        dim.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.45).setFill()
        dim.fill()

        let frame = NSBezierPath(rect: visible.insetBy(dx: 0.75, dy: 0.75))
        frame.lineWidth = 1.5
        NSColor.white.setStroke()
        frame.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { move(to: event) }
    override func mouseDragged(with event: NSEvent) { move(to: event) }

    private func move(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        onMove?(NSPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1),
                        y: min(max((point.y - rect.minY) / rect.height, 0), 1)))
    }
}
