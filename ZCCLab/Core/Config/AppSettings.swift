import Foundation
import Observation

nonisolated struct SettingsValues: Codable, Equatable, Sendable {
    var probeURL = Defaults.probeURL
    var probeUsesPOST = true
    var probeBody = Defaults.graphQLBody
    var hosts: [String] = Defaults.hosts
    var syntheticRange = Defaults.syntheticRange
    var zscalerPageURL = Defaults.zscalerPageURL
    var zscalerMarker = Defaults.zscalerMarker
    var enableZscalerPageCheck = true
    var probeIntervalSeconds = Defaults.probeIntervalSeconds
    var autoProbe = true
    var timeoutSeconds = Defaults.timeoutSeconds
    var retryOnce = true
    var dnsServers: [String] = Defaults.dnsServers
    var egressURLs: [String] = Defaults.egressURLs
    var autoCapture = false

    var probeHost: String { NetUtil.host(from: probeURL) }
    var probeIsPlaceholder: Bool {
        let h = probeHost.lowercased()
        return h.isEmpty || h.hasSuffix(Defaults.placeholderSuffix)
    }
}

/// Reads / applies MDM managed app configuration (`com.apple.configuration.managed`).
nonisolated enum ManagedConfig {
    static let key = "com.apple.configuration.managed"
    static let feedbackKey = "com.apple.feedback.managed"

    static func read() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: key) ?? [:]
    }

    /// Suggested keys: probeURL, hosts, syntheticRange, zscalerMarker,
    /// probeIntervalSeconds, enableZscalerPageCheck.
    static func apply(_ base: SettingsValues, managed: [String: Any]) -> (SettingsValues, Set<String>) {
        var v = base
        var keys = Set<String>()
        if let s = managed["probeURL"] as? String, !s.isEmpty { v.probeURL = s; keys.insert("probeURL") }
        if let a = managed["hosts"] as? [String], !a.isEmpty { v.hosts = a; keys.insert("hosts") }
        if let s = managed["syntheticRange"] as? String, !s.isEmpty { v.syntheticRange = s; keys.insert("syntheticRange") }
        if let s = managed["zscalerMarker"] as? String, !s.isEmpty { v.zscalerMarker = s; keys.insert("zscalerMarker") }
        if let n = (managed["probeIntervalSeconds"] as? NSNumber)?.intValue, n > 0 {
            v.probeIntervalSeconds = n; keys.insert("probeIntervalSeconds")
        }
        if let b = managed["enableZscalerPageCheck"] as? Bool { v.enableZscalerPageCheck = b; keys.insert("enableZscalerPageCheck") }
        return (v, keys)
    }

    static func describe(_ m: [String: Any]) -> String {
        if m.isEmpty { return "(empty: no managed app config received)" }
        return m.keys.sorted().map { "\($0) = \(String(describing: m[$0]!))" }.joined(separator: "\n")
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()
    private static let storeKey = "ZCCLab.settings.v1"

    var values: SettingsValues {
        didSet { save() }
    }
    private(set) var managed: [String: Any] = ManagedConfig.read()

    /// Settings after managed overrides are applied. Use this for behavior.
    var effective: SettingsValues { ManagedConfig.apply(values, managed: managed).0 }
    var managedKeys: Set<String> { ManagedConfig.apply(values, managed: managed).1 }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let v = try? JSONDecoder().decode(SettingsValues.self, from: data) {
            values = v
        } else {
            values = SettingsValues()
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshManaged() }
        }
    }

    func refreshManaged() {
        let new = ManagedConfig.read()
        if !NSDictionary(dictionary: new).isEqual(to: managed) {
            managed = new
            zlog(.mdm, .info, "Managed app config changed", ["config": ManagedConfig.describe(new)])
        }
    }

    func resetToDefaults() { values = SettingsValues() }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
