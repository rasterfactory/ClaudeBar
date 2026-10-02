---
description: Track Gemini Code Assist quota per model tier (Pro, Flash, Flash Lite) using the Gemini CLI's Google sign-in. Use when setting up Gemini or when it shows "Authentication required" or 100% everywhere.
---

# Gemini

Shows the remaining Gemini Code Assist quota for each model tier (Pro, Flash, Flash Lite, plus any model ClaudeBar doesn't recognise), with reset times. The most-used tier is listed first.

## Setup

1. Install the [Gemini CLI](https://github.com/google-gemini/gemini-cli), run `gemini`, and choose **Login with Google**. This creates `~/.gemini/oauth_creds.json`.
2. Settings → Providers → Gemini: turn it on (it is on by default). API quota is the default; CLI `/stats` is available as an explicit source.

ClaudeBar doesn't run `gemini` on each refresh. It reads the CLI's saved sign-in and asks Google's Code Assist API for your quota. It runs `gemini` briefly only to refresh the sign-in once it has expired.

## Separate accounts

Settings → Providers → Gemini → Accounts → **Add Account** accepts a separately signed-in Gemini CLI home. Choose the parent folder containing `.gemini/oauth_creds.json`, then name it Personal or Work. Refresh it once to verify the login before background monitoring starts.

For example, sign in using `GEMINI_CLI_HOME=/absolute/path/to/work-home gemini`, then choose `/absolute/path/to/work-home`. Gemini CLI treats `GEMINI_CLI_HOME` as a home directory and adds `.gemini` itself ([CLI path handling](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/paths.ts), [credential storage](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/config/storage.ts)).

Each account reads and refreshes only its own file. The default home cannot be added again. Removing an account leaves its CLI login files in place.

## Gotchas

- **API-key or Vertex sign-in isn't supported.** Without `~/.gemini/oauth_creds.json`, Gemini is treated as unavailable. Sign in with Google in the CLI.
- **"Authentication required"** means the saved token was rejected, and running `gemini` to refresh it either failed or wasn't possible because `gemini` isn't on your login shell's `PATH`. Run `gemini` yourself once, then refresh.
- **One row per tier, not per model.** Google applies the same quota to several model IDs (e.g. `gemini-2.5-pro`, `gemini-3-pro-preview` and `gemini-3.1-pro-preview` go down together), so ClaudeBar shows them as a single "Pro" row.
- **Every model at 100%** usually meant ClaudeBar couldn't find your Code Assist project and Google returned placeholder numbers. ClaudeBar now looks the project up the way the Gemini CLI does, which works without a Google Cloud account ([#124](https://github.com/tddworks/ClaudeBar/issues/124)). If discovery fails, quota is still fetched without a project.
- **Antigravity is a separate provider.** Its Gemini quota is on the [Antigravity](../antigravity/README.md) card.

## See also

[design.md](design.md) · [troubleshooting](../../troubleshooting.md) · [Antigravity](../antigravity/README.md)
