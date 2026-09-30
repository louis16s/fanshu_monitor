import AppKit

enum SettingsWindowMetrics {
    static let width: CGFloat = 700
    static let height: CGFloat = 620
    static let sidebarWidth: CGFloat = 176

    static var contentSize: NSSize {
        NSSize(width: width, height: height)
    }

    static func needsResize(currentSize: NSSize, targetSize: NSSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(currentSize.width - targetSize.width) > tolerance
            || abs(currentSize.height - targetSize.height) > tolerance
    }
}
