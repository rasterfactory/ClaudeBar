# MiniMax design

MiniMax is a bundled JSON definition in `Modules/Providers/Resources/Providers/minimax.json`, run by the shared `Provider` and `DataSources` engine. `minimax-remains.js` maps interval and weekly Token Plan percentages and legacy remaining-count responses. No provider-specific Swift fetch or lifecycle is used.

`SettingURL` selects the HTTP endpoint and dashboard from the legacy `minimax.region` setting for the default account and the added account's explicit region. The default remains China. The existing configuration card keeps its region, environment override, and API-key controls.

API keys are stored by `ProviderVault` under the provider or account scope. The default's legacy UserDefaults key migrates only after secure storage verifies the write. Added accounts use a form-patched setting credential and never fall back to the default key or environment.

Golden tests run the shipped definition over stubbed connections and cover original responses, errors, both regions, reset/window semantics, and account isolation. Generic selector tests cover live changes, unknown-value fallback, and JSON round trips.
