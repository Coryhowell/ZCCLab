import SwiftUI

struct ScenariosView: View {
    private let store = ScenarioStore.shared
    private let engine = SignalEngine.shared
    @Bindable private var settings = AppSettings.shared
    @State private var notes = ""
    @State private var diffA: UUID?
    @State private var diffB: UUID?

    var body: some View {
        List {
            Section("Test matrix: tap a state, set it up on the device, then capture") {
                ForEach(ScenarioStore.checklist, id: \.self) { item in
                    HStack {
                        Button {
                            if store.checked.contains(item) { store.checked.remove(item) } else { store.checked.insert(item) }
                        } label: {
                            Image(systemName: store.checked.contains(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.checked.contains(item) ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        Text(item)
                        Spacer()
                        Button("Capture") {
                            Task {
                                await engine.runAll(trigger: "scenario: \(item)")
                                store.capture(label: item, notes: notes, trigger: "checklist", engine: engine)
                                store.checked.insert(item)
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                TextField("Notes to attach to the next capture (ZCC state, user, location…)", text: $notes)
                Toggle("Auto-capture on verdict / path / foreground change", isOn: $settings.values.autoCapture)
            }

            Section("Compare two snapshots") {
                Picker("A", selection: $diffA) { Text("—").tag(UUID?.none); ForEach(store.snapshots) { Text(title($0)).tag(UUID?.some($0.id)) } }
                Picker("B", selection: $diffB) { Text("—").tag(UUID?.none); ForEach(store.snapshots) { Text(title($0)).tag(UUID?.some($0.id)) } }
                if let a = store.snapshots.first(where: { $0.id == diffA }), let b = store.snapshots.first(where: { $0.id == diffB }) {
                    ForEach(ScenarioStore.diff(a, b)) { row in
                        let changed = row.a != row.b
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(row.name).font(.subheadline.weight(changed ? .bold : .regular)); if changed { Image(systemName: "arrow.left.arrow.right").foregroundStyle(.orange) } }
                            Text("A: \(row.a)").mono(11).foregroundStyle(changed ? .primary : .secondary)
                            Text("B: \(row.b)").mono(11).foregroundStyle(changed ? .primary : .secondary)
                        }
                    }
                    Text("Rows in bold changed between the two states: those are the signals that track ZCC.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Snapshots (\(store.snapshots.count))") {
                if store.snapshots.isEmpty { Text("None yet. Capture one from the Dashboard or the checklist above.").foregroundStyle(.secondary) }
                ForEach(store.snapshots) { s in
                    NavigationLink { SnapshotDetail(snapshot: s) } label: {
                        VStack(alignment: .leading) {
                            Text(s.label).font(.headline)
                            Text("\(Fmt.clock(s.date)) · \(s.verdict) · \(s.trigger)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.snapshots[$0] }.forEach(store.delete) }
            }
        }
        .inlineTitle("Scenarios")
        .toolbar {
            ToolbarItem { ShareLink(item: ReportBuilder.markdown(), subject: Text("ZCC Lab report")) { Label("Export report", systemImage: "square.and.arrow.up") } }
        }
    }

    private func title(_ s: Snapshot) -> String { "\(s.label) · \(Fmt.clock(s.date))" }
}

struct SnapshotDetail: View {
    let snapshot: Snapshot
    var body: some View {
        List {
            Section {
                Text(snapshot.device).mono()
                Text("Verdict: \(snapshot.verdict)").font(.headline)
                ForEach(snapshot.verdictReasons, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                if !snapshot.notes.isEmpty { Text("Notes: \(snapshot.notes)") }
            }
            Section("Signals") {
                ForEach(snapshot.results) { r in
                    VStack(alignment: .leading) {
                        HStack { StatusDot(color: r.status.color); Text("\(r.id) \(r.name)").font(.subheadline.weight(.semibold)) }
                        Text(r.value).mono(11)
                    }
                }
            }
            Section("Tunnel-like interfaces up") {
                let t = snapshot.interfaces.filter { $0.isTunnel && $0.isUp }
                if t.isEmpty { Text("none").foregroundStyle(.secondary) }
                ForEach(t) { Text("\($0.name): \($0.addresses.joined(separator: ", "))").mono(11) }
            }
        }
        .inlineTitle(snapshot.label)
    }
}
