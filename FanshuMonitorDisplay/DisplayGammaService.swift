import CoreGraphics
import Foundation
import OSLog

nonisolated struct DisplayGammaTable: Equatable, Sendable {
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]

    var count: Int {
        min(red.count, green.count, blue.count)
    }

    func scaled(by factor: Double) -> DisplayGammaTable {
        let clampedFactor = min(1, max(0, factor))
        return DisplayGammaTable(
            red: red.map { Self.scaled($0, by: clampedFactor) },
            green: green.map { Self.scaled($0, by: clampedFactor) },
            blue: blue.map { Self.scaled($0, by: clampedFactor) }
        )
    }

    private static func scaled(_ value: CGGammaValue, by factor: Double) -> CGGammaValue {
        CGGammaValue(min(1, max(0, Double(value) * factor)))
    }
}

nonisolated protocol DisplayGammaHardware: Sendable {
    func isBuiltIn(displayID: CGDirectDisplayID) -> Bool
    func isOnline(displayID: CGDirectDisplayID) -> Bool
    func readTable(displayID: CGDirectDisplayID) -> DisplayGammaTable?
    func writeTable(_ table: DisplayGammaTable, displayID: CGDirectDisplayID) -> Bool
    func restoreColorSyncSettings()
}

nonisolated struct SystemDisplayGammaHardware: DisplayGammaHardware {
    private static let defaultTableSize: UInt32 = 256
    private static let maximumTableSize: UInt32 = 4_096

    func isBuiltIn(displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    func isOnline(displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(displayID) != 0
    }

    func readTable(displayID: CGDirectDisplayID) -> DisplayGammaTable? {
        let reportedCapacity = CGDisplayGammaTableCapacity(displayID)
        let tableSize = reportedCapacity > 1
            ? min(reportedCapacity, Self.maximumTableSize)
            : Self.defaultTableSize
        var red = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var green = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var blue = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var sampleCount: UInt32 = 0

        let result = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(
                        displayID,
                        tableSize,
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress,
                        &sampleCount
                    )
                }
            }
        }

        guard result == .success,
              sampleCount > 1,
              sampleCount <= tableSize
        else {
            return nil
        }

        let count = Int(sampleCount)
        return DisplayGammaTable(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }

    func writeTable(_ table: DisplayGammaTable, displayID: CGDirectDisplayID) -> Bool {
        guard table.count > 1 else { return false }
        let result = table.red.withUnsafeBufferPointer { redBuffer in
            table.green.withUnsafeBufferPointer { greenBuffer in
                table.blue.withUnsafeBufferPointer { blueBuffer in
                    CGSetDisplayTransferByTable(
                        displayID,
                        UInt32(table.count),
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress
                    )
                }
            }
        }
        return result == .success
    }

    func restoreColorSyncSettings() {
        CGDisplayRestoreColorSyncSettings()
    }
}

/// Applies software dimming in the display output transfer curve.
///
/// One baseline is retained per display. A transiently incomplete display list
/// cannot discard an online display's baseline and accidentally compound the
/// dimming factor on the next refresh.
nonisolated final class DisplayGammaService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fanshu.monitor.display-gamma")
    private let hardware: any DisplayGammaHardware
    private var baselines: [CGDirectDisplayID: DisplayGammaTable] = [:]

    init(hardware: any DisplayGammaHardware = SystemDisplayGammaHardware()) {
        self.hardware = hardware
    }

    func apply(factor: Double, displayID: CGDirectDisplayID) -> Bool {
        queue.sync {
            guard !hardware.isBuiltIn(displayID: displayID),
                  hardware.isOnline(displayID: displayID)
            else {
                return false
            }

            let clampedFactor = min(1, max(0, factor))
            if clampedFactor >= 0.999 {
                return restoreLocked(displayID: displayID)
            }

            if baselines[displayID] == nil {
                guard let baseline = hardware.readTable(displayID: displayID) else {
                    AppLogger.ddc.debug(
                        "Gamma baseline unavailable for display \(displayID, privacy: .public)"
                    )
                    return false
                }
                baselines[displayID] = baseline
            }

            guard let baseline = baselines[displayID] else {
                return false
            }
            return hardware.writeTable(
                baseline.scaled(by: clampedFactor),
                displayID: displayID
            )
        }
    }

    func restore(displayID: CGDirectDisplayID) -> Bool {
        queue.sync {
            restoreLocked(displayID: displayID)
        }
    }

    func restoreAll() {
        queue.sync {
            var requiresColorSyncFallback = false
            for displayID in Array(baselines.keys) where !restoreLocked(displayID: displayID) {
                requiresColorSyncFallback = true
            }
            if requiresColorSyncFallback {
                hardware.restoreColorSyncSettings()
                baselines.removeAll()
                AppLogger.ddc.notice("Gamma baseline restore used the ColorSync fallback")
            }
        }
    }

    func removeMissingDisplays(keeping displayIDs: Set<CGDirectDisplayID>) {
        queue.sync {
            for displayID in Array(baselines.keys)
            where !displayIDs.contains(displayID) && !hardware.isOnline(displayID: displayID) {
                baselines.removeValue(forKey: displayID)
            }
        }
    }

    private func restoreLocked(displayID: CGDirectDisplayID) -> Bool {
        guard let baseline = baselines[displayID] else {
            return true
        }
        guard hardware.writeTable(baseline, displayID: displayID) else {
            AppLogger.ddc.error(
                "Unable to restore Gamma baseline for display \(displayID, privacy: .public)"
            )
            return false
        }
        baselines.removeValue(forKey: displayID)
        return true
    }
}
