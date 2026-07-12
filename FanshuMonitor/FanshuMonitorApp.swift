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
    @StateObject private var monitorStore = MonitorStore()
    @Environment(\.colorScheme) private var colorScheme

    var body: some Scene {
        MenuBarExtra {
            MonitorPanelView(store: monitorStore)
                .preferredColorScheme(effectiveColorScheme)
                .environment(\.locale, effectiveLocale)
        } label: {
            Image(nsImage: monitorStore.menuBarIconImage)
            .resizable()
            .frame(width: 18, height: 18)
            .help("番薯Monitor")
        }
        .menuBarExtraStyle(.window)
        .commands { AppMenuCommands() }

        #if DEBUG
        WindowGroup("番薯Monitor Preview") {
            ContentView(store: monitorStore)
                .preferredColorScheme(effectiveColorScheme)
                .environment(\.locale, effectiveLocale)
        }
        .windowResizability(.contentSize)
        #endif

        Settings {
            SettingsRootView(
                settings: monitorStore.settings,
                mouseController: monitorStore.mouseController,
                lockScreenController: monitorStore.lockScreenController
            )
                .environment(\.locale, effectiveLocale)
                // 设置窗口始终跟随系统外观
        }
        .windowResizability(.contentSize)
    }

    private var effectiveColorScheme: ColorScheme? {
        monitorStore.settings.themePreference.colorScheme
    }

    private var effectiveLocale: Locale {
        monitorStore.settings.languagePreference.locale ?? .current
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
