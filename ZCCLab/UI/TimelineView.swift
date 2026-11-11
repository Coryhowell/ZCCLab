import SwiftUI
import Charts

struct TimelineView: View {
    private let engine = SignalEngine.shared
    @State private var markerText = ""

    private let statusColors: [(String, Color)] = SignalStatus.allCases.map { ($0.rawValue, $0.color) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    TextField("Marker, e.g. turned ZCC off", text: $markerText)
                    Button("Add marker") {
                        engine.addMarker(markerText.isEmpty ? "marker" : markerText)
                        zlog(.ui, .info, "Timeline marker: \(markerText)")
                        markerText = ""
                    }
                    .buttonStyle(.bordered)
                }

                Text("Probe latency").font(.headline)
                Chart {
                    ForEach(engine.latency.filter { $0.ms != nil }) { p in
                        LineMark(x: .value("Time", p.date), y: .value("ms", p.ms ?? 0)).foregroundStyle(.green)
                        PointMark(x: .value("Time", p.date), y: .value("ms", p.ms ?? 0)).foregroundStyle(.green)
                    }
                    ForEach(engine.latency.filter { $0.ms == nil }) { p in
                        PointMark(x: .value("Time", p.date), y: .value("ms", 0)).foregroundStyle(.red).symbol(.cross)
                    }
                    ForEach(engine.markers) { m in
                        RuleMark(x: .value("Marker", m.date)).foregroundStyle(.purple.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .top, alignment: .leading) { Text(m.label).font(.system(size: 9)).foregroundStyle(.purple) }
                    }
                }
                .frame(height: 200)
                Text("Red crosses are failed probes. Purple lines are your markers and snapshots.").font(.caption).foregroundStyle(.secondary)

                Text("Signal status over time (which signal reacted first?)").font(.headline)
                Chart {
                    ForEach(engine.history) { h in
                        PointMark(x: .value("Time", h.date), y: .value("Signal", h.signal))
                            .foregroundStyle(by: .value("Status", h.status.rawValue))
                    }
                    ForEach(engine.markers) { m in
                        RuleMark(x: .value("Marker", m.date)).foregroundStyle(.purple.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
                .chartForegroundStyleScale(domain: statusColors.map(\.0), range: statusColors.map(\.1))
                .chartYScale(domain: SignalCatalog.all.map(\.id))
                .frame(height: 320)

                HStack {
                    Text("\(engine.history.count / max(1, SignalCatalog.all.count)) runs recorded").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", role: .destructive) { engine.clearHistory() }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .inlineTitle("Timeline")
    }
}
