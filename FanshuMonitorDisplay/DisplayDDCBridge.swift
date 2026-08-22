import CoreGraphics
import Foundation
import IOKit
import OSLog

#if !arch(arm64)
#error("Display DDC control is Apple Silicon only. Do not compile this Direct-only module for Intel Mac.")
#endif

nonisolated private let displayDDCLog = Logger(
    subsystem: "com.fanshu.monitor.direct",
    category: "DisplayDDC"
)

nonisolated final class DisplayDDCBridge: @unchecked Sendable {
    private var servicesByDisplayID: [CGDirectDisplayID: DDCService] = [:]
    private var valueRanges: [ControlKey: DDCValueRange] = [:]
    private var controlCodes: [ControlKey: DDCVCPCode] = [:]
    private let maxDetectLimit: UInt16 = 100
    private let registry = DDCFaultRegistry()
    private let stateLock = NSLock()

    func refresh(displayIDs: [CGDirectDisplayID], forceReset: Bool = false) {
        let matchedServices = Arm64DDCMatcher().matchedServices(for: displayIDs)
        let (knownDisplayIDs, changedDisplayIDs) = stateLock.withLock {
            let previousServices = servicesByDisplayID
            let changedDisplayIDs: Set<CGDirectDisplayID>
            if forceReset {
                changedDisplayIDs = Set(displayIDs).union(previousServices.keys)
            } else {
                changedDisplayIDs = Set(displayIDs.filter {
                    guard let previous = previousServices[$0],
                          let matched = matchedServices[$0]
                    else {
                        return previousServices[$0] != nil || matchedServices[$0] != nil
                    }
                    return previous.serviceLocation != matched.serviceLocation
                        || previous.serviceIdentity != matched.serviceIdentity
                })
            }
            return (Set(previousServices.keys), changedDisplayIDs)
        }
        for displayID in knownDisplayIDs.subtracting(displayIDs) {
            registry.reset(displayID: displayID)
            DDCTransport.reset(displayID: displayID)
        }
        for displayID in changedDisplayIDs {
            registry.reset(displayID: displayID)
            DDCTransport.reset(displayID: displayID)
            displayDDCLog.notice(
                "Reset DDC transport after display service replacement for display \(displayID, privacy: .public)"
            )
        }
        stateLock.withLock {
            servicesByDisplayID = matchedServices
            valueRanges = valueRanges.filter {
                displayIDs.contains($0.key.displayID) && !changedDisplayIDs.contains($0.key.displayID)
            }
            controlCodes = controlCodes.filter {
                displayIDs.contains($0.key.displayID) && !changedDisplayIDs.contains($0.key.displayID)
            }
        }
    }

    func hasService(for displayID: CGDirectDisplayID) -> Bool {
        stateLock.withLock { servicesByDisplayID[displayID] != nil }
    }

    func isTemporarilyDisabled(_ control: DisplayControlKind, displayID: CGDirectDisplayID) -> Bool {
        registry.isDisabled(ControlKey(displayID: displayID, control: control))
    }

    func hasVerifiedControl(_ control: DisplayControlKind, displayID: CGDirectDisplayID) -> Bool {
        stateLock.withLock {
            controlCodes[ControlKey(displayID: displayID, control: control)] != nil
        }
    }

    func setValueRange(_ range: DDCValueRange, for control: DisplayControlKind, displayID: CGDirectDisplayID) {
        stateLock.withLock {
            valueRanges[ControlKey(displayID: displayID, control: control)] = range
        }
    }

    func valueRange(for control: DisplayControlKind, displayID: CGDirectDisplayID) -> DDCValueRange? {
        stateLock.withLock {
            valueRanges[ControlKey(displayID: displayID, control: control)]
        }
    }

    func brightnessWritePlan(for percentage: Double, displayID: CGDirectDisplayID) -> DDCBrightnessWritePlan {
        let range = valueRange(for: .brightness, displayID: displayID)
            ?? DDCValueRange(min: 0, max: maxDetectLimit)
        return range.brightnessWritePlan(for: percentage)
    }

    func read(_ control: DisplayControlKind, displayID: CGDirectDisplayID, fastFail: Bool = false) -> Double? {
        guard let service = stateLock.withLock({ servicesByDisplayID[displayID] }) else {
            displayDDCLog.debug("No DDC service for display \(displayID, privacy: .public)")
            return nil
        }

        let key = ControlKey(displayID: displayID, control: control)
        guard !registry.isDisabled(key) else {
            displayDDCLog.debug("DDC read skipped for display \(displayID, privacy: .public) control \(String(describing: control), privacy: .public); temporarily disabled")
            return nil
        }

        for vcp in orderedCandidates(for: key) {
            let useLongerDelay = registry.shouldUseLongerDelay(key)
            let maxRetries = fastFail ? 2 : 5
            guard let values = DDCTransport.read(
                service: service.service,
                displayID: displayID,
                vcpCode: vcp.rawValue,
                longerDelay: useLongerDelay,
                maxRetries: maxRetries
            ),
                  values.max > 0
            else {
                continue
            }

            let detectedMax = min(values.max, maxDetectLimit)
            let range = stateLock.withLock {
                var range = valueRanges[key] ?? DDCValueRange(min: 0, max: detectedMax)
                range.max = max(range.min + 1, detectedMax)
                valueRanges[key] = range
                controlCodes[key] = vcp
                return range
            }

            let percentage = range.percentage(from: values.current)
            registry.recordReadSuccess(key)

            displayDDCLog.debug(
                "Read DDC display \(displayID, privacy: .public) control \(String(describing: control), privacy: .public) code \(vcp.rawValue, privacy: .public) raw \(values.current, privacy: .public)/\(values.max, privacy: .public) range \(range.min, privacy: .public)-\(range.max, privacy: .public) mapped \(percentage, privacy: .public)"
            )
            return min(100, max(0, percentage))
        }

        displayDDCLog.warning("Failed to read DDC display \(displayID, privacy: .public) control \(String(describing: control), privacy: .public)")
        registry.recordReadFailure(key)
        return nil
    }

    func write(_ value: Double, for control: DisplayControlKind, displayID: CGDirectDisplayID) -> DDCWriteOutcome {
        guard let service = stateLock.withLock({ servicesByDisplayID[displayID] }) else {
            displayDDCLog.warning("No DDC service while writing display \(displayID, privacy: .public) control \(String(describing: control), privacy: .public)")
            return .failure
        }

        let key = ControlKey(displayID: displayID, control: control)
        guard !registry.isDisabled(key) else {
            displayDDCLog.debug("DDC write skipped for display \(displayID, privacy: .public) control \(String(describing: control), privacy: .public); temporarily disabled")
            return .failure
        }

        let range = stateLock.withLock {
            valueRanges[key] ?? DDCValueRange(min: 0, max: maxDetectLimit)
        }
        let clampedPercentage = min(100, max(0, value))
        let brightnessPlan = control == .brightness
            ? range.brightnessWritePlan(for: clampedPercentage)
            : nil
        var ddcValue = brightnessPlan?.rawValue ?? range.rawValue(for: clampedPercentage)
        if control == .volume, value > 0 {
            ddcValue = max(1, ddcValue)
        }

        if control == .volume {
            let muteValue: UInt16 = value > 0 ? 2 : 1
            let muteSuccess = DDCTransport.write(
                service: service.service,
                displayID: displayID,
                vcpCode: DDCVCPCode.audioMuteScreenBlank.rawValue,
                value: muteValue
            )
            if value <= 0, muteSuccess {
                registry.recordWriteSuccess(key)
                displayDDCLog.debug("Wrote DDC mute display \(displayID, privacy: .public)")
                return .success()
            }
        }

        for vcp in orderedCandidates(for: key) {
            let success = DDCTransport.write(
                service: service.service,
                displayID: displayID,
                vcpCode: vcp.rawValue,
                value: ddcValue
            )
            displayDDCLog.debug(
                "Write DDC display \(displayID, privacy: .public) control \(String(describing: control), privacy: .public) code \(vcp.rawValue, privacy: .public) value \(ddcValue, privacy: .public) range \(range.min, privacy: .public)-\(range.max, privacy: .public) success \(success, privacy: .public)"
            )
            if success {
                stateLock.withLock {
                    controlCodes[key] = vcp
                }
                registry.recordWriteSuccess(key)
                calibrateMinimumIfNeeded(
                    requestedPercentage: clampedPercentage,
                    requestedRawValue: ddcValue,
                    control: control,
                    key: key,
                    service: service.service,
                    vcp: vcp
                )
                return .success(
                    quantizationOverlayOpacity: brightnessPlan?.overlayOpacity ?? 0
                )
            }
        }

        registry.recordWriteFailure(key)
        return .failure
    }

    private func orderedCandidates(for key: ControlKey) -> [DDCVCPCode] {
        let candidates = DDCVCPCode.candidates(for: key.control)
        let preferred = stateLock.withLock { controlCodes[key] }
        guard let preferred, candidates.contains(preferred) else {
            return candidates
        }
        return [preferred] + candidates.filter { $0 != preferred }
    }

    private func calibrateMinimumIfNeeded(
        requestedPercentage: Double,
        requestedRawValue: UInt16,
        control: DisplayControlKind,
        key: ControlKey,
        service: IOAVService,
        vcp: DDCVCPCode
    ) {
        guard control == .brightness, requestedPercentage <= 0 else { return }
        guard let values = DDCTransport.read(
            service: service,
            displayID: key.displayID,
            vcpCode: vcp.rawValue,
            maxRetries: 2
        ),
              values.max > 0
        else { return }

        let detectedMax = min(values.max, maxDetectLimit)
        let returnedCurrent = min(values.current, detectedMax)
        guard returnedCurrent > requestedRawValue,
              returnedCurrent < detectedMax
        else { return }

        let learnedRange = DDCValueRange(min: returnedCurrent, max: detectedMax)
        stateLock.withLock {
            valueRanges[key] = learnedRange
        }
        displayDDCLog.notice(
            "Learned DDC minimum for display \(key.displayID, privacy: .public) brightness: \(returnedCurrent, privacy: .public), max \(detectedMax, privacy: .public)"
        )
    }
}

