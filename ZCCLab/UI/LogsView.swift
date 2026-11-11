import SwiftUI

struct LogsView: View {
    private let store = LogStore.shared
    @State private var minLevel: LogLevel = .debug
    @State private var categories = Set(LogCategory.allCases)
    @State private var search = ""
    @State private var paused = false
    @State private var frozen: [LogEntry] = []
    @State private var expanded: Set<UUID> = []

    private var source: [LogEntry] { paused ? frozen : store.entries }
    private var filtered: [LogEntry] {
        source.filter { e in
            e.level >= minLevel && categories.contains(e.category)
                && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search)
                    || (e.payload?.values.contains { $0.localizedCaseInsensitiveContains(search) } ?? false))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Level", selection: $minLevel) { ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue) } }.fixedSize()
                Menu("Categories (\(categories.count))") {
                    ForEach(LogCategory.allCases, id: \.self) { c in
                        Toggle(c.rawValue, isOn: Binding(get: { categories.contains(c) }, set: { if $0 { categories.insert(c) } else { categories.remove(c) } }))
                    }
                }
                .fixedSize()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            }
            .padding(8)

            ScrollViewReader { proxy in
                List(filtered) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 6) {
                            Text(Fmt.clock(e.ts)).mono(10).foregroundStyle(.secondary)
                            Text(e.level.rawValue.uppercased()).mono(10).foregroundStyle(color(e.level))
                            Text(e.category.rawValue).mono(10).foregroundStyle(.secondary)
                        }
                        Text(e.message).mono(11)
                        if let p = e.payload, !p.isEmpty {
                            if expanded.contains(e.id) {
                                ForEach(p.keys.sorted(), id: \.self) { k in
                                    Text("\(k):\n\(p[k] ?? "")").mono(10).foregroundStyle(.secondary).padding(.leading, 8)
                                }
                            } else {
                                Text("▸ payload (tap)").font(.caption2).foregroundStyle(.blue)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) } }
                    .id(e.id)
                }
                .listStyle(.plain)
                .onChange(of: store.entries.count) { _, _ in
                    if !paused, let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .inlineTitle("Logs (\(filtered.count))")
        .toolbar {
            ToolbarItemGroup {
                Button { paused.toggle(); if paused { frozen = store.entries } } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                Button { Clipboard.copy(text()) } label: { Image(systemName: "doc.on.doc") }
                ShareLink(item: text(), subject: Text("ZCC Lab log")) { Image(systemName: "square.and.arrow.up") }
                Menu {
                    ShareLink(item: ReportBuilder.markdown(), subject: Text("ZCC Lab report")) { Label("Markdown report", systemImage: "doc.richtext") }
                    ShareLink(item: store.jsonl(), subject: Text("ZCC Lab log (JSONL)")) { Label("JSONL log", systemImage: "curlybraces") }
                    Button(role: .destructive) { store.clear() } label: { Label("Clear log", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func text() -> String {
        filtered.map { "\(Fmt.clock($0.ts)) [\($0.level.rawValue)] \($0.category.rawValue): \($0.message)" }.joined(separator: "\n")
    }

    private func color(_ l: LogLevel) -> Color {
        switch l { case .debug: .gray; case .info: .blue; case .warn: .orange; case .error: .red }
    }
}
