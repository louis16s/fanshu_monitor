import Foundation

nonisolated enum AppVersion {
    static let current: String = {
        let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "0.0.0" : normalized
    }()

    static var userAgent: String {
        "番薯Monitor/\(current)"
    }
}
