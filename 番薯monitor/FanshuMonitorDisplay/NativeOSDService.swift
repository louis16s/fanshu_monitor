import CoreGraphics
import Foundation

enum NativeOSDService {
    private static let brightnessImage: Int64 = 1
    private static let priority: UInt32 = 0x1F4
    private static let osdBrightnessScale = 64.0

    static func showBrightness(displayID: CGDirectDisplayID, value: Double) {
        guard let manager = OSDManager.sharedManager() as? OSDManager else {
            return
        }

        let clampedValue = min(100, max(0, value))
        let scaledValue = clampedValue / 100 * osdBrightnessScale
        manager.showImage(
            brightnessImage,
            onDisplayID: displayID,
            priority: priority,
            msecUntilFade: 1000,
            filledChiclets: UInt32((scaledValue * 100).rounded()),
            totalChiclets: UInt32(osdBrightnessScale * 100),
            locked: false
        )
    }
}
