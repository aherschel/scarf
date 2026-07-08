# ASP `ServerTransport` prototype

A third `ServerTransport` implementation, **`ASPTransport`**, that lets Scarf
drive a Hermes session hosted by **ASP** (Agent Server Provider) over ASP's
authenticated HTTP control API — with **no shell, no SSH, and no filesystem
access**.

> **Post-security-review update.** The mock contract below was validated Scarf-side,
> then the ASP-side plan was taken through ASP's enterprise/security persona review
> (ASP repo: `docs/SCARF-TRANSPORT-ENDPOINTS.md`,
> `personas/reports/scarf-asp-transport-sentiment.md`). Verdict: **build read-only
> first, defer chat.** The contract this prototype assumes differs from ASP's real
> API in three ways, now settled:
>
> 1. **Config read/write reuse *existing* ASP endpoints** — `GET /servers/{id}`
>    (structured, secret-free `Session.toPublic()`) for read, and
>    `PUT /servers/{id}/config` with a JSON **`AgentConfigPatch`** (allowlisted,
>    policy-gated, audited) for write. There is **no raw-YAML write** and **no
>    `GET/PUT …/config` YAML file endpoint**. The transport's file-shaped
>    `readFile/writeFile(config.yaml)` should map onto these structured calls
>    (read: render a view from the `GET`; write: a structured patch) rather than a
>    file surface. *Transport realignment is the next Scarf change; the mapping
>    table below is updated to reflect the real endpoints.*
> 2. **`GET /servers/{id}/sessions` is now real on ASP** (read-only, owner/tenant-
>    admin-scoped, kill-switch-gated, `via:'scarf'`-audited, output-capped, over a
>    fixed-command read-only SSM call — no SSH). This matches the transport's
>    `runProcess("hermes", ["sessions","list"])` mapping.
> 3. **Chat is deferred.** `POST /servers/{id}/chat` (SSM one-shot) was **blocked**
>    (a chat prompt is user content that, for a HIPAA tenant, carries PHI, and SSM
>    command strings/output are logged to CloudWatch). The locked lane is Hermes'
>    existing **`:8642` OpenAI-compatible API server** (`/v1/chat/completions`, SSE,
>    per-session Bearer) reached with a **short-lived Cognito-JWT-brokered
>    credential** — behind the spend hard-stop + the P2 isolation plane. The
>    prototype's SSE `chat(prompt:)` shape is close, but the endpoint + credential
>    vending are ASP backend work still to come.
>
> The prototype code + mock below remain the Scarf-side demonstrator; treat the
> config and chat mappings as the *target* the realignment will move to.

## Why a non-shell transport

Scarf's two existing transports both assume shell + filesystem access:

- **`LocalTransport`** — Hermes on the same Mac; reads/writes files under
  `~/.hermes/`, spawns the `hermes` CLI, runs `hermes acp` over stdio.
- **`SSHTransport`** — remote Hermes over system `ssh`; the same operations,
  tunnelled through a shell.

ASP runs the *identical* Hermes harness on managed EC2, but with process
isolation, an on-box secret broker, and a hard **`no_ssh_ingress`** audit
attestation. An ASP enterprise-security review **hard-blocked** any SSH/shell
path into an ASP box — it would defeat all three controls. The approved path is
this transport: Hermes is reachable *only* through authenticated HTTP (a Cognito
-JWT-gated control API plus a chat surface), and every Scarf action becomes a
first-class, audited API call.

## The seam

`ASPTransport` conforms to the existing
[`ServerTransport`](../Packages/ScarfCore/Sources/ScarfCore/Transport/ServerTransport.swift)
protocol, so all downstream services and ViewModels work against an ASP session
unchanged. It is selected by a new `ServerKind` case:

```swift
public enum ServerKind {
    case local
    case ssh(SSHConfig)
    case asp(ASPConfig)   // ← new
}

public struct ASPConfig: Sendable, Hashable, Codable {
    public var apiBaseURL: URL     // e.g. https://<api-id>.execute-api.us-west-2.amazonaws.com
    public var sessionId: String   // the ASP server/session id → /servers/{id}/…
    public var bearerToken: String // PROTOTYPE: static; production = short-lived Cognito JWT
}
```

`ServerContext.makeTransport()` returns an `ASPTransport` for `.asp`;
`ServerContext.paths` gives an `.asp` context a **synthetic virtual home**
(`/__asp__/{sessionId}`) that never touches disk — `ASPTransport` routes on the
trailing path component, so the base only has to be stable and collision-free
with real local paths. `.local` / `.ssh` behavior is byte-identical.

## Primitive → API mapping

The bulk of Scarf's transport usage is file read/write plus `hermes` CLI
invocations. `ASPTransport` recognizes the specific virtual paths and CLI verbs
Scarf actually uses and maps them to ASP routes. **Everything is authenticated:**
every request carries `Authorization: Bearer <token>`.

| Scarf primitive                                     | ASP route                        | Notes |
| --------------------------------------------------- | -------------------------------- | ----- |
| `readFile("<home>/config.yaml")`                    | `GET  /servers/{id}/config`      | Returns YAML text. |
| `writeFile("<home>/config.yaml", …)`                | `PUT  /servers/{id}/config`      | Body = YAML. **Privileged**: the single policy-gated + server-side-audited write seam. |
| `runProcess("hermes", ["sessions","list", …])`      | `GET  /servers/{id}/sessions`    | Emits JSON on stdout (exit 0). `ASPTransport.decodeSessions(_:)` turns it into `[HermesSession]`. |
| `chat(prompt:)` — one turn                          | `POST /servers/{id}/chat`        | SSE; each `data: <token>` frame yields a token, `data: [DONE]` ends. |
| `fileExists("<home>/config.yaml")`                  | *(local predicate)*              | `true` for `config.yaml` (always present on a live session), `false` otherwise. |

