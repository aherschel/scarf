import Testing
import Foundation
@testable import ScarfCore

/// End-to-end prototype coverage for `ASPTransport` — the non-shell,
/// HTTP-only `ServerTransport` that talks to ASP's control API. Every test
/// runs against the in-process `MockASPServer` (canned data, zero AWS), so it
/// exercises the real URLSession codepaths the transport uses in production.
///
/// The headline test (`endToEndListReadConfigChat`) walks the full vertical
/// slice: **register an `.asp` server → list sessions → read config → one chat
/// turn**, all green against the mock.
///
/// `#if canImport(Network)` because `MockASPServer` is built on
/// Network.framework (macOS). The transport itself compiles everywhere; only
/// the in-process mock is Apple-only.
#if canImport(Network)
@Suite struct ASPTransportTests {

    /// Spin up a mock server + an `.asp` `ServerContext` pointed at it.
    private func makeFixture(bearer: String = "prototype-token") throws
        -> (server: MockASPServer, context: ServerContext) {
        let server = try MockASPServer()
        server.start()
        let config = ASPConfig(
            apiBaseURL: server.baseURL,
            sessionId: "asp-sess-1",
            bearerToken: bearer
        )
        let context = ServerContext(id: UUID(), displayName: "ASP", kind: .asp(config))
        return (server, context)
    }

    // MARK: - ServerKind / ServerContext wiring

    @Test func aspContextIsRemoteAndBuildsASPTransport() throws {
        let (server, context) = try makeFixture()
        defer { server.stop() }

        #expect(context.isRemote)
        let transport = context.makeTransport()
        #expect(transport is ASPTransport)
        #expect(transport.isRemote)
        #expect(transport.contextID == context.id)
        // The synthetic virtual home never collides with a real local path.
        #expect(context.paths.configYAML == "/__asp__/asp-sess-1/config.yaml")
    }

    @Test func existingKindsUnchanged() {
        // `.local` / `.ssh` behavior must stay byte-identical.
        #expect(ServerContext.local.isRemote == false)
        #expect(ServerContext.local.makeTransport() is LocalTransport)

        let ssh = ServerContext(id: UUID(), displayName: "r", kind: .ssh(SSHConfig(host: "h")))
        #expect(ssh.isRemote)
    }

    @Test func aspConfigCodableRoundTrips() throws {
        let kind = ServerKind.asp(ASPConfig(
            apiBaseURL: URL(string: "https://api.example.com")!,
            sessionId: "s-42",
            bearerToken: "tok"
        ))
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(ServerKind.self, from: data)
        guard case .asp(let cfg) = decoded else {
            Issue.record("expected .asp after round-trip")
            return
        }
        #expect(cfg.sessionId == "s-42")
        #expect(cfg.bearerToken == "tok")
        #expect(cfg.apiBaseURL.absoluteString == "https://api.example.com")
    }

    // MARK: - The end-to-end slice

    @Test func endToEndListReadConfigChat() async throws {
        let (server, context) = try makeFixture()
        defer { server.stop() }
        let transport = context.makeTransport()

        // 1) LIST SESSIONS — runProcess("hermes", ["sessions","list"]) → GET …/sessions
        let listResult = try transport.runProcess(
            executable: context.paths.hermesBinary, // "hermes"
            args: ["sessions", "list", "--json"],
            stdin: nil,
            timeout: 15
        )
        #expect(listResult.exitCode == 0)
        let sessions = try ASPTransport.decodeSessions(listResult.stdout)
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "asp-sess-1")
        #expect(sessions[0].source == "email")
        #expect(sessions[0].model == "claude-opus-4-8")
        #expect(sessions[0].title == "Daily digest")
        #expect(sessions[0].messageCount == 12)
        #expect(sessions[0].startedAt != nil)
        #expect(sessions[1].id == "asp-sess-2")

