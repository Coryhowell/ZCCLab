import Foundation
import CryptoKit

/// Tiny DER reader, just enough to print subject / issuer / validity / SANs from an X.509 certificate.
nonisolated struct DERNode {
    var tag: UInt8
    var content: Range<Int>
    var full: Range<Int>
}

nonisolated struct DER {
    let b: [UInt8]

    func node(at i: Int, limit: Int) -> DERNode? {
        guard i + 2 <= limit else { return nil }
        let tag = b[i]
        var len = Int(b[i + 1])
        var p = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, p + n <= limit else { return nil }
            len = 0
            for k in 0..<n { len = len << 8 | Int(b[p + k]) }
            p += n
        }
        guard p + len <= limit else { return nil }
        return DERNode(tag: tag, content: p..<(p + len), full: i..<(p + len))
    }

    func children(_ n: DERNode) -> [DERNode] {
        var out: [DERNode] = []
        var i = n.content.lowerBound
        while let c = node(at: i, limit: n.content.upperBound) { out.append(c); i = c.full.upperBound }
        return out
    }

    func oid(_ n: DERNode) -> String {
        let bytes = Array(b[n.content])
        guard let f = bytes.first else { return "" }
        var parts = [Int(f) / 40, Int(f) % 40]
        var v = 0
        for x in bytes.dropFirst() {
            v = v << 7 | Int(x & 0x7F)
            if x & 0x80 == 0 { parts.append(v); v = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    func string(_ n: DERNode) -> String { String(decoding: b[n.content], as: UTF8.self) }

    func name(_ n: DERNode) -> String {
        let short = ["2.5.4.3": "CN", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST"]
        var out: [String] = []
        for rdn in children(n) {
            for atv in children(rdn) {
                let kv = children(atv)
                if kv.count == 2 { out.append("\(short[oid(kv[0])] ?? oid(kv[0]))=\(string(kv[1]))") }
            }
        }
        return out.joined(separator: ", ")
    }

    func date(_ n: DERNode) -> String {
        let s = string(n)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = n.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        if let d = f.date(from: s) {
            let o = DateFormatter(); o.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"; o.timeZone = TimeZone(identifier: "UTC")
            return o.string(from: d)
        }
        return s
    }
}

nonisolated struct CertSummary: Sendable {
    var subject = "", issuer = "", notBefore = "", notAfter = "", sha256 = ""
    var sans: [String] = []
}

nonisolated enum TLSTool {
    static func parse(_ data: Data) -> CertSummary {
        var s = CertSummary()
        s.sha256 = Hex.fingerprint(Data(SHA256.hash(data: data)))
        let der = DER(b: [UInt8](data))
        guard let top = der.node(at: 0, limit: der.b.count) else { return s }
        guard let tbs = der.children(top).first else { return s }
        let kids = der.children(tbs)
        var i = 0
        if kids.first?.tag == 0xA0 { i = 1 }
        guard kids.count > i + 5 else { return s }
        s.issuer = der.name(kids[i + 2])
        let v = der.children(kids[i + 3])
        if v.count == 2 { s.notBefore = der.date(v[0]); s.notAfter = der.date(v[1]) }
        s.subject = der.name(kids[i + 4])
        if let ext = kids.first(where: { $0.tag == 0xA3 }), let seq = der.children(ext).first {
            for e in der.children(seq) {
                let parts = der.children(e)
                guard let o = parts.first, der.oid(o) == "2.5.29.17", let octet = parts.last,
                      let names = der.node(at: octet.content.lowerBound, limit: octet.content.upperBound) else { continue }
                for g in der.children(names) {
                    if g.tag == 0x82 { s.sans.append(der.string(g)) }
                    else if g.tag == 0x87 {
                        let ip = Array(der.b[g.content])
                        s.sans.append(ip.count == 4 ? ip.map(String.init).joined(separator: ".") : "ip:" + Hex.string(ip))
                    }
                }
            }
        }
        return s
    }

    @concurrent static func inspect(host: String, port: Int?, emit: Emit) async {
        let h = NetUtil.host(from: host)
        let url = "https://\(h)" + (port.map { ":\($0)" } ?? "")
        emit("# TLS inspect \(url)")
        var spec = HTTPSpec(url: url)
        spec.timeout = 8
        let r = await HTTPTool.run(spec)
        if let m = r.metrics { emit("  negotiated: \(m.tlsVersion ?? "-"), cipher \(m.cipher ?? "-"), remote \(m.remoteIP ?? "-")") }
        if let s = r.statusCode { emit("  HTTP \(s) after the handshake") } else { emit("  request failed: \(r.errorName ?? "?") \(r.errorText ?? "")") }
        emit("  trust evaluation: \(r.trustEvaluation ?? "no server trust challenge captured")")
        guard !r.certificateChain.isEmpty else { emit("  no certificate chain captured"); return }
        var zscalerIssued = false
        for (i, d) in r.certificateChain.enumerated() {
            let c = parse(d)
            emit("## [\(i)] \(i == 0 ? "leaf" : i == r.certificateChain.count - 1 ? "root/last" : "intermediate")")
            emit("  subject:   \(c.subject)")
            emit("  issuer:    \(c.issuer)")
            emit("  valid:     \(c.notBefore)  →  \(c.notAfter)")
            if !c.sans.isEmpty { emit("  SANs:      " + c.sans.prefix(12).joined(separator: ", ") + (c.sans.count > 12 ? " … (+\(c.sans.count - 12))" : "")) }
            emit("  SHA-256:   \(c.sha256)")
            if (c.issuer + c.subject).lowercased().contains("zscaler") { zscalerIssued = true }
        }
        emit(zscalerIssued
             ? "⚑ A Zscaler CA appears in this chain: ZIA SSL inspection is re-signing this host's traffic."
             : "No Zscaler CA in this chain (inspection bypassed for this host, or ZIA isn't in the path).")
        emit("Tip: run this against \(Defaults.tlsControlHost) with ZCC on and off and compare issuers. Validate before relying on it: bypass lists vary.")
    }

    /// Returns "zscaler-issued" / "not zscaler" / nil when the chain couldn't be read.
    @concurrent static func quickIssuerCheck(host: String) async -> (zscaler: Bool, issuer: String)? {
        let r = await HTTPTool.run(HTTPSpec(url: "https://\(host)", timeout: 6))
        guard let leaf = r.certificateChain.first else { return nil }
        let c = parse(leaf)
        let all = r.certificateChain.map { parse($0) }.map { $0.issuer + $0.subject }.joined().lowercased()
        return (all.contains("zscaler"), c.issuer)
    }
}
