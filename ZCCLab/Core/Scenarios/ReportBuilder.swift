import Foundation

/// Markdown report meant to be pasted into a ticket for the Zscaler / MDM teams.
@MainActor
enum ReportBuilder {
    static func markdown() -> String {
        let engine = SignalEngine.shared, logs = LogStore.shared, scenarios = ScenarioStore.shared, settings = AppSettings.shared
        let toolOutput = ToolRunner.shared.lines
        let s = settings.effective
        var m = "# ZCC Lab report\n\n"
        m += "- Generated: \(Fmt.iso(Date()))\n- Device: \(DeviceInfo.summary())\n"
        m += "- Verdict: **\(engine.verdict.title)**\n"
        for r in engine.verdict.reasons { m += "  - \(r)\n" }
        m += "\n## Environment\n\n"
        m += "- Probe URL: `\(s.probeURL)`\(s.probeIsPlaceholder ? " (PLACEHOLDER)" : "")\n"
        m += "- Hosts: \(s.hosts.joined(separator: ", "))\n- Synthetic range: \(s.syntheticRange)\n"
        m += "- Managed keys active: \(settings.managedKeys.isEmpty ? "none" : settings.managedKeys.sorted().joined(separator: ", "))\n"
        if let p = engine.pathInfo { m += "- Path: \(p.summary)\n" }
        m += "- Tunnel-like interfaces up: \(engine.interfaces.filter { $0.isTunnel && $0.isUp }.map(\.name).joined(separator: ", ").nilIfEmpty ?? "none")\n"
        m += "\n## Signals\n\n| ID | Signal | Status | Value | Changed |\n|---|---|---|---|---|\n"
        for info in SignalCatalog.all {
            guard let r = engine.results[info.id] else { continue }
            let ch = engine.lastChanged[info.id].map(Fmt.clock) ?? "-"
            m += "| \(info.id) | \(info.name) | \(r.status.rawValue) | \(r.value.replacingOccurrences(of: "|", with: "/")) | \(ch) |\n"
        }
        m += "\n## Signal detail\n"
        for info in SignalCatalog.all {
            guard let r = engine.results[info.id] else { continue }
            m += "\n### \(info.id) \(info.name)\n\n```\n\(r.detail)\n```\n"
        }
        if !scenarios.snapshots.isEmpty {
            m += "\n## Snapshots\n\n"
            for sn in scenarios.snapshots.prefix(25) { m += "- \(Fmt.clock(sn.date)) **\(sn.label)** → \(sn.verdict)\(sn.notes.isEmpty ? "" : " (\(sn.notes))")\n" }
        }
        if !toolOutput.isEmpty { m += "\n## Last tool output\n\n```\n\(toolOutput.suffix(200).joined(separator: "\n"))\n```\n" }
        m += "\n## Recent log (last 100)\n\n```\n"
        for e in logs.entries.suffix(100) { m += "\(Fmt.clock(e.ts)) [\(e.level.rawValue)] \(e.category.rawValue): \(e.message)\n" }
        m += "```\n"
        return m
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
