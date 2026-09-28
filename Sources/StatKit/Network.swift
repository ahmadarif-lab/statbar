import Darwin
import SystemConfiguration

public struct NetworkUsage: Sendable, Equatable {
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double
    /// Bytes moved since boot.
    public var totalIn: UInt64
    public var totalOut: UInt64
    /// The interface carrying the default route's address, e.g. `en0`.
    public var interface: String?
    public var address: String?
    /// "Wi-Fi", "Ethernet", "USB 10/100/1000 LAN"...
    public var interfaceName: String?
    public var isWiFi: Bool
}

public struct NetworkInterface: Sendable, Equatable, Identifiable {
    /// BSD name, e.g. "en0".
    public var id: String
    /// "Wi-Fi", "Ethernet"...
    public var name: String
}

/// Throughput summed over the `en*` interfaces, or read from one chosen
/// interface. Tunnels (utun) and bridges are left out of the sum because
/// their traffic is already counted once on `en*`.
public struct NetworkSampler {
    private var previous: (bytesIn: UInt64, bytesOut: UInt64, time: Double)?
    /// A BSD name to measure only that interface; nil for every `en*`.
    public var interface: String? {
        didSet { if interface != oldValue { previous = nil } }
    }

    public init() {}

    public mutating func sample(now: Double) -> NetworkUsage? {
        guard let counters = Self.readCounters(only: interface) else { return nil }
        defer { previous = (counters.bytesIn, counters.bytesOut, now) }
        let primary = Self.primaryAddress(on: interface)
        var usage = NetworkUsage(
            bytesInPerSecond: 0, bytesOutPerSecond: 0,
            totalIn: counters.bytesIn, totalOut: counters.bytesOut,
            interface: primary?.interface, address: primary?.address,
            interfaceName: nil, isWiFi: false
        )
        if let bsd = primary?.interface, let info = interfaceInfo(bsd) {
            usage.interfaceName = info.name
            usage.isWiFi = info.isWiFi
        }
        if let previous, now > previous.time {
            let elapsed = now - previous.time
            usage.bytesInPerSecond = Double(delta(previous.bytesIn, counters.bytesIn)) / elapsed
            usage.bytesOutPerSecond = Double(delta(previous.bytesOut, counters.bytesOut)) / elapsed
        }
        return usage
    }

    private var knownInterfaces: [String: (name: String, isWiFi: Bool)] = [:]

    /// Display name from System Configuration, cached: the list only
    /// changes when hardware comes or goes, which a cache miss catches.
    private mutating func interfaceInfo(_ bsdName: String) -> (name: String, isWiFi: Bool)? {
        if let known = knownInterfaces[bsdName] { return known }
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            knownInterfaces[bsd] = (name, type == (kSCNetworkInterfaceTypeIEEE80211 as String))
        }
        return knownInterfaces[bsdName]
    }

    /// An interface that goes away drops its counters out of the sum; treat
    /// that as no traffic rather than a huge negative spike.
    private func delta(_ old: UInt64, _ new: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    /// Interfaces worth offering in Settings: the physical `en*` ones.
    public static func availableInterfaces() -> [NetworkInterface] {
        (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { interface in
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?, bsd.hasPrefix("en"),
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { return nil }
            return NetworkInterface(id: bsd, name: name)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func readCounters(only interface: String? = nil) -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let name = interfaceName(index: info.ifm_index)
                    let counted = interface.map { name == $0 } ?? (name?.hasPrefix("en") == true)
                    if counted {
                        bytesIn += info.ifm_data.ifi_ibytes
                        bytesOut += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (bytesIn, bytesOut)
    }

    private static func interfaceName(index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(cString: name)
    }

    /// First up, non-link-local IPv4 address on an `en*` interface.
    static func primaryAddress(on interface: String? = nil) -> (interface: String, address: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var candidates: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard interface.map({ name == $0 }) ?? name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append((name, address))
        }
        // en0 is the built-in Wi-Fi/Ethernet; prefer it, else lowest index.
        return candidates.min { $0.interface.localizedStandardCompare($1.interface) == .orderedAscending }
    }
}
