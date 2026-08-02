import AppKit
import CoreGraphics

@MainActor
enum DisplayCapabilityProbe {
    static func snapshot(displayID: CGDirectDisplayID, kind: DisplayKind) -> DisplayCapabilities {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
        let width = mode.map { Int($0.width) } ?? Int(screen?.frame.width ?? 0)
        let height = mode.map { Int($0.height) } ?? Int(screen?.frame.height ?? 0)
        let refreshRate = DisplayCapabilityFormatter.refreshRate(
            current: mode?.refreshRate ?? 0,
            maximumFramesPerSecond: screen?.maximumFramesPerSecond ?? 0,
            maximumRefreshInterval: screen?.maximumRefreshInterval ?? 0
        )
        let dynamicRange = screen.map {
            $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 ? "HDR" : "SDR"
        } ?? "--"

        return DisplayCapabilities(
            resolution: DisplayCapabilityFormatter.resolution(width: width, height: height),
            refreshRate: refreshRate,
            dynamicRange: dynamicRange,
            colorSpace: DisplayCapabilityFormatter.colorSpace(screen?.colorSpace?.localizedName),
            connection: DisplayCapabilityFormatter.connection(for: kind)
        )
    }
}
