import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: MonitorSettings

    var body: some View {
        SettingsPage(scrolls: false) {
            SettingsGroup {
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

            SettingsGroup("实用功能") {
                SettingsRow(title: "检查更新", subtitle: "允许后台检查新版本，手动检查始终可用。") {
                    Toggle("", isOn: $settings.updateChecksEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

            }

            HStack {
                Spacer()
                if #available(macOS 26, *) {
                    Button("重置设置") {
                        settings.resetAll()
                    }
                    .buttonStyle(.glass)
                } else {
                    Button("重置设置") {
                        settings.resetAll()
                    }
                }
            }
        }
    }
}