nonisolated struct DDCValueRange: Equatable {
    var min: UInt16
    var max: UInt16

    init(min: UInt16, max: UInt16) {
        self.min = min
        self.max = max > min ? max : min + 1
    }

    func percentage(from rawValue: UInt16) -> Double {
        let clamped = Swift.min(Swift.max(rawValue, min), max)
        return Double(clamped - min) / Double(max - min) * 100
    }

    func rawValue(for percentage: Double) -> UInt16 {
        let clampedPercentage = Swift.min(100, Swift.max(0, percentage))
        let raw = Double(max - min) * (clampedPercentage / 100) + Double(min)
        return UInt16(Swift.min(Double(max), Swift.max(Double(min), raw.rounded())))
    }

    func brightnessWritePlan(for percentage: Double) -> DDCBrightnessWritePlan {
        let clampedPercentage = Swift.min(100, Swift.max(0, percentage))
        let span = Double(max - min)
        let desiredRaw = Double(min) + span * clampedPercentage / 100
        let raw = UInt16(
            Swift.min(
                Double(max),
                Swift.max(Double(min), desiredRaw.rounded(.up))
            )
        )
        let actualPercentage = self.percentage(from: raw)
        let overlayOpacity: Double
        if clampedPercentage > 0, actualPercentage > clampedPercentage {
            overlayOpacity = 1 - clampedPercentage / actualPercentage
        } else {
            overlayOpacity = 0
        }
        return DDCBrightnessWritePlan(
            rawValue: raw,
            overlayOpacity: Swift.min(1, Swift.max(0, overlayOpacity))
        )
    }
}

