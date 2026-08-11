import Darwin
import CoreWLAN
import Foundation
import OSLog
import SystemConfiguration

nonisolated final class NetworkSampler: MonitorSampler {
    var kind: MonitorKind { .network }

    private var previousNetworkBytes: (input: UInt64, output: UInt64, interface: String, timestamp: Date)?
    private var cachedSSID: (interface: String, value: String, refreshedAt: Date)?
    private var cachedAddresses: (interface: String, ipv4: String, ipv6: String, refreshedAt: Date)?
    private var lastLoggedInterface: String?
    private let ssidRefreshInterval: TimeInterval = 30
    private let ssidFailureRetryInterval: TimeInterval = 3
    private let addressRefreshInterval: TimeInterval = 30
    private let ssidReader: @Sendable (String?) -> String?
    private let nowProvider: @Sendable () -> Date

    init(
        ssidReader: @escaping @Sendable (String?) -> String? = WiFiSSIDReader.read,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ssidReader = ssidReader
        self.nowProvider = nowProvider
    }

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        let now = nowProvider()
        let shouldCollectAddresses = context.panelVisible
            && (context.includes("ipv4") || context.includes("ipv6"))
        let bytes = networkBytes(includeAddresses: shouldCollectAddresses)
        let addresses = shouldCollectAddresses
            ? addressSummary(for: bytes, at: now)
            : cachedAddressValues(from: previous)
        let ssid = context.shouldCollectExpensiveMetric("ssid")
            ? currentSSID(for: bytes.identifier, at: now)
            : previous?.metrics.first { $0.name == "ssid" }?.value ?? "--"
        let previousBytes = previousNetworkBytes
        previousNetworkBytes = (bytes.input, bytes.output, bytes.identifier, now)

        guard let previousBytes, previousBytes.interface == bytes.identifier else {
            return MonitorModule(
                kind: .network,
                value: 0,
                summary: bytes.interface,
                metrics: metrics(
                    context: context,
                    ssid: ssid,
                    addresses: addresses,
                    upload: "--",
                    download: "--"
                ),
                samples: seedSamples(0)
            )
        }

        let delta = max(0.1, now.timeIntervalSince(previousBytes.timestamp))
        let upload = Double(monotonicCounterDelta(current: bytes.output, previous: previousBytes.output)) / delta
        let download = Double(monotonicCounterDelta(current: bytes.input, previous: previousBytes.input)) / delta
        let value = min(100, log10(max(1, upload + download)) * 14)

        return MonitorModule(
            kind: .network,
            value: value,
            summary: bytes.interface,
            metrics: metrics(
                context: context,
                ssid: ssid,
                addresses: addresses,
                upload: bytesPerSecond(upload),
                download: bytesPerSecond(download)
            ),
            samples: seedSamples(value)
        )
    }

    private func metrics(
        context: MonitorSamplingContext,
        ssid: String,
        addresses: (ipv4: String, ipv6: String),
        upload: String,
        download: String
    ) -> [MonitorMetric] {
        let values: [MetricID: String] = [
            "ssid": ssid,
            "ipv4": addresses.ipv4,
            "ipv6": addresses.ipv6,
            "upload": upload,
            "download": download
        ]
        return MonitorKind.network.availableMetrics.compactMap { metric in
            guard context.includes(metric.id), let value = values[metric.id] else {
                return nil
            }
            return MonitorMetric(name: metric.id, value: value)
        }
    }

    private func cachedAddressValues(from previous: MonitorModule?) -> (ipv4: String, ipv6: String) {
        (
            ipv4: previous?.metrics.first { $0.name == "ipv4" }?.value ?? "--",
            ipv6: previous?.metrics.first { $0.name == "ipv6" }?.value ?? "--"
        )
    }

    private func networkBytes(includeAddresses: Bool) -> NetworkInterfaceSnapshot {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        var totalsByInterface: [String: (input: UInt64, output: UInt64)] = [:]
        var ipv4ByInterface: [String: [String]] = [:]
        var ipv6ByInterface: [String: [String]] = [:]

        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            AppLogger.sampler.error("getifaddrs failed, errno: \(errno)")
            return NetworkInterfaceSnapshot(
                input: 0,
                output: 0,
                identifier: "network",
                interface: "network",
                ipv4Addresses: [],
                ipv6Addresses: []
            )
        }
        defer { freeifaddrs(addressList) }

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard !shouldIgnoreInterface(name) else {
                continue
            }

            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else {
                    continue
                }

                var current = totalsByInterface[name] ?? (0, 0)
                current.input += UInt64(data.ifi_ibytes)
                current.output += UInt64(data.ifi_obytes)
                totalsByInterface[name] = current

            case AF_INET, AF_INET6:
                guard includeAddresses else {
                    continue
                }
                guard let addressText = ipAddress(from: address) else {
                    continue
                }

                let isIPv4 = Int32(address.pointee.sa_family) == AF_INET
                var addresses = isIPv4 ? (ipv4ByInterface[name] ?? []) : (ipv6ByInterface[name] ?? [])
                if !addresses.contains(addressText) {
                    addresses.append(addressText)
                    if isIPv4 {
                        ipv4ByInterface[name] = addresses
                    } else {
                        ipv6ByInterface[name] = addresses
                    }
                }

            default:
                continue
            }
        }

        let primaryInterface = Self.primaryInterfaceName()
        let selectedName = selectedNetworkInterface(
            primary: primaryInterface,
            totals: totalsByInterface
        )
        let selected = selectedName.flatMap { name in
            totalsByInterface[name].map { (key: name, value: $0) }
        }

        if selected?.key != lastLoggedInterface {
            lastLoggedInterface = selected?.key
            AppLogger.sampler.debug("Network primary interface changed to \(selected?.key ?? "none", privacy: .public)")
        }

        return NetworkInterfaceSnapshot(
            input: selected?.value.input ?? 0,
            output: selected?.value.output ?? 0,
            identifier: selected?.key ?? "network",
            interface: networkInterfaceTitle(selected?.key),
            ipv4Addresses: selected.flatMap { ipv4ByInterface[$0.key] } ?? [],
            ipv6Addresses: selected.flatMap { ipv6ByInterface[$0.key] } ?? []
        )
    }

    private func networkInterfaceTitle(_ name: String?) -> String {
        guard let name else {
            return "network"
        }

        if name == "en0" {
            return "Wi-Fi"
        }
        if name.hasPrefix("en") {
            return "ethernet"
        }
        if name.hasPrefix("bridge") {
            return "bridge"
        }
        if name.hasPrefix("utun") {
            return "VPN"
        }
        if name.hasPrefix("pdp_ip") {
            return "cellular"
        }
        return name
    }

    private func shouldIgnoreInterface(_ name: String) -> Bool {
        name == "lo0" || name.hasPrefix("awdl") || name.hasPrefix("llw")
    }

    private static func primaryInterfaceName() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let value = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
                  let name = value["PrimaryInterface"] as? String,
                  !name.isEmpty else {
                continue
            }
            return name
        }
        return nil
    }

    private func ipAddress(from socketAddress: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(socketAddress.pointee.sa_family)
        let maxLength = Int(NI_MAXHOST)
        var host = [CChar](repeating: 0, count: maxLength)
        let length: socklen_t

        switch family {
        case AF_INET:
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6:
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default:
            return nil
        }

        let result = getnameinfo(
            socketAddress,
            length,
            &host,
            socklen_t(maxLength),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else {
            return nil
        }

        let address = String(cString: host)
        guard !address.isEmpty, !address.hasPrefix("fe80:") else {
            return nil
        }
        return address
    }

    private func currentSSID(for interface: String, at date: Date) -> String {
        if let cachedSSID,
           cachedSSID.interface == interface,
           date.timeIntervalSince(cachedSSID.refreshedAt) < (cachedSSID.value == "--"
               ? ssidFailureRetryInterval
               : ssidRefreshInterval) {
            return cachedSSID.value
        }

        let value = ssidReader(interface).flatMap { $0.isEmpty ? nil : $0 } ?? "--"
        cachedSSID = (interface, value, date)
        return value
    }

    private func addressSummary(for snapshot: NetworkInterfaceSnapshot, at date: Date) -> (ipv4: String, ipv6: String) {
        if let cachedAddresses,
           cachedAddresses.interface == snapshot.identifier,
           date.timeIntervalSince(cachedAddresses.refreshedAt) < addressRefreshInterval {
            return (cachedAddresses.ipv4, cachedAddresses.ipv6)
        }

        let value = (
            ipv4: networkAddressSummary(snapshot.ipv4Addresses),
            ipv6: networkAddressSummary(snapshot.ipv6Addresses)
        )
        cachedAddresses = (snapshot.identifier, value.ipv4, value.ipv6, date)
        return value
    }
}

