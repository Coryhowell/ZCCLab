import Foundation
import Darwin

typealias Emit = @Sendable (String) -> Void

nonisolated struct ResolvedAddress: Sendable, Codable, Equatable {
    var ip: String
    var family: String   // "IPv4" / "IPv6"
}

nonisolated struct InterfaceInfo: Sendable, Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var flags: [String]
    var addresses: [String]
    var isUp: Bool
    var isRunning: Bool
    var isTunnel: Bool
}

nonisolated enum NetUtil {
    // MARK: Parsing

    /// "https://host:8443/path" -> "host"; "host" -> "host".
    static func host(from input: String) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), let h = u.host, !h.isEmpty { return h }
        var s = t
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if !s.contains("]"), let c = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 { s = String(s[..<c]) }
        return s
    }

    static func ipv4ToUInt(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func parseCIDR(_ s: String) -> (net: UInt32, mask: UInt32)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let ip = ipv4ToUInt(String(parts[0])), let bits = Int(parts[1]), (0...32).contains(bits) else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        return (ip & mask, mask)
    }

    static func inRange(_ ip: String, cidr: String) -> Bool {
        guard let c = parseCIDR(cidr), let v = ipv4ToUInt(ip) else { return false }
        return (v & c.mask) == c.net
    }

    // MARK: sockaddr helpers

    static func ipString(from sa: UnsafePointer<sockaddr>, numeric: Bool = true) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, numeric ? NI_NUMERICHOST : 0)
        return rc == 0 ? String(cString: buf) : nil
    }

    static func gaiMessage(_ rc: Int32) -> String { String(cString: gai_strerror(rc)) }

    // MARK: Resolve (getaddrinfo)

    /// Blocking. Call from a @concurrent context.
    static func resolve(_ host: String, family: Int32 = AF_UNSPEC) -> (addrs: [ResolvedAddress], canonical: String?, error: String?, ms: Double) {
        let t0 = Clock.now()
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_CANONNAME
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        let ms = Clock.ms(since: t0)
        guard rc == 0, let first = res else { return ([], nil, gaiMessage(rc), ms) }
        defer { freeaddrinfo(first) }
        var out: [ResolvedAddress] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        let canon = first.pointee.ai_canonname.map { String(cString: $0) }
        while let ai = cur {
            if let sa = ai.pointee.ai_addr, let s = ipString(from: sa) {
                let fam = ai.pointee.ai_family == AF_INET ? "IPv4" : "IPv6"
                let a = ResolvedAddress(ip: s, family: fam)
                if !out.contains(a) { out.append(a) }
            }
            cur = ai.pointee.ai_next
        }
        return (out, canon, nil, ms)
    }

    // MARK: Interfaces (getifaddrs)

    static func interfaces() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var map: [String: InterfaceInfo] = [:]
        var order: [String] = []
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        let flagMap: [(UInt32, String)] = [
            (UInt32(IFF_UP), "UP"), (UInt32(IFF_BROADCAST), "BROADCAST"), (UInt32(IFF_LOOPBACK), "LOOPBACK"),
            (UInt32(IFF_POINTOPOINT), "P2P"), (UInt32(IFF_RUNNING), "RUNNING"), (UInt32(IFF_MULTICAST), "MULTICAST"),
        ]
        while let p = cur {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            let flags = flagMap.filter { ifa.ifa_flags & $0.0 != 0 }.map(\.1)
            let tunnel = ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
            var info = map[name] ?? InterfaceInfo(name: name, flags: flags, addresses: [],
                                                  isUp: ifa.ifa_flags & UInt32(IFF_UP) != 0,
                                                  isRunning: ifa.ifa_flags & UInt32(IFF_RUNNING) != 0,
                                                  isTunnel: tunnel)
            if map[name] == nil { order.append(name) }
            if let sa = ifa.ifa_addr {
                let fam = Int32(sa.pointee.sa_family)
                if fam == AF_INET || fam == AF_INET6, let s = ipString(from: sa) { info.addresses.append(s) }
            }
            map[name] = info
            cur = ifa.ifa_next
        }
        return order.compactMap { map[$0] }
    }

    // MARK: Proxy settings (CFNetwork)

    static func proxySettings() -> [String: Any] {
        (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// Undocumented `__SCOPED__` key: per-interface proxy dictionaries. Weak evidence only.
    static func scopedInterfaceNames() -> [String] {
        let scoped = proxySettings()["__SCOPED__"] as? [String: Any] ?? [:]
        return scoped.keys.sorted()
    }

    static func isTunnelName(_ n: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { n.hasPrefix($0) }
    }
}

nonisolated enum Hex {
    static func string(_ bytes: [UInt8], limit: Int = 64) -> String {
        bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ") + (bytes.count > limit ? " …" : "")
    }
    static func fingerprint(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
