import CoreGraphics
import Darwin
import Foundation

enum NativeOSDService {
    private typealias SharedManagerFunction = @convention(c) (
        AnyObject,
        Selector
    ) -> Unmanaged<AnyObject>?
    private typealias ShowBrightnessFunction = @convention(c) (
        AnyObject,
        Selector,
        Int64,
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        Bool
    ) -> Void

    private static let brightnessImage: Int64 = 1
    private static let priority: UInt32 = 0x1F4
    private static let osdBrightnessScale = 64.0

    static func showBrightness(displayID: CGDirectDisplayID, value: Double) {
        guard PrivateDisplayAPI.shared.loadOSDFramework() else {
            return
        }
        guard let managerClass = NSClassFromString("OSDManager"),
              let objcHandle = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_LOCAL),
              let objcMessageSend = dlsym(objcHandle, "objc_msgSend") else {
            return
        }
        defer { dlclose(objcHandle) }

        let sharedManager = unsafeBitCast(objcMessageSend, to: SharedManagerFunction.self)
        guard let manager = sharedManager(
            managerClass as AnyObject,
            Selector(("sharedManager"))
        )?.takeUnretainedValue() else {
            return
        }

        let clampedValue = min(100, max(0, value))
        let scaledValue = clampedValue / 100 * osdBrightnessScale
        let showBrightness = unsafeBitCast(objcMessageSend, to: ShowBrightnessFunction.self)
        showBrightness(
            manager,
            Selector(("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")),
            brightnessImage,
            displayID,
            priority,
            1000,
            UInt32((scaledValue * 100).rounded()),
            UInt32(osdBrightnessScale * 100),
            false
        )
    }
}
