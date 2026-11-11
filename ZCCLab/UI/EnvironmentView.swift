import SwiftUI

struct EnvironmentView: View {
    private let engine = SignalEngine.shared
    @State private var resolvers: [String] = []
    @State private var proxyDump = ""
    @State private var scoped: [String] = []
    @State private var interfaces: [InterfaceInfo] = []

    var body: some View {
        List {
            Section("Device") {
                Text(DeviceInfo.summary()).mono()
                Text("App config keys: \(ManagedConfig.read().count) managed, \(AppSettings.shared.managedKeys.count) overriding").mono()
            }
            Section("Current NWPath") {
                Text(engine.pathInfo?.detail ?? "No path update yet").mono(11)
            }
            Section("Interfaces (getifaddrs)") {
                ForEach(interfaces) { i in
                    VStack(alignment: .leading) {
                        HStack {
                            StatusDot(color: i.isTunnel ? (i.isUp ? .orange : .gray) : (i.isUp ? .green : .gray))
                            Text(i.name).font(.headline.monospaced())
                            if i.isTunnel { Text("tunnel-like").font(.caption).foregroundStyle(.orange) }
                        }
                        Text(i.flags.joined(separator: " ")).mono(10).foregroundStyle(.secondary)
                        ForEach(i.addresses, id: \.self) { Text($0).mono(11) }
                    }
                }
            }
            Section("DNS resolvers") {
                ForEach(resolvers, id: \.self) { Text($0).mono(11) }
            }
            Section("Proxy settings (CFNetwork)") {
                Text("__SCOPED__ keys: \(scoped.isEmpty ? "(none)" : scoped.joined(separator: ", "))").mono(11)
                Text(proxyDump).mono(10)
            }
            Section("Managed app config") {
                Text(ManagedConfig.describe(ManagedConfig.read())).mono(11)
            }
        }
        .inlineTitle("Environment")
        .toolbar { ToolbarItem { Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } } }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        resolvers = await DNSTool.resolvers()
        interfaces = NetUtil.interfaces()
        let proxy = NetUtil.proxySettings()
        scoped = (proxy["__SCOPED__"] as? [String: Any])?.keys.sorted() ?? []
        proxyDump = proxy.keys.sorted().map { "\($0) = \(String(describing: proxy[$0]!))" }.joined(separator: "\n")
    }
}
