---
description: The architecture that implements the canonical model — a provider as a JSON definition, one DataSource type that fetches for every provider through single-job internal workers, no vendor-named code, the runtime from definition to popover, settings keys, testing, and the migration slices starting with Codex; read before moving a provider to JSON or adding a fetch, mapping or credential case.
---

# ClaudeBar — the target architecture

> [CANONICAL_MODEL.md](CANONICAL_MODEL.md) says WHAT the domain is.
> [MODULAR_DESIGN.md](MODULAR_DESIGN.md) says which module each file lives in.
> [USER_JOURNEYS.md](USER_JOURNEYS.md) walks the screens first; the flows in §4.2
> are its moments, seen from inside.
> **This document says how a provider runs**: from a JSON file, through one
> `DataSource`, to the popover — and in what order today's code gets there.
>
> **Status: PROPOSED.** Branch `refactor/provider-data-sources`. Today's
> wiring is [ARCHITECTURE.md](ARCHITECTURE.md); it stays the truth until a
> slice below lands, and each slice updates it.

---

## 1 · The goal, as two principles

| Principle | Today | Target |
|---|---|---|
| **SRP** — one reason to change | `CodexAPIUsageProbe` changes when the auth file moves, when OAuth refresh changes, when the URL changes, when a header changes, and when the JSON changes. Twenty providers repeat this, each with its own `XxxProvider` lifecycle on top | a **definition** changes when Codex changes. A **worker** changes when its protocol or format changes. **`Provider`** changes when the lifecycle changes. Nothing else |
| **OCP** — open for extension, closed for modification | adding a provider adds ~5 types and edits ~10 files | adding a provider adds **one JSON file**. Adding a protocol or format adds **one case and one worker** to a closed list. Neither touches another provider |

There is no `UsageProbe`, no `XxxUsageProbe`, no `XxxProvider`, no
`XxxCredentialLoader`, and no vendor module. Vendor knowledge — URLs, file
paths, field names, client ids, CLI arguments — is data.

## 2 · The pieces

```text
  codex.json  ─────────────────────────────────────────────────┐   DATA
  deepseek.json · ~/.claudebar/providers/*.json · extensions   │   (what Codex IS)
                                                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ProviderCatalog      reads files → [ProviderDefinition]                  │
│ Providers.make(_:)   definition → Provider, each data source made live   │
│                      by DataSources.make(_:settings:vault:cloudWatch:)   │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Provider ◆  THE PRODUCT and THE lifecycle: isEnabled · the data source   │
│             in use · fallback · refresh(account) · use(kind)             │
│   └ accounts: [Account] — the logins: values · isEnabled · usage · sync  │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │ refresh(account) → dataSource.fetchUsage(for: account)
                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ DataSource ◆  ONE type for every provider: its definition + only the     │
│               connection its fetch needs. fetchUsage() = look up the     │
│               key → fetch → map. isReady. Never knows a vendor           │
└───────┬──────────────────────────┬──────────────────────────┬────────────┘
        ▼                          ▼                          ▼
  CredentialLookup (enum)     Fetch (enum)               Mapping (enum)
  each case's worker:         each case's worker:        each case's worker:
  EnvironmentReader           HTTPFetcher                JSONMapper
  SettingReader               JSONRPCFetcher             TextMapper
  JSONFileReader              CLIFetcher
  KeychainReader              TerminalFetcher
  BrowserCookieReader         FileFetcher
  OAuth2Refresher (refresh)   ScriptFetcher
                              CloudWatchFetcher ── CloudWatchClient (port; AWSClients)
        │                          │
        ▼                          ▼
  settings · vault            NetworkClient · CLIExecutor · RPCTransport
  (passed in by name)         (the module's own, built by its factory)
```

| Piece | One job | Changes when |
|---|---|---|
| `ProviderDefinition` · `DataSourceDefinition` | the provider as data, validated on load | a vendor changes |
| `Provider` | the lifecycle every provider shares, and the fallback between its data sources | the lifecycle changes |
| `DataSource` | fetches one data source's usage: look up the key, fetch, map | the order of those three changes |
| `CredentialLookup` · `Fetch` · `Mapping` | closed sums — one case per JSON tag | a protocol, format or key location is added |
| a worker (`HTTPFetcher`, `JSONMapper`, `OAuth2Refresher`, …) | carries out one case | that protocol or format changes |
| `DataSources.make(_:settings:vault:cloudWatch:)` | the one place a case meets the connection it needs | a connection is added |

