import AppKit
import SwiftUI
import OSLog

enum SettingsTab: String {
    case general
    case lockScreen
    case mouse
    case about
}

enum SettingsWindowPresenter {
    static let routeChangeNotification = Notification.Name("SettingsWindowPresenter.routeChange")
    static let tabUserInfoKey = "tab"

    @MainActor
    private static weak var settingsWindow: NSWindow?
    @MainActor
    private static var pendingFocus = false
    @MainActor
    private static var pendingTab: SettingsTab?

    @MainActor
    static func open(_ openSettings: OpenSettingsAction, tab: SettingsTab? = nil) {
        AppLogger.settings.info("Opening settings window")
        if let tab {
            pendingTab = tab
        }

        if let window = settingsWindow {
            focus(window)
            broadcastPendingTab()
            return
        }

        pendingFocus = true
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    @MainActor
    static func register(_ window: NSWindow) {
        let isNewWindow = settingsWindow !== window
        settingsWindow = window
        if isNewWindow {
            AppLogger.settings.info("Registering settings window")
            window.title = ""
            window.minSize = SettingsWindowMetrics.contentSize
        }

        if pendingFocus {
            pendingFocus = false
            focus(window)
        }

        broadcastPendingTab()
    }

    @MainActor
    private static func broadcastPendingTab() {
        guard let tab = pendingTab else { return }
        pendingTab = nil
        NotificationCenter.default.post(
            name: routeChangeNotification,
            object: nil,
            userInfo: [tabUserInfoKey: tab.rawValue]
        )
    }

    @MainActor
    private static func focus(_ window: NSWindow) {
        AppLogger.settings.debug("Focusing settings window")
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
