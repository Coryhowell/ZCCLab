import Foundation
import NetworkExtension
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One function per signal (A–M). Each returns a SignalResult with the raw detail.
enum Signals {
    nonisolated private static func make(_ id: String, _ status: SignalStatus, _ value: String, _ detail: String, _ t0: UInt64) -> SignalResult {
        SignalResult(id: id, name: SignalCatalog.info(id)?.name ?? id, status: status, value: value, detail: detail, durationMs: Clock.ms(since: t0))
    }

    // A
    static func nevpn() async -> SignalResult {
        let t0 = Clock.now()
        let mgr = NEVPNManager.shared()
        do { try await mgr.loadFromPreferences() } catch {
            return make("A", .info, "load error", "loadFromPreferences failed: \(error.localizedDescription)\nThis app owns no VPN configuration, so this is expected.", t0)
        }
        let s = mgr.connection.status
        let name: String
        switch s {
        case .invalid: name = "invalid"
        case .disconnected: name = "disconnected"
        case .connecting: name = "connecting"
        case .connected: name = "connected"
        case .reasserting: name = "reasserting"
        case .disconnecting: name = "disconnecting"
        @unknown default: name = "unknown(\(s.rawValue))"
        }
        return make("A", .info, name, "NEVPNManager.shared().connection.status = \(name)\nprotocol configured: \(mgr.protocolConfiguration != nil)\nOnly reflects VPN configurations THIS app owns. It cannot see ZCC.", t0)
    }

    // C
    static func scoped() async -> SignalResult {
        let t0 = Clock.now()
        let raw = NetUtil.proxySettings()
        let scoped = raw["__SCOPED__"] as? [String: Any] ?? [:]
        let keys = scoped.keys.sorted()
        let tunnels = keys.filter(NetUtil.isTunnelName)
        var d = "__SCOPED__ keys: \(keys.isEmpty ? "(none)" : keys.joined(separator: ", "))\n"
        d += "tunnel-like keys: \(tunnels.isEmpty ? "(none)" : tunnels.joined(separator: ", "))\n"
        d += "Undocumented API. iOS also creates utun interfaces for Private Relay, Handoff, etc.: weak evidence only.\n\nFull proxy settings:\n"
        d += raw.keys.sorted().map { "  \($0) = \(String(describing: raw[$0]!))" }.joined(separator: "\n")
        return make("C", .info, tunnels.isEmpty ? "no tunnel keys" : tunnels.joined(separator: ","), d, t0)
    }

    // D
    @concurrent static func interfaces() async -> (SignalResult, [InterfaceInfo]) {
        let t0 = Clock.now()
        let ifs = NetUtil.interfaces()
        let tunnelsUp = ifs.filter { $0.isTunnel && $0.isUp }
        var d = ""
        for i in ifs {
            d += "\(i.isTunnel ? "★ " : "  ")\(i.name)  [\(i.flags.joined(separator: " "))]\n"
            for a in i.addresses { d += "      \(a)\n" }
        }
        let value = tunnelsUp.isEmpty ? "no tunnel up (\(ifs.count) ifs)" : "\(tunnelsUp.count) tunnel up: " + tunnelsUp.map(\.name).joined(separator: ",")
        return (make("D", .info, value, d, t0), ifs)
    }

    // G: also covers the probe host
    @concurrent static func synthetic(hosts: [String], range: String) async -> (SignalResult, Bool) {
        let t0 = Clock.now()
        var d = "Range: \(range)\n"
        var any = 0
        for h in hosts {
            let r = NetUtil.resolve(h)
            if let e = r.error { d += "  \(h) → error: \(e)\n"; continue }
            let hit = r.addrs.filter { $0.family == "IPv4" && NetUtil.inRange($0.ip, cidr: range) }
            if !hit.isEmpty { any += 1 }
            d += "  \(h) → \(r.addrs.map(\.ip).joined(separator: ", "))\(hit.isEmpty ? "" : "   ⚑ SYNTHETIC")\n"
        }
        let status: SignalStatus = any > 0 ? .ok : .info
        return (make("G", status, any > 0 ? "\(any)/\(hosts.count) synthetic" : "none synthetic", d, t0), any > 0)
    }

