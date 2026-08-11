import Foundation
import OSLog

nonisolated enum AppLogger {
    static let sampler = Logger(subsystem: "com.fanshu.monitor", category: "Sampler")
    static let ui = Logger(subsystem: "com.fanshu.monitor", category: "UI")
    static let settings = Logger(subsystem: "com.fanshu.monitor", category: "Settings")
    static let mouse = Logger(subsystem: "com.fanshu.monitor", category: "Mouse")
    static let lockScreen = Logger(subsystem: "com.fanshu.monitor", category: "LockScreen")
    static let codex = Logger(subsystem: "com.fanshu.monitor", category: "Codex")
    static let power = Logger(subsystem: "com.fanshu.monitor", category: "Power")
    static let displayTopology = Logger(subsystem: "com.fanshu.monitor", category: "DisplayTopology")
    static let ddc = Logger(subsystem: "com.fanshu.monitor", category: "DDC")
}
