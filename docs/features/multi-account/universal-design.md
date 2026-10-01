---
description: Proposed universal multi-account architecture and source-by-source acceptance map for all built-ins, custom definitions, and extensions.
---

# Universal accounts — proposed design

Status: proposed; authentication adapters below are requirements, not claims of completed support. PR #358 currently implements Codex sign-in and shared optional naming.

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

This map comes from current source readers. Exact login commands and selectable credential paths require verification during implementation.

| Provider | Current usage/credential route | Added-account adapter must isolate |
|---|---|---|
| Claude | CLI and OAuth API; file, Keychain or environment credentials | Independent Claude config/login source; both fetch modes and renewal |
| Codex | CLI RPC and OAuth API | Separate Codex home and identity (already implemented) |
| Gemini | Local OAuth credential file and CLI | Selected credential home, CLI environment and renewal |
| Antigravity | Running local language server; Keychain/cloud fallback | Selected process/session or independent OAuth source; no global-process fallback |
| Z.ai | Configured key, environment or local Claude settings | Per-account key and endpoint/config options |
| Copilot | GitHub token and configured billing/user context | Token, user/org context and source mode |
| Bedrock | AWS profile, CloudWatch and regional budget settings | AWS profile/client, regions and budget |
| Amp | `amp usage` CLI login | Selected CLI credentials/environment and reported email |
| Kimi | CLI and regional OAuth/API source | Login/profile, token, region and fallback chain |
| Kiro | Interactive CLI `/usage` | Selected CLI profile/session environment |
| Cursor | Desktop SQLite credential database and usage API | Selected database/profile and account token |
| MiniMax | Configured/environment API key and region | Key, region and endpoint |
| DeepSeek | Configured/environment API key | Per-account key and token precedence |
| Vercel | Secure token and API context | Vault token and account/team context |
| Alibaba | Configured/browser cookie and API context | Cookie source, region and account context |
| Mistral | Local Vibe session logs | Selected log/profile directory; do not imply cloud quota for local metrics |
| OpenCode | Auth file/API and CLI fallback | Selected auth home/key and CLI profile |
| Oh My Pi | CLI reports several upstream OAuth accounts | Selected harness/profile; preserve all existing upstream account/organization rows |
| Grok | Auth file and usage API | Selected auth home and identity |
| Command Code | Auth file/environment and usage API | Selected credential home/key and account context |
| Custom definitions | User-defined DataSources and vault | Per-account secret references, options and identity rules |
| Script extensions | User-defined script | Explicit account input/environment contract; separate process invocation and data identity |

## Validation and submission gates

Every adapter needs two independently stubbed accounts showing different usage; separate secret/source lookup and fallback; persistence and restart; rename/clear/remove preserving account identity and menu pins; one account expired while the other succeeds; and original default-source behavior unchanged. CLI adapters additionally need scoped environment and executable discovery. Browser adapters need cancellation and timeout coverage. Desktop/process adapters must prove that discovery cannot return another account’s session.

The shared UI is rendered for single and multiple accounts and long/duplicate names. Credentials never enter logs or ordinary settings. Every built-in, custom definition and script-extension route remains on the coverage checklist until implemented and checked. The PR stays draft until this matrix is satisfied; unavailable live accounts are documented as unverified rather than reported as tested.
