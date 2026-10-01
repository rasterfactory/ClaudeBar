---
description: Add Personal and Work accounts for any provider, with separate credentials, usage and menu bar selections.
---

# Multiple accounts

Every provider has **Accounts** in Settings. A single account keeps the provider's name. After adding another, use optional names such as **Personal** and **Work**, or let ClaudeBar use the reported email, profile or source name. Each account has its own usage, errors, refresh and enable switch.

## Add an account

Open **Settings → Providers → the provider → Accounts → Add Account**.

- **Claude and Codex:** click **Sign In**, complete browser sign-in for the other account, check the email and click **Add Account**. ClaudeBar creates a separate private login folder. No Terminal command is required. Codex can use the CLI bundled with an installed desktop app; Claude requires Claude Code. **Choose Existing Folder** is also available.
- **API and token providers:** enter that account's key or OAuth token. Region, billing mode and other options belong to this account. Keys are saved in a separate Keychain namespace; a missing key never uses the default account's key.
- **CLI and file providers:** select an independently signed-in home or credential database. Use a separate login, rather than copying a refresh token. Folder selection does not create a login or install a tool.
- **Bedrock:** select an independently authenticated AWS profile, regions and optional daily budget.
- **Mistral:** select a separate Vibe session log folder. These are local cost/token metrics, not cloud quota.
- **Custom providers:** select a separate home and supply this account's keys or separate Keychain service. Relative files resolve within that home. Shared absolute credential/usage paths must be adapted in the definition first.
- **Extensions:** select a separate home and supply the extension's account-specific configuration. Scripts must support the [account contract](../extensions/README.md#multiple-accounts). Health-check sections require different account URLs.

ClaudeBar checks the connection before adding it. The default login and its existing configuration keep working. Added connections use the explicit source above; they do not discover arbitrary browser or desktop sessions.

Claude's guided sign-in is for Claude.ai subscriptions. Console keyless profiles are not isolated by `CLAUDE_CONFIG_DIR` and are not supported by this flow. Codex added folders use file credential storage; the default account still supports its existing Keychain/RPC behavior. Both accounts can access the same repositories: the login folders separate credentials, not projects.

## Names and menu bar

Use **Edit Name** on any account, including the default. Clear the name to restore the source identity. Names affect presentation only; they do not change credentials or menu bar selection IDs. Default names follow the reported identity when available, or the stable default connection when the source supplies no identity.

In **Menu Bar** settings, pin accounts independently. With multiple accounts, chosen names use up to 12 characters and automatic labels up to eight. Collisions receive distinct numbered suffixes, including collisions with a name that already contains a suffix. Full names, emails and source details remain in tooltips and Settings. A single account needs no menu bar account label. The existing three-selection limit still applies.

## Remove or reconnect

**Remove** unlinks the added account and its menu bar selections and forgets keys entered for that connection. It does not sign out of the upstream tool or delete its login files. Sign in again with the original account when a session expires. If the reported identity changes, remove and re-add the connection so its saved identity stays accurate.

Claude's configuration mode applies to its added subscription accounts; Codex's mode applies to its added accounts. CLI fallbacks retain the selected folder. Claude's default local activity and guest passes remain attached to the default login. Other added connections use the supported route listed above; the default connection retains its original routes and settings.

## Validation status

The implementation has independent fixture coverage for all 20 built-ins, plus custom definitions and extension subprocesses. These checks verify source selection and isolation in ClaudeBar. Live second-account sign-ins and upstream CLI handling of selected homes remain unverified; see the [acceptance matrix](universal-design.md). The upstream contribution remains a draft pending those checks.
