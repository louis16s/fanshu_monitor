import CoreGraphics
import Foundation
import OSLog

/// Applies software dimming in the display output transfer curve.
///
/// The service keeps one baseline per display. If the baseline cannot be
/// captured, it refuses to apply Gamma so the caller can use its overlay
/// fallback without overwriting an unknown color profile.
nonisolated final class DisplayGammaService: @unchecked Sendable {
    static let tableSize: UInt32 = 256

    private struct Baseline {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    private let queue = DispatchQueue(label: "com.fanshu.monitor.display-gamma")
    private var baselines: [CGDirectDisplayID: Baseline] = [:]

    func apply(factor: Double, displayID: CGDirectDisplayID) -> Bool {
        queue.sync {
            guard CGDisplayIsBuiltin(displayID) == 0,
                  CGDisplayIsOnline(displayID) == 1
            else {
                return false
            }

            let clampedFactor = min(1, max(0, factor))
            if clampedFactor >= 0.999 {
                return restoreLocked(displayID: displayID)
            }

            if baselines[displayID] == nil {
                guard let baseline = readBaseline(displayID: displayID) else {
                    return false
                }
                baselines[displayID] = baseline
            }

            guard let baseline = baselines[displayID] else {
                return false
            }

            let red = baseline.red.map { scaled($0, by: clampedFactor) }
            let green = baseline.green.map { scaled($0, by: clampedFactor) }
            let blue = baseline.blue.map { scaled($0, by: clampedFactor) }
            let result = red.withUnsafeBufferPointer { redBuffer in
                green.withUnsafeBufferPointer { greenBuffer in
                    blue.withUnsafeBufferPointer { blueBuffer in
                        CGSetDisplayTransferByTable(
                            displayID,
                            UInt32(red.count),
                            redBuffer.baseAddress,
                            greenBuffer.baseAddress,
                            blueBuffer.baseAddress
                        )
                    }
                }
            }

            return result == .success
        }
    }

    func restore(displayID: CGDirectDisplayID) -> Bool {
        queue.sync {
            restoreLocked(displayID: displayID)
        }
    }

    func restoreAll() {
        queue.sync {
            for displayID in Array(baselines.keys) {
                _ = restoreLocked(displayID: displayID)
            }
        }
    }

    func removeMissingDisplays(keeping displayIDs: Set<CGDirectDisplayID>) {
        queue.sync {
            for displayID in Array(baselines.keys) where !displayIDs.contains(displayID) {
                baselines.removeValue(forKey: displayID)
            }
        }
    }

    private func readBaseline(displayID: CGDirectDisplayID) -> Baseline? {
        var red = [CGGammaValue](repeating: 0, count: Int(Self.tableSize))
        var green = [CGGammaValue](repeating: 0, count: Int(Self.tableSize))
        var blue = [CGGammaValue](repeating: 0, count: Int(Self.tableSize))
        var sampleCount: UInt32 = 0

        let result = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(
                        displayID,
                        Self.tableSize,
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
              sampleCount <= Self.tableSize
        else {
            AppLogger.ddc.debug(
                "Gamma baseline unavailable for display \(displayID, privacy: .public)"
            )
            return nil
        }

        let count = Int(sampleCount)
        return Baseline(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }

    private func restoreLocked(displayID: CGDirectDisplayID) -> Bool {
        guard let baseline = baselines[displayID] else {
            return true
        }

        let result = baseline.red.withUnsafeBufferPointer { redBuffer in
            baseline.green.withUnsafeBufferPointer { greenBuffer in
                baseline.blue.withUnsafeBufferPointer { blueBuffer in
                    CGSetDisplayTransferByTable(
                        displayID,
                        UInt32(baseline.red.count),
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress
                    )
                }
            }
        }
        if result == .success {
            baselines.removeValue(forKey: displayID)
            return true
        }
        return false
    }

    private func scaled(_ value: CGGammaValue, by factor: Double) -> CGGammaValue {
        CGGammaValue(min(1, max(0, Double(value) * factor)))
    }
}
