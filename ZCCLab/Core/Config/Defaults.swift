import Foundation

/// Hardcoded defaults. Everything here is a PLACEHOLDER until you add your real
/// GraphQL host. Values can be edited in Settings or pushed via managed app config.
nonisolated enum Defaults {
    /// Any host ending in this suffix is treated as a placeholder (probe won't run).
    static let placeholderSuffix = "example.com"

    static let probeURL = "https://graphql.corp.example.com/graphql"
    static let graphQLBody = #"{"query":"{__typename}"}"#
    static let hosts = [
        "graphql.corp.example.com",
        "internal.corp.example.com",
        "ip.zscaler.com",
        "www.apple.com",
    ]
    /// ZPA synthetic IPs default to 100.64.0.0/16 but can be configured up to 100.127.0.0/16.
    static let syntheticRange = "100.64.0.0/10"
    static let zscalerPageURL = "https://ip.zscaler.com"
    /// VERIFY on a real device. Matched case-insensitively against the page text.
    static let zscalerMarker = "via Zscaler"
    static let probeIntervalSeconds = 45
    static let timeoutSeconds = 5.0
    static let dnsServers = ["8.8.8.8", "1.1.1.1"]
    static let egressURLs = ["https://api.ipify.org?format=json", "https://ip.zscaler.com"]
    static let zscalerScheme = "zsa://"
    static let tlsControlHost = "www.apple.com"
}
