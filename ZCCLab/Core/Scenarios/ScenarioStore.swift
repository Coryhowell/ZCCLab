import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

nonisolated struct Snapshot: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var label: String
    var notes: String
    var trigger: String
    var device: String
    var verdict: String
    var verdictReasons: [String]
    var results: [SignalResult]
    var interfaces: [InterfaceInfo]
}

nonisolated enum DeviceInfo {
    @MainActor static func summary() -> String {
        #if os(iOS)
        return "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        return "Mac, \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.hostName)"
        #endif
    }
}

@Observable
final class ScenarioStore {
    static let shared = ScenarioStore()

    static let checklist: [String] = [
        "ZCC connected",
        "ZCC logged out",
        "ZPA disabled, ZIA enabled",
        "ZIA disabled, ZPA enabled",
        "ZPA re-authentication required",
        "Trusted network (ZCC intentionally off)",
        "Wi-Fi ↔ cellular handoff",
        "Airplane mode",
        "iCloud Private Relay on",
        "iCloud Private Relay off",
        "App in the per-app VPN rule",
        "App NOT in the per-app VPN rule",
    ]

    private(set) var snapshots: [Snapshot] = []
    var checked: Set<String> = [] { didSet { UserDefaults.standard.set(Array(checked), forKey: "ZCCLab.checklist") } }
    var currentLabel = ""
    private var lastAuto = Date.distantPast

    private let dir: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("ZCCLab/Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        checked = Set(UserDefaults.standard.stringArray(forKey: "ZCCLab.checklist") ?? [])
        load()
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        snapshots = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Snapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    func capture(label: String, notes: String = "", trigger: String = "manual", engine: SignalEngine) -> Snapshot {
        let snap = Snapshot(label: label.isEmpty ? "Snapshot" : label, notes: notes, trigger: trigger,
                            device: DeviceInfo.summary(), verdict: engine.verdict.title, verdictReasons: engine.verdict.reasons,
                            results: SignalCatalog.all.compactMap { engine.results[$0.id] }, interfaces: engine.interfaces)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snap) {
            try? data.write(to: dir.appendingPathComponent("\(snap.id.uuidString).json"))
        }
        snapshots.insert(snap, at: 0)
        engine.addMarker(snap.label)
        zlog(.ui, .info, "Snapshot captured: \(snap.label) [\(trigger)] verdict \(snap.verdict)")
        return snap
    }

    /// Throttled auto-capture (verdict change / path change / foreground).
    func autoCapture(trigger: String, engine: SignalEngine) {
        guard Date().timeIntervalSince(lastAuto) > 10 else { return }
        lastAuto = Date()
        capture(label: "auto: \(trigger)", trigger: "auto", engine: engine)
    }

    func delete(_ s: Snapshot) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id.uuidString).json"))
        snapshots.removeAll { $0.id == s.id }
    }

    func deleteAll() { snapshots.forEach { delete($0) } }

    struct DiffRow: Identifiable { var id: String; var name: String; var a: String; var b: String }

    static func diff(_ a: Snapshot, _ b: Snapshot) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.append(.init(id: "verdict", name: "Verdict", a: a.verdict, b: b.verdict))
        for info in SignalCatalog.all {
            let ra = a.results.first { $0.id == info.id }, rb = b.results.first { $0.id == info.id }
            rows.append(.init(id: info.id, name: "\(info.id) \(info.name)", a: ra?.value ?? "-", b: rb?.value ?? "-"))
        }
        let ta = Set(a.interfaces.filter { $0.isTunnel && $0.isUp }.map(\.name)), tb = Set(b.interfaces.filter { $0.isTunnel && $0.isUp }.map(\.name))
        rows.append(.init(id: "tun", name: "Tunnel ifaces up", a: ta.sorted().joined(separator: ","), b: tb.sorted().joined(separator: ",")))
        return rows
    }
}
