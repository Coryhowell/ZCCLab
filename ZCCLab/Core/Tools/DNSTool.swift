import Foundation
import Darwin
import dnssd

nonisolated enum DNSRecordType: String, CaseIterable, Sendable, Identifiable {
    case A, AAAA, CNAME, MX, TXT, SRV, PTR, NS
    var id: String { rawValue }
    var code: UInt16 {
        switch self { case .A: 1; case .NS: 2; case .CNAME: 5; case .PTR: 12; case .MX: 15; case .TXT: 16; case .AAAA: 28; case .SRV: 33 }
    }
    static func name(for code: UInt16) -> String { allCases.first { $0.code == code }?.rawValue ?? "TYPE\(code)" }
}

/// Minimal DNS wire-format helpers (used for both dnssd rdata and direct UDP queries).
nonisolated enum DNSWire {
    static func name(in b: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = start
        var next = -1
        var hops = 0
        while i < b.count {
            let len = Int(b[i])
            if len == 0 { i += 1; break }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < b.count, hops < 16 else { return nil }
                if next < 0 { next = i + 2 }
                i = ((len & 0x3F) << 8) | Int(b[i + 1])
                hops += 1
                continue
            }
            guard i + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        return (labels.isEmpty ? "." : labels.joined(separator: "."), next >= 0 ? next : i)
    }

    static func describe(type: UInt16, buf b: [UInt8], start: Int, len: Int) -> String {
        guard start + len <= b.count else { return "(truncated)" }
        switch type {
        case 1 where len == 4: return b[start..<start + 4].map(String.init).joined(separator: ".")
        case 28 where len == 16:
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { dst in for k in 0..<16 { dst[k] = b[start + k] } }
            var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &out, socklen_t(out.count))
            return String(cString: out)
        case 2, 5, 12: return name(in: b, at: start)?.0 ?? Hex.string(Array(b[start..<start + len]))
        case 15 where len > 2:
            let pref = Int(b[start]) << 8 | Int(b[start + 1])
            return "pref \(pref) \(name(in: b, at: start + 2)?.0 ?? "?")"
        case 16:
            var parts: [String] = []
            var i = start
            while i < start + len {
                let l = Int(b[i]); i += 1
                guard i + l <= start + len else { break }
                parts.append("\"" + String(decoding: b[i..<i + l], as: UTF8.self) + "\"")
                i += l
            }
            return parts.joined(separator: " ")
        case 33 where len > 6:
            let prio = Int(b[start]) << 8 | Int(b[start + 1])
            let w = Int(b[start + 2]) << 8 | Int(b[start + 3])
            let port = Int(b[start + 4]) << 8 | Int(b[start + 5])
            return "prio \(prio) weight \(w) port \(port) \(name(in: b, at: start + 6)?.0 ?? "?")"
        default: return Hex.string(Array(b[start..<start + len]))
        }
    }
}

nonisolated final class DNSQueryBox: @unchecked Sendable {
    var records: [(type: UInt16, ttl: UInt32, text: String)] = []
    var error: Int32 = 0
    var finished = false
}

