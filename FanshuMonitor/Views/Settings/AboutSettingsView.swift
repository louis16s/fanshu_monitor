import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    let updateChecker: UpdateChecker

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
                    title: String(localized: "settings.automatic-update-checks"),
                    subtitle: String(localized: "settings.automatic-update-checks.subtitle")
                ) {
                    Toggle("", isOn: $settings.updateChecksEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(String(localized: "settings.automatic-update-checks"))
                        .accessibilityLabel(String(localized: "settings.automatic-update-checks"))
                }

                SettingsDivider()

                AboutSettingRow(
                    symbol: updateStatusSymbol,
                    title: String(localized: "about.current-version") + " \(appVersion)",
                    subtitle: updateStatusText
                ) {
                    updateControl
                }

                SettingsDivider()

                AboutSettingRow(
                    symbol: "computermouse",
                    title: String(localized: "about.mouse-enhancement"),
                    subtitle: String(localized: "about.mouse-compatibility")
                ) {}
            }

            Text("© 2026 番薯Monitor contributors · MIT")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
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
        Button {
            NSWorkspace.shared.open(websiteURL)
        } label: {
            Image(systemName: "arrow.up.right")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help(String(localized: "about.open-website"))
        .accessibilityLabel(String(localized: "about.open-website"))
    }

    @ViewBuilder
    private var updateControl: some View {
        switch updateChecker.state {
        case .idle:
            updateButton(title: String(localized: "about.check-updates")) {
                Task { await updateChecker.checkForUpdates() }
            }
        case .checking:
            ProgressView()
                .controlSize(.small)
                .help(String(localized: "about.checking"))
        case .upToDate:
            updateButton(title: String(localized: "about.check-again")) {
                Task { await updateChecker.checkForUpdates() }
            }
        case .updateAvailable(let latestVersion, _, let downloadURL, _):
            Button(String(localized: "about.download-update")) {
                NSWorkspace.shared.open(downloadURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(String(localized: "about.found") + " \(latestVersion)")
        case .failed:
            updateButton(title: String(localized: "about.retry")) {
                Task { await updateChecker.checkForUpdates() }
            }
        }
    }

    @ViewBuilder
    private func updateButton(title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.glass)
            .controlSize(.small)
    }

    private var updateStatusSymbol: String {
        if updateChecker.lastError != nil { return "exclamationmark.triangle.fill" }
        switch updateChecker.state {
        case .idle, .checking:
            return "arrow.triangle.2.circlepath"
        case .upToDate:
            return "checkmark.circle.fill"
        case .updateAvailable:
            return "arrow.down.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var updateStatusText: String {
        if let lastError = updateChecker.lastError { return lastError }
        switch updateChecker.state {
        case .idle:
            return String(localized: "about.update-not-checked")
        case .checking:
            return String(localized: "about.checking")
        case .upToDate:
            return String(localized: "about.up-to-date")
        case .updateAvailable(let latestVersion, _, _, _):
            return String(localized: "about.found") + " \(latestVersion)"
        case .failed(let message):
            return message
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
