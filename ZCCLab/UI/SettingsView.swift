import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    private func managedBadge(_ key: String) -> some View {
        Group {
            if settings.managedKeys.contains(key) {
                Label("managed", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func lines(_ keyPath: WritableKeyPath<SettingsValues, [String]>) -> Binding<String> {
        Binding(get: { settings.values[keyPath: keyPath].joined(separator: "\n") },
                set: { settings.values[keyPath: keyPath] = $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    var body: some View {
        Form {
            Section {
                Text("All values below are PLACEHOLDERS until you enter your real GraphQL host. Fields marked “managed” are overridden by MDM app config and can't be changed here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("GraphQL probe (signal F)") {
                HStack { TextField("Probe URL", text: $settings.values.probeURL).plainInput(); managedBadge("probeURL") }
                Toggle("Use POST with body", isOn: $settings.values.probeUsesPOST)
                if settings.values.probeUsesPOST {
                    TextField("Body", text: $settings.values.probeBody, axis: .vertical).mono(12)
                }
                Stepper("Timeout: \(Int(settings.values.timeoutSeconds)) s", value: $settings.values.timeoutSeconds, in: 1...30)
                Toggle("Retry once after 2 s before “Not connected”", isOn: $settings.values.retryOnce)
            }
            Section("Schedule") {
                Toggle("Auto-probe while in foreground", isOn: $settings.values.autoProbe)
                HStack { Stepper("Interval: \(settings.values.probeIntervalSeconds) s", value: $settings.values.probeIntervalSeconds, in: 5...600, step: 5); managedBadge("probeIntervalSeconds") }
            }
            Section("Hosts (one per line) · also used by DNS/ZPA check and presets") {
                TextField("Hosts", text: lines(\.hosts), axis: .vertical).lineLimit(3...8).plainInput().mono(12)
                managedBadge("hosts")
            }
            Section("Zscaler checks") {
                HStack { TextField("Synthetic IP range (CIDR)", text: $settings.values.syntheticRange).plainInput(); managedBadge("syntheticRange") }
                Toggle("ip.zscaler.com page check (signal H)", isOn: $settings.values.enableZscalerPageCheck)
                managedBadge("enableZscalerPageCheck")
                TextField("Check page URL", text: $settings.values.zscalerPageURL).plainInput()
                HStack { TextField("Marker string", text: $settings.values.zscalerMarker); managedBadge("zscalerMarker") }
            }
            Section("Tools") {
                Text("DNS servers for direct comparison").font(.caption).foregroundStyle(.secondary)
                TextField("DNS servers", text: lines(\.dnsServers), axis: .vertical).lineLimit(1...4).plainInput().mono(12)
                Text("Egress / public IP URLs").font(.caption).foregroundStyle(.secondary)
                TextField("Egress URLs", text: lines(\.egressURLs), axis: .vertical).lineLimit(1...4).plainInput().mono(12)
            }
            Section("Managed app config (as received)") {
                Text(ManagedConfig.describe(settings.managed)).mono(11)
                Text("Supported keys: probeURL, hosts, syntheticRange, zscalerMarker, probeIntervalSeconds, enableZscalerPageCheck").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to defaults", role: .destructive) { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .inlineTitle("Settings")
    }
}
