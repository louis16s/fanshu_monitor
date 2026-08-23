//
//  FanshuMonitorApp.swift
//  FanshuMonitor
//
//  
//

import SwiftUI

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

@main
struct FanshuMonitorApp: App {
    @StateObject private var settings: MonitorSettings
    @StateObject private var monitorStore: MonitorStore
    @Environment(\.colorScheme) private var colorScheme

    init() {
        let settings = MonitorSettings()
        _settings = StateObject(wrappedValue: settings)
        _monitorStore = StateObject(wrappedValue: MonitorStore(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPanelView(store: monitorStore, settings: settings)
                .preferredColorScheme(effectiveColorScheme)
                .environment(\.locale, effectiveLocale)
        } label: {
            Image(nsImage: monitorStore.menuBarIconImage)
                .help("番薯Monitor")
        }
        .menuBarExtraStyle(.window)
        .commands { AppMenuCommands() }

        #if DEBUG
        WindowGroup("番薯Monitor Preview") {
            ContentView(store: monitorStore, settings: settings)
                .preferredColorScheme(effectiveColorScheme)
                .environment(\.locale, effectiveLocale)
        }
        .windowResizability(.contentSize)
        #endif

        Settings {
            SettingsRootView(
                settings: settings,
                mouseController: monitorStore.mouseController,
                lockScreenController: monitorStore.lockScreenController,
                updateChecker: monitorStore.updateChecker,
                requestWiFiAuthorization: monitorStore.requestWiFiAuthorizationFromForeground
            )
                .environment(\.locale, effectiveLocale)
                // 设置窗口始终跟随系统外观
        }
        .windowResizability(.contentSize)
    }

    private var effectiveColorScheme: ColorScheme? {
        settings.themePreference.colorScheme
    }

    private var effectiveLocale: Locale {
        settings.languagePreference.locale ?? .current
    }
}

// MARK: - Menu Commands

struct AppMenuCommands: Commands {
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "menu.about")) {
                SettingsWindowPresenter.open(openSettings, tab: .about)
            }

            Divider()

            Button(String(localized: "menu.quit")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