## 3 · Codex, as data

`Resources/Providers/codex.json` — the whole of Codex. The fields below are the
ones today's two probes hard-code; slice 1 pins every one of them with a test
against the current probes' fixtures before those probes are deleted.

```json
{
  "profile": {
    "id": "codex",
    "name": "Codex",
    "links": { "dashboard": "https://platform.openai.com/usage",
               "status": "https://status.openai.com" },
    "look": { "symbol": "chevron.left.forwardslash.chevron.right", "icon": "CodexIcon",
              "color": { "light": [0.18, 0.72, 0.68], "dark": [0.35, 0.85, 0.78] },
              "gradientEnd": { "light": [0.12, 0.52, 0.72], "dark": [0.25, 0.65, 0.85] } }
  },
  "cli": "codex",
  "enabledByDefault": true,
  "defaultDataSource": "rpc",
  "dataSources": [
    {
      "kind": "rpc", "label": "RPC", "summary": "Uses codex app-server RPC",
      "fetch": { "jsonRpc": {
        "cli": "codex", "args": ["-s", "read-only", "-a", "never", "app-server"],
        "workingDirectory": "probe",
        "handshake": [
          { "request": "initialize", "params": { "clientInfo": { "name": "claudebar", "version": "1.0.0" } } },
          { "notify": "initialized" } ],
        "call": "account/rateLimits/read" } },
      "mapping": { "json": {
        "plan": "$.result.rateLimits.planType",
        "quotas": [
          { "name": "Session", "at": "$.result.rateLimits.primary",
            "usedPercent": "usedPercent", "resetsAt": { "epochSeconds": "resetsAt" },
            "window": { "minutes": "windowDurationMins" } },
          { "name": "Weekly", "at": "$.result.rateLimits.secondary",
            "usedPercent": "usedPercent", "resetsAt": { "epochSeconds": "resetsAt" },
            "window": { "minutes": "windowDurationMins" } },
          { "each": "$.result.rateLimitsByLimitId", "skipKeys": ["codex"],
            "name": { "firstOf": ["limitName", "limitId", "$key"], "dropPrefix": "codex_", "capitalize": true },
            "windows": [ { "at": "primary" }, { "at": "secondary", "suffix": " 7d" } ],
            "usedPercent": "usedPercent", "resetsAt": { "epochSeconds": "resetsAt" },
            "window": { "minutes": "windowDurationMins" } } ] } },
      "fallback": "tty"
    },
    {
      "kind": "api", "label": "API", "summary": "Calls ChatGPT API directly",
      "credential": {
        "jsonFile": { "path": "~/.codex/auth.json",
                      "token": "$.tokens.access_token", "refreshToken": "$.tokens.refresh_token",
                      "account": "$.tokens.account_id", "refreshedAt": "$.last_refresh" },
        "refresh": { "oauth2": { "tokenURL": "https://auth.openai.com/oauth/token",
                                 "clientId": "app_EMoamEEZ73f0CkXaXp7hrann",
                                 "every": "8d", "onStatus": [401],
                                 "expiredCodes": ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"],
                                 "hint": "Run `codex` in terminal to log in again." } } },
      "fetch": { "http": {
        "url": "https://chatgpt.com/backend-api/wham/usage",
        "headers": { "Authorization": "Bearer {{token}}", "ChatGPT-Account-Id": "{{account}}",
                     "Accept": "application/json", "User-Agent": "OpenUsage" } } },
      "mapping": { "json": {
        "plan": "$.plan_type",
        "quotas": [
          { "name": "Session", "at": "$.rate_limit.primary_window",
            "usedPercent": ["$header.x-codex-primary-used-percent", "used_percent"],
            "resetsAt": [ { "epochSeconds": "reset_at" }, { "secondsFromNow": "reset_after_seconds" } ],
            "window": { "seconds": "limit_window_seconds" } },
          { "name": "Weekly", "at": "$.rate_limit.secondary_window", "…": "same shape" },
          { "each": "$.additional_rate_limits[*]",
            "name": { "firstOf": ["limit_name", "metered_feature"], "dropPrefix": "codex_", "capitalize": true },
            "windows": [ { "at": "rate_limit.primary_window" }, { "at": "rate_limit.secondary_window", "suffix": " 7d" } ],
            "…": "same shape" } ],
        "cost": { "kind": "extraUsage", "limit": 1000,
                  "remaining": ["$header.x-codex-credits-balance", "$.credits.balance"] } } }
    },
    {
      "kind": "tty", "label": "Terminal", "hidden": true,
      "fetch": { "terminal": { "cli": "codex", "args": ["-s", "read-only", "-a", "never"], "send": "/status" } },
      "mapping": { "text": { "quotas": [
        { "name": "Session", "pattern": "5h limit[\\s\\S]{0,400}?([0-9]{1,3})% left", "leftPercent": 1 },
        { "name": "Weekly",  "pattern": "Weekly limit[\\s\\S]{0,400}?([0-9]{1,3})% left", "leftPercent": 1 } ] } }
    }
  ]
}
```

