import SwiftUI

struct StorageVolumeDetailList: View {
    let volumes: [StorageVolumeInfo]
    let kind: MonitorKind
    let tint: Color
    let theme: MonitorPanelTheme

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(theme.rowSeparator(for: kind))
                .frame(height: 1)
                .padding(.leading, 28)

            VStack(spacing: 8) {
                ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                    if index > 0 {
                        Rectangle()
                            .fill(theme.rowSeparator(for: kind).opacity(0.72))
                            .frame(height: 1)
                            .padding(.leading, 22)
                    }

                    StorageVolumeRow(volume: volume, kind: kind, tint: tint, theme: theme)
                }
            }
            .padding(.leading, 28)
        }
    }
}

private struct StorageVolumeRow: View {
    let volume: StorageVolumeInfo
    let kind: MonitorKind
    let tint: Color
    let theme: MonitorPanelTheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: volume.symbol)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(volume.name)
                        .panelCaptionFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(volume.name)

                    Spacer(minLength: 8)

                    Text("\(volume.clampedPercentage)%")
                        .panelMonoFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(theme.badgeFill(for: kind))
                        }
                }

                ProgressMeter(value: Double(volume.clampedPercentage), tint: tint, theme: theme)
                    .frame(height: 3)

                HStack(spacing: 8) {
                    StorageVolumeStat(label: String(localized: "metric.storage.used"), value: volume.used, theme: theme)
                    StorageVolumeStat(label: String(localized: "metric.storage.free"), value: volume.free, theme: theme)
                    StorageVolumeStat(label: String(localized: "metric.storage.total"), value: volume.total, theme: theme)
                    if let health = volume.health {
                        StorageVolumeStat(label: String(localized: "metric.storage.health"), value: health, theme: theme)
                    }
                }
            }
        }
    }
}

private struct StorageVolumeStat: View {
    let label: String
    let value: String
    let theme: MonitorPanelTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .panelCaptionFont(size: 9)
                .foregroundStyle(theme.captionText)
                .lineLimit(1)

            Text(value)
                .panelMonoFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StorageVolumeInfo: Identifiable {
    let id: String
    let name: String
    let used: String
    let free: String
    let total: String
    let health: String?
    let percentage: Int

    var isExternal: Bool

    var symbol: String {
        isExternal ? "externaldrive" : "internaldrive"
    }

    var clampedPercentage: Int {
        min(100, max(0, percentage))
    }
}

func parseExternalVolumes(_ context: String?) -> [StorageVolumeInfo] {
    guard let context, let data = context.data(using: .utf8) else {
        return []
    }

    guard let payload = try? JSONDecoder().decode([ExternalVolumePayload].self, from: data) else {
        return []
    }

    return payload.enumerated().map { index, volume in
        StorageVolumeInfo(
            id: "external-\(index)-\(volume.name)",
            name: volume.name,
            used: volume.used,
            free: volume.free,
            total: volume.total,
            health: nil,
            percentage: volume.percentage,
            isExternal: true
        )
    }
}

private struct ExternalVolumePayload: Decodable {
    let name: String
    let used: String
    let free: String
    let total: String
    let percentage: Int
}
