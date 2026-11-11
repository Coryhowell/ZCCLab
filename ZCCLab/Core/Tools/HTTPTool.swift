import Foundation
import Network
import Security

nonisolated struct HTTPSpec: Sendable {
    var url: String
    var method = "GET"
    var headers: [String: String] = [:]
    var body = ""
    var timeout = 8.0
    var ephemeralNoCache = true
    var waitsForConnectivity = false
    var bodyPreviewLimit = 2000
}

nonisolated struct HTTPMetrics: Sendable {
    var protocolName: String?
    var remoteIP: String?
    var remotePort: Int?
    var localIP: String?
    var localPort: Int?
    var proxy = false
    var reused = false
    var tlsVersion: String?
    var cipher: String?
    var dnsMs: Double?
    var connectMs: Double?
    var tlsMs: Double?
    var requestMs: Double?
    var ttfbMs: Double?
    var responseMs: Double?
    var totalMs: Double?
    var redirects = 0
}

nonisolated struct HTTPResult: Sendable {
    var statusCode: Int?
    var errorCode: Int?
    var errorName: String?
    var errorText: String?
    var requestMethod = ""
    var requestURL = ""
    var requestHeaders: [String: String] = [:]
    var requestBody = ""
    var responseHeaders: [String: String] = [:]
    var bodySize = 0
    var bodyPreview = ""
    var metrics: HTTPMetrics?
    var totalMs = 0.0
    var certificateChain: [Data] = []
    var trustEvaluation: String?
    var gotHTTPResponse: Bool { statusCode != nil }
}

nonisolated final class HTTPCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _metrics: URLSessionTaskMetrics?
    private var _chain: [Data] = []
    private var _trust: String?

    var metrics: URLSessionTaskMetrics? { lock.withLock { _metrics } }
    var chain: [Data] { lock.withLock { _chain } }
    var trust: String? { lock.withLock { _trust } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { _metrics = metrics }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let certs = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            var err: CFError?
            let ok = SecTrustEvaluateWithError(trust, &err)
            lock.withLock {
                _chain = certs.map { SecCertificateCopyData($0) as Data }
                _trust = ok ? "trusted by system" : "NOT trusted: \(err.map { CFErrorCopyDescription($0) as String } ?? "unknown")"
            }
        }
        completionHandler(.performDefaultHandling, nil)   // never bypass validation
    }
}

