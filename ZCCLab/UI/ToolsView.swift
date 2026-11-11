import SwiftUI

struct ToolsView: View {
    @Bindable private var runner = ToolRunner.shared
    private let settings = AppSettings.shared

    private var presets: [String] {
        var p = settings.effective.hosts
        let u = settings.effective.probeURL
        if !p.contains(u) { p.insert(u, at: 0) }
        return p
    }

    var body: some View {
        Form {
            Section {
                Picker("Tool", selection: $runner.kind) {
                    ForEach(ToolKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    TextField("Host or URL", text: $runner.target).plainInput()
                    Menu {
                        ForEach(presets, id: \.self) { p in Button(p) { runner.target = p } }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).fixedSize()
                }

                options
                HStack {
                    Button { runner.run() } label: { Label(runner.running ? "Running…" : "Run", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).disabled(runner.running)
                    if runner.running { Button("Stop") { runner.cancel() } }
                    Spacer()
                    Button { runner.presetGraphQL() } label: { Label("GraphQL", systemImage: "curlybraces").lineLimit(1) }
                    Button { Clipboard.copy(runner.lines.joined(separator: "\n")) } label: { Image(systemName: "doc.on.doc") }
                    Button { runner.clear() } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.bordered)
            }

            Section("Output") {
                OutputView(lines: runner.lines)
            }
        }
        .formStyle(.grouped)
        .inlineTitle("Tools")
    }

    @ViewBuilder private var options: some View {
        switch runner.kind {
        case .dns:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], alignment: .leading) {
                ForEach(DNSRecordType.allCases) { t in
                    Toggle(t.rawValue, isOn: Binding(get: { runner.dnsTypes.contains(t) },
                                                     set: { if $0 { runner.dnsTypes.insert(t) } else { runner.dnsTypes.remove(t) } }))
                    .toggleStyle(.button).controlSize(.small).lineLimit(1)
                }
            }
            Toggle("Also query \(settings.effective.dnsServers.joined(separator: ", ")) directly (compare)", isOn: $runner.dnsCompare)
        case .ping:
            Stepper("Count: \(runner.pingCount)", value: $runner.pingCount, in: 1...50)
            Stepper("Payload: \(runner.pingPayload) B", value: $runner.pingPayload, in: 0...1400, step: 8)
            Stepper("TTL: \(runner.pingTTL)", value: $runner.pingTTL, in: 1...255)
            Stepper("Interval: \(runner.pingIntervalMs) ms", value: $runner.pingIntervalMs, in: 100...5000, step: 100)
            Text("ZPA doesn't carry ICMP by default, so a failed ping to a ZPA app doesn't mean it's down.").font(.caption).foregroundStyle(.secondary)
        case .tcp:
            Stepper("Port: \(runner.tcpPort)", value: $runner.tcpPort, in: 1...65535)
        case .http:
            Picker("Method", selection: $runner.httpMethod) { ForEach(["GET", "POST", "HEAD", "PUT", "DELETE"], id: \.self) { Text($0) } }
            TextField("Headers (one per line)", text: $runner.httpHeaders, axis: .vertical).lineLimit(1...4).mono(12)
            TextField("Body", text: $runner.httpBody, axis: .vertical).lineLimit(1...4).mono(12)
            Toggle("Ephemeral session (no cache / cookies)", isOn: $runner.httpEphemeral)
            Toggle("waitsForConnectivity", isOn: $runner.httpWaits)
            Stepper("Timeout: \(Int(runner.httpTimeout)) s", value: $runner.httpTimeout, in: 1...60)
        case .trace:
            Stepper("Max hops: \(runner.traceMaxHops)", value: $runner.traceMaxHops, in: 1...30)
            Toggle("Reverse DNS", isOn: $runner.traceReverseDNS)
            Text("Best effort. ZPA and Zscaler edges commonly don't return TTL-exceeded.").font(.caption).foregroundStyle(.secondary)
        case .tls:
            TextField("Port (optional, default 443)", text: $runner.tlsPort).plainInput()
            Button("Use control host (\(Defaults.tlsControlHost))") { runner.target = Defaults.tlsControlHost }.font(.caption)
        case .egress:
            Text("Fetches \(settings.effective.egressURLs.joined(separator: ", ")). Edit the list in Settings.").font(.caption).foregroundStyle(.secondary)
        #if os(macOS)
        case .shell:
            ScrollView(.horizontal) {
                HStack {
                    ForEach(MacShell.presets) { p in
                        Button(p.title.replacingOccurrences(of: "{host}", with: NetUtil.host(from: runner.target))) { runner.runPreset(p) }
                            .controlSize(.small).disabled(runner.running)
                    }
                }
            }
            TextField("Custom command ({host} = target)", text: $runner.shellCustom).mono(12)
        #endif
        }
    }
}

struct OutputView: View {
    let lines: [String]
    var body: some View {
        if lines.isEmpty {
            Text("Output appears here. Every run is also written to the Logs tab.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l.isEmpty ? " " : l).mono(11).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
