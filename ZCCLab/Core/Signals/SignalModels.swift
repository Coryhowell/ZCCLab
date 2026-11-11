import Foundation
import Network

nonisolated enum SignalStatus: String, Codable, Sendable, CaseIterable {
    case ok, warn, bad, info, unavailable
}

nonisolated struct SignalResult: Identifiable, Codable, Sendable, Equatable {
    var id: String            // "A" … "M"
    var name: String
    var status: SignalStatus
    var value: String        // short, shown in the table
    var detail: String       // full raw detail
    var durationMs: Double
    var timestamp = Date()
}

nonisolated struct SignalInfo: Identifiable, Sendable {
    var id: String
    var name: String
    var explanation: String
    var expected: String
}

nonisolated enum SignalCatalog {
    static let all: [SignalInfo] = [
        .init(id: "A", name: "NEVPNManager status", explanation: "loadFromPreferences, then connection.status.",
              expected: "Stays .invalid for ZCC's VPN: this app doesn't own it. Included to demonstrate the limitation."),
        .init(id: "B", name: "NEVPNStatusDidChange events", explanation: "Counts every NEVPNStatusDidChange notification received.",
              expected: "Never fires for ZCC. Expect 0 events while you toggle ZCC."),
        .init(id: "C", name: "Proxy __SCOPED__ keys", explanation: "CFNetworkCopySystemProxySettings()[\"__SCOPED__\"]: undocumented per-interface proxy keys.",
              expected: "Weak evidence. utun/ipsec/ppp keys may appear with ZCC on, but iOS makes its own utun interfaces too."),
        .init(id: "D", name: "getifaddrs interfaces", explanation: "All network interfaces with flags and addresses; tunnel-like ones highlighted.",
              expected: "Same caveats as C. Shows whether ZCC's interface stays up while logged out."),
        .init(id: "E", name: "NWPathMonitor", explanation: "Latest NWPath: status, interface types, expensive/constrained, DNS/IPv4/IPv6 support.",
              expected: "A trigger only. Check the Logs tab to see whether it fires when ZCC changes state."),
        .init(id: "F", name: "GraphQL probe", explanation: "Short-timeout request to your GraphQL host, classified by URLError code or HTTP status.",
              expected: "PRIMARY signal. Any HTTP response (even 401/403) means reachable."),
        .init(id: "G", name: "ZPA synthetic IP", explanation: "getaddrinfo for each host; flags answers inside the synthetic range (default 100.64.0.0/10).",
              expected: "Only meaningful if the host is a ZPA application segment."),
        .init(id: "H", name: "ip.zscaler.com check", explanation: "GETs the Zscaler check page and looks for a marker string.",
              expected: "ZIA only. Verify the marker string on a real device. The page is for humans, not an API."),
        .init(id: "I", name: "zsa:// scheme", explanation: "canOpenURL for zsa:// (needs LSApplicationQueriesSchemes).",
              expected: "UX nicety: lets you add an Open Zscaler button. Doesn't return status."),
        .init(id: "J", name: "Managed app config", explanation: "Reads com.apple.configuration.managed pushed by your MDM.",
              expected: "Empty unless the MDM pushes config for this bundle ID."),
        .init(id: "K", name: "Managed feedback write", explanation: "Writes the last verdict to com.apple.feedback.managed.",
              expected: "Ask the MDM team whether they can read it back."),
        .init(id: "L", name: "ZSDK status", explanation: "Would show ZSDK tunnelConnectionState if the SDK were added (off by default).",
              expected: "Reports ZSDK's own tunnel, not ZCC. Not included in this build."),
        .init(id: "M", name: "macOS system checks", explanation: "Zscaler processes via NSWorkspace, plus scutil --nc list.",
              expected: "Mac only. Ground truth to compare against the sandbox-safe signals."),
    ]
    static func info(_ id: String) -> SignalInfo? { all.first { $0.id == id } }
}

// MARK: - Path

nonisolated struct PathInfo: Sendable, Codable, Equatable {
    var status: String
    var satisfied: Bool
    var interfaces: [String]
    var expensive: Bool
    var constrained: Bool
    var supportsDNS: Bool
    var supportsIPv4: Bool
    var supportsIPv6: Bool
    var unsatisfiedReason: String?
    var gateways: [String]
    var at = Date()

    init(_ p: NWPath) {
        satisfied = p.status == .satisfied
        status = "\(p.status)"
        interfaces = p.availableInterfaces.map { "\($0.name) (\($0.type))" }
        expensive = p.isExpensive
        constrained = p.isConstrained
        supportsDNS = p.supportsDNS
        supportsIPv4 = p.supportsIPv4
        supportsIPv6 = p.supportsIPv6
        unsatisfiedReason = p.status == .satisfied ? nil : "\(p.unsatisfiedReason)"
        gateways = p.gateways.map { "\($0)" }
    }

    var summary: String { "\(status): \(interfaces.joined(separator: ", "))" }
    var detail: String {
        """
        status: \(status)\(unsatisfiedReason.map { " (\($0))" } ?? "")
        interfaces: \(interfaces.isEmpty ? "none" : interfaces.joined(separator: ", "))
        expensive: \(expensive)  constrained: \(constrained)
        supportsDNS: \(supportsDNS)  IPv4: \(supportsIPv4)  IPv6: \(supportsIPv6)
        gateways: \(gateways.isEmpty ? "-" : gateways.joined(separator: ", "))
        updated: \(Fmt.clock(at))
        """
    }
}

