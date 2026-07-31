import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @State private var updateChecker = UpdateChecker()

    private let releasesURL = URL(string: "https://github.com/louis16s/fanshu_monitor/releases")!

    private var appVersion: String {
        guard AppVersion.current != "0.0.0" else {
            return String(localized: "about.unknown")
        }
        return AppVersion.current
    }

    var body: some View {
        SettingsPage {
            SettingsGroup {
                aboutHeader
            }

            SettingsGroup(String(localized: "settings.utilities")) {
                SettingsRow(title: String(localized: "settings.check-updates"), subtitle: String(localized: "settings.check-updates.subtitle")) {
                    Toggle("", isOn: $settings.updateChecksEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup {
                SettingsRow(title: String(localized: "about.release-version")) {
                    if #available(macOS 26, *) {
                        Button {
                            NSWorkspace.shared.open(releasesURL)
                        } label: {
                            Label("Releases", systemImage: "shippingbox")
                        }
                        .buttonStyle(.glass)
                    } else {
                        Link(destination: releasesURL) {
                            Label("Releases", systemImage: "shippingbox")
                        }
                    }
                }
            }

            SettingsGroup("参考") {
                ReferenceLinkRow(title: "Mouser", url: URL(string: "https://github.com/TomBadash/Mouser")!)
                SettingsDivider()
                ReferenceLinkRow(title: "BetterDisplay", url: URL(string: "https://github.com/waydabber/BetterDisplay")!)
                SettingsDivider()
                ReferenceLinkRow(title: "Hagimi Monitor", url: URL(string: "https://github.com/Acerola-1/hagimi-monitor")!)
                SettingsDivider()
                ReferenceLinkRow(title: "MonitorControl", url: URL(string: "https://github.com/MonitorControl/MonitorControl")!)
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
        ) {
            updateAccessory
        }
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

private struct ReferenceLinkRow: View {
    let title: String
    let url: URL

    var body: some View {
        SettingsRow(title: title) {
            Link(destination: url) {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }
}
