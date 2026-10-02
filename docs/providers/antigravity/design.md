# Antigravity definition design

Contributor notes for the Antigravity provider. For setup, see the [README](README.md). The endpoints were reverse-engineered from the Antigravity app and can change without notice. The approach follows robinebers/openusage's Antigravity provider.

## Sources, best first

1. **Local language server** of the running app or `agy`.
2. **Google Cloud Code** with the OAuth token Antigravity / `agy` saved in the Keychain, used when no process is found (#201).

Readiness is true when either a process with CSRF or stored credentials are found, including stored credentials whose token needs renewal. Fetching goes to Cloud Code **only** when no process is found. Any other detection error (e.g. a process with no CSRF token → `authenticationRequired`) is reported as it is.

## Shared runtime

`antigravity.json` declares fixed command and HTTP templates; `antigravity.js` contains the pure process, credential and quota parsers and the request planner. The shared `fetch.workflow` worker performs I/O, permits at most 128 steps, keeps executables fixed, fills argument strings without a shell and passes only failure categories to the planner. Availability can discover processes and credentials but cannot request quota HTTP. Cancellation stops the workflow.

Only explicitly declared loopback templates use the separate local network client. Their URL must be loopback with a valid port, and local redirects cannot leave loopback. Google requests use the normal TLS-validating client. Import review lists every endpoint and declared executable, including alternative paths.

Added accounts patch out all process and Keychain commands and bind the workflow to their own secure `apiKey` (OAuth access token). They use the same quota and plan endpoints and retain independent names, pins and state. Account tokens never appear in settings metadata or exported definitions.

## Local language server

1. **Find the process**: `/usr/bin/pgrep -lf language_server`. Keep lines that contain one of `language_server`, `language_server_macos`, `language_server_macos_arm` or `agy`, and also look like Antigravity: an `agy` binary, `--app_data_dir … antigravity`, or `/antigravity/` / `.antigravity/` in the path. The first matching line must have `--csrf_token <t>`, or detection throws `authenticationRequired`. `--extension_server_port <p>` is optional.
2. **Empty `pgrep` (#301, PR #304)**: when `pgrep` matches nothing it exits with empty output. The PTY runner reports that as `InteractiveRunner.RunError.timedOut`, not as empty output. Before the fix, that timeout escaped `detectProcess()`, `probe()` never saw `cliNotFound`, and the Cloud Code fallback was unreachable with the app closed. The user saw "Command did not complete within the timeout" on every refresh. A `pgrep` timeout now counts as "not running".
3. **Ports**: `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` → every `:<port> (LISTEN)`.
4. **Quota**: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/<method>` on each port, in this order:
   - `RetrieveUserQuotaSummary`: the pooled summary.
   - `GetUserStatus`: legacy, one entry per model.
   - `GetCommandModelConfigs`: legacy fallback.

   Headers: `X-Codeium-Csrf-Token: <t>`, `Connect-Protocol-Version: 1`. Body: `{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}`. The certificate is self-signed, so this uses `InsecureLocalhostNetworkClient`. If no HTTPS port answers, the same three paths are tried over plain HTTP on `--extension_server_port`.

## Cloud Code (app closed)

- **Token**: `security find-generic-password -s gemini -a antigravity -w`. The value is `go-keyring-base64:`-wrapped JSON `{ "token": { "access_token", "refresh_token", "expiry" } }`; `accessToken`/`expires_at`/`expiresAt` are also accepted. ClaudeBar only reads this item and never writes back to it.
- **No refresh.** The token is sent as it is, and a token within 60 s of expiry counts as expired. Refreshing it would mean embedding Antigravity's OAuth client credentials, so ClaudeBar doesn't. The token is refreshed whenever the app or `agy` runs. Expired or rejected → `sessionExpired("Sign in to Antigravity or run `agy` again.")`.
- **Endpoints**: `POST` to `https://daily-cloudcode-pa.googleapis.com` first, then `https://cloudcode-pa.googleapis.com`, with `User-Agent: antigravity` and full TLS validation:
  - `/v1internal:retrieveUserQuotaSummary`: the pooled summary.
  - `/v1internal:fetchAvailableModels`: legacy per-model quotas. Models with `isInternal` are dropped.
  - `/v1internal:loadCodeAssist`: plan name (`paidTier.name`, else `currentTier.name`), shown as the account tier.
- A 401/403 on a quota endpoint means the token is bad and fetching stops. A failed optional plan request leaves the already fetched quota intact. Any other failure moves on to the next base URL or endpoint. If every attempt fails: "Could not reach the Antigravity quota API".

## Quota summary

`RetrieveUserQuotaSummary` is the only endpoint that reports both pools with both windows. It accepts the language-server envelope `{"response":{"groups":…}}` and the bare Cloud Code `{"groups":…}`. Buckets are matched by exact `bucketId`:

| bucketId | Quota type | Group | Card title | Menu bar |
|---|---|---|---|---|
| `gemini-5h` | session | Gemini | 5h | Gemini |
| `gemini-weekly` | weekly | Gemini | 7d | Gemini Weekly |
| `3p-5h` | model "Claude" | Claude & others | 5h | Claude |
| `3p-weekly` | model "Claude Weekly" | Claude & others | 7d | Claude Weekly |

- Buckets without a usable `remainingFraction` are dropped rather than reported as 0%. The legacy per-model parsers do the opposite: a missing `remainingFraction` there means the quota is used up.
- If the result isn't a summary at all, fall back to the legacy endpoints. A usable nonempty summary wins; an empty one falls back to the legacy model path, matching the existing coordinator.
- `menuBarTitle` was added so the Gemini pool reads "Gemini / Gemini Weekly" in the menu bar like the Claude pool, instead of `5h` / `7d` (#278). The quota types and saved keys didn't change.

## Known limits

- `pgrep` matches on `language_server`, so an `agy` process is only found if its command line contains that string. The `agy` name check only runs on lines `pgrep` has already matched.
- If the keychain item's service or account changes in a future Antigravity build, the app-closed fallback stops working without any error beyond "not running and no stored credentials".
