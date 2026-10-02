---
description: Vercel AI Gateway JSON definition, credits mapping, account key isolation and compatibility with saved keys and settings. Use when changing its connection or migrating credentials.
---

# Vercel Gateway definition

`Modules/Providers/Resources/Providers/vercel-gateway.json` runs through the shared Provider/DataSource pipeline. `GET https://ai-gateway.vercel.sh/v1/credits`, Bearer authorization, JSON Accept header and a 30-second timeout match the legacy probe. Number and numeric-string balances map to exact USD money with no ceiling. Missing or invalid balances fail mapping; 401/403 require authentication. Old golden fixtures are ported to `VercelDefinitionTests`; no live keys were used for migration validation.

The default account checks the configurable environment variable (`vercel.authEnvVar`, falling back to `AI_GATEWAY_API_KEY`) before its saved key. Form-created accounts patch the lookup to their own vault key only. Secrets are never written to settings. Provider ID, name, disabled default and dashboard remain stable.

`ProviderVault` reads `provider.vercel-gateway.apiKey`. The original secure item `vercel-ai-gateway-api-key` and legacy UserDefaults entry `com.claudebar.credentials.vercel-api-key` migrate only into that exact default scope. Old values are removed after a verified secure write; failed writes preserve the original. The existing configuration card and JSON settings getters use the same migration, so save/delete cannot leave a disconnected credential. `vercel.authEnvVar` and `providers.vercel-gateway.isEnabled` keep their names.

The generic JSON money mapper reads numeric strings directly into Decimal after validating the numeric format, avoiding an intermediate Double. This preserves precise credit balances for other definitions too.
