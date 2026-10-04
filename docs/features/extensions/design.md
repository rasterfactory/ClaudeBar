---
description: How an extension's manifest is read as a definition and run, for contributors: the script fetch, the usage mapping, sections answering together, settings and the upgrade.
---

# Extensions: design

User guide: [README.md](README.md). Field reference: [manifest.md](manifest.md).

## Flow

An extension is a definition of origin *Extension* ([TARGET_ARCHITECTURE §12](../../architecture/TARGET_ARCHITECTURE.md#12--retiring-aiprovider)):

1. At launch `Extensions.catalog()` (Providers) reads each `~/.claudebar/extensions/<id>/manifest.json`; one that doesn't read is logged and left out.
2. `Extensions.definition(manifest:folder:)` makes the definition, id `ext-<id>`, `"together": true`:
   - `quotaGrid` / `costUsage` → a data source with **`Fetch.script`** (run with `/bin/sh` from the extension's folder; every config field as `CLAUDEBAR_<UPPER_SNAKE>`, secrets read from the vault) and **`Mapping.usage`** (the documented output);
   - `healthCheck` → an `http` HEAD request with nothing to map; failing is fetch health;
   - `dailyUsage`, `metricsRow`, `statusBanner` → skipped and logged.
   - config fields → provider-scope settings (`number` a text with a number pattern, `toggle` an On/Off choice).
3. `ExtensionSettingsUpgrade` (Infrastructure) moves what was saved before, once: values from `extensions.<id>.<field>`, secrets from UserDefaults into the vault.
4. `ProviderFactory.make` builds it like any custom provider; its logins join the lineup.

With `together`, every section runs on each refresh; the usage is their union in the manifest's order, a failed one is left out and shows as fetch health, and the refresh fails only when all do.

## Security

Scripts run as the person, with their permissions; *Import* and the docs say so. Secrets are passed as real environment variables of the child process (not on its command line, so not in `ps`), read from the Keychain vault scoped to the login.