What the JSON mapping language must therefore say — each a **feature every
provider gets**, never a Codex special case:

| Feature | Why Codex needs it | Who else will |
|---|---|---|
| `at` · `each` over arrays and maps · `skipKeys` · `$key` | additional limits arrive as an array (API) or a map keyed by limit id (RPC) | any provider with per-model limits |
| `usedPercent` **or** `leftPercent` | Codex reports used | most report used; some left |
| a list = first that answers, including `$header.<name>` | headers are preferred over the body | rate-limit headers are common |
| `resetsAt`: `epochSeconds` · `secondsFromNow` · `iso8601` | both shapes occur | all |
| `window`: `seconds` · `minutes` | the window length is the provider's word ([the law](CANONICAL_MODEL.md#5--the-laws-on-the-node-that-owns-them)) | all |
| name rules: `firstOf`, `dropPrefix`, `capitalize`, `suffix` | `codex_spark` → `Spark`, `Spark 7d` | any provider with model names |
| constants (`"limit": 1000`) | credits have a fixed ceiling | balance providers |

**A rule the language cannot say yet** (today's free-plan defaults in the RPC
client are one) becomes a new mapping feature with its own test, or — if no
second provider could ever use it — is questioned until it goes away. It never
becomes vendor code.

## 4 · The runtime

### 4.1 · The types

```swift
// Providers — the definition: a value, decoded and validated on load
public struct ProviderDefinition: Sendable, Equatable, Codable {
    public let id: String, name: String, cli: String?
    public let links: Links, enabledByDefault: Bool
    public let dataSources: [DataSourceDefinition]   // ≥ 1, unique kinds
    public let defaultDataSource: String             // names one of them
}

// DataSources — the JSON of one data source: no behaviour
public struct DataSourceDefinition: Sendable, Equatable, Codable {
    public let kind: String, label: String, summary: String?, hidden: Bool
    public let credential: CredentialLookup?
    public let fetch: Fetch
    public let mapping: Mapping
    public let fallback: String?
}

// DataSources — three closed sums, one case per JSON tag
public enum CredentialLookup: Sendable, Equatable, Codable {
    case environment(String), setting(String), jsonFile(JSONFileFields),
         keychain(service: String), browserCookie(domain: String)
    indirect case refreshing(CredentialLookup, OAuth2Refresh)
}
public enum Fetch: Sendable, Equatable, Codable {
    case http(HTTPRequest), jsonRpc(JSONRPCCall), cli(CLICall),
         terminal(TerminalSession), file(path: String), script(path: String),
         cloudWatch(CloudWatchQuery)
}
public enum Mapping: Sendable, Equatable, Codable {
    case json(JSONMappingRules), text(TextMappingRules), script(ScriptMapping)
}

// DataSources — what came back, before anyone read it ("Response" on the Map fields step)
public struct Response: Sendable, Equatable {
    public let status: Int?, headers: [String: String], body: Data
}

// DataSources — a failure names its step ("Couldn't read your key · connect · find the numbers")
public struct DataSourceError: Error, Sendable {
    public enum Step: Sendable { case lookup, fetch, mapping }
    public let step: Step
    public let reason: UsageError          // today's cases (was ProbeError); never a secret or a body
}

// DataSources — ONE type that fetches for every provider
public struct DataSource: Sendable {
    public let definition: DataSourceDefinition
    public func fetchResponse() async throws(DataSourceError) -> Response      // Test Connection
    public func fetchUsage() async throws(DataSourceError) -> UsageSnapshot    // mapping.read(fetchResponse())
    public func isReady() async -> Bool
}
extension Mapping {
    public func read(_ response: Response, kind: String) throws(DataSourceError) -> UsageSnapshot  // Map fields' live card
}

// DataSources — the factory: the only place a case meets its connection
public enum DataSources {
    public static func make(_ definition: DataSourceDefinition,
                            settings: any ProviderSettingsRepository,
                            vault: any CredentialRepository,
                            cloudWatch: (any CloudWatchClient)? = nil) -> DataSource
}

// Providers — THE lifecycle
@MainActor @Observable
public final class Provider: AIProvider {
    public let definition: ProviderDefinition
    public let dataSources: [DataSource]
    public private(set) var activeKind: String       // persisted
    public var isEnabled: Bool                        // persisted
    public private(set) var isSyncing = false
    public private(set) var snapshot: UsageSnapshot?  // kept on failure
    public private(set) var lastError: Error?
    public func use(_ kind: String) -> Bool
    public func refresh() async throws -> UsageSnapshot   // active, then its fallback
}
```

