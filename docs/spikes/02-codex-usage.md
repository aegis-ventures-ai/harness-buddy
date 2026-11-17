# Spike 02: Codex subscription usage (live) and version source

_2026-11-17 · Codex CLI 0.167.2 (Homebrew cask) · macOS 27.2 · ChatGPT login (team plan)_
All identifiers (emails, account/user IDs, workspace names, tokens) are redacted. Scratch scripts were not committed.

## Questions

1. Does `codex app-server` expose a live rate-limit read? What are its shapes, cost, network needs and `auth.json` side effects?
2. Is there a ChatGPT backend usage endpoint we could call directly, and how does it compare?
3. Where does the plan tier come from?
4. Does `CODEX_HOME` isolate auth and config per profile?
5. Why is `~/.codex/version.json` stale, and what are the best latest-version sources and update commands per install method?

## Findings

**1. app-server: `account/rateLimits/read` exists and works.**
- **verified** The method is in the *stable* schema (`codex app-server generate-json-schema --out DIR`, no `--experimental`), together with `account/read`, `account/usage/read` and the push notification `account/rateLimits/updated`. The `app-server` subcommand itself is labelled `[experimental]`.
- **verified** Transport: newline-delimited JSON-RPC over stdio, with no `"jsonrpc"` field. Handshake: `initialize` request, then the `initialized` notification.
- **verified** Timing over 4 cold spawns: `initialize` returns in 0.03–0.07 s. The first `account/rateLimits/read` takes 0.6–0.9 s, and repeat calls cost the same, so results are not cached. RSS is about 85–90 MB. No child processes were spawned: the 3 configured MCP servers do not start without a thread.
- **verified** It needs the network. Under `sandbox-exec` with outbound IP denied it fails fast with `-32603 "failed to fetch codex rate limits: error sending request for url (https://chatgpt.com/backend-api/wham/usage)"`. `account/read` also needs the network (`"workspace routing discovery failed"`).
- **verified** `auth.json` was not modified: mtime and SHA-256 were unchanged across all runs. The access token was still valid (10-day lifetime, it expires 2026-11-18). `account/read` has a `refreshToken: bool` param; never send `true`.
- **inferred** Once the access token expires, app-server will refresh it and rewrite `auth.json` itself under Codex's own `auth.lock`. That is acceptable under §5.1 but was not observed.
- **verified** Side effect: on start it creates or opens SQLite DBs (`state_5`, `logs_2`, `goals_1`, `memories_1`, `queue_1`) and `installation_id` in `CODEX_HOME`. This ran fine next to a live Codex daemon.
- **verified** `codex app-server proxy`, which relays to the already-running daemon socket, did not answer our NDJSON `initialize` within 30 s before the pipe broke. Treat it as not usable.

**2. Direct HTTP: `GET https://chatgpt.com/backend-api/wham/usage`.**
- **verified** The binary contains `wham/usage`; the app-server error above confirms it is the backing call. The headers it sends are `Authorization: Bearer <access_token>` and `chatgpt-account-id` (string found in the binary).
- **verified** We made 2 GETs. Both returned HTTP 200 in about 0.85 s, one with the account header and one without; a single-workspace account works without it.
- **verified** Freshness: identical to app-server (same `used_percent` and `reset_at`), because both are live. The wire format has a few extras: `reset_after_seconds`, `allowed`/`limit_reached`, `model_usage`, `code_review_rate_limit`, `additional_rate_limits`, `promo`.
- **inferred** The `chatgpt-account-id` header is required to select a workspace when a login has several.
- **Downsides** Direct HTTP needs the raw token, so we would read `auth.json`, or the Keychain item `Codex Auth` when `cli_auth_credentials_store = "keyring"`. Once the token expires (at most about 10 days after Codex last ran) it returns 401 and we must not refresh it. app-server avoids both problems.
- **verified** For comparison, the passive rollout snapshot was from 2026-11-16 13:58Z: primary 8% with `resets_at` 2026-11-16 18:52Z, a window that had already expired. The live sources reported 10% in a newer window.

**3. Plan tier.**
- **verified** `account/read` returns `account.planType = "team"`, and so do `rateLimits.planType` and wham `plan_type`. The app-server also pushes `account/updated {authMode:"chatgpt", planType:"team"}` after the handshake.
- **verified** The plan-related claims in the `id_token` payload sit under the `https://api.openai.com/auth` namespace: `chatgpt_plan_type = "team"`, `chatgpt_subscription_active_start = 2026-04-27T03:20:00Z`, `chatgpt_subscription_active_until = 2027-04-27T03:20:00Z`, `chatgpt_subscription_last_checked = 2026-11-08T10:58:47Z`. The access token also has `chatgpt_plan_type`.
- **verified** The JWT is only as fresh as the last refresh (`last_refresh` 2026-11-08), so app-server is better.
- **verified** The `PlanType` enum is `free, go, plus, pro, prolite, promax, team, self_serve_business_prolite, self_serve_business_usage_based, business, ent26, enterprise_cbp_automation, enterprise_cbp_usage_based, enterprise, edu, edu_plus, edu_pro, sci, sci_plus, unknown`.

