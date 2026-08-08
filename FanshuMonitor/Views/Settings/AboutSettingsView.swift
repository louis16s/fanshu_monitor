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
            sectionSpacing: 14,
            topPadding: 18,
            bottomPadding: 18
        ) {
            aboutHeader

            SettingsGroup {
                AboutSettingRow(
                    symbol: "safari",
                    title: String(localized: "about.website")
                ) {
                    websiteButton
                }

                SettingsDivider()

                AboutSettingRow(
                    symbol: "arrow.triangle.2.circlepath",
                    title: String(localized: "settings.check-updates")
                ) {
                    HStack(spacing: 10) {
                        updateControl
                        Toggle("", isOn: $settings.updateChecksEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help("自动检查更新")
                            .accessibilityLabel("自动检查更新")
                    }
                }

                SettingsDivider()

                AboutSettingRow(
                    symbol: "computermouse",
                    title: "鼠标增强",
                    subtitle: "目前仅适配 Logitech MX Anywhere 3S"
                ) {}
            }

            Text("© 2026 番薯Monitor contributors · MIT")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
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
    private var websiteButton: some View {
        if #available(macOS 26, *) {
            Button {
                NSWorkspace.shared.open(websiteURL)
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
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

    @ViewBuilder
    private var updateControl: some View {
        switch updateChecker.state {
        case .idle:
            updateButton(symbol: "arrow.clockwise", help: String(localized: "about.check-updates")) {
                Task { await updateChecker.checkForUpdates() }
            }

        case .checking:
            ProgressView()
                .controlSize(.small)
                .help(String(localized: "about.checking"))

        case .upToDate:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(String(localized: "about.up-to-date"))
                updateButton(symbol: "arrow.clockwise", help: String(localized: "about.check-again")) {
                    Task { await updateChecker.checkForUpdates() }
                }
            }

        case .updateAvailable(let latestVersion, _, let downloadURL, _):
            Button {
                NSWorkspace.shared.open(downloadURL)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(String(localized: "about.found") + " \(latestVersion)")
            .accessibilityLabel(String(localized: "about.download-update"))

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                updateButton(symbol: "arrow.clockwise", help: String(localized: "about.retry")) {
                    Task { await updateChecker.checkForUpdates() }
                }
            }
        }
    }

    @ViewBuilder
    private func updateButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        if #available(macOS 26, *) {
            Button(action: action) {
                Image(systemName: symbol)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(help)
        } else {
            Button(action: action) {
                Image(systemName: symbol)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(help)
        }
    }
}

private struct AboutSettingRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let accessory: Accessory

    init(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            accessory
                .frame(minWidth: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 10 : 11)
        .frame(minHeight: subtitle == nil ? 44 : 54)
    }
}
