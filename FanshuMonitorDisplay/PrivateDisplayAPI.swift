import CoreGraphics
import Darwin
import Foundation
import IOKit

/// Runtime-loaded bridge for display APIs that are not part of the stable macOS SDK.
/// Keeping symbol lookup here prevents a missing private symbol from preventing the app
/// from launching; callers receive nil/false and can use their normal fallback path.
nonisolated final class PrivateDisplayAPI: @unchecked Sendable {
    static let shared = PrivateDisplayAPI()

    private typealias DisplayInfoFunction = @convention(c) (
        CGDirectDisplayID
    ) -> Unmanaged<CFDictionary>?
    private typealias GetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        Float
    ) -> Int32
    private typealias CreateAVServiceFunction = @convention(c) (
        CFAllocator?
    ) -> Unmanaged<CFTypeRef>?
    private typealias CreateAVServiceWithEntryFunction = @convention(c) (
        CFAllocator?,
        io_service_t
    ) -> Unmanaged<CFTypeRef>?
    private typealias ReadI2CFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer?,
        UInt32
    ) -> IOReturn
    private typealias WriteI2CFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer?,
        UInt32
    ) -> IOReturn

    private let lock = NSLock()
    private var handles: [String: UnsafeMutableRawPointer] = [:]
    private var symbols: [String: UnsafeMutableRawPointer] = [:]

    private init() {}

    func displayInfoDictionary(for displayID: CGDirectDisplayID) -> [String: Any]? {
        guard let function: DisplayInfoFunction = resolve(
            "CoreDisplay_DisplayCreateInfoDictionary",
            frameworks: ["CoreDisplay"]
        ) else {
            return nil
        }
        return function(displayID)?.takeRetainedValue() as? [String: Any]
    }

    func readBrightness(for displayID: CGDirectDisplayID) -> Float? {
        guard let function: GetBrightnessFunction = resolve(
            "DisplayServicesGetBrightness",
            frameworks: ["DisplayServices"]
        ) else {
            return nil
        }

        var value: Float = -1
        guard function(displayID, &value) == 0, value.isFinite, value >= 0 else {
            return nil
        }
        return min(1, max(0, value))
    }

    func setBrightness(for displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let function: SetBrightnessFunction = resolve(
            "DisplayServicesSetBrightness",
            frameworks: ["DisplayServices"]
        ) else {
            return false
        }
        return function(displayID, min(1, max(0, value))) == 0
    }

    func createAVService() -> IOAVService? {
        guard let function: CreateAVServiceFunction = resolve(
            "IOAVServiceCreate",
            frameworks: ["DisplayServices", "IOKit"]
        ) else {
            return nil
        }
        return function(kCFAllocatorDefault)?.takeRetainedValue()
    }

    func createAVService(for entry: io_service_t) -> IOAVService? {
        guard let function: CreateAVServiceWithEntryFunction = resolve(
            "IOAVServiceCreateWithService",
            frameworks: ["DisplayServices", "IOKit"]
        ) else {
            return nil
        }
        return function(kCFAllocatorDefault, entry)?.takeRetainedValue()
    }

    func readI2C(
        service: IOAVService,
        chipAddress: UInt32,
        offset: UInt32,
        outputBuffer: UnsafeMutableRawPointer?,
        outputBufferSize: UInt32
    ) -> IOReturn? {
        guard let function: ReadI2CFunction = resolve(
            "IOAVServiceReadI2C",
            frameworks: ["DisplayServices", "IOKit"]
        ) else {
            return nil
        }
        return function(service, chipAddress, offset, outputBuffer, outputBufferSize)
    }

    func writeI2C(
        service: IOAVService,
        chipAddress: UInt32,
        dataAddress: UInt32,
        inputBuffer: UnsafeMutableRawPointer?,
        inputBufferSize: UInt32
    ) -> IOReturn? {
        guard let function: WriteI2CFunction = resolve(
            "IOAVServiceWriteI2C",
            frameworks: ["DisplayServices", "IOKit"]
        ) else {
            return nil
        }
        return function(service, chipAddress, dataAddress, inputBuffer, inputBufferSize)
    }

    @discardableResult
    func loadOSDFramework() -> Bool {
        frameworkHandle(named: "OSD") != nil
    }

    private func resolve<Function>(
        _ name: String,
        frameworks: [String]
    ) -> Function? {
        guard let symbol = resolvedSymbol(name, frameworks: frameworks) else {
            return nil
        }
        return unsafeBitCast(symbol, to: Function.self)
    }

    private func resolvedSymbol(
        _ name: String,
        frameworks: [String]
    ) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = symbols[name] {
            return cached
        }

        for framework in frameworks {
            guard let handle = frameworkHandleLocked(named: framework),
                  let symbol = dlsym(handle, name) else {
                continue
            }
            symbols[name] = symbol
            return symbol
        }
        return nil
    }

    private func frameworkHandle(named name: String) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        return frameworkHandleLocked(named: name)
    }

    private func frameworkHandleLocked(named name: String) -> UnsafeMutableRawPointer? {
        if let handle = handles[name] {
            return handle
        }

        let candidates = [
            "/System/Library/Frameworks/\(name).framework/\(name)",
            "/System/Library/Frameworks/\(name).framework/Versions/A/\(name)",
            "/System/Library/PrivateFrameworks/\(name).framework/\(name)",
            "/System/Library/PrivateFrameworks/\(name).framework/Versions/A/\(name)"
        ]

        for path in candidates {
            guard let handle = path.withCString({ dlopen($0, RTLD_LAZY | RTLD_LOCAL) }) else {
                continue
            }
            handles[name] = handle
            return handle
        }
        return nil
    }
}