// MARK: - Probe

nonisolated enum ProbeKind: String, Codable, Sendable {
    case reachable, dns, route, offline, tls, other, notConfigured, skipped
}

nonisolated struct ProbeOutcome: Codable, Sendable {
    var kind: ProbeKind
    var url: String
    var statusCode: Int?
    var errorName: String?
    var errorCode: Int?
    var ms: Double
    var attempts: Int
    var detail: String
    var timestamp = Date()
}

nonisolated enum ProbeService {
    static func classify(code: Int?) -> ProbeKind {
        guard let code else { return .other }
        switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: return .offline
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .timedOut, .cannotConnectToHost, .networkConnectionLost: return .route
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection: return .tls
        default: return .other
        }
    }

    @concurrent static func run(_ s: SettingsValues, pathSatisfied: Bool) async -> ProbeOutcome {
        if s.probeIsPlaceholder {
            return ProbeOutcome(kind: .notConfigured, url: s.probeURL, ms: 0, attempts: 0,
                                detail: "Probe URL is still a placeholder (\(s.probeURL)). Set the real GraphQL URL in Settings or via managed config.")
        }
        if !pathSatisfied {
            return ProbeOutcome(kind: .offline, url: s.probeURL, ms: 0, attempts: 0, detail: "NWPath is unsatisfied; probe skipped.")
        }
        var spec = HTTPSpec(url: s.probeURL)
        spec.method = s.probeUsesPOST ? "POST" : "GET"
        if s.probeUsesPOST {
            spec.headers = ["Content-Type": "application/json"]
            spec.body = s.probeBody
        }
        spec.timeout = s.timeoutSeconds
        var attempts = 1
        var r = await HTTPTool.run(spec)
        var kind: ProbeKind = r.gotHTTPResponse ? .reachable : classify(code: r.errorCode)
        if !r.gotHTTPResponse, s.retryOnce, kind == .dns || kind == .route {
            // ZCC can need a few seconds to rebuild its tunnel after a network change.
            try? await Task.sleep(for: .seconds(2))
            attempts = 2
            r = await HTTPTool.run(spec)
            kind = r.gotHTTPResponse ? .reachable : classify(code: r.errorCode)
        }
        let detail = HTTPTool.lines(for: r).joined(separator: "\n")
        return ProbeOutcome(kind: kind, url: s.probeURL, statusCode: r.statusCode, errorName: r.errorName,
                            errorCode: r.errorCode, ms: r.totalMs, attempts: attempts, detail: detail)
    }
}

// MARK: - Verdict

nonisolated enum VerdictKind: String, Codable, Sendable {
    case checking, connected, notConnectedDNS, notConnectedRoute, tlsProblem, offline, unknown
}

nonisolated struct Verdict: Codable, Sendable, Equatable {
    var kind: VerdictKind
    var reasons: [String]

    static let initial = Verdict(kind: .checking, reasons: ["Waiting for first run"])

    var title: String {
        switch kind {
        case .checking: "Checking…"
        case .connected: "Connected"
        case .notConnectedDNS: "Not connected (DNS)"
        case .notConnectedRoute: "Not connected (route)"
        case .tlsProblem: "Reachable, TLS problem"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }

    static func compute(path: PathInfo?, probe: ProbeOutcome?, syntheticSeen: Bool, tunnelInterfaces: [String]) -> Verdict {
        if let path, !path.satisfied { return Verdict(kind: .offline, reasons: ["NWPath is \(path.status): the device has no usable network"]) }
        guard let p = probe else { return .initial }
        var reasons: [String] = []
        let tunnelNote = tunnelInterfaces.isEmpty ? "no tunnel-like interface up" : "tunnel-like interface(s) up: \(tunnelInterfaces.joined(separator: ", "))"
        switch p.kind {
        case .reachable:
            reasons.append("Probe got HTTP \(p.statusCode ?? 0) in \(Fmt.ms(p.ms)): host is reachable")
            return Verdict(kind: .connected, reasons: reasons)
        case .dns:
            reasons.append("Probe failed with DNS error \(p.errorName ?? "") after \(p.attempts) attempt(s)")
            reasons.append(syntheticSeen ? "A ZPA synthetic IP was seen for a host: ZCC is answering DNS, so check the backend / ZPA policy"
                                         : "No ZPA synthetic IP seen: Zscaler appears to be off")
            reasons.append(tunnelNote)
            return Verdict(kind: .notConnectedDNS, reasons: reasons)
        case .route:
            reasons.append("Probe failed with \(p.errorName ?? "route error") after \(p.attempts) attempt(s)")
            if syntheticSeen { reasons.append("DNS is intercepted (synthetic IP) but the path failed: backend or ZPA policy issue") }
            reasons.append(tunnelNote)
            return Verdict(kind: .notConnectedRoute, reasons: reasons)
        case .tls:
            reasons.append("Host answered but TLS failed: \(p.errorName ?? ""). Possible ZIA SSL inspection with a CA this device doesn't trust")
            return Verdict(kind: .tlsProblem, reasons: reasons)
        case .offline:
            return Verdict(kind: .offline, reasons: ["Probe reports the device is offline (\(p.errorName ?? "no network"))"])
        case .notConfigured, .skipped:
            return Verdict(kind: .unknown, reasons: [p.detail])
        case .other:
            return Verdict(kind: .unknown, reasons: ["Unclassified probe error \(p.errorName ?? "") (\(p.errorCode.map(String.init) ?? "-"))"])
        }
    }
}
