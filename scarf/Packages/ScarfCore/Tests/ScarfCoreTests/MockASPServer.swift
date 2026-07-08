import Foundation
#if canImport(Network)
import Network

/// A tiny in-process HTTP server that serves the ASP control-API contract the
/// `ASPTransport` prototype speaks — with canned data and **zero AWS**. Point
/// `ASPConfig.apiBaseURL` at `http://127.0.0.1:{port}` and every transport call
/// is answered here.
///
/// Contract served (one fake session, id echoed from the path):
///   - `GET  /servers/{id}/config`   → 200 `text/yaml`, the canned config.yaml
///   - `PUT  /servers/{id}/config`   → 200, stores the body (readable via
///                                     `lastConfigWrite`) — the policy-gated,
///                                     audited write seam
///   - `GET  /servers/{id}/sessions` → 200 `application/json`, a sessions list
///   - `POST /servers/{id}/chat`     → 200 `text/event-stream`, a fixed reply
///                                     streamed back token-by-token as SSE
///
/// Every route requires `Authorization: Bearer …`; a missing/empty bearer gets
/// `401`. Deliberately minimal HTTP/1.1 — enough for URLSession, not a general
/// server. macOS-only (Network.framework); the ASP transport test that uses it
/// is `#if canImport(Network)`-guarded to match.
final class MockASPServer: @unchecked Sendable {
    /// Canned config.yaml body returned by `GET …/config`.
    static let cannedConfigYAML = """
    model:
      default: claude-opus-4-8
      provider: anthropic
    display:
      skin: solarized
      compact: true
    """

    /// The fixed assistant reply the chat endpoint streams, pre-tokenized so
    /// the concatenation of the streamed tokens reproduces it exactly
    /// (leading spaces are part of the token, preserved by SSE framing).
    static let chatReplyTokens = ["Hello", " from", " the", " mock", " ASP", " backend."]
    static var chatReply: String { chatReplyTokens.joined() }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-asp-server")
    private let lock = NSLock()
    private var _lastConfigWrite: Data?

    /// The most recent body received by `PUT …/config`, if any. Lets a test
    /// assert the write actually reached the (mock) audited endpoint.
    var lastConfigWrite: Data? {
        lock.lock(); defer { lock.unlock() }
        return _lastConfigWrite
    }

    /// The TCP port the server is listening on (assigned once `start()` returns).
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .any)
    }

    /// Base URL a `ASPConfig` should point at.
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self {
                self.port = self.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        ready.wait()
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until the full request (headers + Content-Length body)
    /// has arrived, then dispatch.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let chunk { acc.append(chunk) }

            if let request = HTTPRequest(parsing: acc) {
                self.handle(request, on: conn)
                return
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: acc)
        }
    }

    private func handle(_ request: HTTPRequest, on conn: NWConnection) {
        // Auth gate — every ASP route is authenticated.
        let bearer = request.header("Authorization") ?? ""
        guard bearer.hasPrefix("Bearer "), bearer.count > "Bearer ".count else {
            send(status: 401, contentType: "text/plain", body: Data("missing bearer token".utf8), on: conn)
            return
        }

        let path = request.path
        switch (request.method, path) {
        case ("GET", let p) where p.hasSuffix("/config"):
            send(status: 200, contentType: "application/x-yaml",
                 body: Data(Self.cannedConfigYAML.utf8), on: conn)

        case ("PUT", let p) where p.hasSuffix("/config"):
            lock.lock(); _lastConfigWrite = request.body; lock.unlock()
            send(status: 200, contentType: "text/plain", body: Data("ok".utf8), on: conn)

        case ("GET", let p) where p.hasSuffix("/sessions"):
            send(status: 200, contentType: "application/json",
                 body: Data(Self.sessionsJSON.utf8), on: conn)

        case ("POST", let p) where p.hasSuffix("/chat"):
            sendSSEChat(on: conn)

        default:
            send(status: 404, contentType: "text/plain",
                 body: Data("no route for \(request.method) \(path)".utf8), on: conn)
        }
    }

    // MARK: - Responses

    private func send(status: Int, contentType: String, body: Data, on conn: NWConnection) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Stream the fixed reply as Server-Sent-Events, one `data:` frame per
    /// token, terminated by `data: [DONE]`. Frames are written sequentially so
    /// the client's SSE parser sees real per-token boundaries.
    private func sendSSEChat(on conn: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = ""
        for token in Self.chatReplyTokens {
            payload += "data: \(token)\n\n"
        }
        payload += "data: [DONE]\n\n"

        var out = Data(head.utf8)
        out.append(Data(payload.utf8))
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static let sessionsJSON = """
    [
      {
        "id": "asp-sess-1",
        "source": "email",
        "userId": "ademp90@gmail.com",
        "model": "claude-opus-4-8",
        "title": "Daily digest",
        "startedAt": "2026-07-08T12:00:00Z",
        "messageCount": 12,
        "toolCallCount": 3,
        "inputTokens": 4200,
        "outputTokens": 880,
        "estimatedCostUSD": 0.0731
      },
      {
        "id": "asp-sess-2",
        "source": "telegram",
        "model": "minimax/minimax-m2.7",
        "title": "Trip planning",
        "startedAt": "2026-07-08T09:15:00Z",
        "messageCount": 5,
        "toolCallCount": 0,
        "inputTokens": 1200,
        "outputTokens": 300,
        "estimatedCostUSD": 0.0021
      }
    ]
    """

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Status"
        }
    }
}

/// Minimal HTTP/1.1 request parser: fails (`nil`) until the full request —
/// request line, headers, and the entire `Content-Length` body — is present in
/// `raw`. Good enough for the mock; not a general parser.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    init?(parsing raw: Data) {
        guard let headerEndRange = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw[raw.startIndex..<headerEndRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        lines.removeFirst()
        var parsed: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            parsed[key] = value
        }
        headers = parsed

        let bodyStart = headerEndRange.upperBound
        let available = raw[bodyStart...]
        let expected = Int(parsed["content-length"] ?? "0") ?? 0
        // Wait until the whole declared body has arrived.
        guard available.count >= expected else { return nil }
        body = Data(available.prefix(expected))
    }
}
#endif
