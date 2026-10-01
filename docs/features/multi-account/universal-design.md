---
description: Universal multi-account architecture and source-by-source acceptance map for all built-ins, custom definitions, and extensions.
---

# Universal accounts — implementation and acceptance

Status: implemented in draft PR #358. Shared lifecycle, account controls and explicit connection recipes cover all 20 built-ins, custom definitions and extensions. Fixture checks are complete; live two-account browser/CLI authentication remains unverified.

## Product behavior

Every provider has an Accounts section: add, connect, optionally name, rename, refresh, enable, pin and remove each login independently. A single login keeps the product name. Multiple logins use optional names or source identity, with compact menu-bar labels and complete identity in details and tooltips. No email is invented for sources that report only a username, profile or local directory.

## Components and data flow

```text
Provider connection recipe (data) → shared Accounts UI
                                      ↓ connect / validate
                             account configuration + secret reference
                                      ↓
                       shared provider/account lifecycle
                         ↙                        ↘
             existing DataSource workers    legacy source adapter
                         ↘                        ↙
                         account-specific usage and errors
                                      ↓
                        QuotaMonitor → cards / menu bar
```

- Connection recipes describe required fields and authentication mode: browser/CLI login, secure key or token, existing credential source, AWS profile, or local data directory.
- Account configuration stores stable identity, optional name and non-secret options. Secrets live in the credential vault or the upstream tool’s own independently authenticated store. Each secret reference is scoped by provider and account.
- The common lifecycle owns the account list, independent refresh, errors, enable state and stable pin IDs. Definition-driven providers use their existing workers. A generic infrastructure bridge adapts legacy implementations during the migration, preserving their current behavior rather than requiring 18 simultaneous provider rewrites.
- A provider-specific composition recipe binds an account’s selected sources to existing readers/probes. Its fallback chain must never switch to the ordinary login or an ambient environment token. Local CLI/process discovery, cookies, files, profiles and renewal are scoped to the selected account.
- Identity is verified before registration and after refresh where the source supplies it. Missing/expired credentials affect only that account. Shared refresh tokens are not copied to manufacture independent sessions.

## Acceptance map

The following routes preserve default behavior and explicitly select sources for added accounts. The added route may be narrower than the default discovery chain; it never substitutes the ordinary login.

| Provider | Current usage/credential route | Added-account route |
|---|---|---|
| Claude | CLI and OAuth API; file, Keychain or environment credentials | Independent Claude.ai config/login source, selected Keychain/file credentials; CLI/API and renewal |
| Codex | CLI RPC and OAuth API | Separate Codex home and identity (already implemented) |
| Gemini | Local OAuth credential file and CLI | Selected credential home, CLI environment and renewal |
| Antigravity | Running local language server; Keychain/cloud fallback | Explicit OAuth token and cloud API; no discovery of a running global language server |
| Z.ai | Configured key, environment or local Claude settings | Per-account key and endpoint/config options |
| Copilot | GitHub token and configured billing/user context | Token, user/org context and source mode |
| Bedrock | AWS profile, CloudWatch and regional budget settings | AWS profile/client, regions and budget |
| Amp | `amp usage` CLI login | Selected CLI credentials/environment and reported email |
| Kimi | CLI and regional OAuth/API source | Explicit kimi-auth token and region; no global browser/CLI fallback |
| Kiro | Interactive CLI `/usage` | Separate CLI home and data directory; upstream isolation still needs live verification |
| Cursor | Desktop SQLite credential database and usage API | Separate database and JWT subject; reconnect when the subject changes |
| MiniMax | Configured/environment API key and region | Key, region and endpoint |
| DeepSeek | Configured/environment API key | Per-account key and token precedence |
| Vercel | Secure token and API context | Vault token and account/team context |
| Alibaba | Configured/browser cookie and API context | Explicit Coding Plan API key and region; no global browser cookie discovery |
| Mistral | Local Vibe session logs | Selected log/profile directory; do not imply cloud quota for local metrics |
| OpenCode | Auth file/API and CLI fallback | Selected auth home/key and CLI profile |
| Oh My Pi | CLI reports several upstream OAuth accounts | Selected harness/profile; preserve all existing upstream account/organization rows |
| Grok | Auth file and usage API | Selected auth home and identity |
| Command Code | Auth file/environment and usage API | Selected credential home/key and account context |
| Custom definitions | User-defined DataSources and vault | Scoped keys, home-relative files and separate Keychain services; absolute paths cannot escape the selected home |
| Script extensions | User-defined script | Scoped config, keys and subprocess home; accountId response required; per-account health endpoints |

## Validation and submission gates

Every adapter needs two independently stubbed accounts showing different usage; separate secret/source lookup and fallback; persistence and restart; rename/clear/remove preserving account identity and menu pins; one account expired while the other succeeds; and original default-source behavior unchanged. CLI adapters additionally need scoped environment and executable discovery. Browser adapters need cancellation and timeout coverage. Desktop/process adapters must prove that discovery cannot return another account’s session.

The shared UI is rendered for single and multiple accounts and long/duplicate names. Credentials never enter logs or ordinary settings. Every built-in, custom definition and script-extension route remains on the coverage checklist until implemented and checked. The PR stays draft until this matrix is satisfied; unavailable live accounts are documented as unverified rather than reported as tested.


## Evidence and remaining checks

| Route | Fixture evidence | Live boundary |
|---|---|---|
| Common lifecycle, all 22 provider categories | Independent refresh/quotas, changed identity, names, enabled state, restart and removal | These are lifecycle fixtures, not authentication claims |
| Claude | Two actual selected token/config files through API readers; changed login rejected before cached usage; derived Keychain service | Second browser sign-in, subscription CLI/API renewal |
| Codex | Existing independently configured RPC/API, identity, duplicate and browser cancellation/timeout tests | Second desktop-account browser sign-in |
| Eight token readers | Actual API readers with different credentials and usage, missing-key failure and restart | Real keys, upstream authorization and renewal |
| Gemini, Grok, OpenCode, Command Code | Two actual auth homes through API readers; missing files fail without sibling/default fallback | Upstream login/refresh and CLI fallback behavior |
| Amp, Kiro, Oh My Pi | Existing CLI parsers with selected executor contexts, credential-file preflight and distinct usage; Oh My Pi groups retained | Upstream binaries honoring selected homes/data directories, especially Kiro on macOS |
| Cursor | Two actual SQLite databases and JWT subjects, distinct API fixture usage, switched subject rejected | Live desktop profile/account switching |
| Bedrock | Separate injected profile clients, regional budgets, failure isolation; no global environment mutation | Real profile providers and CloudWatch permissions |
| Mistral | Separate actual session log directories retain local daily metrics | User profile conventions |
| Custom definition | Real scoped file fetch and separate vault keys; restart, rename and missing key | Author-specific definitions, including OAuth/Keychain services |
| Script extension | Real subprocess verifies its HOME, account key and ID; incorrect response ID rejected | Extension author implementing the contract; scripts remain trusted user code |

No live account was signed in, app installed or release performed. The PR stays draft while the live boundaries above and selected-session checks remain unresolved. Default provider discovery is intentionally preserved; added Antigravity, Kimi and Alibaba connections use explicit cloud credentials rather than the default process/cookie discovery chain.
