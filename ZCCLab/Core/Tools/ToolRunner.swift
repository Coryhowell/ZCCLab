import Foundation
import Observation

enum ToolKind: String, CaseIterable, Identifiable {
    case dns = "DNS", ping = "Ping", tcp = "TCP", http = "HTTP", trace = "Trace", tls = "TLS", egress = "Egress"
    #if os(macOS)
    case shell = "Shell"
    #endif
    var id: String { rawValue }
}

@Observable
final class ToolRunner {
    static let shared = ToolRunner()

    var kind: ToolKind = .dns
    var target = "www.apple.com"
    var running = false
    var lines: [String] = []

    // DNS
    var dnsTypes: Set<DNSRecordType> = [.A, .AAAA]
    var dnsCompare = false
    // Ping / trace
    var pingCount = 4
    var pingIntervalMs = 1000
    var pingPayload = 56
    var pingTTL = 64
    var pingTimeoutMs = 2000
    var traceMaxHops = 20
    var traceReverseDNS = false
    // TCP
    var tcpPort = 443
    // HTTP
    var httpMethod = "GET"
    var httpHeaders = "Accept: */*"
    var httpBody = ""
    var httpEphemeral = true
    var httpWaits = false
    var httpTimeout = 8.0
    // TLS
    var tlsPort = ""
    // macOS shell
    var shellCustom = ""

    @ObservationIgnored private var task: Task<Void, Never>?

    func presetGraphQL() {
        let s = AppSettings.shared.effective
        kind = .http
        target = s.probeURL
        httpMethod = "POST"
        httpHeaders = "Content-Type: application/json"
        httpBody = s.probeBody
    }

    func cancel() { task?.cancel() }
    func clear() { lines.removeAll() }

    private func append(_ s: String) { lines.append(s) }

    func run() {
        guard !running else { return }
        running = true
        let start = lines.count
        let kindName = kind.rawValue
        let tgt = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let emit: Emit = { line in Task { @MainActor in ToolRunner.shared.append(line) } }
        let s = AppSettings.shared.effective
        append("────────  \(kindName)  \(tgt)  [\(Fmt.clock(Date()))]  ────────")

        // Snapshot every option on the main actor, then hop to background tools.
        let types = DNSRecordType.allCases.filter { dnsTypes.contains($0) }
        let compare = dnsCompare
        let (pc, pi, pp, pt, pto) = (pingCount, pingIntervalMs, pingPayload, pingTTL, pingTimeoutMs)
        let (hops, rdns, port, tlsP) = (traceMaxHops, traceReverseDNS, UInt16(clamping: tcpPort), Int(tlsPort))
        var spec = HTTPSpec(url: tgt.contains("://") ? tgt : "https://\(tgt)")
        spec.method = httpMethod
        spec.body = httpBody
        spec.timeout = httpTimeout
        spec.ephemeralNoCache = httpEphemeral
        spec.waitsForConnectivity = httpWaits
        for l in httpHeaders.split(separator: "\n") {
            if let i = l.firstIndex(of: ":") {
                spec.headers[String(l[..<i]).trimmingCharacters(in: .whitespaces)] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let k = kind
        let custom = shellCustom

        task = Task {
            switch k {
            case .dns:
                await DNSTool.lookup(host: tgt, types: types.isEmpty ? [.A] : types, emit: emit)
                if compare { await DNSTool.compare(host: tgt, servers: s.dnsServers, emit: emit) }
            case .ping: await PingTool.run(host: tgt, count: pc, intervalMs: pi, payload: pp, ttl: pt, timeoutMs: pto, emit: emit)
            case .tcp: await TCPTool.connect(host: tgt, port: port, timeout: 6, emit: emit)
            case .http:
                let r = await HTTPTool.run(spec)
                HTTPTool.lines(for: r).forEach(emit)
            case .trace: await PingTool.traceroute(host: tgt, maxHops: hops, probesPerHop: 3, timeoutMs: 1500, reverseDNS: rdns, emit: emit)
            case .tls: await TLSTool.inspect(host: tgt, port: tlsP, emit: emit)
            case .egress: await EgressTool.run(urls: s.egressURLs, emit: emit)
            #if os(macOS)
            case .shell: await Self.runShell(custom: custom, host: NetUtil.host(from: tgt), emit: emit)
            #endif
            }
            await MainActor.run {
                let out = Array(ToolRunner.shared.lines[min(start, ToolRunner.shared.lines.count)...])
                zlog(.tool, .info, "\(kindName) \(tgt) finished", ["output": out.joined(separator: "\n")])
                ToolRunner.shared.running = false
            }
        }
    }

    #if os(macOS)
    func runPreset(_ p: MacShell.Preset) {
        guard !running else { return }
        running = true
        let host = NetUtil.host(from: target)
        let args = p.args.map { $0.replacingOccurrences(of: "{host}", with: host) }
        append("────────  \(p.title.replacingOccurrences(of: "{host}", with: host))  [\(Fmt.clock(Date()))]  ────────")
        let emit: Emit = { line in Task { @MainActor in ToolRunner.shared.append(line) } }
        task = Task {
            await Self.exec(p.path, args, emit: emit)
            await MainActor.run { ToolRunner.shared.running = false }
        }
    }

    @concurrent static func runShell(custom: String, host: String, emit: Emit) async {
        let cmd = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { emit("Pick a preset above, or type a command line here (runs via /bin/zsh -c)."); return }
        await exec("/bin/zsh", ["-c", cmd.replacingOccurrences(of: "{host}", with: host)], emit: emit)
    }

    @concurrent static func exec(_ path: String, _ args: [String], emit: Emit) async {
        emit("$ \(path) \(args.joined(separator: " "))")
        let o = await MacShell.run(path, args)
        if !o.stdout.isEmpty { emit(o.stdout.trimmingCharacters(in: .newlines)) }
        if !o.stderr.isEmpty { emit("[stderr] " + o.stderr.trimmingCharacters(in: .newlines)) }
        emit("exit \(o.status)\(o.timedOut ? " (timed out, killed)" : "")")
    }
    #endif
}