**4. Multiple profiles.**
- **verified** With `CODEX_HOME=<empty dir>`, `initialize` echoes `codexHome` = that dir. `account/read` returns `{account:null, requiresOpenaiAuth:true}`, and rate limits fail with `-32600 "codex account authentication required to read rate limits"`. `codex login status` says "Not logged in". So auth and config are isolated per `CODEX_HOME`.
- **verified** `-p/--profile` only layers `$CODEX_HOME/<name>.config.toml` over the config. Profiles share one login, so they are not separate subscriptions.

**5. Version source.**
- **verified** The binary resolves to `/opt/homebrew/Caskroom/codex/0.167.2/bin/codex`, so this is a Homebrew **cask**. `formulae.brew.sh/api/formula/codex.json` returns 404: there is no formula.
- **verified** `version.json` is written by the interactive TUI's startup update check (`tui/src/updates.rs`, next to the cask, npm and GitHub URLs). Every session since 2026-11-01 came from T3 Code through app-server (`originator` in the rollout `session_meta`), so the TUI never ran and the file was never refreshed. Running `codex doctor` doesn't update it either. Don't use it.
- **verified** Live sources, all reporting 0.169.0 today:
  - `https://formulae.brew.sh/api/cask/codex.json` → `.version`. This is the URL Codex itself uses for brew installs; responses take about 50 ms.
  - `https://api.github.com/repos/openai/codex/releases/latest` → `.tag_name` `rust-v0.169.0`. Strip the `rust-v` prefix. `/releases` mostly lists `-alpha` prereleases, so use `/latest`. The unauthenticated limit is 60 requests/h/IP.
  - `https://registry.npmjs.org/@openai/codex/latest` → `.version`. That response is 3.5 KB; the full package document is huge because of hundreds of dist-tags.
- **verified** `brew info --json=v2 codex` reported `0.167.2, outdated:false` because its local API cache was stale. Don't use it unless you run `brew update` first.
- **verified** `codex doctor --json` gives `checks.installation.details."install context"`, `checks.updates.status.details."update action"` and `"latest version"`, but it takes about 8.5 s. Use it only for diagnostics.
- **verified** Installed version without spawning: `<package root>/codex-package.json` → `.version`, where the package root is the parent of `bin/`.
- **verified** A separate self-updating app-server daemon lives in `~/.codex/packages/app-server-daemon/current` (0.169.0 here). It is not the PATH CLI, so don't report it as the harness version.

| Install method | Detect from `realpath(which codex)` | Latest source | Update command (from binary strings) |
|---|---|---|---|
| Homebrew cask | contains `/Caskroom/codex/` | brew cask API | `brew upgrade --cask codex` |
| npm | contains `/node_modules/@openai/codex/`; launcher sets `CODEX_MANAGED_BY_NPM` | npm `/latest` | `npm install -g @openai/codex` |
| bun / pnpm / Vite+ | `~/.bun/…`, pnpm global dir; `CODEX_MANAGED_BY_{BUN,PNPM,VITE_PLUS}` | npm `/latest` | `bun install -g` / `pnpm add -g` / `vp install -g @openai/codex` |
| standalone | anything else that has `codex-package.json` | GitHub `/latest` | `CODEX_NON_INTERACTIVE=1` + `chatgpt.com/codex/install.sh` |

**inferred** `codex update` runs the matching action for each method, so it is the simplest single click-to-update command. It was not executed in this spike.

## Redacted schemas

```jsonc
// -> {"id":1,"method":"initialize","params":{"clientInfo":{"name":"harness-butler","title":"Harness Butler","version":"x"}}}
// <- {"id":1,"result":{"userAgent":"harness-butler/0.167.2 (Mac OS 27.2.0; arm64) …","codexHome":"/Users/…/.codex","platformFamily":"unix","platformOs":"macos"}}
// -> {"method":"initialized"}
// -> {"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}   // params optional
// <- {"id":2,"result":{
//   "accountId":"<redacted>","ordinaryUsageAllowed":true,"rateLimitUpsell":null,
//   "rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"planType":"team",
//     "primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1794925834},     // int %, epoch s
//     "secondary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1795159250},
//     "credits":{"hasCredits":false,"unlimited":false,"balance":null},
//     "individualLimit":null,"spendControlReached":false,"rateLimitReachedType":null},
//   "rateLimitsByLimitId":{"codex":{ /* same RateLimitSnapshot */ }},
//   "rateLimitResetCredits":{"availableCount":3,"credits":null}}}   // credits[] {id,resetType,status,grantedAt,expiresAt,title} without exclude flag
// -> {"id":3,"method":"account/read","params":{"refreshToken":false}}
// <- {"id":3,"result":{"account":{"type":"chatgpt","email":"<redacted>","planType":"team","workspaceName":"<redacted>"},
//      "requiresOpenaiAuth":true,"workspaceRouting":{"chatgptAccountId":"<redacted>","backendOrigin":"https://chatgpt.com","accountRoutingOverride":"NO_CONSTRAINT"}}}
// -> {"id":4,"method":"account/usage/read"}
// <- {"id":4,"result":{"summary":{"lifetimeTokens":N,"peakDailyTokens":N,"longestRunningTurnSec":N,"currentStreakDays":N,"longestStreakDays":N},
//      "dailyUsageBuckets":[{"startDate":"2026-11-16","tokens":N}, …],"threadUsage":null}}   // backed by wham/profiles/me
// Error shapes: {"id":n,"error":{"code":-32603,"message":"failed to fetch codex rate limits: …"}} (network)
//               {"id":n,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}} (logged out)

// GET https://chatgpt.com/backend-api/wham/usage   (Authorization: Bearer …, optional chatgpt-account-id)
{"user_id":"<redacted>","account_id":"<redacted>","email":"<redacted>","plan_type":"team",
 "rate_limit":{"allowed":true,"limit_reached":false,
   "primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":121,"reset_at":1794925834},
   "secondary_window":{"used_percent":8,"limit_window_seconds":604800,"reset_after_seconds":233537,"reset_at":1795159250}},
 "code_review_rate_limit":null,"additional_rate_limits":null,
 "model_usage":{"<model>":{"available":true,"available_at":null,"credits_would_enable":false}},
 "credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":null,"approx_local_messages":null,"approx_cloud_messages":null},
 "spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null,
 "rate_limit_reset_credits":{"available_count":3,"applicable_available_count":0}}
```

