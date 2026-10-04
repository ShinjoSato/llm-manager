import Darwin
import Foundation

/// 待ち受けに使える LAN のインターフェース（IPv4）。
public struct LANInterface: Sendable, Equatable, Hashable, Identifiable {
    /// `en0` 等。
    public var name: String
    public var address: String
    /// サブネットマスク（`255.255.255.0` 等）。読めなければ nil。
    public var netmask: String?

    public var id: String { name }

    public init(name: String, address: String, netmask: String? = nil) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    /// 属しているネットワーク（`192.168.1.0/24` 等）。
    public var network: String? { netmask.flatMap { LANNetwork.cidr(address: address, netmask: $0) } }
}

public enum LANInterfaces {
    /// VPN・仮想マシン・共有用のブリッジ・AirDrop 等の口は手元の Wi-Fi / 有線 LAN ではないので候補に出さない。
    static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "anpi", "ap", "gif", "stf", "ipsec", "ppp",
                                   "bridge", "vmnet", "vmenet", "vnic", "tun", "tap", "feth"]

    /// 候補にするか（名前・フラグ・アドレスで決める）。
    static func isCandidate(name: String, flags: Int32, address: String) -> Bool {
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { return false }
        guard !excludedPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        return !address.hasPrefix("169.254.")
    }

    /// 動いている IPv4 のインターフェース（ループバック・ポイントツーポイント・リンクローカル 169.254 を除く）。Wi-Fi / 有線（en*）を先に。
    public static func current() -> [LANInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [LANInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let address = numericHost(addr) else { continue }
            let name = String(cString: entry.ifa_name)
            guard isCandidate(name: name, flags: Int32(bitPattern: entry.ifa_flags), address: address) else { continue }
            found.append(LANInterface(name: name, address: address, netmask: entry.ifa_netmask.flatMap(numericHost)))
        }
        return sort(found)
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(max(addr.pointee.sa_len, UInt8(MemoryLayout<sockaddr_in>.size))), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
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

/// 口を有効にした時のネットワーク。別のネットワーク（外出先の Wi-Fi 等）では自動で開かないために覚える。
public struct LANNetwork: Codable, Sendable, Equatable {
    /// `192.168.1.0/24` の形。
    public var cidr: String
    /// 既定のルーターの MAC アドレス（取れなければ nil）。同じアドレス帯の別の場所を見分けるため。
    public var routerMAC: String?

    public init(cidr: String, routerMAC: String?) {
        self.cidr = cidr
        self.routerMAC = routerMAC
    }

    /// アドレスとマスクからネットワークを作る。
    public static func cidr(address: String, netmask: String) -> String? {
        guard let a = parse(address), let m = parse(netmask) else { return nil }
        let prefix = m.nonzeroBitCount
        // 連続しないマスクは扱わない。
        guard m == (prefix == 0 ? 0 : UInt32.max << (32 - prefix)) else { return nil }
        let n = a & m
        return "\(n >> 24).\((n >> 16) & 0xff).\((n >> 8) & 0xff).\(n & 0xff)/\(prefix)"
    }

    static func parse(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    public enum Match: Equatable {
        case same
        case different
    }

    /// 覚えたネットワークと今のものが同じか。ルーターの MAC は両方取れた時だけ比べる（取れないことがあるので、片方だけなら CIDR で決める）。
    public static func compare(saved: LANNetwork, current: LANNetwork) -> Match {
        guard saved.cidr == current.cidr else { return .different }
        if let a = saved.routerMAC, let b = current.routerMAC, a != b { return .different }
        return .same
    }

    public enum Decision: Equatable {
        /// 開いてよい。
        case open
        /// 開いてよく、これを覚え直す（初めて・ルーターの MAC が取れた）。
        case remember(LANNetwork)
        /// 別のネットワーク（か、今のネットワークが分からない）なので開かない。
        case refuse
    }

    /// 口を自動で開いてよいか。
    public static func decide(saved: LANNetwork?, current: LANNetwork?) -> Decision {
        guard let current else { return saved == nil ? .open : .refuse }
        guard let saved else { return .remember(current) }
        guard compare(saved: saved, current: current) == .same else { return .refuse }
        if saved.routerMAC == nil, current.routerMAC != nil { return .remember(current) }
        return .open
    }

    /// そのインターフェースの今のネットワーク（マスクが読めなければ nil）。
    public static func current(for interface: LANInterface) -> LANNetwork? {
        guard let cidr = interface.network else { return nil }
        return LANNetwork(cidr: cidr, routerMAC: RouterLookup.routerMAC(interfaceName: interface.name))
    }
}

/// 既定のルーター（IPv4）の MAC アドレスを経路表と ARP 表から引く。取れなければ nil（判定は CIDR だけになる）。
enum RouterLookup {
    static func routerMAC(interfaceName: String) -> String? {
        let index = if_nametoindex(interfaceName)
        guard index != 0, let gateway = defaultGateway(interfaceIndex: UInt16(index)) else { return nil }
        return arpEntry(for: gateway, interfaceIndex: UInt16(index))
    }

    /// 経路表を読み、メッセージごとに（ヘッダー, その後ろの sockaddr の列）を渡す。
    private static func walkRoutes(flags: Int32, _ body: (rt_msghdr, [UnsafePointer<sockaddr>]) -> Bool) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return }
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= length {
                let header = base.advanced(by: offset).loadUnaligned(as: rt_msghdr.self)
                let size = Int(header.rtm_msglen)
                guard size > 0, offset + size <= length else { return }
                var addrs: [UnsafePointer<sockaddr>] = []
                var cursor = offset + MemoryLayout<rt_msghdr>.size
                for bit in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << bit) != 0 {
                    guard cursor + MemoryLayout<sockaddr>.size <= offset + size else { break }
                    let sa = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr.self)
                    addrs.append(UnsafePointer(sa))
                    let len = Int(sa.pointee.sa_len)
                    // sockaddr は 4 バイト境界にそろえて並ぶ。
                    cursor += len > 0 ? (1 + ((len - 1) | 3)) : 4
                }
                if !body(header, addrs) { return }
                offset += size
            }
        }
    }

    private static func ipv4(_ sa: UnsafePointer<sockaddr>) -> UInt32? {
        guard sa.pointee.sa_family == UInt8(AF_INET), sa.pointee.sa_len >= 8 else { return nil }
        return UnsafeRawPointer(sa).loadUnaligned(fromByteOffset: 4, as: UInt32.self)
    }

    static func defaultGateway(interfaceIndex: UInt16) -> UInt32? {
        var found: UInt32?
        walkRoutes(flags: RTF_GATEWAY) { header, addrs in
            // 宛先 0.0.0.0（既定の経路）で、そのインターフェースを通るもの。
            guard header.rtm_index == interfaceIndex, addrs.count >= 2, header.rtm_addrs & RTA_DST != 0,
                  header.rtm_addrs & RTA_GATEWAY != 0, let dst = ipv4(addrs[0]), dst == 0, let gw = ipv4(addrs[1]) else { return true }
            found = gw
            return false
        }
        return found
    }

    static func arpEntry(for ip: UInt32, interfaceIndex: UInt16) -> String? {
        var found: String?
        walkRoutes(flags: RTF_LLINFO) { header, addrs in
            guard header.rtm_index == interfaceIndex, addrs.count >= 2, let dst = ipv4(addrs[0]), dst == ip,
                  addrs[1].pointee.sa_family == UInt8(AF_LINK) else { return true }
            // sockaddr_dl: len, family, index(2), type, nlen, alen, slen, data（名前の後ろにアドレス）。
            let dl = UnsafeRawPointer(addrs[1])
            let length = Int(dl.load(fromByteOffset: 0, as: UInt8.self))
            let nlen = Int(dl.load(fromByteOffset: 5, as: UInt8.self)), alen = Int(dl.load(fromByteOffset: 6, as: UInt8.self))
            guard alen == 6, 8 + nlen + alen <= length else { return true }
            let mac = (0..<alen).map { String(format: "%02x", dl.load(fromByteOffset: 8 + nlen + $0, as: UInt8.self)) }.joined(separator: ":")
            guard mac != "00:00:00:00:00:00" else { return true }
            found = mac
            return false
        }
        return found
    }
}
