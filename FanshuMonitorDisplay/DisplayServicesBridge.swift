import CoreGraphics
import Foundation

nonisolated final class DisplayServicesBridge: Sendable {
    func getBrightness(displayID: CGDirectDisplayID) -> Float? {
        PrivateDisplayAPI.shared.readBrightness(for: displayID)
    }

    func setBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        PrivateDisplayAPI.shared.setBrightness(for: displayID, value: value)
    }
}
