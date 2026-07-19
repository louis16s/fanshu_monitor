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
                            Text(colorScheme.title).tag(colorScheme)
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

            SettingsGroup("权限") {
                SettingsRow(title: "辅助功能", subtitle: "用于接管 F1/F2 和鼠标可编程按键") {
                    Button(accessibilityTrusted ? "已授权" : "授权") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        accessibilityTrusted = AXIsProcessTrusted()
                    }
                    .fixedSize()
                    .disabled(accessibilityTrusted)
                }

                SettingsDivider()

                SettingsRow(title: "输入监听", subtitle: "用于识别系统亮度键") {
                    Button(inputMonitoringTrusted ? "已授权" : "授权") {
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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionState()
        }
        .confirmationDialog(
            "重置所有设置",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重置所有设置", role: .destructive) {
                settings.resetAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有模块、外观、显示器、鼠标和锁屏设置都会恢复默认值")
        }
    }

    private func refreshPermissionState() {
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringTrusted = CGPreflightListenEventAccess()
    }
}
