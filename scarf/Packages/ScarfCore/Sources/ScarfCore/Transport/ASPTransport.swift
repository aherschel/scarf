import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `ServerTransport` for a Hermes session managed by **ASP** (Agent Server
/// Provider) — reached exclusively over ASP's authenticated HTTP control API,
/// never a shell.
///
/// **Why this exists.** `LocalTransport` and `SSHTransport` both assume shell +
/// filesystem access: they read/write files under `~/.hermes/`, spawn the
/// `hermes` CLI, and run `hermes acp` over stdio. ASP runs the identical Hermes
/// harness on managed EC2 with process isolation, an on-box secret broker, and
/// a hard `no_ssh_ingress` audit attestation — there is **no** SSH, no shell,
/// and no filesystem for Scarf to touch. An ASP enterprise-security review
/// hard-blocked any shell path in (it would defeat all three controls). The
/// approved path is this transport: every Scarf action becomes a first-class,
/// audited API call.
///
/// **Strictly non-shell.** `ASPTransport` NEVER spawns a `Process`, opens an
/// SSH channel, or writes to a real `~/.hermes`. All I/O is authenticated
/// HTTP. The `ServerTransport` primitives are translated to ASP routes by a
/// small router that recognizes the specific virtual paths and CLI verbs Scarf
/// actually uses; anything outside the implemented slice throws a clear
/// `TransportError.other("ASPTransport: <op> not implemented in prototype")`
/// rather than silently misbehaving.
///
/// **Prototype scope (the vertical slice that is wired):**
/// | Scarf primitive                                   | ASP route                          |
/// | ------------------------------------------------- | ---------------------------------- |
/// | `readFile(".../config.yaml")`                     | `GET  /servers/{id}/config`        |
/// | `writeFile(".../config.yaml", …)`                 | `PUT  /servers/{id}/config`        |
/// | `runProcess("hermes", ["sessions","list", …])`    | `GET  /servers/{id}/sessions`      |
/// | `chat(prompt:)` (one turn)                         | `POST /servers/{id}/chat` (SSE)    |
///
/// See `docs/asp-transport-prototype.md` for the full contract + open
/// questions for a production version.
public struct ASPTransport: ServerTransport {
    public let contextID: ServerID
    public let isRemote: Bool = true

    private let config: ASPConfig
    private let displayName: String

    public nonisolated init(
        contextID: ServerID,
        config: ASPConfig,
        displayName: String
    ) {
        self.contextID = contextID
        self.config = config
        self.displayName = displayName
    }

    // MARK: - Route construction

    private var baseServerURL: URL {
        config.apiBaseURL
            .appendingPathComponent("servers")
            .appendingPathComponent(config.sessionId)
    }
    private var configURL: URL { baseServerURL.appendingPathComponent("config") }
    private var sessionsURL: URL { baseServerURL.appendingPathComponent("sessions") }
    private var chatURL: URL { baseServerURL.appendingPathComponent("chat") }

    /// Build a request carrying the bearer credential. Every ASP call is
    /// authenticated — there is no unauthenticated surface.
    private func authorized(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // TODO(production): `config.bearerToken` is a static prototype string.
        // Production must present a short-lived Cognito/SAML-issued JWT and
        // refresh it before expiry, never persisting a long-lived credential.
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    // MARK: - Files

    /// Only `config.yaml` is modeled by the prototype. The router keys on the
    /// trailing path component so it is independent of the synthetic ASP
    /// `home` root (`/__asp__/{id}`).
    private func isConfigPath(_ path: String) -> Bool {
        path.hasSuffix("/config.yaml") || path == "config.yaml"
    }

    public func readFile(_ path: String) throws -> Data {
        guard isConfigPath(path) else {
            throw Self.notImplemented("readFile(\(path))")
        }
        let (data, http) = try syncData(authorized(configURL, method: "GET"))
        try Self.ensureSuccess(http, body: data)
        return data
    }

    public func writeFile(_ path: String, data: Data) throws {
        guard isConfigPath(path) else {
            throw Self.notImplemented("writeFile(\(path))")
        }
        // Treat config writes as privileged: they route through the single
        // policy-gated + server-side-audited config PUT endpoint. There is no
        // bulk/unaudited write path — that is a deliberate security invariant.
        var request = authorized(configURL, method: "PUT")
        request.setValue("application/x-yaml", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, http) = try syncData(request)
        try Self.ensureSuccess(http, body: body)
    }

    public func fileExists(_ path: String) -> Bool {
        // The prototype models only `config.yaml`, which always exists on a
        // live ASP session. Everything else reports absent so callers degrade
        // to their "file missing" branch instead of hitting an unimplemented
        // route. (`readTextThrowing` gates `readFile` on this.)
        isConfigPath(path)
    }

    public func stat(_ path: String) -> FileStat? {
        // No cheap metadata endpoint in the prototype contract.
        nil
    }

    public func listDirectory(_ path: String) throws -> [String] {
        throw Self.notImplemented("listDirectory(\(path))")
    }

    public func createDirectory(_ path: String) throws {
        throw Self.notImplemented("createDirectory(\(path))")
    }

    public func removeFile(_ path: String) throws {
        throw Self.notImplemented("removeFile(\(path))")
    }

    // MARK: - Processes

    public func runProcess(
        executable: String,
        args: [String],
        stdin: Data?,
        timeout: TimeInterval?
    ) throws -> ProcessResult {
        if Self.isSessionsListInvocation(executable: executable, args: args) {
            let (data, http) = try syncData(authorized(sessionsURL, method: "GET"))
            try Self.ensureSuccess(http, body: data)
            // Emit the API's JSON on stdout in the shape Scarf's session parser
            // expects (see `decodeSessions`). Exit 0 == success, mirroring a
            // real `hermes sessions list --json`.
            return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
        }
        throw Self.notImplemented("runProcess(\(executable) \(args.joined(separator: " ")))")
    }

    #if !os(iOS)
    public func makeProcess(executable: String, args: [String]) -> Process {
        // ASP has NO subprocess surface. The protocol requires this method on
        // non-iOS, but `ASPTransport` must never spawn a process. Return an
        // inert `Process` pointed at a path that cannot exist, so an accidental
        // `run()` throws immediately rather than doing anything.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/nonexistent/asp-transport-has-no-shell")
        proc.arguments = args
        return proc
    }
    #endif

    public func streamLines(
        executable: String,
        args: [String]
    ) -> AsyncThrowingStream<String, Error> {
        // Streaming stdout (log tail, ACP JSON-RPC) is not part of the slice —
        // ASP chat goes through `chat(prompt:)` (SSE) instead. Fail fast.
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: Self.notImplemented("streamLines(\(executable))"))
        }
    }

    public func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        throw Self.notImplemented("streamScript")
    }

    // MARK: - Watching

    public func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        // No push/poll change-feed in the prototype contract. A finished
        // stream means "never ticks" — callers just don't auto-refresh.
        AsyncStream { $0.finish() }
    }

    // MARK: - Chat (one turn)

    /// Run a single chat turn against the ASP session and stream the assistant
    /// reply back token-by-token.
    ///
    /// Maps to `POST /servers/{id}/chat` with a JSON body `{"prompt": "…"}`,
    /// consuming a Server-Sent-Events response: each `data: <token>` frame
    /// yields one token; a `data: [DONE]` frame (or stream EOF) finishes.
    ///
    /// This is a **minimal direct path** rather than a bridge through
    /// `ACPChannel` — a single working chat turn is the prototype goal, and
    /// ASP's chat surface is HTTP/SSE, not the stdio JSON-RPC `hermes acp`
    /// speaks. `docs/asp-transport-prototype.md` discusses the fidelity gap.
    public func chat(prompt: String) -> AsyncThrowingStream<String, Error> {
        var request = authorized(chatURL, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": prompt])

        return AsyncThrowingStream { continuation in
            #if canImport(Darwin)
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: TransportError.commandFailed(
                            exitCode: Int32(http.statusCode),
                            stderr: "ASP chat returned HTTP \(http.statusCode)"
                        ))
                        return
                    }
                    for try await line in bytes.lines {
                        // SSE framing: token payloads arrive as `data: <token>`.
                        // Per the SSE spec, exactly one optional leading space
                        // after the colon is stripped — so a token that itself
                        // begins with a space is preserved.
                        guard line.hasPrefix("data:") else { continue }
                        var payload = String(line.dropFirst("data:".count))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if payload == "[DONE]" { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            // Linux CI target: URLSession byte-streaming isn't relied on here.
            // Chat is a macOS runtime concern; fail fast off-Darwin.
            continuation.finish(throwing: Self.notImplemented("chat streaming (non-Darwin)"))
            #endif
        }
    }

    // MARK: - Session-list decoding

    /// Decode the JSON body returned by `GET /servers/{id}/sessions` (also what
    /// `runProcess("hermes", ["sessions","list"])` emits on stdout) into
    /// `HermesSession` values. This is the shape Scarf's session parser
    /// expects; fields absent from the ASP summary default to zero/`nil`.
    public static func decodeSessions(_ data: Data) throws -> [HermesSession] {
        let dtos = try JSONDecoder().decode([ASPSessionDTO].self, from: data)
        return dtos.map { $0.toHermesSession() }
    }

    // MARK: - Verb recognition

    /// Recognize a `hermes sessions list` invocation in either the direct form
    /// (`executable` == `hermes`, args `["sessions","list", …]`) or the
    /// shell-wrapped form (`/bin/sh -c "… hermes sessions list …"`) that some
    /// call sites use.
    static func isSessionsListInvocation(executable: String, args: [String]) -> Bool {
        let exe = (executable as NSString).lastPathComponent
        if exe == "hermes" {
            return args.count >= 2 && args[0] == "sessions" && args[1] == "list"
        }
        if exe == "sh" || exe == "bash" || exe == "zsh" {
            return args.contains { $0.contains("sessions list") }
        }
        return false
    }

    // MARK: - HTTP plumbing

    private static func notImplemented(_ op: String) -> TransportError {
        .other(message: "ASPTransport: \(op) not implemented in prototype")
    }

    /// Map a non-2xx response onto the existing `TransportError` taxonomy so
    /// the UI can distinguish auth failures from other command failures.
    private static func ensureSuccess(_ http: HTTPURLResponse, body: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = String(data: body, encoding: .utf8) ?? ""
        if http.statusCode == 401 {
            throw TransportError.authenticationFailed(host: "ASP", stderr: message)
        }
        // 403 (e.g. a server-side PolicyDenied on config PUT), 404, 5xx, …
        throw TransportError.commandFailed(exitCode: Int32(http.statusCode), stderr: message)
    }

    /// Bridge URLSession's async completion onto the synchronous
    /// `ServerTransport` primitives. Callers run these on `Task.detached`
    /// background threads (see the ViewModels), so blocking on a semaphore is
    /// safe — URLSession's completion fires on its own delegate queue.
    private func syncData(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let http = response as? HTTPURLResponse, let data {
                box.result = .success((data, http))
            } else {
                box.result = .failure(TransportError.other(
                    message: "ASPTransport: malformed HTTP response from \(request.url?.absoluteString ?? "?")"
                ))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        guard let result = box.result else {
            throw TransportError.other(message: "ASPTransport: request completed without a result")
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            if error is TransportError { throw error }
            throw TransportError.other(message:
                "ASPTransport: request to \(request.url?.absoluteString ?? "?") failed: \(error.localizedDescription)")
        }
    }

    /// Mutable transport for a value out of the URLSession completion closure.
    private final class ResultBox: @unchecked Sendable {
        var result: Result<(Data, HTTPURLResponse), Error>?
    }
}

// MARK: - Session summary DTO

/// The per-session JSON object returned by `GET /servers/{id}/sessions`. A
/// deliberately small summary — the ASP control API doesn't expose Hermes'
/// full `state.db` row today (see the doc's open questions). Missing numeric
/// fields default to zero so the `HermesSession` still constructs.
struct ASPSessionDTO: Codable {
    let id: String
    let source: String
    var userId: String?
    var model: String?
    var title: String?
    var startedAt: String?
    var endedAt: String?
    var messageCount: Int?
    var toolCallCount: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCostUSD: Double?

    func toHermesSession() -> HermesSession {
        HermesSession(
            id: id,
            source: source,
            userId: userId,
            model: model,
            title: title,
            parentSessionId: nil,
            startedAt: ASPSessionDTO.parseDate(startedAt),
            endedAt: ASPSessionDTO.parseDate(endedAt),
            endReason: nil,
            messageCount: messageCount ?? 0,
            toolCallCount: toolCallCount ?? 0,
            inputTokens: inputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            estimatedCostUSD: estimatedCostUSD,
            reasoningTokens: 0,
            actualCostUSD: nil,
            costStatus: nil,
            billingProvider: nil
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
