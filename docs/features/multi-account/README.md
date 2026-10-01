---
description: Track separate Codex accounts by email, with independent usage cards and menu bar selections. Use when you have more than one ChatGPT login.
---

# Multiple accounts

Codex supports separate ChatGPT accounts. A single account keeps the **Codex** name. After you add a second account, each appears with the Codex icon and its signed-in email, with independent quotas, refreshes, enable toggles and errors. Other providers retain their existing account behavior.

## Add a Codex account

1. Open **Settings → Providers → Codex → Codex Accounts → Add Codex Account**. If Codex already shows an email, select that entry instead.
2. Click **Sign In**. ClaudeBar finds your installed Codex CLI or the CLI bundled inside a desktop app and opens browser sign-in. Choose the ChatGPT account you want to add.
3. Check the email shown after sign-in, then click **Add Account**. ClaudeBar creates and selects the separate login folder for you; no Terminal command, name, or token needs to be pasted.

You can cancel while waiting for the browser, or retry if sign-in fails or times out. If Codex cannot be found, install the Codex CLI or desktop app and try again.

**Choose Existing Folder** links an existing independently authenticated Codex folder. Additional accounts require file credential storage (`cli_auth_credentials_store = "file"`); the default account still supports Keychain through RPC mode.

You can keep switching accounts in your desktop app and use the same repositories with both accounts. These folders separate ClaudeBar’s sign-ins, not your projects.

The default login remains the one used by your ordinary Codex CLI. Added accounts use their own folders. Do not copy an existing `auth.json` to make a second login: authenticate separately so token refreshes have independent sessions.

## View both accounts

- Select either email in the dropdown's provider tabs.
- Enable **General → Overview Mode** to see all enabled accounts together.
- In **Menu Bar** settings, select both accounts to pin both quotas. With multiple accounts, Codex icons get labels of up to eight characters from the email’s local part; collisions get a numbered suffix. Full addresses remain in tooltips and account details. A single account needs no menu-bar account label. Accounts count toward the existing three-selection limit.

The Codex probe mode setting applies to all Codex accounts. Both RPC and API modes use each added account's own folder. Account-specific RPC failures never fall back to the default account's terminal session.

## Remove or reconnect

**Remove** only unlinks the account from ClaudeBar and its menu bar selections. It does not sign out of Codex or delete the folder.

For an expired session, sign in again using the same folder and account. If you sign in to a different account in that folder, ClaudeBar asks you to remove and re-add it rather than displaying the new account under the old email.

## See also

[Codex setup](../../providers/codex/README.md) · [Settings storage](../../settings.md)
