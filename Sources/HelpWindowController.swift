import AppKit
import WebKit

/// Help → Easy Img Help: shows the bundled Help.html. Links to other sites open in the browser.
final class HelpWindowController: NSWindowController, WKNavigationDelegate {
    private let webView = WKWebView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Easy Img Help"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init(window: window)
        webView.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "Help", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, !url.isFileURL {
            // Only web and mail links leave the help window; anything else is ignored.
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
