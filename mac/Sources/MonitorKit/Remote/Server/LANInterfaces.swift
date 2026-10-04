import Darwin
import Foundation

/// 待ち受けに使える LAN のインターフェース（IPv4）。
public struct LANInterface: Sendable, Equatable, Hashable, Identifiable {
    /// `en0` 等。
    public var name: String
    public var address: String

    public var id: String { name }

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

public enum LANInterfaces {
    /// VPN・AirDrop 等の口は LAN ではないので候補に出さない。
    static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "anpi", "ap", "gif", "stf", "ipsec", "ppp"]

    /// 動いている IPv4 のインターフェース（ループバック・リンクローカル 169.254 を除く）。Wi-Fi / 有線（en*）を先に。
    public static func current() -> [LANInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [LANInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard !excludedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            found.append(LANInterface(name: name, address: address))
        }
        return sort(found)
    }

    static func sort(_ list: [LANInterface]) -> [LANInterface] {
        list.sorted { a, b in
            let ea = a.name.hasPrefix("en"), eb = b.name.hasPrefix("en")
            if ea != eb { return ea }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 指定の名前のもの。無ければ（nil 指定なら）先頭（Wi-Fi / 有線を優先）。
    public static func choose(_ name: String?, from list: [LANInterface]) -> LANInterface? {
        if let name, !name.isEmpty { return list.first { $0.name == name } }
        return list.first
    }
}
