import Foundation
import OSLog

enum AppLogger {
    static let sampler = Logger(subsystem: "com.fanshu.monitor", category: "Sampler")
    static let ui = Logger(subsystem: "com.fanshu.monitor", category: "UI")
    static let settings = Logger(subsystem: "com.fanshu.monitor", category: "Settings")
    static let mouse = Logger(subsystem: "com.fanshu.monitor", category: "Mouse")
}
