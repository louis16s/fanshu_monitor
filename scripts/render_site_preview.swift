import AppKit
import WebKit

final class PreviewRenderer: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let app = NSApplication.shared
    private let window: NSWindow
    private let webView: WKWebView
    private let outputURL: URL
    private var hasRendered = false

    init(root: URL) {
        outputURL = root.appendingPathComponent("docs/images/site-preview.png")
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1280, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.appearance = NSAppearance(named: .aqua)
        webView.appearance = NSAppearance(named: .aqua)
        app.setActivationPolicy(.accessory)
        app.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        webView.loadFileURL(root.appendingPathComponent("docs/zh/index.html"), allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasRendered else { return }
        hasRendered = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            let snapshotConfiguration = WKSnapshotConfiguration()
            snapshotConfiguration.rect = CGRect(x: 0, y: 0, width: 1280, height: 720)
            webView.takeSnapshot(with: snapshotConfiguration) { [self] image, error in
                defer {
                    window.close()
                    app.terminate(nil)
                }
                guard let image, error == nil,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    fputs("Could not capture website preview: \(error?.localizedDescription ?? "unknown error")\n", stderr)
                    return
                }
                do {
                    try png.write(to: outputURL, options: .atomic)
                    print("Rendered website preview at \(outputURL.path)")
                } catch {
                    fputs("Could not write website preview: \(error)\n", stderr)
                }
            }
        }
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let renderer = PreviewRenderer(root: root)
NSApplication.shared.run()