## Recommendation for the Swift adapter

- **Live source: `codex app-server` → `account/rateLimits/read`.** Run one spawn per `CODEX_HOME`: `Process` with `CODEX_HOME` set, executable = the resolved PATH `codex`. Codex owns token refresh and Keychain storage, which satisfies the §5.1 rule. Don't use direct wham HTTP. Keep it only as a documented emergency fallback that reads but never refreshes.
- **Process lifecycle: spawn per refresh, not long-lived.**
  - Each refresh runs `initialize` → `initialized` → `account/rateLimits/read {excludeResetCreditDetails:true}` → `SIGTERM`, then `SIGKILL` after 2 s. Set a 10 s overall timeout.
  - The whole cycle takes about 1 s, and memory goes back to zero instead of 90 MB held per profile.
  - Call `account/read` only on add-profile and about once a day, to get the plan and confirm login.
  - Serialise refreshes per profile and kill children when the app quits.
  - Don't rely on `account/rateLimits/updated`: our process runs no turns, so it is unlikely to fire (inferred).
- **Polling cadence.**
  - Every 5 min in the background.
  - On popover open, if the data is more than 60 s old.
  - Right after a window's `resetsAt` passes.
  - Exponential backoff to 30 min on errors.
  - Pause when the Mac sleeps or the network is unreachable (`NWPathMonitor`).
- **Passive fallback and merge.**
  - Watch `$CODEX_HOME/sessions/**/rollout-*.jsonl` with FSEvents and take the newest `token_count.rate_limits`. This is free fresh data while the user works in Codex.
  - Show whichever snapshot is newer, with a "last updated" time.
  - If a window's `resets_at` is already in the past, show it as reset (0% used, next reset unknown) rather than the stale %.
- **Error mapping.**
  - `-32600 … authentication required` → *signed out*: "run `codex login`".
  - `-32603` that mentions a URL → *offline/stale*: use passive data.
  - Spawn failure → *harness missing*.
- **Model.** Drive the UI from `windowDurationMins` (300 / 10080), not from field names. Iterate `rateLimitsByLimitId` to pick up extra buckets. Use `planType` for the badge. Decode with optional fields everywhere.
- **Versions.** Installed version: `codex-package.json` next to the resolved `bin/`, falling back to `codex --version`. Latest version: pick by install method from the table above, cached for 6 h. Update: run `codex update`, or the per-method command, behind the click.
- **Requirements deltas** (§5.1 and §5.2):
  - Set Codex active confidence to High (verified).
  - Change the brew update command to `brew upgrade --cask codex`.
  - The brew latest source is `formulae.brew.sh/api/cask/codex.json`, not `brew info`.
  - Mark `version.json` as unreliable.
  - Optional extras: a reset-credit count (`availableCount`) and daily token buckets (`account/usage/read`).

## Remaining risks

- `app-server` is labelled experimental and wham is undocumented, so fields may move. Use tolerant decoding and capture `generate-json-schema` output in CI fixtures per Codex version.
- The token-expiry refresh path was not observed. Re-test after 2026-11-18 11:00Z and confirm that app-server refreshes cleanly while the user's CLI or daemon is also running, without a logout from refresh-token rotation.
- Each spawn writes into `CODEX_HOME` (the SQLite DBs, `installation_id`). If the user points us at a new, empty `CODEX_HOME`, it gets populated.
- Behaviour with multiple workspaces (`chatgpt-account-id` routing, `accountRoutingOverride`) and with API-key or Bedrock logins (`account.type != chatgpt`, likely no rate limits) is untested.
- GitHub's unauthenticated limit of 60 requests/h is shared per IP. Prefer the cask and npm endpoints, and cache with ETag.
- Install-method detection for npm, bun, pnpm and standalone comes from binary strings, not from real installs.
