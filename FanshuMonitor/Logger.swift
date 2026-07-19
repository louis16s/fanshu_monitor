import Foundation
import OSLog

nonisolated enum AppLogger {
    static let sampler = Logger(subsystem: "com.fanshu.monitor", category: "Sampler")
    static let ui = Logger(subsystem: "com.fanshu.monitor", category: "UI")
    static let settings = Logger(subsystem: "com.fanshu.monitor", category: "Settings")
    static let mouse = Logger(subsystem: "com.fanshu.monitor", category: "Mouse")
    static let lockScreen = Logger(subsystem: "com.fanshu.monitor", category: "LockScreen")
}
