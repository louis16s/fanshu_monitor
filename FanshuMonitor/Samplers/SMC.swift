import Foundation
import IOKit

nonisolated protocol SMCTemperatureSource: AnyObject {
    var isConnectionValid: Bool { get }
    func cpuTemperature() -> Double?
    func gpuTemperature() -> Double?
}

nonisolated final class SMCTemperatureCache {
    private let makeSource: () -> SMCTemperatureSource?
    private let now: () -> Date
    private var source: SMCTemperatureSource?
    private var retryAt: Date?
    private var failures = 0

    init(makeSource: @escaping () -> SMCTemperatureSource? = { SMCReader() }, now: @escaping () -> Date = Date.init) {
        self.makeSource = makeSource
        self.now = now
    }

    func temperature(gpu: Bool) -> Double? {
        guard !Task.isCancelled else { return nil }
        if source == nil {
            guard retryAt.map({ now() >= $0 }) ?? true else { return nil }
            source = makeSource()
            guard source != nil else {
                deferReconnect()
                return nil
            }
        }
        guard let source else { return nil }
        let value = gpu ? source.gpuTemperature() : source.cpuTemperature()
        if !source.isConnectionValid {
            self.source = nil
            deferReconnect()
        } else {
            failures = 0
            retryAt = nil
        }
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func deferReconnect() {
        failures = min(failures + 1, 3)
        retryAt = now().addingTimeInterval(min(60, 15 * pow(2, Double(failures - 1))))
    }
}

nonisolated final class SMCReader: SMCTemperatureSource {
    private(set) var isConnectionValid = true
    private static let callLock = NSLock()
    private var conn: io_connect_t = 0
    private static let temperatureKeys = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"
    ]
    private static let gpuTemperatureKeys = [
        "TG0D", "TG0P", "TG0H", "TG0T", "Tg0D", "Tg0P", "Tg0H", "Tg0T"
    ]

    init?() {
        var iterator: io_iterator_t = 0
        let matchingDictionary = IOServiceMatching("AppleSMC")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard result == kIOReturnSuccess else { return nil }

        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return nil }

        let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        guard openResult == kIOReturnSuccess else { return nil }
    }

    deinit {
        _ = IOServiceClose(conn)
    }

    func cpuTemperature() -> Double? {
        averageTemperature(for: Self.temperatureKeys)
    }

    func gpuTemperature() -> Double? {
        averageTemperature(for: Self.gpuTemperatureKeys)
    }

    private func averageTemperature(for keys: [String]) -> Double? {
        var temperatures: [Double] = []
        for key in keys {
            guard isConnectionValid, !Task.isCancelled else { break }
            if let value = readValue(key), value.isFinite, value > 0 {
                temperatures.append(value)
            }
        }
        guard !temperatures.isEmpty else { return nil }
        return temperatures.reduce(0, +) / Double(temperatures.count)
    }

    // MARK: - Private

    private func readValue(_ key: String) -> Double? {
        guard conn != 0, isConnectionValid else { return nil }

        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        input.key = fourCharCode(key)
        input.data8 = 9 // readKeyInfo

        var result = call(2, input: &input, output: &output)
        guard result == kIOReturnSuccess else { return nil }
        guard output.result == 0 else { return nil }

        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType

        input.data8 = 5 // readBytes
        input.keyInfo.dataSize = dataSize
        result = call(2, input: &input, output: &output)
        guard result == kIOReturnSuccess else { return nil }
        guard output.result == 0 else { return nil }

        return parseValue(bytes: output.bytes, dataSize: dataSize, dataType: dataType)
    }

    private func parseValue(bytes: SMCKeyData_t.SMCBytes_t, dataSize: IOByteCount32, dataType: UInt32) -> Double? {
        guard dataSize > 0 else { return nil }

        let byteArray = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5,
                         bytes.6, bytes.7, bytes.8, bytes.9, bytes.10, bytes.11,
                         bytes.12, bytes.13, bytes.14, bytes.15, bytes.16, bytes.17,
                         bytes.18, bytes.19, bytes.20, bytes.21, bytes.22, bytes.23,
                         bytes.24, bytes.25, bytes.26, bytes.27, bytes.28, bytes.29,
                         bytes.30, bytes.31]

        if byteArray.first(where: { $0 != 0 }) == nil {
            return nil
        }

        let typeString = fourCharCodeToString(dataType)

        switch typeString {
        case "sp78":
            let intValue = Int(byteArray[0]) * 256 + Int(byteArray[1])
            return Double(intValue) / 256.0
        case "sp87":
            let intValue = Int(byteArray[0]) * 256 + Int(byteArray[1])
            return Double(intValue) / 128.0
        case "sp96":
            let intValue = Int(byteArray[0]) * 256 + Int(byteArray[1])
            return Double(intValue) / 64.0
        case "ui16 ":
            return Double(UInt16(byteArray[0]) * 256 + UInt16(byteArray[1]))
        case "flt ":
            let floatBits = byteArray.prefix(4).enumerated().reduce(UInt32.zero) { result, element in
                result | (UInt32(element.element) << UInt32(element.offset * 8))
            }
            let floatValue = Float(bitPattern: floatBits)
            return Double(floatValue)
        default:
            return nil
        }
    }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        Self.callLock.lock()
        defer { Self.callLock.unlock() }
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        let result = IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
        // Missing/unsupported keys do not invalidate an otherwise live connection.
        if result != kIOReturnSuccess,
           result != kIOReturnNotFound,
           result != kIOReturnUnsupported,
           result != kIOReturnBadArgument {
            isConnectionValid = false
        }
        return result
    }

    private func fourCharCode(_ str: String) -> UInt32 {
        str.utf8.reduce(0) { sum, character in
            sum << 8 | UInt32(character)
        }
    }

    private func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(decoding: bytes, as: UTF8.self)
    }
}

nonisolated private struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = (major: CUnsignedChar(0), minor: CUnsignedChar(0), build: CUnsignedChar(0), reserved: CUnsignedChar(0), release: CUnsignedShort(0))
    var pLimitData = (version: UInt16(0), length: UInt16(0), cpuPLimit: UInt32(0), gpuPLimit: UInt32(0), memPLimit: UInt32(0))
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}