nonisolated struct DDCBrightnessWritePlan: Equatable {
    let rawValue: UInt16
    let overlayOpacity: Double
}

nonisolated struct DDCWriteOutcome {
    let success: Bool
    let quantizationOverlayOpacity: Double

    static let failure = DDCWriteOutcome(success: false, quantizationOverlayOpacity: 0)

    static func success(quantizationOverlayOpacity: Double = 0) -> DDCWriteOutcome {
        DDCWriteOutcome(
            success: true,
            quantizationOverlayOpacity: quantizationOverlayOpacity
        )
    }
}

nonisolated private enum DDCVCPCode: UInt8 {
    case luminance = 0x10
    case contrast = 0x12
    case backlightControlLegacy = 0x13
    case audioSpeakerVolume = 0x62
    case audioMuteScreenBlank = 0x8D

    static func candidates(for control: DisplayControlKind) -> [DDCVCPCode] {
        switch control {
        case .brightness:
            [.luminance, .backlightControlLegacy]
        case .contrast:
            [.contrast]
        case .volume:
            [.audioSpeakerVolume]
        }
    }
}

nonisolated struct DDCTransportLease: @unchecked Sendable {
    let queue: DispatchQueue
    let generation: UInt64
}

nonisolated final class DDCTransportChannelRegistry: @unchecked Sendable {
    private struct Channel {
        var queue: DispatchQueue
        var generation: UInt64
        var quarantineUntil: Date?
        var timeoutCount: Int
    }

    private let lock = NSLock()
    private let cooldown: TimeInterval
    private let maximumRecoveries: Int
    private let now: @Sendable () -> Date
    private var channels: [CGDirectDisplayID: Channel] = [:]

    init(
        cooldown: TimeInterval = 10,
        maximumRecoveries: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cooldown = cooldown
        self.maximumRecoveries = maximumRecoveries
        self.now = now
    }

    func lease(for displayID: CGDirectDisplayID) -> DDCTransportLease? {
        lock.withLock {
            var channel = channels[displayID] ?? makeChannel(displayID: displayID, generation: 0)
            if let quarantineUntil = channel.quarantineUntil {
                guard now() >= quarantineUntil,
                      channel.timeoutCount <= maximumRecoveries else {
                    channels[displayID] = channel
                    return nil
                }
                channel = makeChannel(
                    displayID: displayID,
                    generation: channel.generation &+ 1,
                    timeoutCount: channel.timeoutCount
                )
            }
            channels[displayID] = channel
            return DDCTransportLease(queue: channel.queue, generation: channel.generation)
        }
    }

    func recordTimeout(displayID: CGDirectDisplayID, generation: UInt64) {
        lock.withLock {
            guard var channel = channels[displayID], channel.generation == generation else { return }
            channel.timeoutCount += 1
            channel.quarantineUntil = now().addingTimeInterval(cooldown)
            channels[displayID] = channel
        }
    }

    func reset(displayID: CGDirectDisplayID) {
        _ = lock.withLock {
            channels.removeValue(forKey: displayID)
        }
    }

    func isQuarantined(displayID: CGDirectDisplayID) -> Bool {
        lock.withLock { channels[displayID]?.quarantineUntil != nil }
    }

    private func makeChannel(
        displayID: CGDirectDisplayID,
        generation: UInt64,
        timeoutCount: Int = 0
    ) -> Channel {
        Channel(
            queue: DispatchQueue(
                label: "fanshu.ddc.io.\(displayID).\(generation)",
                qos: .userInitiated
            ),
            generation: generation,
            quarantineUntil: nil,
            timeoutCount: timeoutCount
        )
    }
}

