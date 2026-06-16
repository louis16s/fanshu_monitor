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

            SettingsGroup(String(localized: "settings.utilities")) {
                SettingsRow(title: String(localized: "settings.check-updates"), subtitle: String(localized: "settings.check-updates.subtitle")) {
                    Toggle("", isOn: $settings.updateChecksEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: String(localized: "settings.codex-refresh-interval"), subtitle: String(localized: "settings.codex-refresh-interval.subtitle")) {
                    Stepper(value: $settings.codexRefreshIntervalMinutes, in: 1...60, step: 1) {
                        Text(codexRefreshIntervalText)
                            .monospacedDigit()
                    }
                    .fixedSize()
                }

            }

            HStack {
                Spacer()
                if #available(macOS 26, *) {
                    Button(String(localized: "settings.reset-settings")) {
                        settings.resetAll()
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                } else {
                    Button(String(localized: "settings.reset-settings")) {
                        settings.resetAll()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, -2)
            .padding(.trailing, 2)
        }
    }

    private var codexRefreshIntervalText: String {
        String(
            format: String(localized: "settings.minutes-format"),
            Int(settings.codexRefreshIntervalMinutes)
        )
    }
}
