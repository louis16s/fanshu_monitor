import Darwin
import CoreWLAN
import Foundation
import OSLog

nonisolated final class NetworkSampler: MonitorSampler {
    var kind: MonitorKind { .network }

    private var previousNetworkBytes: (input: UInt64, output: UInt64, timestamp: Date)?
    private var cachedSSID: (value: String, refreshedAt: Date)?
    private var cachedAddresses: (ipv4: String, ipv6: String, refreshedAt: Date)?
    private let ssidRefreshInterval: TimeInterval = 30
    private let addressRefreshInterval: TimeInterval = 30

    func sample(previous: MonitorModule?) -> MonitorModule {
        let now = Date()
        let bytes = networkBytes()
        let addresses = addressSummary(for: bytes, at: now)
        let previousBytes = previousNetworkBytes
        previousNetworkBytes = (bytes.input, bytes.output, now)

        guard let previousBytes else {
            return MonitorModule(
                kind: .network,
                value: 0,
                summary: bytes.interface,
                metrics: [
                    MonitorMetric(name: "ssid", value: currentSSID(at: now)),
                    MonitorMetric(name: "ipv4", value: addresses.ipv4),
                    MonitorMetric(name: "ipv6", value: addresses.ipv6),
                    MonitorMetric(name: "upload", value: "--"),
                    MonitorMetric(name: "download", value: "--")
                ],
                samples: seedSamples(0)
            )
        }

        let delta = max(0.1, now.timeIntervalSince(previousBytes.timestamp))
        let upload = Double(bytes.output &- previousBytes.output) / delta
        let download = Double(bytes.input &- previousBytes.input) / delta
        let value = min(100, log10(max(1, upload + download)) * 14)

        return MonitorModule(
            kind: .network,
            value: value,
            summary: bytes.interface,
            metrics: [
                MonitorMetric(name: "ssid", value: currentSSID(at: now)),
                MonitorMetric(name: "ipv4", value: addresses.ipv4),
                MonitorMetric(name: "ipv6", value: addresses.ipv6),
                MonitorMetric(name: "upload", value: bytesPerSecond(upload)),
                MonitorMetric(name: "download", value: bytesPerSecond(download))
            ],
            samples: seedSamples(value)
        )
    }

    private func networkBytes() -> NetworkInterfaceSnapshot {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        var totalsByInterface: [String: (input: UInt64, output: UInt64)] = [:]
        var ipv4ByInterface: [String: [String]] = [:]
        var ipv6ByInterface: [String: [String]] = [:]

        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            AppLogger.sampler.error("getifaddrs failed, errno: \(errno)")
            return NetworkInterfaceSnapshot(input: 0, output: 0, interface: "network", ipv4Addresses: [], ipv6Addresses: [])
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

        let active = totalsByInterface.max {
            ($0.value.input + $0.value.output) < ($1.value.input + $1.value.output)
        }
        let total = totalsByInterface.values.reduce((input: UInt64(0), output: UInt64(0))) { partial, next in
            (partial.input + next.input, partial.output + next.output)
        }

        AppLogger.sampler.debug("Network interfaces detected: \(totalsByInterface.keys.joined(separator: ", "), privacy: .public), active: \(active?.key ?? "none", privacy: .public)")

        return NetworkInterfaceSnapshot(
            input: total.input,
            output: total.output,
            interface: networkInterfaceTitle(active?.key),
            ipv4Addresses: active.flatMap { ipv4ByInterface[$0.key] } ?? [],
            ipv6Addresses: active.flatMap { ipv6ByInterface[$0.key] } ?? []
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
        if name.hasPrefix("pdp_ip") {
            return "cellular"
        }
        return name
    }

    private func shouldIgnoreInterface(_ name: String) -> Bool {
        name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("awdl")
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

    private func currentSSID(at date: Date) -> String {
        if let cachedSSID,
           date.timeIntervalSince(cachedSSID.refreshedAt) < ssidRefreshInterval {
            return cachedSSID.value
        }

        let value = CWWiFiClient.shared().interface()?.ssid() ?? "--"
        cachedSSID = (value, date)
        return value
    }

    private func addressSummary(for snapshot: NetworkInterfaceSnapshot, at date: Date) -> (ipv4: String, ipv6: String) {
        if let cachedAddresses,
           date.timeIntervalSince(cachedAddresses.refreshedAt) < addressRefreshInterval {
            return (cachedAddresses.ipv4, cachedAddresses.ipv6)
        }

        let value = (
            ipv4: networkAddressSummary(snapshot.ipv4Addresses),
            ipv6: networkAddressSummary(snapshot.ipv6Addresses)
        )
        cachedAddresses = (value.ipv4, value.ipv6, date)
        return value
    }
}

nonisolated struct NetworkInterfaceSnapshot {
    let input: UInt64
    let output: UInt64
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