    // H
    @concurrent static func zscalerPage(_ s: SettingsValues) async -> SignalResult {
        let t0 = Clock.now()
        guard s.enableZscalerPageCheck else { return make("H", .unavailable, "disabled", "Disabled in settings / managed config.", t0) }
        var spec = HTTPSpec(url: s.zscalerPageURL)
        spec.timeout = s.timeoutSeconds + 2
        let r = await HTTPTool.run(spec)
        guard let code = r.statusCode else {
            return make("H", .warn, "request failed", "\(r.errorName ?? "?"): \(r.errorText ?? "")", t0)
        }
        let text = EgressTool.stripHTML(r.bodyPreview)
        let found = text.range(of: s.zscalerMarker, options: .caseInsensitive) != nil
        let d = "GET \(s.zscalerPageURL) → HTTP \(code) from \(r.metrics?.remoteIP ?? "?")\nmarker \"\(s.zscalerMarker)\": \(found ? "FOUND" : "absent")\n\nPage text (first 800 chars):\n\(text.prefix(800))"
        return make("H", found ? .ok : .warn, found ? "marker found" : "marker absent", d, t0)
    }

    // I
    static func scheme() async -> SignalResult {
        let t0 = Clock.now()
        guard let url = URL(string: Defaults.zscalerScheme) else { return make("I", .unavailable, "bad url", "", t0) }
        #if os(iOS)
        let can = UIApplication.shared.canOpenURL(url)
        #else
        let can = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #endif
        return make("I", .info, can ? "zsa:// openable" : "zsa:// not openable",
                    "canOpenURL(\(url)) = \(can)\nOn iOS this needs LSApplicationQueriesSchemes to contain \"zsa\" (set in Info.plist). A false result usually means ZCC isn't installed.", t0)
    }

    static func openZscaler() {
        guard let url = URL(string: Defaults.zscalerScheme) else { return }
        #if os(iOS)
        UIApplication.shared.open(url) { ok in zlog(.ui, ok ? .info : .warn, "Open zsa:// \(ok ? "succeeded" : "failed")") }
        #else
        let ok = NSWorkspace.shared.open(url)
        zlog(.ui, ok ? .info : .warn, "Open zsa:// \(ok ? "succeeded" : "failed")")
        #endif
    }

    // J
    static func managed() async -> SignalResult {
        let t0 = Clock.now()
        let m = ManagedConfig.read()
        let keys = AppSettings.shared.managedKeys
        let d = ManagedConfig.describe(m) + "\n\nKeys currently overriding settings: " + (keys.isEmpty ? "(none)" : keys.sorted().joined(separator: ", "))
        return make("J", m.isEmpty ? .info : .ok, m.isEmpty ? "empty" : "\(m.count) key(s)", d, t0)
    }

    // K
    static func feedback(verdict: Verdict, probe: ProbeOutcome?) async -> SignalResult {
        let t0 = Clock.now()
        var fb: [String: Any] = ["lastVerdict": verdict.kind.rawValue, "lastVerdictAt": Fmt.iso(Date())]
        if let p = probe { fb["lastProbeKind"] = p.kind.rawValue; fb["lastProbeMs"] = Int(p.ms) }
        UserDefaults.standard.set(fb, forKey: ManagedConfig.feedbackKey)
        let d = "Wrote to UserDefaults key \(ManagedConfig.feedbackKey):\n" + fb.keys.sorted().map { "  \($0) = \(fb[$0]!)" }.joined(separator: "\n")
            + "\n\nAsk the MDM team whether they can read this back per device."
        return make("K", .info, "written: \(verdict.kind.rawValue)", d, t0)
    }

    // L
    static func zsdk() async -> SignalResult {
        make("L", .unavailable, "not included", "ZSDK is not part of this build. It would report its own in-app tunnel state (ZscalerSDK status().tunnelConnectionState), never ZCC's.", Clock.now())
    }

    // M
    static func macSystem() async -> SignalResult {
        let t0 = Clock.now()
        #if os(macOS)
        let apps = MacShell.zscalerApps()
        let nc = await MacShell.run("/usr/sbin/scutil", ["--nc", "list"])
        let lines = nc.stdout.split(separator: "\n").map(String.init)
        let z = lines.filter { $0.lowercased().contains("zscaler") }
        let connected = z.contains { $0.contains("(Connected)") }
        var d = "Zscaler processes:\n" + (apps.isEmpty ? "  (none running)\n" : apps.map { "  \($0)" }.joined(separator: "\n") + "\n")
        d += "\nscutil --nc list:\n" + (nc.stdout.isEmpty ? "  (empty) \(nc.stderr)" : nc.stdout)
        let value = "ZCC proc: \(apps.isEmpty ? "no" : "yes"); NC: " + (z.isEmpty ? "no zscaler entry" : connected ? "connected" : "not connected")
        return make("M", (!apps.isEmpty && connected) ? .ok : .info, value, d, t0)
        #else
        return make("M", .unavailable, "macOS only", "System checks need Process/NSWorkspace and are only available on the Mac build.", t0)
        #endif
    }
}
