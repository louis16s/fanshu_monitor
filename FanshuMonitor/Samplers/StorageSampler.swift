import Darwin
import Foundation
import OSLog

nonisolated final class StorageSampler: MonitorSampler {
    var kind: MonitorKind { .storage }

    private static let healthCacheInterval: TimeInterval = 300
    private static let externalVolumeCacheInterval: TimeInterval = 30
    private let healthReader: @Sendable () -> String?
    private let nowProvider: @Sendable () -> Date
    private var cachedHealth: (value: String, date: Date)?
    private var cachedExternalVolumes: (value: String?, date: Date)?

    init(
        healthReader: @escaping @Sendable () -> String? = DiskHealthReader.read,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.healthReader = healthReader
        self.nowProvider = nowProvider
    }

    /// `statfs` is a sub-millisecond local syscall. Prewarming only the root
    /// capacity prevents the storage card from flashing a placeholder while
    /// the panel's asynchronous samplers are being scheduled.
    static func bootstrapModule() -> MonitorModule {
        StorageSampler().sample(
            previous: nil,
            context: MonitorSamplingContext(
                enabledMetricIDs: Set(
                    MonitorKind.storage.availableMetrics
                        .filter(\.isDefault)
                        .map(\.id)
                ),
                panelVisible: false,
                mode: .firstPaint
            )
        )
    }

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        var fileSystem = statfs()
        guard statfs("/", &fileSystem) == 0 else {
            AppLogger.sampler.error("StorageSampler statfs failed, errno: \(errno)")
            return previous ?? placeholderModule(.storage, summary: "无法读取")
        }

        let blockSize = Double(fileSystem.f_bsize)
        let total = Double(fileSystem.f_blocks) * blockSize
        let free = Double(fileSystem.f_bavail) * blockSize
        guard total > 0, total.isFinite, free.isFinite else {
            return previous ?? placeholderModule(.storage, summary: "无法读取")
        }
        let used = max(0, total - free)
        let percentage = total > 0 ? (used / total) * 100 : 0

        var metrics = [
            MonitorMetric(name: "used", value: bytes(used)),
            MonitorMetric(name: "free", value: bytes(free)),
            MonitorMetric(name: "total", value: bytes(total))
        ]
        if context.includes("health") {
            let previousHealth = previous?.metrics.first { $0.name == "health" }?.value
            let health = context.shouldCollectExpensiveMetric("health")
                && !context.prioritizesFirstPaint
                ? diskHealth()
                : previousHealth ?? cachedHealth?.value ?? "--"
            metrics.append(MonitorMetric(name: "health", value: health))
        }

        return MonitorModule(
            kind: .storage,
            context: context.panelVisible && !context.prioritizesFirstPaint
                ? externalVolumesJSON()
                : previous?.context,
            value: percentage,
            summary: percent(percentage),
            metrics: metrics,
            samples: seedSamples(percentage)
        )
    }

    private func diskHealth() -> String {
        let now = nowProvider()
        if let cachedHealth,
           now.timeIntervalSince(cachedHealth.date) < Self.healthCacheInterval {
            return cachedHealth.value
        }
        guard let value = healthReader() else {
            return cachedHealth?.value ?? "--"
        }
        cachedHealth = (value, now)
        return value
    }

    private func externalVolumesJSON() -> String? {
        let now = nowProvider()
        if let cachedExternalVolumes,
           now.timeIntervalSince(cachedExternalVolumes.date) < Self.externalVolumeCacheInterval {
            return cachedExternalVolumes.value
        }
        let volumes = detectExternalVolumes()
        guard !volumes.isEmpty else {
            cachedExternalVolumes = (nil, now)
            return nil
        }

        let payload = volumes.map { vol in
            let pct = vol.total > 0 ? Int((vol.used / vol.total * 100).rounded()) : 0
            return ExternalVolumePayload(
                name: vol.name,
                used: bytes(vol.used),
                free: bytes(vol.free),
                total: bytes(vol.total),
                percentage: pct
            )
        }

        guard let data = try? JSONEncoder().encode(payload),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        cachedExternalVolumes = (value, now)
        return value
    }

    private func detectExternalVolumes() -> [ExternalVolume] {
        guard let volumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey], options: []) else {
            return []
        }

        var volumes: [ExternalVolume] = []
        for url in volumeURLs {
            guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey]),
                  let totalCapacity = values.volumeTotalCapacity,
                  let availableCapacity = values.volumeAvailableCapacity,
                  let name = values.volumeName,
                  // 用 volumeIsInternalKey == false 检测外置卷，比 removable 更准确
                  values.volumeIsInternal == false else {
                continue
            }

            let total = Double(totalCapacity)
            let free = Double(availableCapacity)
            let used = max(0, total - free)

            guard total > 0 else { continue }

            volumes.append(ExternalVolume(name: name, used: used, free: free, total: total))
        }

        // 最多 3 个，避免撑高面板
        return Array(volumes.prefix(3))
    }
}

nonisolated enum DiskHealthReader {
    static func read() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !process.isRunning else {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return status(fromPropertyList: data)
        } catch {
            AppLogger.sampler.error(
                "Unable to read disk health: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func status(fromPropertyList data: Data) -> String? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let dictionary = propertyList as? [String: Any],
        let status = dictionary["SMARTStatus"] as? String else {
            return nil
        }
        return switch status.lowercased() {
        case "verified": "normal"
        case "failing": "failing"
        case "not supported": "unsupported"
        default: status
        }
    }
}

nonisolated private struct ExternalVolume {
    let name: String
    let used: Double
    let free: Double
    let total: Double
}

nonisolated private struct ExternalVolumePayload: Encodable {
    let name: String
    let used: String
    let free: String
    let total: String
    let percentage: Int
}
