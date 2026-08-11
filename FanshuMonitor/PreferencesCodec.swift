import Foundation
import OSLog

nonisolated enum PreferencesCodec {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        key: String
    ) -> Value? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLogger.settings.error(
                "Unable to decode preference \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func encode<Value: Encodable>(_ value: Value, key: String) -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            AppLogger.settings.error(
                "Unable to encode preference \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