nonisolated enum WiFiSSIDReader {
    static func read(interfaceName: String?) -> String? {
        let client = CWWiFiClient.shared()
        var interfaces: [CWInterface] = []
        if let interfaceName,
           interfaceName != "network",
           let matching = client.interface(withName: interfaceName) {
            interfaces.append(matching)
        }
        if let defaultInterface = client.interface(),
           !interfaces.contains(where: { $0.interfaceName == defaultInterface.interfaceName }) {
            interfaces.append(defaultInterface)
        }
        for interface in client.interfaces() ?? [] where !interfaces.contains(where: {
            $0.interfaceName == interface.interfaceName
        }) {
            interfaces.append(interface)
        }
        return interfaces.lazy.compactMap { interface in
            interface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first(where: { !$0.isEmpty })
    }
}

nonisolated struct NetworkInterfaceSnapshot {
    let input: UInt64
    let output: UInt64
    let identifier: String
    let interface: String
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
}

nonisolated func networkAddressSummary(_ addresses: [String]) -> String {
    guard !addresses.isEmpty else {
        return "--"
    }

    return addresses.joined(separator: ", ")
}

nonisolated func monotonicCounterDelta(current: UInt64, previous: UInt64) -> UInt64 {
    guard current >= previous else {
        return 0
    }
    return current - previous
}

nonisolated func selectedNetworkInterface(
    primary: String?,
    totals: [String: (input: UInt64, output: UInt64)]
) -> String? {
    if let primary, totals[primary] != nil {
        return primary
    }
    return totals.max {
        ($0.value.input + $0.value.output) < ($1.value.input + $1.value.output)
    }?.key
}
