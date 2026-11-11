import Foundation
import Network
import NetworkExtension
import Observation
import SwiftUI

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let signal: String
    let status: SignalStatus
}

struct LatencyPoint: Identifiable {
    let id = UUID()
    let date: Date
    let ms: Double?       // nil = failed
    let kind: ProbeKind
}

struct TimelineMarker: Identifiable {
    let id = UUID()
    let date: Date
    let label: String
}

@Observable
final class SignalEngine {
    static let shared = SignalEngine()

    private(set) var results: [String: SignalResult] = [:]
    private(set) var lastChanged: [String: Date] = [:]
    private(set) var verdict = Verdict.initial
    private(set) var probe: ProbeOutcome?
    private(set) var pathInfo: PathInfo?
    private(set) var interfaces: [InterfaceInfo] = []
    private(set) var history: [HistoryPoint] = []
    private(set) var latency: [LatencyPoint] = []
    private(set) var markers: [TimelineMarker] = []
    private(set) var vpnEvents = 0
    private(set) var pathEvents = 0
    private(set) var running = false
    private(set) var lastRun: Date?
    private(set) var lastTrigger = ""

    @ObservationIgnored private var started = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested: String?
    @ObservationIgnored private var inForeground = true

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        zlog(.ui, .info, "ZCC Lab started")

        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let info = PathInfo(path)
            Task { @MainActor in self?.handlePath(info) }
        }
        m.start(queue: DispatchQueue(label: "zcclab.path"))
        monitor = m

        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            let s = (note.object as? NEVPNConnection).map { "\($0.status.rawValue)" } ?? "?"
            Task { @MainActor in
                self?.vpnEvents += 1
                zlog(.signal, .warn, "NEVPNStatusDidChange received (status \(s))")
            }
        }
        startPolling()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            inForeground = true
            zlog(.ui, .info, "App became active")
            Task { await runAll(trigger: "foreground") }
            startPolling()
        case .background:
            inForeground = false
            zlog(.ui, .info, "App entered background")
            pollTask?.cancel()
        default: break
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = AppSettings.shared.effective
                try? await Task.sleep(for: .seconds(max(5, s.probeIntervalSeconds)))
                if Task.isCancelled { return }
                if s.autoProbe, inForeground { await runAll(trigger: "timer") }
            }
        }
    }

    private func handlePath(_ info: PathInfo) {
        let changed = pathInfo != nil
        pathInfo = info
        pathEvents += 1
        zlog(.path, .info, "NWPath update: \(info.summary)", ["detail": info.detail])
        guard changed else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            // Give ZCC a moment to rebuild its tunnel after a network change.
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            await self?.runAll(trigger: "path-change")
        }
    }

    func addMarker(_ label: String) { markers.append(TimelineMarker(date: Date(), label: label)) }
    func clearHistory() { history.removeAll(); latency.removeAll(); markers.removeAll() }

    // MARK: Run

    func runAll(trigger: String) async {
        if running { rerunRequested = trigger; return }
        running = true
        lastTrigger = trigger
        defer { running = false }
        let started = Clock.now()
        let s = AppSettings.shared.effective
        let path = pathInfo
        zlog(.signal, .debug, "Run all signals (trigger: \(trigger))")

        let hosts: [String] = (!s.probeIsPlaceholder && !s.hosts.contains(s.probeHost)) ? [s.probeHost] + s.hosts : s.hosts

        async let a = Signals.nevpn()
        async let c = Signals.scoped()
        async let d = Signals.interfaces()
        async let f = ProbeService.run(s, pathSatisfied: path?.satisfied ?? true)
        async let g = Signals.synthetic(hosts: hosts, range: s.syntheticRange)
        async let h = Signals.zscalerPage(s)
        async let i = Signals.scheme()
        async let j = Signals.managed()
        async let l = Signals.zsdk()
        async let m = Signals.macSystem()

        let (dResult, ifs) = await d
        let (gResult, synthetic) = await g
        let outcome = await f
        interfaces = ifs
        probe = outcome

        let t0 = Clock.now()
        let probeResult = SignalResult(
            id: "F", name: SignalCatalog.info("F")!.name,
            status: outcome.kind == .reachable ? .ok : (outcome.kind == .notConfigured || outcome.kind == .skipped) ? .unavailable : .bad,
            value: outcome.kind == .reachable ? "reachable (HTTP \(outcome.statusCode ?? 0), \(Fmt.ms(outcome.ms)))"
                : outcome.kind == .notConfigured ? "placeholder URL" : "\(outcome.kind.rawValue): \(outcome.errorName ?? "-")",
            detail: outcome.detail, durationMs: outcome.ms)

        let tunnels = ifs.filter { $0.isTunnel && $0.isUp }.map(\.name)
        let newVerdict = Verdict.compute(path: path, probe: outcome, syntheticSeen: synthetic, tunnelInterfaces: tunnels)
        let kResult = await Signals.feedback(verdict: newVerdict, probe: outcome)

        let bResult = SignalResult(id: "B", name: SignalCatalog.info("B")!.name, status: .info,
                                   value: "\(vpnEvents) event(s)",
                                   detail: "NEVPNStatusDidChange notifications received since launch: \(vpnEvents).\nExpected to stay at 0 when ZCC changes state.",
                                   durationMs: 0)
        let eResult = SignalResult(id: "E", name: SignalCatalog.info("E")!.name,
                                   status: path == nil ? .unavailable : (path!.satisfied ? .ok : .bad),
                                   value: path.map { "\($0.status) (\($0.interfaces.count) if) · \(pathEvents) updates" } ?? "no path yet",
                                   detail: (path?.detail ?? "no NWPath update received yet") + "\n\npath updates since launch: \(pathEvents)",
                                   durationMs: 0)

        let all: [SignalResult] = [await a, bResult, await c, dResult, eResult, probeResult, gResult, await h, await i, await j, kResult, await l, await m]
        _ = t0
        apply(all, newVerdict: newVerdict, outcome: outcome, trigger: trigger)
        lastRun = Date()
        zlog(.signal, .info, "Run complete [\(trigger)] verdict: \(newVerdict.title) in \(Fmt.ms(Clock.ms(since: started)))")

        if let again = rerunRequested {
            rerunRequested = nil
            Task { await runAll(trigger: again) }
        }
    }

    private func apply(_ all: [SignalResult], newVerdict: Verdict, outcome: ProbeOutcome, trigger: String) {
        let now = Date()
        for r in all {
            let old = results[r.id]
            if old == nil || old!.value != r.value || old!.status != r.status {
                lastChanged[r.id] = now
                if old != nil {
                    zlog(.signal, .info, "Signal \(r.id) changed: \"\(old!.value)\" → \"\(r.value)\"", ["detail": r.detail])
                }
            }
            results[r.id] = r
            history.append(HistoryPoint(date: now, signal: r.id, status: r.status))
        }
        latency.append(LatencyPoint(date: now, ms: outcome.kind == .reachable ? outcome.ms : nil, kind: outcome.kind))
        if history.count > 4000 { history.removeFirst(history.count - 4000) }
        if latency.count > 1000 { latency.removeFirst(latency.count - 1000) }

        let verdictChanged = newVerdict.kind != verdict.kind
        if verdictChanged { zlog(.signal, .warn, "VERDICT changed: \(verdict.title) → \(newVerdict.title)", ["reasons": newVerdict.reasons.joined(separator: " | ")]) }
        verdict = newVerdict
        if AppSettings.shared.effective.autoCapture, verdictChanged || trigger == "path-change" || trigger == "foreground" {
            ScenarioStore.shared.autoCapture(trigger: verdictChanged ? "verdict → \(newVerdict.title)" : trigger, engine: self)
        }
    }
}

extension VerdictKind {
    var color: Color {
        switch self {
        case .connected: .green
        case .notConnectedDNS, .notConnectedRoute: .red
        case .tlsProblem: .orange
        case .offline: .gray
        case .unknown, .checking: .blue
        }
    }
    var symbol: String {
        switch self {
        case .connected: "checkmark.shield.fill"
        case .notConnectedDNS, .notConnectedRoute: "xmark.shield.fill"
        case .tlsProblem: "exclamationmark.shield.fill"
        case .offline: "wifi.slash"
        case .unknown: "questionmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath"
        }
    }
}

extension SignalStatus {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .info: .blue
        case .unavailable: .gray
        }
    }
}
