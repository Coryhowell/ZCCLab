import Foundation
import Darwin

/// Unprivileged ICMP (SOCK_DGRAM / IPPROTO_ICMP) works on iOS and macOS without root. IPv4 only.
nonisolated enum PingTool {
    static func checksum(_ d: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < d.count { sum += UInt32(d[i]) << 8 | UInt32(d[i + 1]); i += 2 }
        if i < d.count { sum += UInt32(d[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    static func packet(id: UInt16, seq: UInt16, payload: Int) -> [UInt8] {
        var p: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xFF), UInt8(seq >> 8), UInt8(seq & 0xFF)]
        p += (0..<max(0, payload)).map { UInt8(truncatingIfNeeded: $0 &+ 0x20) }
        let c = checksum(p)
        p[2] = UInt8(c >> 8); p[3] = UInt8(c & 0xFF)
        return p
    }

    static func makeAddr(_ ip: String) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
        return a
    }

    static func send(fd: Int32, to addr: sockaddr_in, packet: [UInt8]) -> Bool {
        var a = addr
        return withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == packet.count
            }
        }
    }

    struct Reply { var type: UInt8; var code: UInt8; var seq: UInt16; var ttl: Int; var bytes: Int; var from: String }

    /// Waits up to `timeoutMs` for any ICMP message. Returns nil on timeout.
    static func receive(fd: Int32, timeoutMs: Int) -> Reply? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeoutMs)) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 1500)
        var src = sockaddr_in()
        var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &src) { sp in
            sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &slen) }
        }
        guard n > 8 else { return nil }
        var off = 0, ttl = 0
        if buf[0] >> 4 == 4 { off = Int(buf[0] & 0x0F) * 4; ttl = Int(buf[8]) }
        guard n > off + 7 else { return nil }
        let from = withUnsafePointer(to: &src) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { NetUtil.ipString(from: $0) } ?? "?"
        }
        var seq = UInt16(buf[off + 6]) << 8 | UInt16(buf[off + 7])
        if buf[off] == 11 || buf[off] == 3 {
            // ICMP error: embedded original IP header + our echo request header.
            let inner = off + 8
            if n > inner, buf[inner] >> 4 == 4 {
                let ihl = Int(buf[inner] & 0x0F) * 4
                if n > inner + ihl + 7 { seq = UInt16(buf[inner + ihl + 6]) << 8 | UInt16(buf[inner + ihl + 7]) }
            }
        }
        return Reply(type: buf[off], code: buf[off + 1], seq: seq, ttl: ttl, bytes: n - off, from: from)
    }

    @concurrent static func run(host: String, count: Int, intervalMs: Int, payload: Int, ttl: Int, timeoutMs: Int, emit: Emit) async {
        let h = NetUtil.host(from: host)
        emit("# Ping \(h)  (ICMP echo, \(payload) byte payload, TTL \(ttl))")
        let r = NetUtil.resolve(h, family: AF_INET)
        guard let ip = r.addrs.first?.ip, let addr = makeAddr(ip) else {
            emit("  could not resolve an IPv4 address: \(r.error ?? "no A record")"); return
        }
        emit("  resolved \(h) → \(ip) in \(Fmt.ms(r.ms))")
        if NetUtil.inRange(ip, cidr: await AppSettings.shared.effective.syntheticRange) {
            emit("  ⚑ synthetic ZPA address: ZPA doesn't carry ICMP by default, so loss here does NOT mean the app is down")
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { emit("  socket() failed: \(String(cString: strerror(errno)))"); return }
        defer { close(fd) }
        var t = Int32(ttl)
        setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size))
        let id = UInt16.random(in: 1...UInt16.max)
        var rtts: [Double] = []
        var sent = 0
        for seq in 1...max(1, count) {
            if Task.isCancelled { emit("  (cancelled)"); break }
            let pkt = packet(id: id, seq: UInt16(seq), payload: payload)
            let t0 = Clock.now()
            guard send(fd: fd, to: addr, packet: pkt) else {
                emit("  seq \(seq): send failed: \(String(cString: strerror(errno)))"); continue
            }
            sent += 1
            var got = false
            while !got {
                let remaining = timeoutMs - Int(Clock.ms(since: t0))
                guard remaining > 0, let rep = receive(fd: fd, timeoutMs: remaining) else { break }
                guard rep.seq == UInt16(seq) else { continue }
                let rtt = Clock.ms(since: t0)
                switch rep.type {
                case 0:
                    rtts.append(rtt)
                    emit(String(format: "  %d bytes from %@: icmp_seq=%d ttl=%d time=%.2f ms", rep.bytes, rep.from, seq, rep.ttl, rtt))
                case 11: emit("  seq \(seq): TTL exceeded from \(rep.from)")
                case 3: emit("  seq \(seq): destination unreachable (code \(rep.code)) from \(rep.from)")
                default: emit("  seq \(seq): ICMP type \(rep.type) code \(rep.code) from \(rep.from)")
                }
                got = true
            }
            if !got { emit("  seq \(seq): request timeout (\(timeoutMs) ms)") }
            if seq < count { try? await Task.sleep(for: .milliseconds(intervalMs)) }
        }
        emit("--- \(h) (\(ip)) statistics ---")
        let loss = sent == 0 ? 100.0 : Double(sent - rtts.count) / Double(sent) * 100
        emit("  \(sent) sent, \(rtts.count) received, \(String(format: "%.0f", loss))% loss")
        if let mn = rtts.min(), let mx = rtts.max() {
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            let sd = (rtts.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(rtts.count)).squareRoot()
            emit(String(format: "  rtt min/avg/max/stddev = %.2f/%.2f/%.2f/%.2f ms", mn, avg, mx, sd))
        }
    }

    // MARK: Traceroute (ICMP echo with increasing TTL, best effort)

    @concurrent static func traceroute(host: String, maxHops: Int, probesPerHop: Int, timeoutMs: Int, reverseDNS: Bool, emit: Emit) async {
        let h = NetUtil.host(from: host)
        emit("# Traceroute \(h)  (ICMP, best effort)")
        emit("  Note: ZPA and Zscaler edges commonly don't return TTL-exceeded. Stars are normal. On macOS use the Shell tab for /usr/sbin/traceroute.")
        let r = NetUtil.resolve(h, family: AF_INET)
        guard let ip = r.addrs.first?.ip, let addr = makeAddr(ip) else { emit("  could not resolve IPv4: \(r.error ?? "?")"); return }
        emit("  target \(h) [\(ip)], max \(maxHops) hops")
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { emit("  socket() failed: \(String(cString: strerror(errno)))"); return }
        defer { close(fd) }
        let id = UInt16.random(in: 1...UInt16.max)
        var seq: UInt16 = 0
        for hop in 1...max(1, maxHops) {
            if Task.isCancelled { emit("  (cancelled)"); return }
            var t = Int32(hop)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size))
            var line = String(format: "%2d ", hop)
            var hopIPs: [String] = []
            var reached = false
            for _ in 0..<max(1, probesPerHop) {
                seq &+= 1
                let t0 = Clock.now()
                guard send(fd: fd, to: addr, packet: packet(id: id, seq: seq, payload: 32)) else { line += " !"; continue }
                var answered = false
                while true {
                    let remaining = timeoutMs - Int(Clock.ms(since: t0))
                    guard remaining > 0, let rep = receive(fd: fd, timeoutMs: remaining) else { break }
                    guard rep.seq == seq else { continue }
                    if !hopIPs.contains(rep.from) { hopIPs.append(rep.from) }
                    line += String(format: " %.1f ms", Clock.ms(since: t0))
                    if rep.type == 0 { reached = true }
                    answered = true
                    break
                }
                if !answered { line += " *" }
            }
            var who = hopIPs.joined(separator: ", ")
            if reverseDNS, let first = hopIPs.first, var sa = makeAddr(first) {
                let name: String? = withUnsafePointer(to: &sa) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { NetUtil.ipString(from: $0, numeric: false) }
                }
                if let name, name != first { who += " (\(name))" }
            }
            emit(line + (who.isEmpty ? "" : "   " + who))
            if reached { emit("  reached destination at hop \(hop)"); return }
        }
        emit("  max hops reached without a reply from the destination")
    }
}
