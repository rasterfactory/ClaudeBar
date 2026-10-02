# Gemini definition design

Contributor notes for the Gemini provider. For setup, see the [README](README.md).

## Sources

| Step | Call | Notes |
|---|---|---|
| Credentials | `~/.gemini/oauth_creds.json` → `access_token` | Written by gemini-cli's "Login with Google". `isAvailable()` only checks that this file exists |
| Project | `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` → `cloudaicompanionProject` | Body `{"metadata":{"pluginType":"GEMINI"}}`, the same bootstrap call gemini-cli makes. Up to 3 attempts, 400 ms and then 600 ms apart, to ride out cold-start network delays. A 401/403 isn't retried |
| Quota | `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with the project ID | Returns `buckets[]`: `modelId`, `remainingFraction`, `resetTime` (ISO 8601) |
| Token refresh | Run `gemini` with `/quit` as input (15 s timeout), wait 1.5 s, retry once | Only after quota HTTP 401. The CLI refreshes the token when it starts. ClaudeBar doesn't do an OAuth refresh itself |

`Modules/Providers/Resources/Providers/gemini.json` declares the API flow and an explicit CLI source. The default remains API, with no automatic CLI quota fallback. `gemini-flow.js` plans fixed requests without I/O; `gemini-api.js` and `gemini-cli.js` map quota data.

The shared flow worker permits at most eight requests, counts attempts, honours bounded cancellable delays, and continues only declared optional request failures. Error payloads never enter the planner. Credential `refresh.cli` runs the declared owner's command once after 401 and rereads the same file without rewriting it. A second 401 fails; 403 does not refresh. The selected custom CLI location reaches both stats and token refresh.

Named accounts bind the OAuth file, required file and refresh CLI to their own `GEMINI_CLI_HOME`. API-key and Vertex environment overrides are removed for those CLI calls. Default file-existence readiness remains compatible; missing login files never start a CLI. Named accounts require one explicit successful refresh before background fetching.

## Why `loadCodeAssist` (#124, #122)

Project discovery used to call `cloudresourcemanager.googleapis.com/v1/projects`. A personal Google sign-in has no GCP scope, so that call failed. `retrieveUserQuota` then went out without a project and came back with three dummy "100% remaining" buckets. It also hid `gemini-3-*-preview` for users eligible for that tier. An earlier workaround ("use any GCP project") helped only users who have a GCP project. `loadCodeAssist` returns the project gemini-cli itself uses, so it works for everyone. If discovery still fails, the quota call goes out without a project and the numbers may be less accurate.

## Mapping buckets

1. Keep the lowest `remainingFraction` for each `modelId`.
2. **Merge aliases that share a tier.** Code Assist sets quota by tier (Pro / Flash / Flash-Lite) but reports the same bucket under every model ID the user may call. Calling `gemini-3-pro-preview` reduces `gemini-2.5-pro` and `gemini-3.1-pro-preview` by the same amount. Entries are grouped by (tier, fraction, resetTime). The stable, non-preview ID survives, then the highest version, then alphabetical order. The row is labelled with the bare tier name ("Pro", "Flash", "Flash Lite") to match gemini-cli's `/model` view. Check for Flash-Lite before Flash, because "flash" is a substring of both. Models without a recognisable tier keep their raw ID.
3. Sort by remaining fraction, lowest first, with the model ID breaking ties. This puts the model under pressure at the top instead of under models at 100%, and keeps the order from shuffling between refreshes.
4. `resetTime` is parsed with and without fractional seconds. It used to be shown as a raw ISO string.

## Known limits

- The quota type is `.modelSpecific(<tier label>)`, so a saved menu-bar selection is tied to that label. Renaming a label (e.g. "Flash Lite") breaks existing selections.
- If `oauth_creds.json` has expired and `gemini` isn't installed, there's no way to refresh it. The user sees "Authentication required".
