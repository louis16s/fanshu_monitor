import Foundation
import IOKit
import OSLog

nonisolated func registryDictionaryValue(_ service: io_service_t, _ key: String) -> [String: Any]? {
    let result = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
    guard let value = result?.takeRetainedValue() else {
        AppLogger.sampler.error("IORegistryEntryCreateCFProperty failed for key: \(key, privacy: .public)")
        return nil
    }
    guard let dict = value as? [String: Any] else {
        AppLogger.sampler.error("IORegistryEntryCreateCFProperty returned non-dictionary for key: \(key, privacy: .public)")
        return nil
    }
    return dict
}