Inside `DataSource`, `fetchUsage()` switches on the three cases and hands each
to its `internal` worker, built by the factory with **only** the connection
that case needs: `HTTPFetcher` holds a `NetworkClient`, `CLIFetcher` a
`CLIExecutor`, `JSONRPCFetcher` an `RPCTransport` factory, `SettingReader`
the settings, `KeychainReader` the vault. No type receives a bag of
everything.

`AIProvider` stays the protocol the Monitor and views consume while the other
providers move; `Provider` conforms. When the last `XxxProvider` is gone it
folds into `Provider`. `UsageSnapshot` keeps its name until the renames of
slice 7 (`Usage`), and gains `source: kind` — *via RPC* — in slice 1.

### 4.2 · Flows

**Launch.** `ProviderCatalog` reads the definitions (bundled, then
`~/.claudebar/providers/`, then extensions) → `Providers.make` builds one
`Provider` each, its data sources made live by `DataSources.make` →
`QuotaMonitor` receives them. A file that fails to decode — an unknown tag
included, since the sums are closed — is logged by file name and left out;
the rest load.

**Refresh.** `QuotaMonitor.refresh(id)` → `provider.refresh(kind)` →
`activeDataSource.fetchUsage()` off the main actor: look up the key
(refreshing it when the lookup says so), fetch, map. On failure the provider
tries the active data source's `fallback` once. Success replaces `snapshot`
and clears `lastError`; failure sets `lastError` and **keeps `snapshot`**.

**A 401.** `HTTPFetcher` reports the status; when the lookup is
`refreshing(_, oauth2)` with `onStatus: [401]`, the data source refreshes once
and fetches once more. An `expiredCodes` match becomes
`sessionExpired(hint:)` with the definition's hint.

**Switching data source.** The card writes `<id>.probeMode`, or calls
`provider.use(kind)`; both land on the same key, read on the next refresh.

**Add Provider** (moments 5–9). *Start from* makes an unsaved
`ProviderDefinition` — `blank(fetch: .http | .cli | .file)` or `copy()` of an
existing one with a new id. *Connect* edits its `fetch` and `credential`;
**Test Connection** builds a throw-away `DataSource` and calls
`fetchResponse()` — no mapping, nothing written — and the sheet shows the
`Response`. *Map fields* edits the `mapping` by pointing at values in that
`Response`, and the preview card is `mapping.read(response)` on every change,
with no second fetch. *Save* validates the definition (§3's laws, plus: at
least one quota or a cost read from the last `Response`), writes
`~/.claudebar/providers/<id>.json`, stores secrets in the vault, and hands the
new `Provider` to the Monitor — no restart.

**Export · Import** (moments 10–11). `definition.exported()` writes the JSON
with every secret setting reduced to its name and lookup order.
`catalog.import(file)` decodes it as a **custom** provider with a fresh id when
the id is taken, shows the URL a key will be sent to and any CLI command it
will run, and lists `missingSettings` (*Key needed*) before *Add*.

## 5 · Settings and secrets

| Key | Means | Status |
|---|---|---|
| `providers.<id>.isEnabled` | the Providers pane toggle | unchanged |
| `<id>.probeMode` | the active data source's `kind` | unchanged — a match name, so no user's setting moves |
| `providers.<id>.settings.<field>` | a non-secret form value | new |
| vault `claudebar.<id>.<field>` | a secret form value | new; Keychain with the file fallback Notify! uses for ad-hoc builds |

A credential lookup never writes settings, with one exception the definition
asks for by name: `OAuth2Refresher` writes the refreshed token **back to where
the credential came from** (for Codex, `~/.codex/auth.json`, preserving every
other field), because the CLI that owns that file must keep working.

