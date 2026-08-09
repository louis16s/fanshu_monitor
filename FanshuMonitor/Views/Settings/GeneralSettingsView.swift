import ApplicationServices
import Combine
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var inputMonitoringTrusted = CGPreflightListenEventAccess()
    @State private var showsResetConfirmation = false

    var body: some View {
        SettingsPage {
            SettingsGroup(String(localized: "settings.general")) {
                SettingsRow(title: String(localized: "settings.launch-at-login"), subtitle: String(localized: "settings.launch-at-login.subtitle")) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup(String(localized: "settings.appearance")) {
                SettingsRow(title: String(localized: "settings.theme")) {
                    Picker(String(localized: "settings.theme"), selection: $settings.themePreference) {
                        ForEach(AppThemePreference.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(title: String(localized: "settings.language")) {
                    Picker(String(localized: "settings.language"), selection: $settings.languagePreference) {
                        ForEach(AppLanguagePreference.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsDivider()

                SettingsRow(title: String(localized: "settings.color-scheme")) {
                    Picker(String(localized: "settings.color-scheme"), selection: $settings.colorSchemePreference) {
                        ForEach(MonitorColorSchemePreference.allCases) { colorScheme in
                            ColorSchemeOptionLabel(preference: colorScheme)
                                .tag(colorScheme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsGroup(String(localized: "settings.menu-bar")) {
                SettingsRow(title: String(localized: "settings.halo-ring")) {
                    Picker(String(localized: "settings.halo-ring"), selection: $settings.ringSource) {
                        ForEach(HaloRingSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsGroup(String(localized: "settings.permissions")) {
                SettingsRow(
                    title: String(localized: "settings.accessibility"),
                    subtitle: String(localized: "settings.accessibility.subtitle")
                ) {
                    Button(accessibilityTrusted ? String(localized: "settings.authorized") : String(localized: "settings.authorize")) {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        accessibilityTrusted = AXIsProcessTrusted()
                    }
                    .fixedSize()
                    .disabled(accessibilityTrusted)
                }

                SettingsDivider()

                SettingsRow(
                    title: String(localized: "settings.input-monitoring"),
                    subtitle: String(localized: "settings.input-monitoring.subtitle")
                ) {
                    Button(inputMonitoringTrusted ? String(localized: "settings.authorized") : String(localized: "settings.authorize")) {
                        _ = CGRequestListenEventAccess()
                        inputMonitoringTrusted = CGPreflightListenEventAccess()
                    }
                    .fixedSize()
                    .disabled(inputMonitoringTrusted)
                }
            }

            HStack {
                Spacer()
                if #available(macOS 26, *) {
                    Button(String(localized: "settings.reset-settings")) {
                        showsResetConfirmation = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                } else {
                    Button(String(localized: "settings.reset-settings")) {
                        showsResetConfirmation = true
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, -2)
            .padding(.trailing, 2)
        }
        .onAppear {
            refreshPermissionState()
            settings.refreshLaunchAtLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionState()
            settings.refreshLaunchAtLoginStatus()
        }
        .confirmationDialog(
            String(localized: "settings.reset-all.title"),
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.reset-all.action"), role: .destructive) {
                settings.resetAll()
            }
            Button(String(localized: "settings.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.reset-all.message"))
        }
    }

    private func refreshPermissionState() {
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringTrusted = CGPreflightListenEventAccess()
    }
}

private struct ColorSchemeOptionLabel: View {
    let preference: MonitorColorSchemePreference

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 2) {
                ForEach(Array(preference.previewColors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
            }

            Text(preference.title)
        }
    }
}
