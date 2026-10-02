# OpenCode Go design

`Modules/Providers/Resources/Providers/opencode-go.json` runs through the shared provider engine. The default API credential preserves `OPENCODE_API_KEY`, the XDG auth file's `opencode-go` entry, and its shared `opencode` entry, in that order.

`opencode-api.js` maps rolling, weekly and monthly server usage with server reset timestamps. HTTP status overrides preserve the 401 login hint and 403 subscription failure. Only a missing key hands off to the local data source; API failures never do.

The local data source uses `Fetch.commandPlan`. Its pure `opencode-local-plan.js` computes the same two guarded SQL queries, UTC weekly bounds, and Calendar-compatible anchored monthly bounds as the old probe. A generic worker runs the fixed CLI with argv and checks every exit. Without an anchor it skips the monthly query. `opencode-local.js` preserves the $12/$30/$60 local limits and their windows.

Added API-key accounts patch out the default credential chain and handoff. Keys remain in the account's vault scope. CLI location, identity, appearance and enabled-by-default behavior are retained.

Golden tests run shipped definitions over stubbed network and CLI connections; generic planner tests cover successful completion, nonzero exits, invalid output and the eight-command limit. Live API and local database integration require a real user account and are not exercised by those fixtures.
