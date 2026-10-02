# Amp Code: definition design

How the Amp probe reads `amp usage`, from the code and commit history (Feb–Mar 2026).

## Source

`amp usage --no-color`, located through the login-shell PATH, 8-second timeout. A non-zero exit code is an error; stdout is parsed line by line. ClaudeBar makes no direct API call. The default account retains the CLI's own sign-in; added accounts use their own securely stored access tokens.

## Output format

As seen in March 2026:

```
Signed in as user@example.com (username)
Amp Free: $17.59/$20 remaining (replenishes +$0.83/hour) [+100% bonus for 19 more days] - https://...
Individual credits: $0 remaining - https://...
```

| Line | Pattern | Becomes |
|---|---|---|
| Account | `Signed in as <email> (` | account email (redacted to `u***@domain` in logs) |
| Capped credit | `<label>: $<left>/$<total> remaining` | percentage quota, reset text `$left/$total` |
| Balance | `<label>: $<left> remaining` | dollar-balance quota (no percentage) |

- Labels are mapped: `Amp Free` → "Free", `Individual credits` → "Individual". Any other label is kept as printed, so a new credit type still shows up.
- Everything after `remaining` (replenish rate, bonus, URL) is ignored. There is no reset time in the output, so none is shown.
- No matching line at all → "No valid credit lines found in amp usage output".

## Dead end: plan tier

The first version (0.4.28) derived a plan tier ("Free") from the credit labels. It was removed in 0.4.41: Free and Individual credits are separate balances that can exist side by side, not tiers of one plan, so no single tier label is correct.

## Definition and account isolation

`ampcode.json` declares the existing `amp usage --no-color` call and the pure `amp-usage.js` parser. `AMP_API_KEY` or the default vault key is used when present; only a missing key hands off to the hidden CLI-login source. An added account removes that handoff and uses its own vault key. A deleted or missing key therefore fails authentication instead of reading the default login.

The shared CLI worker resolves credential placeholders in environment additions at launch, without changing the definition or the app's environment. Optional error rules reject nonzero exits before mapping and retain the legacy missing-program and launch-failure messages. Golden tests cover all old text fixtures, availability/errors and missing added-account keys; generic tests distinguish output from processes given different keys.

Amp documents `AMP_API_KEY` precedence over saved accounts and requires long-lived access tokens for non-interactive use: [CLI accounts](https://ampcode.com/docs/cli), [non-interactive authentication](https://ampcode.com/docs/cli/execute-mode). The added-account form uses that supported path, without calling `amp account switch`.
