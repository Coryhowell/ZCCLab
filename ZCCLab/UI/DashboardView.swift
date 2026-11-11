import SwiftUI

struct DashboardView: View {
    private let engine = SignalEngine.shared
    private let settings = AppSettings.shared
    private let scenarios = ScenarioStore.shared
    @State private var snapshotLabel = ""
    @State private var showCapture = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: engine.verdict.kind.symbol)
                            .font(.system(size: 34))
                            .foregroundStyle(engine.verdict.kind.color)
                            .symbolEffect(.pulse, isActive: engine.running)
                        VStack(alignment: .leading) {
                            Text(engine.verdict.title).font(.title2.bold())
                            Text(engine.running ? "Probing… (\(engine.lastTrigger))" : (engine.lastRun.map { "Updated \(Fmt.clock($0)) · \(engine.lastTrigger)" } ?? "Not run yet"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(engine.verdict.reasons, id: \.self) { r in
                        Label(r, systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(.secondary)
                    }
                    if settings.effective.probeIsPlaceholder {
                        Label("Probe URL is a placeholder. Set your GraphQL URL in Settings (or push probeURL via managed config).", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("The verdict is advisory. The raw signals below are the real output.").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Button { Task { await engine.runAll(trigger: "manual") } } label: { Label("Probe", systemImage: "bolt.horizontal").lineLimit(1) }
                        .buttonStyle(.borderedProminent).disabled(engine.running)
                    Button { showCapture = true } label: { Label("Snapshot", systemImage: "camera").lineLimit(1) }
                        .buttonStyle(.bordered)
                    Button { Signals.openZscaler() } label: { Label("Zscaler", systemImage: "arrow.up.forward.app").lineLimit(1) }
                        .buttonStyle(.bordered)
                }
                .labelStyle(.titleOnly)
            }

            Section("Signals") {
                ForEach(SignalCatalog.all) { info in
                    NavigationLink {
                        SignalDetailView(id: info.id)
                    } label: {
                        SignalRow(info: info, result: engine.results[info.id], changed: engine.lastChanged[info.id])
                    }
                }
            }
        }
        .inlineTitle("ZCC Lab")
        .alert("Capture snapshot", isPresented: $showCapture) {
            TextField("Label, e.g. ZCC logged out", text: $snapshotLabel)
            Button("Capture") {
                scenarios.capture(label: snapshotLabel, engine: engine)
                snapshotLabel = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Stores every signal value right now under this label.") }
    }
}

struct SignalRow: View {
    let info: SignalInfo
    let result: SignalResult?
    let changed: Date?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: result?.status.color ?? .gray).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(info.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(info.name).font(.subheadline.weight(.semibold))
                }
                Text(result?.value ?? "not run yet").font(.callout).foregroundStyle(.primary).lineLimit(2)
                if let changed { Text("changed \(Fmt.clock(changed))").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct SignalDetailView: View {
    let id: String
    private let engine = SignalEngine.shared
    var body: some View {
        let info = SignalCatalog.info(id)
        let r = engine.results[id]
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(info?.explanation ?? "").font(.callout)
                Label("Expected: \(info?.expected ?? "")", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                Divider()
                if let r {
                    HStack { StatusDot(color: r.status.color); Text(r.value).font(.headline) }
                    Text("status \(r.status.rawValue) · took \(Fmt.ms(r.durationMs)) · \(Fmt.clock(r.timestamp))").font(.caption).foregroundStyle(.secondary)
                    Text(r.detail).mono(11).frame(maxWidth: .infinity, alignment: .leading)
                    Button { Clipboard.copy("\(id) \(r.name): \(r.value)\n\(r.detail)") } label: { Label("Copy", systemImage: "doc.on.doc") }
                } else {
                    Text("Not run yet.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .inlineTitle("\(id) · \(info?.name ?? "")")
    }
}
