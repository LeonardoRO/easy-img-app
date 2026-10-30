import AppKit
import UniformTypeIdentifiers

enum Clipboard {
    /// Full path with symlinks resolved (/tmp → /private/tmp), so file and folder paths always match.
    static func copyPath(of url: URL) {
        copy(url.resolvingSymlinksInPath().path)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Puts the image on the pasteboard as the file (Finder pastes a copy) and as image data
    /// (Messages, Mail, documents paste the picture).
    static func copyImage(at url: URL) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let type, let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        // Apps that only read TIFF/PNG get a converted copy.
        if type != .png, type != .jpeg, let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}

/// Short message that fades in over the window ("Path copied") and goes away by itself.
final class ToastView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        alphaValue = 0
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Never intercepts clicks meant for the image.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String) {
        label.stringValue = message
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
