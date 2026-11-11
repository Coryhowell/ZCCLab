import Foundation
import Observation
import os

nonisolated enum LogLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case debug, info, warn, error
    private var order: Int { switch self { case .debug: 0; case .info: 1; case .warn: 2; case .error: 3 } }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.order < b.order }
}

nonisolated enum LogCategory: String, Codable, CaseIterable, Sendable {
    case signal, tool, path, mdm, ui
}

nonisolated struct LogEntry: Identifiable, Encodable, Sendable {
    var id = UUID()
    var ts = Date()
    var category: LogCategory
    var level: LogLevel
    var message: String
    var payload: [String: String]?

    enum CodingKeys: String, CodingKey { case ts, category, level, message, payload }
}

nonisolated enum Fmt {
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
    static func ms(_ v: Double) -> String { String(format: "%.1f ms", v) }
}

nonisolated enum Clock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }
}

/// Appends JSONL to disk on a serial queue; rotates by size.
nonisolated final class LogFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "zcclab.logfile")
    private let encoder: JSONEncoder
    private let maxBytes = 2_000_000

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ZCCLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("log.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(Fmt.iso(d))
        }
        encoder.outputFormatting = [.sortedKeys]
    }

    func write(_ e: LogEntry) {
        queue.async { [self] in
            guard var data = try? encoder.encode(e) else { return }
            data.append(0x0A)
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.jsonl")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }
    }

    func clear() { queue.async { [self] in try? FileManager.default.removeItem(at: url) } }
}

@Observable
final class LogStore {
    static let shared = LogStore()
    private(set) var entries: [LogEntry] = []
    let capacity = 5000
    @ObservationIgnored private let writer = LogFileWriter()
    @ObservationIgnored private let logger = Logger(subsystem: "ZCCLab", category: "app")

    var fileURL: URL { writer.url }

    func append(_ e: LogEntry) {
        entries.append(e)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        writer.write(e)
        let type: OSLogType = switch e.level { case .debug: .debug; case .info: .info; case .warn: .default; case .error: .error }
        logger.log(level: type, "[\(e.category.rawValue, privacy: .public)] \(e.message, privacy: .public)")
    }

    func clear() {
        entries.removeAll()
        writer.clear()
    }

    func jsonl() -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { d, e in var c = e.singleValueContainer(); try c.encode(Fmt.iso(d)) }
        enc.outputFormatting = [.sortedKeys]
        return entries.compactMap { try? String(data: enc.encode($0), encoding: .utf8) }.joined(separator: "\n")
    }
}

/// Log from anywhere (any thread / actor).
nonisolated func zlog(_ category: LogCategory, _ level: LogLevel = .info, _ message: String, _ payload: [String: String]? = nil) {
    let e = LogEntry(category: category, level: level, message: message, payload: payload)
    Task { @MainActor in LogStore.shared.append(e) }
}