nonisolated enum HTTPTool {
    static func urlErrorName(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: "notConnectedToInternet"
        case .dataNotAllowed: "dataNotAllowed"
        case .cannotFindHost: "cannotFindHost"
        case .dnsLookupFailed: "dnsLookupFailed"
        case .timedOut: "timedOut"
        case .cannotConnectToHost: "cannotConnectToHost"
        case .networkConnectionLost: "networkConnectionLost"
        case .secureConnectionFailed: "secureConnectionFailed"
        case .serverCertificateUntrusted: "serverCertificateUntrusted"
        case .serverCertificateHasBadDate: "serverCertificateHasBadDate"
        case .serverCertificateHasUnknownRoot: "serverCertificateHasUnknownRoot"
        case .serverCertificateNotYetValid: "serverCertificateNotYetValid"
        case .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection"
        case .cancelled: "cancelled"
        case .badURL: "badURL"
        case .unsupportedURL: "unsupportedURL"
        case .internationalRoamingOff: "internationalRoamingOff"
        case .callIsActive: "callIsActive"
        default: "URLError(\(code.rawValue))"
        }
    }

    static func tlsName(_ raw: UInt16) -> String {
        switch raw { case 0x0301: "TLS 1.0"; case 0x0302: "TLS 1.1"; case 0x0303: "TLS 1.2"; case 0x0304: "TLS 1.3"; default: String(format: "0x%04X", raw) }
    }

    static func ms(_ a: Date?, _ b: Date?) -> Double? {
        guard let a, let b else { return nil }
        return b.timeIntervalSince(a) * 1000
    }

    @concurrent static func run(_ spec: HTTPSpec) async -> HTTPResult {
        var out = HTTPResult()
        out.requestMethod = spec.method
        out.requestURL = spec.url
        out.requestBody = spec.body
        guard let url = URL(string: spec.url), url.scheme != nil else {
            out.errorName = "badURL"; out.errorText = "Invalid URL"; return out
        }
        let cfg: URLSessionConfiguration = spec.ephemeralNoCache ? .ephemeral : .default
        cfg.timeoutIntervalForRequest = spec.timeout
        cfg.timeoutIntervalForResource = spec.timeout + 3
        cfg.waitsForConnectivity = spec.waitsForConnectivity
        if spec.ephemeralNoCache {
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            cfg.httpCookieStorage = nil
        }
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.httpMethod = spec.method
        for (k, v) in spec.headers { req.setValue(v, forHTTPHeaderField: k) }
        if !spec.body.isEmpty, spec.method != "GET", spec.method != "HEAD" { req.httpBody = Data(spec.body.utf8) }
        out.requestHeaders = req.allHTTPHeaderFields ?? [:]

        let collector = HTTPCollector()
        let t0 = Clock.now()
        do {
            let (data, resp) = try await session.data(for: req, delegate: collector)
            out.totalMs = Clock.ms(since: t0)
            if let http = resp as? HTTPURLResponse {
                out.statusCode = http.statusCode
                out.responseHeaders = Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { ("\($0.key)", "\($0.value)") })
            }
            out.bodySize = data.count
            out.bodyPreview = String(decoding: data.prefix(spec.bodyPreviewLimit), as: UTF8.self)
        } catch {
            out.totalMs = Clock.ms(since: t0)
            if let e = error as? URLError {
                out.errorCode = e.code.rawValue
                out.errorName = urlErrorName(e.code)
            } else {
                out.errorName = "error"
            }
            out.errorText = error.localizedDescription
        }
        out.certificateChain = collector.chain
        out.trustEvaluation = collector.trust
        if let m = collector.metrics {
            var hm = HTTPMetrics()
            hm.redirects = m.redirectCount
            if let t = m.transactionMetrics.last {
                hm.protocolName = t.networkProtocolName
                hm.remoteIP = t.remoteAddress
                hm.remotePort = t.remotePort
                hm.localIP = t.localAddress
                hm.localPort = t.localPort
                hm.proxy = t.isProxyConnection
                hm.reused = t.isReusedConnection
                hm.tlsVersion = t.negotiatedTLSProtocolVersion.map { tlsName($0.rawValue) }
                hm.cipher = t.negotiatedTLSCipherSuite.map { String(format: "0x%04X", $0.rawValue) }
                hm.dnsMs = ms(t.domainLookupStartDate, t.domainLookupEndDate)
                hm.connectMs = ms(t.connectStartDate, t.connectEndDate)
                hm.tlsMs = ms(t.secureConnectionStartDate, t.secureConnectionEndDate)
                hm.requestMs = ms(t.requestStartDate, t.requestEndDate)
                hm.ttfbMs = ms(t.requestStartDate, t.responseStartDate)
                hm.responseMs = ms(t.responseStartDate, t.responseEndDate)
                hm.totalMs = ms(t.fetchStartDate, t.responseEndDate)
                if let sent = t.request.allHTTPHeaderFields { out.requestHeaders = sent }
            }
            out.metrics = hm
        }
        return out
    }

    static func lines(for r: HTTPResult, showBody: Bool = true) -> [String] {
        var l: [String] = []
        l.append("→ \(r.requestMethod) \(r.requestURL)")
        for k in r.requestHeaders.keys.sorted() { l.append("  \(k): \(r.requestHeaders[k]!)") }
        if !r.requestBody.isEmpty { l.append("  body (\(r.requestBody.utf8.count) B): \(r.requestBody)") }
        if let s = r.statusCode {
            l.append("← HTTP \(s) \(HTTPURLResponse.localizedString(forStatusCode: s))  total \(Fmt.ms(r.totalMs))")
            for k in r.responseHeaders.keys.sorted() { l.append("  \(k): \(r.responseHeaders[k]!)") }
            l.append("  body: \(r.bodySize) bytes")
            if showBody, !r.bodyPreview.isEmpty { l.append("  preview: " + r.bodyPreview.replacingOccurrences(of: "\n", with: "\n           ")) }
        } else {
            l.append("✗ FAILED after \(Fmt.ms(r.totalMs)): \(r.errorName ?? "error") (\(r.errorCode.map(String.init) ?? "-"))")
            if let t = r.errorText { l.append("  \(t)") }
        }
        if let m = r.metrics {
            l.append("— Metrics —")
            l.append("  remote   \(m.remoteIP ?? "-"):\(m.remotePort.map(String.init) ?? "-")")
            l.append("  local    \(m.localIP ?? "-"):\(m.localPort.map(String.init) ?? "-")")
            l.append("  protocol \(m.protocolName ?? "-")   proxy: \(m.proxy)   reused conn: \(m.reused)   redirects: \(m.redirects)")
            if m.tlsVersion != nil || m.cipher != nil { l.append("  TLS      \(m.tlsVersion ?? "-")  cipher \(m.cipher ?? "-")") }
            func f(_ v: Double?) -> String { v.map { Fmt.ms($0) } ?? "-" }
            l.append("  DNS \(f(m.dnsMs))  | connect \(f(m.connectMs))  | TLS \(f(m.tlsMs))")
            l.append("  request \(f(m.requestMs))  | TTFB \(f(m.ttfbMs))  | response \(f(m.responseMs))  | total \(f(m.totalMs))")
        }
        return l
    }
}