nonisolated private final class DDCCommunicationResult: @unchecked Sendable {
    struct Value {
        let success: Bool
        let send: [UInt8]
        let reply: [UInt8]
    }

    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func load() -> Value? {
        lock.withLock { value }
    }
}

nonisolated private final class DDCServiceReference: @unchecked Sendable {
    let value: IOAVService

    init(_ value: IOAVService) {
        self.value = value
    }
}

nonisolated private enum DDCTransport {
    private static let sevenBitAddress: UInt8 = 0x37
    private static let dataAddress: UInt8 = 0x51
    private static let communicateTimeoutSeconds = 3
    private static let channels = DDCTransportChannelRegistry()

    static func reset(displayID: CGDirectDisplayID) {
        channels.reset(displayID: displayID)
    }

    static func read(
        service: IOAVService,
        displayID: CGDirectDisplayID,
        vcpCode: UInt8,
        longerDelay: Bool = false,
        maxRetries: Int = 5
    ) -> (current: UInt16, max: UInt16)? {
        var send = [vcpCode]
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(
            service: service,
            displayID: displayID,
            send: &send,
            reply: &reply,
            longerDelay: longerDelay,
            maxRetries: maxRetries
        ) else {
            return nil
        }
        let maxValue = (UInt16(reply[6]) << 8) + UInt16(reply[7])
        let currentValue = (UInt16(reply[8]) << 8) + UInt16(reply[9])
        return (currentValue, maxValue)
    }

    static func write(
        service: IOAVService,
        displayID: CGDirectDisplayID,
        vcpCode: UInt8,
        value: UInt16,
        maxRetries: Int = 5
    ) -> Bool {
        var send = [vcpCode, UInt8(value >> 8), UInt8(value & 0xFF)]
        var reply: [UInt8] = []
        return communicate(
            service: service,
            displayID: displayID,
            send: &send,
            reply: &reply,
            maxRetries: maxRetries
        )
    }

    private static func communicate(
        service: IOAVService,
        displayID: CGDirectDisplayID,
        send: inout [UInt8],
        reply: inout [UInt8],
        longerDelay: Bool = false,
        maxRetries: Int = 5
    ) -> Bool {
        guard let lease = channels.lease(for: displayID) else {
            return false
        }

        let initialSend = send
        let initialReply = reply
        let result = DDCCommunicationResult()
        let serviceReference = DDCServiceReference(service)
        let semaphore = DispatchSemaphore(value: 0)

        lease.queue.async {
            var sendCopy = initialSend
            var replyCopy = initialReply
            let succeeded = communicateUnlocked(
                service: serviceReference.value,
                send: &sendCopy,
                reply: &replyCopy,
                longerDelay: longerDelay,
                maxRetries: maxRetries
            )
            result.store(.init(success: succeeded, send: sendCopy, reply: replyCopy))
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .seconds(communicateTimeoutSeconds)) == .timedOut {
            channels.recordTimeout(displayID: displayID, generation: lease.generation)
            displayDDCLog.error("DDC communicate timed out for display \(displayID, privacy: .public) after \(communicateTimeoutSeconds, privacy: .public)s; device channel quarantined")
            return false
        }

        guard let value = result.load() else { return false }
        send = value.send
        reply = value.reply
        return value.success
    }

    private static func communicateUnlocked(
        service: IOAVService,
        send: inout [UInt8],
        reply: inout [UInt8],
        longerDelay: Bool,
        maxRetries: Int
    ) -> Bool {
        let dataAddress = Self.dataAddress
        var success = false
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let checksumSeed = send.count == 1
            ? Self.sevenBitAddress << 1
            : Self.sevenBitAddress << 1 ^ dataAddress
        packet[packet.count - 1] = checksum(seed: checksumSeed, data: packet, start: 0, end: packet.count - 2)

        for _ in 0..<maxRetries {
            for _ in 0..<2 {
                usleep(10_000)
                let packetCount = UInt32(packet.count)
                success = packet.withUnsafeMutableBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return false
                    }
                    return PrivateDisplayAPI.shared.writeI2C(
                        service: service,
                        chipAddress: UInt32(Self.sevenBitAddress),
                        dataAddress: UInt32(dataAddress),
                        inputBuffer: baseAddress,
                        inputBufferSize: packetCount
                    ) == KERN_SUCCESS
                }
            }

            if reply.isEmpty {
                if success {
                    return true
                }
            } else {
                usleep(longerDelay ? 150_000 : 50_000)
                let replyCount = UInt32(reply.count)
                success = reply.withUnsafeMutableBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return false
                    }
                    return PrivateDisplayAPI.shared.readI2C(
                        service: service,
                        chipAddress: UInt32(Self.sevenBitAddress),
                        offset: 0,
                        outputBuffer: baseAddress,
                        outputBufferSize: replyCount
                    ) == KERN_SUCCESS
                }
                if success, reply.count >= 2 {
                    success = checksum(seed: 0x50, data: reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
                }
                if success {
                    return true
                }
            }

            usleep(20_000)
        }

        return false
    }

    private static func checksum(seed: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
        guard start <= end else {
            return seed
        }

        var value = seed
        for index in start...end {
            value ^= data[index]
        }
        return value
    }
}