## 6 · Concurrency, errors, logging

- `Provider` is `@MainActor @Observable`; `DataSource` and its workers are
  `Sendable` and `nonisolated`, so CLI, RPC and HTTP work runs off the main actor.
- At most one refresh per provider is in flight; a second call waits for the
  first one's result.
- `DefinitionError` (bad JSON, unknown tag, missing default, duplicate kind)
  is a load-time error with the file name. It never crashes the app.
- Workers log what they did (`AppLog.probes`), never what they carried: no
  token, header value, `{{secret}}` substitution, or response body at `info`
  or above. A response body is logged at `debug` only by the mapper,
  truncated, and only when mapping fails.

## 7 · Testing

| Subject | Test | How |
|---|---|---|
| each worker | its protocol or format, alone | `@testable`, built with a mocked connection (`NetworkClient`, `CLIExecutor`, `RPCTransport`); Chicago: assert on the payload / snapshot |
| `JSONMapper` · `TextMapper` | every mapping feature | small JSON/text fixtures, one feature per test |
| a mapping script | the old probe's screens and responses, quota for quota | run through its definition in `ProvidersTests` (`ClaudeHarness`), never by calling JavaScript directly |
| `DataSource` | look up → fetch → map, `fetchResponse` stops before mapping, 401-refresh-retry, each error's step | built with mocked connections |
| `Provider` | lifecycle: keeps usage on failure, fallback (and a switched-off one), a rate limit not handed over, one request for overlapping refreshes, `use`, the background floor, held until checked (#216), status across logins | `ProviderTests`: a provider no vendor ships ("Acme") over a fake `NetworkClient` |
| each definition | **golden test**: today's recorded responses (`Tests/…/Fixtures/codex/`) through the definition produce exactly the snapshot today's probe produced | the fixtures are captured from the current probe tests before the probe is deleted |
| the catalog | every bundled definition decodes | one test over `Resources/Providers/*.json` |

The golden tests are how deleting `CodexUsageProbe` stays safe: the JSON must
reproduce its output, quota for quota, before the Swift goes.

## 8 · Migration slices

Each slice is one PR, green, with no change a user can see unless it says so.

| # | Slice | Done when |
|---|---|---|
| **1** | **Codex** — the definition types, `CredentialLookup` · `Fetch` · `Mapping`, `DataSource`, `Provider`; workers `JSONFileReader`, `OAuth2Refresher`, `HTTPFetcher`, `JSONRPCFetcher`, `TerminalFetcher`, `JSONMapper`, `TextMapper`; `codex.json`; golden tests | `CodexProvider`, `CodexUsageProbe`, `CodexAPIUsageProbe`, `DefaultCodexRPCClient`, `CodexCredentialLoader` are deleted; both modes and the fallback work; `codex.probeMode` is read as before |
| 1a ✅ | **Accounts under one Provider** — `Provider` owns `[Account]`; `{{account.x}}` filled at fetch time; `codex.json`'s `accounts.dataSources` deleted; `AddedAccounts` → `provider.add(account:)` | same ids, pills, pins and settings keys; no visible change |
| 2a ✅ | **DeepSeek** — `deepseek.json`, balance script, `accounts.form`, scoped keys and verified legacy-key migration | its probe and provider class are deleted; golden tests cover currency, paid/granted details and independent keys |
| 2 | the remaining HTTP + API-key providers (MiniMax, Z.ai, Kimi API, Vercel, …): `EnvironmentReader`, `SettingReader` | their probes and provider classes are deleted |
| 3 | the look (✅ #353), the Data source section (✅ #352) and the settings form move into the JSON; the `switch id` tables and the simple config cards go | adding a provider edits no Swift |
| 4 ✅ | the kernel laws: `Left` (no fake 100%), `Window` (no guessed length) | balance definitions map money only |
| 5 | the CLI and cookie providers (Gemini, Kiro, Cursor, AmpCode, Antigravity, Alibaba, …): `CLIFetcher`, `BrowserCookieReader`, …; Bedrock via `Fetch.cloudWatch` and the `AWSClients` module; extensions read as definitions; *PROBE MODE* → *DATA SOURCE* | no `XxxUsageProbe` is left |
| 6 ✅ | *Add Provider* (#354), *Export*, *Import* (#355) — the screens of [USER_JOURNEYS.md](USER_JOURNEYS.md) moments 5–11, outer loop from its §5 scenarios | a person adds, shares and imports a provider without a restart, and no exported file contains a key |
| 7 | Claude (PTY CLI, multi-account, guest passes, budget); the renames (`Usage`, `Plan`, `Cost`, `DataSourceError`) | `AIProvider` folds into `Provider` |

## 8.1 · What Claude added

MiniMax adds `SettingURL`: `http.urlBySetting` selects a fixed URL by a live named provider setting, or an explicit account value. Unknown or unset selections use the request URL. `links.dashboardBySetting` uses the same selector, with each account's saved values before the default provider setting. No arbitrary setting becomes a URL.
OpenCode adds `Fetch.commandPlan`: a fixed CLI and a bundled pure `next(responses, context)` JavaScript planner produce at most eight argv commands, each exit-checked before its response is passed back. The planner receives prior stdout and one fixed clock; it has no host I/O and cannot change the executable. `done` becomes the mapping response. Settings' CLI location applies to this fetch too, and import review names the CLI and planner. HTTP requests may declare per-status `errors`; the status remains available for OAuth retry logic.
Command Code adds `Fetch.httpSequence`: up to eight fixed HTTP requests collect named JSON objects. Later query values come from declared paths in earlier responses and are encoded as URL query items. A failed request or invalid response stops the sequence; HTTP status overrides retain the response status for OAuth retry. Import review includes every request host. The reusable script money result from the DeepSeek migration represents balances and capped money without inventing percentages.
CLI environment additions may contain credential placeholders, resolved only for the process being launched. Missing placeholders fail authentication; they never inherit another account's login. Optional `cli.errors` names a missing program and supplies nonzero-exit or launch-failure messages. Without these rules, existing interactive terminal behavior stays unchanged. Mapping scripts can also return typed money balances, including an optional ceiling.
Script reports can carry `group`, `compactTitle`, and `menuBarTitle` on quotas and `metrics` for observations that are not quotas. Interim `spend: {used, limit}` metadata preserves a server's authoritative reported percentage alongside exact dollars in the existing UI. It is not accepted on an uncapped balance. Pure `jsonDecimal(text)` and `decimalCents(value)` helpers retain original JSON monetary number tokens and round half away from zero without binary floating point. `backgroundRefreshSeconds` sets a generic provider-level background floor without caching or delaying manual refresh.

`cli.mode: "pipes"` selects the reusable plain-process runner, preserving timeout/cancellation, combined stdout/stderr, working directory and PATH augmentation. The terminal remains the default. CLI credential environment placeholders and optional exit error rules use the same per-process isolation in either mode. Account form fields may require an absolute filesystem path (`absolutePath`) so a profile root cannot silently resolve against the default home.

Claude needed more than Codex, and each need became a generic piece, never a
vendor type:

| Need | Generic piece |
|---|---|
| an alert uses a longer product name than the menu | `profile.notificationName`, falling back to `profile.name` |
| an API request needs a username beside its bearer key | `credential.companions` reads declared fields, required names and a missing-field error; it never supplies a missing primary token |
| billing values and period rollover belong to one login | `settings` binds non-secret JSON values to the login scope. Scripts read `context.settings` and return `settings` effects; only declared writable keys persist, before a returned mapping error. Preview never writes |
| an added login chooses an API and its allowance | `accounts.dataSourceField`, form `defaultValue`/`pattern`/`when`, and non-secret `vault` fields; tokens and vault fields remain outside settings JSON |
| an endpoint accepts only 200 with specific error messages | `http.acceptedStatuses` and `http.errors` preserve the HTTP status for refresh rules |
| credential selection combines a saved key, a config file, platform detection and a login-shell fallback | `CredentialLookup.script` declares credential inputs, text files, environment names, constants and CLI checks. A pure `readCredential(input)` script returns fields/readiness/error and may request one declared environment lookup. Host I/O stays in the shared reader; scripts have no I/O API |
| configuration is available before a token is resolved | asynchronous credential readiness and fetch lookup preserve the existing synchronous readers; readiness never starts a login shell |
| an endpoint has provider-specific HTTP errors | `http.errors` and optional `acceptedStatuses`, with HTTP status retained for refresh |
| a TUI screen and human reset dates no rule can say | `Mapping.script` — a JavaScript file in JavaScriptCore, no I/O, host `humanDate()`; the scripts ship beside the definition |
| Claude Code's Keychain item | `CredentialLookup.keychain(service, fields)` via `security`, hex-decoded, written back as compact JSON |
| expiry in milliseconds, a JSON refresh body with `scope` | `OAuth2Refresh.dueWhen`, `bodyFormat`, `scope`; values keep their JSON type on write-back; a failed refresh re-reads the store |
| `env`, ready markers and a rendered screen for the CLI | `CLICall.environment`, `readyWhen`, `screen` |
| `/cost` only for API-billed accounts; API→CLI only while a setting allows | `fallbackOn` (hand-off by failure) and `fallback.enabledBySetting`; the provider follows the chain and reports the first real failure |
| 15-minute cache, a remembered 429 | `cache.ttl` (also the background floor) and rate-limit memory on `DataSource` |
| the account's email and billing type | `context` files handed to the mapping |
| browser sign-in sessions, regional requests and conditional account sources | `CredentialLookup.browserCookies`, `urlBySetting`/`headersBySetting`, reserved timezone, conditional/vault/path-validated account fields and `dataSourceField`; see Shared browser credentials below |
| delayed CLI input and an explicit missing-binary check | `CLICall.inputDelay` and `checkAvailability` |
| console security-token discovery and conditional HTTP stages | `Fetch.httpFlow`: a pure script selects only declared HTTP request templates, at most eight calls; earlier text/JSON responses can fill later request values |
| saved-key priority and manual/browser selection | lazy `CredentialLookup.bySetting` and nonsecret `as` tags; browser headers preserve empty cookie values and stop at the first matching store |
| the folder-trust prompt | `recover.patchJSONFile`, tried once |
| Optional multi-request APIs | `fetch.httpFlow`: pure planner over fixed named HTTP templates, eight requests maximum, attempt counts, bounded cancellable delays and explicit `continueOnError` requests; no script I/O or exception payloads |
| CLI-owned OAuth refresh | `credential.refresh.cli`: declared call, retry statuses, bounded delay and same-lookup reread; never writes the CLI's file; CLI location and import command review include refresh calls |
| File-existence readiness and strict login JSON | `availability.files`, `requiresFiles`, `missingFilesError`; `jsonFile.strict` preserves invalid-object errors and string credential types without opening login flows |
| Explicit terminal error conventions | `fetch.cli.mapInteractiveErrors` maps binary-not-found, timeout and launch failures while preserving existing default behavior |
| Mixed local discovery and remote APIs | `fetch.workflow`: pure planner over fixed CLI/HTTP templates, literal argument substitution, bounded steps, failure categories and optional declared alternate executables; scripts perform no I/O |
| Read-only workflow availability and loopback trust | workflow readiness permits command discovery, refuses quota HTTP; declared loopback requests use a separately injected client and URL guard, with remote-host redirects refused; remote requests retain normal TLS |
| Pooled quota headings from scripts | script quota `group`, `compactTitle` and `menuBarTitle` preserve existing card and menu-bar labels without vendor UI branches |
| Codex logins in their own folders (#326) | `accounts` (`folder`), `{{account.x}}`, `identity` (fail closed when a folder signs in to someone else), `requiresFiles` (#216), `verifyBeforeBackground`, JSON-RPC `then` + `environment`, `#jwt.claim` and `$credential.` paths |
| the usage API's model limits, plan and money | JSON mapping rules, not a script: `each` + `where`, names by `firstWord`/`lowercase`, `unique` (first wins), `overLimit` (negative left), `countdown: "hours"`, `plan.plans` from `$credential.`, and a list of `cost` shapes with `when` and exact `{amount, decimals}` minor units |
| today's usage and guest passes | `UsageHistory` beside the providers (read with the popover open, never in the background; keyed by the login whose logs it reads) and the `GuestPasses` capability |
| Claude logins in their own config folders | `accounts.folder` with `email` and `accountId.field` as an `IdentityField` (`$context.account.email`), `derived` values (the Keychain service, from a sha256 of the folder), `identity` read from a context file; today's usage and guest passes stay with the default login |

| Desktop state databases | `credential.sqlite` opens a database read-only and maps named columns from a read-only query; no login database is created or updated |
| Token request companions | `credential.claims` maps JWT payload fields and requires named values before fetching; the API authenticates the token |
| Desktop installation availability | `availability: "files"` with `requiresFiles` and optional `missingFilesError`; added accounts can use credential availability instead |
| Account recovery copy | `accounts.defaultLoginDescription` and `defaultReauthHelp` describe the default login without assuming a CLI or API key |
| HTTP response contracts | `fetch.http.acceptedStatuses` and `errors` preserve provider status handling; errors retain HTTP status for OAuth retry |
| Dictionary login files | `jsonFile.select` selects by mapped-field presence and expiry and writes back into the exact selected record; defaults are request companions |
| OAuth issuer/client and ISO expiry | Templates in `oauth2.tokenURL` and `clientId`, optional `tokenPath`, ISO-8601 `dueWhen`, and configurable missing-token and retry errors |
| Separate signed-in folders | Absolute-path account form fields and per-account credential paths, with recovery/removal text that leaves external login files intact |
| HTTP response contracts | Optional `acceptedStatuses` and error maps preserve status handling and OAuth retry |

## 9 · Open

- **The mapping language's ceiling.** Slices 1, 2 and 5 will find what it must
  express. If a provider needs real computation (Bedrock prices tokens per
  model), that is a fetch case's job — `Fetch.cloudWatch` returns usage
  already priced — not a scripting language inside the mapping.
- **JSONPath dialect.** A small, documented subset (`$.a.b`, `[*]`, maps by
  key, `$header.`), implemented and tested here, rather than a dependency.
- ~~**Multi-account in a definition.**~~ — **decided** ([CANONICAL_MODEL §1, §5](CANONICAL_MODEL.md#1--the-tree)):
  a definition declares how an account is added (`accounts.folder` today, an
  account-scope setting in the form later); the provider owns `[Account]`;
  one definition serves every account, the account's values filled when the
  fetch runs. Accounts are simultaneous. **Built** for Codex (#356) and
  Claude (`claude.json`'s `accounts`): `accounts.patch` and `{{account.x}}`,
  one `Provider` owning its `Account`s. The rest is designed in
  [features/multi-account/design.md](../features/multi-account/design.md).
- **A `command` fetch from the UI** — see [CANONICAL_MODEL §9](CANONICAL_MODEL.md#9--open).

Vercel’s migration also preserves numeric-string money directly as Decimal in the generic JSON mapper; account keys and the older secure-key name are bridged at the storage boundary.
### Shared browser credentials and conditional account inputs

`credential.browserCookies` declares suffix-matched domains, cookie names and `format` (`value` or `header`). Optional `domainsBySetting` chooses domains by a named setting. The injected cookie connection reads nonexpired browser stores in native order and stops at the first matching store. Cookie values never enter logs or account metadata. Added accounts replace this lookup with their scoped vault key.

`http.urlBySetting` and `headersBySetting` select request values by a named setting or an explicit account value. Headers can use reserved `{{system.timeZone}}`. `acceptedStatuses`, status `errors`, `networkErrorPrefix`, `invalidResponseError` and error placeholders `{{status}}`/`{{body}}` preserve the transport contract. Credential values are redacted from error messages.

Account fields support `defaultValue`, `when`, `pattern`, `vault`, `absolutePath`, `existingDirectory` and `excludedPaths`. Paths are compared after resolving symlinks. `accounts.dataSourceField` selects the account's source and reachable fallbacks before filling account placeholders. Irrelevant fields and sources are omitted; secret fields cannot embed defaults. `cli.inputDelay` preserves startup timing and `checkAvailability` requests an explicit missing-binary check before execution; `wrapExecutionErrors` preserves the execution error contract.
### Bounded HTTP flows and credential choices

`httpFlow` declares `script`, named `requests`, optional named `settings` and `constants`. A pure `next(responses, context)` function returns `{request, values}`, `{done}` or `{error}`. Only the shared worker has I/O. It rejects undeclared request names, limits each fetch to eight requests, and never exposes script exceptions in errors. Scripts cannot overwrite credentials found by the lookup. Responses retain their original text and JSON for the next stage; the selected final response uses the ordinary mapping. Import review includes every declared regional destination.

`credential.bySetting` selects one declared lookup lazily, falling back to its declared default when the setting is absent or invalid. `as` adds nonsecret facts to a found credential; token/refresh-token fields cannot be embedded as tags, and tags are stripped from refresh writeback. Ordered `firstOf` remains lazy, so a saved key avoids all browser access. Named accounts replace default credential lookup with their own vault entry.

`HTTPRequest.propagateNetworkErrors` retains an existing underlying network error when its message is credential-safe; echoed credentials are redacted. `ignoreResponseStatus` permits token discovery from a text response without treating its HTTP status as the billing request's result. Both default to false. Browser header credentials retain empty named cookie values while single-value credentials require a nonempty value.