nonisolated enum DNSTool {
    /// nslookup-style output via the system resolver (getaddrinfo + dnssd).
    @concurrent static func lookup(host: String, types: [DNSRecordType], emit: Emit) async {
        let h = NetUtil.host(from: host)
        emit("# DNS lookup: \(h)")
        emit("## System resolver (getaddrinfo)")
        let r = NetUtil.resolve(h)
        if let e = r.error {
            emit("  error: \(e)  (\(Fmt.ms(r.ms)))")
        } else {
            for a in r.addrs { emit("  \(a.family)  \(a.ip)") }
            if let c = r.canonical, c.lowercased() != h.lowercased() { emit("  canonical name: \(c)") }
            emit("  \(r.addrs.count) address(es) in \(Fmt.ms(r.ms))")
            let range = await AppSettings.shared.effective.syntheticRange
            for a in r.addrs where a.family == "IPv4" && NetUtil.inRange(a.ip, cidr: range) {
                emit("  ⚑ \(a.ip) is inside \(range): looks like a ZPA synthetic IP (ZCC is intercepting DNS for this host)")
            }
        }
        for t in types where !(t == .A || t == .AAAA) || true {
            if Task.isCancelled { return }
            emit("## \(t.rawValue) record (dnssd)")
            let t0 = Clock.now()
            let q = queryRecord(name: h, type: t.code, timeout: 4)
            let ms = Clock.ms(since: t0)
            if q.error != 0 {
                emit("  \(q.error == -65554 ? "no such record" : "dnssd error \(q.error)")  (\(Fmt.ms(ms)))")
            } else if q.records.isEmpty {
                emit("  (no answer in 4 s)")
            } else {
                for rec in q.records { emit("  \(DNSRecordType.name(for: rec.type))  ttl \(rec.ttl)  \(rec.text)") }
                emit("  \(Fmt.ms(ms))")
            }
        }
        emit("## Resolvers in use")
        for line in await resolvers() { emit("  \(line)") }
    }

    static func queryRecord(name: String, type: UInt16, timeout: Double) -> (records: [(type: UInt16, ttl: UInt32, text: String)], error: Int32) {
        let box = DNSQueryBox()
        let ptr = Unmanaged.passRetained(box)
        defer { ptr.release() }
        var ref: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, err, _, rrtype, _, rdlen, rdata, ttl, ctx in
            guard let ctx else { return }
            let b = Unmanaged<DNSQueryBox>.fromOpaque(ctx).takeUnretainedValue()
            if err != 0 { b.error = err; b.finished = true; return }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata {
                let bytes = Array(UnsafeBufferPointer(start: rdata.assumingMemoryBound(to: UInt8.self), count: Int(rdlen)))
                b.records.append((rrtype, ttl, DNSWire.describe(type: rrtype, buf: bytes, start: 0, len: bytes.count)))
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { b.finished = true }
        }
        let rc = DNSServiceQueryRecord(&ref, 0, 0, name, type, UInt16(kDNSServiceClass_IN), callback, ptr.toOpaque())
        guard rc == 0, let ref else { return ([], rc) }
        defer { DNSServiceRefDeallocate(ref) }
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Clock.now() + UInt64(timeout * 1_000_000_000)
        while !box.finished, Clock.now() < deadline, !Task.isCancelled {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, 200)
            if n > 0 { DNSServiceProcessResult(ref) }
        }
        return (box.records, box.error)
    }

    /// libresolv isn't importable from Swift, so resolver lists come from `scutil --dns` on macOS.
    /// iOS has no public API for this; use the direct-query comparison instead.
    static func resolvers() async -> [String] {
        #if os(macOS)
        let o = await MacShell.run("/usr/sbin/scutil", ["--dns"])
        let lines = o.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let ns = lines.filter { $0.hasPrefix("nameserver[") || $0.hasPrefix("resolver #") || $0.hasPrefix("domain") || $0.hasPrefix("if_index") }
        return ns.isEmpty ? ["(scutil --dns returned nothing)"] : ns
        #else
        return ["iOS exposes no public resolver list. Use \"Also query … directly\" to compare system vs. direct DNS."]
        #endif
    }

    // MARK: Direct UDP query to a chosen server (shows what ZCC intercepts)

    @concurrent static func direct(host: String, server: String, type: DNSRecordType, emit: Emit) async {
        let h = NetUtil.host(from: host)
        emit("## Direct query → \(server):53  \(type.rawValue) \(h)")
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, "53", &hints, &res) == 0, let ai = res else { emit("  bad DNS server address"); return }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else { emit("  socket() failed: \(String(cString: strerror(errno)))"); return }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            emit("  connect failed: \(String(cString: strerror(errno)))"); return
        }
        let txid = UInt16.random(in: 0...UInt16.max)
        var q: [UInt8] = [UInt8(txid >> 8), UInt8(txid & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in h.split(separator: ".") {
            q.append(UInt8(label.utf8.count)); q.append(contentsOf: Array(label.utf8))
        }
        q.append(0)
        q += [UInt8(type.code >> 8), UInt8(type.code & 0xFF), 0, 1]
        let t0 = Clock.now()
        guard send(fd, q, q.count, 0) == q.count else { emit("  send failed: \(String(cString: strerror(errno)))"); return }
        emit("  sent \(q.count) bytes (txid \(String(format: "0x%04X", txid)))")
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        let ms = Clock.ms(since: t0)
        guard n >= 12 else { emit("  no response (timeout or error) after \(Fmt.ms(ms))"); return }
        let b = Array(buf[0..<n])
        let rcode = Int(b[3] & 0x0F)
        let qd = Int(b[4]) << 8 | Int(b[5]), an = Int(b[6]) << 8 | Int(b[7])
        emit("  received \(n) bytes in \(Fmt.ms(ms)); rcode \(rcode) (\(["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED"][safe: rcode] ?? "?")); answers \(an)")
        var i = 12
        for _ in 0..<qd { guard let (_, nx) = DNSWire.name(in: b, at: i) else { return }; i = nx + 4 }
        for _ in 0..<an {
            guard let (nm, nx) = DNSWire.name(in: b, at: i), nx + 10 <= b.count else { break }
            let t = UInt16(b[nx]) << 8 | UInt16(b[nx + 1])
            let ttl = UInt32(b[nx + 4]) << 24 | UInt32(b[nx + 5]) << 16 | UInt32(b[nx + 6]) << 8 | UInt32(b[nx + 7])
            let rl = Int(b[nx + 8]) << 8 | Int(b[nx + 9])
            emit("  \(nm)  \(DNSRecordType.name(for: t))  ttl \(ttl)  \(DNSWire.describe(type: t, buf: b, start: nx + 10, len: rl))")
            i = nx + 10 + rl
        }
    }

    /// System vs. direct comparison: if only the system resolver answers (often a 100.64/10 address), ZCC DNS interception is active.
    @concurrent static func compare(host: String, servers: [String], emit: Emit) async {
        let h = NetUtil.host(from: host)
        emit("# Resolver comparison for \(h)")
        let sys = NetUtil.resolve(h, family: AF_INET)
        emit("System resolver: " + (sys.error ?? sys.addrs.map(\.ip).joined(separator: ", ")))
        for s in servers { await direct(host: h, server: s, type: .A, emit: emit) }
        emit("Interpretation: a 100.64.0.0/10 answer from the system resolver, with the direct server returning NXDOMAIN or a different address, means ZCC/ZPA is answering DNS locally.")
    }
}

extension Array {
    nonisolated subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