        // 2) READ CONFIG — readFile(".../config.yaml") → GET …/config
        let configText = try context.readTextThrowing(context.paths.configYAML)
        #expect(configText == MockASPServer.cannedConfigYAML)
        // And it parses through the normal config path.
        let parsed = HermesConfig(yaml: configText ?? "")
        #expect(parsed.model == "claude-opus-4-8")
        #expect(parsed.provider == "anthropic")

        // 3) ONE CHAT TURN — chat(prompt:) → POST …/chat (SSE tokens)
        guard let asp = transport as? ASPTransport else {
            Issue.record("expected ASPTransport")
            return
        }
        var tokens: [String] = []
        for try await token in asp.chat(prompt: "hello there") {
            tokens.append(token)
        }
        #expect(tokens == MockASPServer.chatReplyTokens)
        #expect(tokens.joined() == MockASPServer.chatReply)
    }

    // MARK: - Write path (privileged, single audited endpoint)

    @Test func writeConfigRoutesThroughPutEndpoint() async throws {
        let (server, context) = try makeFixture()
        defer { server.stop() }

        let newYAML = "model:\n  default: minimax/minimax-m2.7\n"
        let ok = context.writeText(context.paths.configYAML, content: newYAML)
        #expect(ok)
        // The body actually reached the (mock) audited PUT endpoint.
        let written = server.lastConfigWrite
        #expect(written != nil)
        #expect(String(data: written ?? Data(), encoding: .utf8) == newYAML)
    }

    // MARK: - Auth

    @Test func missingBearerSurfacesAuthFailure() throws {
        // Empty bearer → server answers 401 → transport maps to authenticationFailed.
        let (server, context) = try makeFixture(bearer: "")
        defer { server.stop() }
        let transport = context.makeTransport()

        var thrown: Error?
        do {
            _ = try transport.readFile(context.paths.configYAML)
        } catch {
            thrown = error
        }
        guard case .authenticationFailed = (thrown as? TransportError) else {
            Issue.record("expected .authenticationFailed, got \(String(describing: thrown))")
            return
        }
    }

    // MARK: - Out-of-slice ops fail loud, never silently

    @Test func unimplementedPrimitivesThrowClearly() throws {
        let (server, context) = try makeFixture()
        defer { server.stop() }
        let transport = context.makeTransport()

        // A non-config file read.
        #expect(throws: TransportError.self) {
            try transport.readFile("/__asp__/asp-sess-1/state.db")
        }
        // A non-config file write.
        #expect(throws: TransportError.self) {
            try transport.writeFile("/__asp__/asp-sess-1/.env", data: Data("x".utf8))
        }
        // An unrecognized process verb.
        #expect(throws: TransportError.self) {
            try transport.runProcess(executable: "hermes", args: ["kanban", "list"], stdin: nil, timeout: 5)
        }
        // Directory ops.
        #expect(throws: TransportError.self) {
            try transport.listDirectory("/__asp__/asp-sess-1")
        }
        // fileExists is a pure predicate: true only for config.yaml.
        #expect(transport.fileExists(context.paths.configYAML))
        #expect(!transport.fileExists(context.paths.stateDB))
    }

    // MARK: - Verb recognition unit coverage

    @Test func recognizesSessionsListInBothForms() {
        #expect(ASPTransport.isSessionsListInvocation(
            executable: "/Users/x/.local/bin/hermes", args: ["sessions", "list"]))
        #expect(ASPTransport.isSessionsListInvocation(
            executable: "hermes", args: ["sessions", "list", "--json"]))
        #expect(ASPTransport.isSessionsListInvocation(
            executable: "/bin/sh", args: ["-c", "PATH=... hermes sessions list --json"]))
        // Negatives.
        #expect(!ASPTransport.isSessionsListInvocation(
            executable: "hermes", args: ["kanban", "list"]))
        #expect(!ASPTransport.isSessionsListInvocation(
            executable: "hermes", args: ["sessions", "show", "abc"]))
    }
}
#endif
