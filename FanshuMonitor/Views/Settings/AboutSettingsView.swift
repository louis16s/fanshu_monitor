import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @State private var updateChecker = UpdateChecker()

    private let websiteURL = URL(string: "https://louis16s.github.io/fanshu_monitor/")!

    private var appVersion: String {
        guard AppVersion.current != "0.0.0" else {
            return String(localized: "about.unknown")
        }
        return AppVersion.current
    }

    var body: some View {
        SettingsPage(
            scrolls: false,
            sectionSpacing: 12,
            topPadding: 18,
            bottomPadding: 18
        ) {
            SettingsGroup {
                aboutHeader
            }

            SettingsGroup {
                SettingsRow(title: String(localized: "about.website")) {
                    if #available(macOS 26, *) {
                        Button {
                            NSWorkspace.shared.open(websiteURL)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.glass)
                        .help(String(localized: "about.open-website"))
                        .accessibilityLabel(String(localized: "about.open-website"))
                    } else {
                        Link(destination: websiteURL) {
                            Image(systemName: "arrow.up.right")
                        }
                        .help(String(localized: "about.open-website"))
                        .accessibilityLabel(String(localized: "about.open-website"))
                    }
                }
            }

            SettingsGroup(String(localized: "settings.utilities")) {
                SettingsRow(title: String(localized: "settings.check-updates"), subtitle: String(localized: "settings.check-updates.subtitle")) {
                    HStack(spacing: 10) {
                        updateAccessory
                        Toggle("", isOn: $settings.updateChecksEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            SettingsGroup("兼容性") {
                SettingsRow(
                    title: "鼠标增强",
                    subtitle: "目前仅适配 Logitech MX Anywhere 3S"
                ) {
                    Image(systemName: "computermouse")
                        .foregroundStyle(.secondary)
                }
            }

            Text("© 2026 番薯Monitor contributors · MIT")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .task {
            guard settings.updateChecksEnabled else { return }
            await updateChecker.checkForUpdates()
        }
    }

    @ViewBuilder
    private var aboutHeader: some View {
        SettingsIconHeader(
            title: "番薯Monitor",
            subtitle: String(localized: "about.version") + " \(appVersion)",
            footnote: String(localized: "about.footnote")
        )
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch updateChecker.state {
        case .idle:
            primaryButton(title: String(localized: "about.check-updates")) {
                Task { await updateChecker.checkForUpdates() }
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "about.checking"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack(spacing: 8) {
                Text(String(localized: "about.up-to-date"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if #available(macOS 26, *) {
                    Button(String(localized: "about.check-again")) {
                        Task { await updateChecker.checkForUpdates() }
                    }
                    .buttonStyle(.glass)
                } else {
                    Button(String(localized: "about.check-again")) {
                        Task { await updateChecker.checkForUpdates() }
                    }
                }
            }

        case .updateAvailable(let latestVersion, _, let downloadURL, _):
            VStack(alignment: .trailing, spacing: 5) {
                Text(String(localized: "about.found") + " \(latestVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                primaryButton(title: String(localized: "about.download-update")) {
                    NSWorkspace.shared.open(downloadURL)
                }
            }

        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if #available(macOS 26, *) {
                    Button(String(localized: "about.retry")) {
                        Task { await updateChecker.checkForUpdates() }
                    }
                    .buttonStyle(.glass)
                } else {
                    Button(String(localized: "about.retry")) {
                        Task { await updateChecker.checkForUpdates() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        if #available(macOS 26, *) {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
        }
    }
}