nonisolated private final class Arm64DDCMatcher {
    private static let maxMatchScore = 20

    func matchedServices(for displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
        let registryServices = registryServicesForMatching()
        var candidatesByScore: [Int: [DDCService]] = [:]

        for displayID in displayIDs where CGDisplayIsBuiltin(displayID) == 0 {
            for registryService in registryServices {
                let score = matchScore(displayID: displayID, registryService: registryService)
                guard score > 0, let service = registryService.service else {
                    continue
                }
                let candidate = DDCService(
                    displayID: displayID,
                    service: service,
                    serviceLocation: registryService.serviceLocation,
                    serviceIdentity: registryService.identity,
                    matchScore: score
                )
                candidatesByScore[score, default: []].append(candidate)
            }
        }

        var matched: [CGDirectDisplayID: DDCService] = [:]
        var usedDisplayIDs: Set<CGDirectDisplayID> = []
        var usedLocations: Set<Int> = []

        for score in stride(from: Self.maxMatchScore, through: 1, by: -1) {
            guard let candidates = candidatesByScore[score] else {
                continue
            }
            for candidate in candidates {
                guard !usedDisplayIDs.contains(candidate.displayID),
                      !usedLocations.contains(candidate.serviceLocation)
                else {
                    continue
                }
                matched[candidate.displayID] = candidate
                usedDisplayIDs.insert(candidate.displayID)
                usedLocations.insert(candidate.serviceLocation)
                displayDDCLog.debug(
                    "Matched DDC service display \(candidate.displayID, privacy: .public) location \(candidate.serviceLocation, privacy: .public) score \(candidate.matchScore, privacy: .public)"
                )
            }
        }

        let unmatchedDisplayIDs = displayIDs.filter {
            CGDisplayIsBuiltin($0) == 0 && !usedDisplayIDs.contains($0)
        }
        let unusedServices = registryServices.filter {
            $0.service != nil && !usedLocations.contains($0.serviceLocation)
        }
        if unmatchedDisplayIDs.count == 1,
           unusedServices.count == 1,
           let service = unusedServices[0].service {
            let fallback = DDCService(
                displayID: unmatchedDisplayIDs[0],
                service: service,
                serviceLocation: unusedServices[0].serviceLocation,
                serviceIdentity: unusedServices[0].identity,
                matchScore: 0
            )
            matched[fallback.displayID] = fallback
            displayDDCLog.notice(
                "Fallback matched single DDC service display \(fallback.displayID, privacy: .public) location \(fallback.serviceLocation, privacy: .public)"
            )
        }

        displayDDCLog.debug("Matched \(matched.count, privacy: .public) DDC services from \(registryServices.count, privacy: .public) registry services")
        return matched
    }

    private func registryServicesForMatching() -> [RegistryService] {
        var services: [RegistryService] = []
        var serviceLocation = 0
        var current = RegistryService()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else {
            return []
        }
        defer {
            IOObjectRelease(root)
        }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer {
            IOObjectRelease(iterator)
        }

        let framebufferNames = ["AppleCLCD2", "IOMobileFramebufferShim"]
        let serviceName = "DCPAVServiceProxy"

        while let object = nextObject(namedLike: framebufferNames + [serviceName], iterator: &iterator) {
            defer {
                IOObjectRelease(object.entry)
            }

            if framebufferNames.contains(object.name) {
                current = registryDisplayProperties(entry: object.entry)
                serviceLocation += 1
                current.serviceLocation = serviceLocation
            } else if object.name == serviceName {
                attachAVService(entry: object.entry, to: &current)
                if current.service != nil {
                    services.append(current)
                }
            }
        }

        return services
    }

    private func nextObject(
        namedLike names: [String],
        iterator: inout io_iterator_t
    ) -> (name: String, entry: io_service_t)? {
        let namePointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer {
            namePointer.deallocate()
        }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL,
                  IORegistryEntryGetName(entry, namePointer) == KERN_SUCCESS
            else {
                return nil
            }

            let name = String(cString: namePointer)
            if names.contains(where: { name.contains($0) }) {
                return (name, entry)
            }
            IOObjectRelease(entry)
        }
    }

    private func registryDisplayProperties(entry: io_service_t) -> RegistryService {
        var service = RegistryService()

        if let unmanagedValue = IORegistryEntryCreateCFProperty(
            entry,
            "EDID UUID" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ), let value = unmanagedValue.takeRetainedValue() as? String {
            service.edidUUID = value
        }

        let path = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer {
            path.deallocate()
        }
        if IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS {
            service.ioDisplayLocation = String(cString: path)
        }

        if let unmanagedAttributes = IORegistryEntryCreateCFProperty(
            entry,
            "DisplayAttributes" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ), let attributes = unmanagedAttributes.takeRetainedValue() as? NSDictionary {
            if let productAttributes = attributes["ProductAttributes"] as? NSDictionary {
                service.productName = productAttributes["ProductName"] as? String ?? ""
                service.serialNumber = productAttributes["SerialNumber"] as? Int64 ?? 0
            }
        }

        return service
    }

    private func attachAVService(entry: io_service_t, to service: inout RegistryService) {
        guard let unmanagedLocation = IORegistryEntryCreateCFProperty(
            entry,
            "Location" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ), let location = unmanagedLocation.takeRetainedValue() as? String,
           location == "External",
           let avService = PrivateDisplayAPI.shared.createAVService(for: entry)
        else {
            return
        }

        service.service = avService
    }

    private func matchScore(displayID: CGDirectDisplayID, registryService: RegistryService) -> Int {
        guard let info = PrivateDisplayAPI.shared.displayInfoDictionary(for: displayID) as NSDictionary? else {
            return 0
        }

        var score = 0

        if let location = info[kIODisplayLocationKey] as? String,
           !registryService.ioDisplayLocation.isEmpty,
           location == registryService.ioDisplayLocation {
            score += 10
        }

        if let productNames = info["DisplayProductName"] as? [String: String],
           let displayName = productNames["en_US"] ?? productNames.first?.value,
           !registryService.productName.isEmpty,
           displayName.lowercased() == registryService.productName.lowercased() {
            score += 1
        }

        if let serial = info[kDisplaySerialNumber] as? Int64,
           serial != 0,
           serial == registryService.serialNumber {
            score += 1
        }

        for searchKey in edidSearchKeys(from: info) {
            let prefix = registryService.edidUUID.prefix(searchKey.location + 4)
            guard searchKey.value != "0000",
                  prefix.suffix(4) == searchKey.value
            else {
                continue
            }
            score += 1
        }

        return score
    }

    private func edidSearchKeys(from info: NSDictionary) -> [(value: String, location: Int)] {
        guard let vendorID = info[kDisplayVendorID] as? Int64,
              let productID = info[kDisplayProductID] as? Int64,
              let week = info[kDisplayWeekOfManufacture] as? Int64,
              let year = info[kDisplayYearOfManufacture] as? Int64,
              let horizontalSize = info[kDisplayHorizontalImageSize] as? Int64,
              let verticalSize = info[kDisplayVerticalImageSize] as? Int64
        else {
            return []
        }

        let product = UInt16(max(0, min(productID, 65_535)))
        return [
            (String(format: "%04X", UInt16(max(0, min(vendorID, 65_535)))), 0),
            (
                String(format: "%02X", UInt8((product >> 0) & 0xFF))
                    + String(format: "%02X", UInt8((product >> 8) & 0xFF)),
                4
            ),
            (
                String(format: "%02X", UInt8(max(0, min(week, 255))))
                    + String(format: "%02X", UInt8(max(0, min(year - 1990, 255)))),
                19
            ),
            (
                String(format: "%02X", UInt8(max(0, min(horizontalSize / 10, 255))))
                    + String(format: "%02X", UInt8(max(0, min(verticalSize / 10, 255)))),
                30
            )
        ]
    }
}

nonisolated private struct DDCService {
    let displayID: CGDirectDisplayID
    let service: IOAVService
    let serviceLocation: Int
    let serviceIdentity: String
    let matchScore: Int
}

nonisolated private struct RegistryService {
    var edidUUID = ""
    var productName = ""
    var serialNumber: Int64 = 0
    var ioDisplayLocation = ""
    var service: IOAVService?
    var serviceLocation = 0

    var identity: String {
        let parts = [edidUUID, ioDisplayLocation, productName, String(serialNumber)]
            .filter { !$0.isEmpty && $0 != "0" }
        return parts.isEmpty ? "registry-location-\(serviceLocation)" : parts.joined(separator: "|")
    }
}
