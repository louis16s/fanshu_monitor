import Foundation
import IOKit

nonisolated func registryDictionaryValue(_ service: io_service_t, _ key: String) -> [String: Any]? {
    let result = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
    guard let value = result?.takeRetainedValue() else { return nil }
    return value as? [String: Any]
}