// MARK: - TCP connect

nonisolated enum TCPTool {
    @concurrent static func connect(host: String, port: UInt16, timeout: Double, emit: Emit) async {
        let h = NetUtil.host(from: host)
        emit("# TCP connect \(h):\(port)")
        guard let p = NWEndpoint.Port(rawValue: port) else { emit("  invalid port"); return }
        let conn = NWConnection(host: NWEndpoint.Host(h), port: p, using: .tcp)
        let (stream, cont) = AsyncStream<NWConnection.State>.makeStream()
        conn.stateUpdateHandler = { cont.yield($0) }
        let t0 = Clock.now()
        conn.start(queue: DispatchQueue(label: "zcclab.tcp"))
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { conn.cancel() }
        }
        for await s in stream {
            let ms = Fmt.ms(Clock.ms(since: t0))
            switch s {
            case .setup: emit("  [\(ms)] state: setup")
            case .preparing: emit("  [\(ms)] state: preparing (resolving / connecting)")
            case .waiting(let e): emit("  [\(ms)] state: waiting: \(e)")
            case .ready:
                emit("  [\(ms)] state: READY: connected in \(ms)")
                if let path = conn.currentPath {
                    emit("  path status: \(path.status)  expensive: \(path.isExpensive)  constrained: \(path.isConstrained)")
                    emit("  interfaces: " + path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", "))
                    emit("  local  endpoint: \(path.localEndpoint.map { "\($0)" } ?? "-")")
                    emit("  remote endpoint: \(path.remoteEndpoint.map { "\($0)" } ?? "-")")
                }
                cont.finish()
            case .failed(let e): emit("  [\(ms)] state: FAILED: \(e)"); cont.finish()
            case .cancelled: emit("  [\(ms)] state: cancelled (timeout \(timeout) s or closed)"); cont.finish()
            @unknown default: break
            }
        }
        timer.cancel()
        conn.cancel()
    }
}

// MARK: - Egress / public IP

nonisolated enum EgressTool {
    @concurrent static func run(urls: [String], emit: Emit) async {
        emit("# Egress / public IP check")
        emit("Run once with ZCC on and once with it off; the egress IP should differ if ZIA forwards traffic.")
        for u in urls {
            if Task.isCancelled { return }
            emit("## \(u)")
            var spec = HTTPSpec(url: u)
            spec.timeout = 8
            let r = await HTTPTool.run(spec)
            if let s = r.statusCode {
                emit("  HTTP \(s) in \(Fmt.ms(r.totalMs)), remote \(r.metrics?.remoteIP ?? "-")")
                emit("  " + stripHTML(r.bodyPreview).prefix(600))
            } else {
                emit("  failed: \(r.errorName ?? "?") \(r.errorText ?? "")")
            }
        }
    }

    static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