Both invocation forms of the sessions verb are recognized — the direct form
(`executable == hermes`, args `["sessions","list", …]`) and the shell-wrapped
form (`/bin/sh -c "… hermes sessions list …"`) some call sites use.

### Assumed ASP API contract (prototype)

- `GET /servers/{id}/config` → `200`, `Content-Type: application/x-yaml`, body is
  the session's `config.yaml`.
- `PUT /servers/{id}/config` → body is YAML; `200` on success. `403` when a
  server-side policy denies the edit (surfaced as `TransportError.commandFailed`).
- `GET /servers/{id}/sessions` → `200`, `application/json`, an array of session
  summaries (`id`, `source`, `model`, `title`, `startedAt`, `messageCount`,
  token/cost counts, …). Fields absent from the summary default to zero/`nil`
  when mapped to `HermesSession`.
- `POST /servers/{id}/chat` → body `{"prompt": "…"}`, response
  `Content-Type: text/event-stream`; assistant tokens stream as `data:` frames,
  terminated by `data: [DONE]`.
- Any non-2xx maps onto the existing `TransportError` taxonomy: `401` →
  `.authenticationFailed`, everything else → `.commandFailed(exitCode: status)`.

## What is stubbed / unimplemented

The prototype is a **narrow vertical slice** (list → read-config → chat). Any
path or verb outside it throws a clear
`TransportError.other("ASPTransport: <op> not implemented in prototype")`
rather than silently misbehaving. Specifically unimplemented:

- `writeFile` / `readFile` for anything other than `config.yaml` (e.g. `.env`,
  `state.db`, `cron/jobs.json`, `skills/…`, `SOUL.md`).
- `listDirectory`, `createDirectory`, `removeFile`, `stat` (returns `nil`).
- `runProcess` for any verb other than `sessions list` (kanban, curator,
  gateway, config-set, git, backup, …).
- `streamLines` (log tail, ACP JSON-RPC) and `streamScript` — throw.
- `makeProcess` returns an **inert** `Process` pointed at a non-existent path so
  an accidental `run()` fails immediately: `ASPTransport` must never spawn.
- `watchPaths` returns an immediately-finished stream (no change-feed) — callers
  just don't auto-refresh.

## Security invariants (from the ASP review)

- **No shell, no `Process`, no `ssh`, no writes to a real `~/.hermes`.** All I/O
  is authenticated HTTP. `makeProcess` is deliberately inert.
- **Writes are privileged.** Config writes route only through the `PUT …/config`
  endpoint, which in production is policy-gated + audited server-side. There is
  no bulk/unaudited write path.
- **Bearer token only**, and (production) short-lived. See open questions.

## Running the demo / test

The slice is proven end-to-end against an in-process mock (zero AWS):

- `Tests/ScarfCoreTests/MockASPServer.swift` — a tiny Network.framework HTTP
  server that serves the contract above with canned data (one fake session, a
  canned `config.yaml`, a sessions list, and a chat endpoint that streams a fixed
  reply token-by-token as SSE).
- `Tests/ScarfCoreTests/ASPTransportTests.swift` —
  `endToEndListReadConfigChat` registers an `.asp` `ServerContext` pointed at the
  mock and walks **list sessions → read config → one chat turn**, all green; plus
  coverage for the privileged write path, the auth gate, and that out-of-slice
  ops throw.

```bash
# Run just the ASP transport suite:
cd scarf
swift test --package-path Packages/ScarfCore --filter ASPTransportTests
```

## Open questions for a production version

1. **Auth / JWT refresh.** The prototype uses a static bearer string. Production
   must source a short-lived Cognito (or SAML-federated) JWT, refresh it before
   expiry, and never persist a long-lived credential to disk. Where does the
   token live in memory, who refreshes it, and how does a 401 mid-operation
   trigger a transparent re-auth + retry?
2. **Streaming chat fidelity vs. `hermes acp`.** Local/SSH chat runs the full ACP
   JSON-RPC protocol (`session/new`, tool-call permission prompts, rewind,
   model-set, cancellation, rich content blocks). SSE token streaming is a
   thin substitute. Does ASP's chat surface expose ACP-equivalent semantics
   (tool permission round-trips, structured events) over HTTP, or is a
   WebSocket/ACP-over-HTTP bridge needed to reach parity with the Mac chat UX?
   The prototype bridges a single turn directly rather than through `ACPChannel`.
3. **`state.db`-backed reads.** Sessions, kanban, curator state, cost/analytics,
   and log tail all come from SQLite (`state.db`) or files over the shell today.
   ASP exposes only a control API — `GET /servers/{id}/sessions` stands in for the
   sessions list, but there are **no** ASP endpoints yet for kanban, curator,
   cron, skills, memory, or log streaming. Each needs a first-class, audited API
   before the corresponding Scarf feature lights up on an ASP session. Until then
   those features must degrade gracefully (the transport throws
   `not implemented`, and the ViewModels should surface "unavailable on ASP"
   rather than erroring).
4. **Config write round-trip.** `PUT …/config` replaces the whole YAML; there's
   no `hermes config set` key-level seam. Does ASP preserve comments/key-order,
   and how are policy denials (403) surfaced to the user distinctly from
   transport errors?
5. **Change notifications.** `watchPaths` is a no-op. A production ASP transport
   likely wants a server push (WebSocket / SSE) or a poll cadence so the fleet
   view and session detail refresh without manual reload.
