import Foundation

#if os(macOS)
import AppKit

/// Process-based ground-truth checks. Requires the App Sandbox to be OFF (it is for macOS in this project).
nonisolated enum MacShell {
    struct Output: Sendable { var stdout: String; var stderr: String; var status: Int32; var timedOut: Bool }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    @concurrent static func run(_ launchPath: String, _ args: [String], timeout: Double = 20) async -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let ob = Box(), eb = Box()
        out.fileHandleForReading.readabilityHandler = { ob.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { eb.append($0.availableData) }
        do { try p.run() } catch {
            return Output(stdout: "", stderr: "failed to launch \(launchPath): \(error.localizedDescription)", status: -1, timedOut: false)
        }
        let flag = Box()
        let killer = DispatchWorkItem { if p.isRunning { flag.append(Data([1])); p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        try? await Task.sleep(for: .milliseconds(120))
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        return Output(stdout: ob.string, stderr: eb.string, status: p.terminationStatus, timedOut: !flag.data.isEmpty)
    }

    struct Preset: Identifiable, Sendable {
        var id: String { title }
        var title: String
        var path: String
        var args: [String]   // "{host}" is replaced by the target
    }

    static let presets: [Preset] = [
        .init(title: "scutil --nc list", path: "/usr/sbin/scutil", args: ["--nc", "list"]),
        .init(title: "scutil --proxy", path: "/usr/sbin/scutil", args: ["--proxy"]),
        .init(title: "scutil --dns", path: "/usr/sbin/scutil", args: ["--dns"]),
        .init(title: "ifconfig", path: "/sbin/ifconfig", args: []),
        .init(title: "netstat -rn", path: "/usr/sbin/netstat", args: ["-rn"]),
        .init(title: "networksetup -listallnetworkservices", path: "/usr/sbin/networksetup", args: ["-listallnetworkservices"]),
        .init(title: "nslookup {host}", path: "/usr/bin/nslookup", args: ["{host}"]),
        .init(title: "dig {host}", path: "/usr/bin/dig", args: ["{host}"]),
        .init(title: "ping -c 4 {host}", path: "/sbin/ping", args: ["-c", "4", "{host}"]),
        .init(title: "traceroute -m 20 {host}", path: "/usr/sbin/traceroute", args: ["-m", "20", "{host}"]),
        .init(title: "Find Zscaler files", path: "/bin/sh", args: ["-c", "ls -d /Library/*/*[Zz]scaler* /Library/*/*/*[Zz]scaler* ~/Library/*/*[Zz]scaler* 2>/dev/null | head -40"]),
        .init(title: "Zscaler processes", path: "/bin/sh", args: ["-c", "ps aux | grep -i [z]scaler"]),
    ]

    static func zscalerApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").lowercased().contains("zscaler") || ($0.localizedName ?? "").lowercased().contains("zscaler") }
            .map { "\($0.localizedName ?? "?") [\($0.bundleIdentifier ?? "?")] pid \($0.processIdentifier)" }
    }
}
#endif
