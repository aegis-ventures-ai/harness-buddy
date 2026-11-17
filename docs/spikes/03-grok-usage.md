# Spike 03: Grok Build plan usage and version source

Date: 2026-11-17 · Grok Build 1.0.88 (`grok 1.0.88 (2fe3608f7398) [stable]`, self-installer, `~/.grok/bin/grok`) · Plan: SuperGrok

## Questions

1. What is the leader? How is it started headlessly? Does `grok usage --json` work once one is running?
2. What shape does plan usage have (windows, percentages, reset times, plan name)? Does headless or ACP mode expose it?
3. Which HTTP endpoint serves plan usage, and what does it return?
4. Can the app point Grok at a different home or auth directory (profiles)?
5. Where does the latest version come from, how fresh is `~/.grok/version.json`, and what is the update command?
6. How can the app count active Grok sessions?

## Findings

**1. Leader and `grok usage`**
- **Verified.** The leader is Grok's "background service", a shared process that TUI and IDE windows can join. It keeps runs alive after a window quits and hosts the relay and Cursor worker. Its default socket is `~/.grok/leader.sock`. Custom sockets named `~/.grok/leader-*.sock` show up in `grok leader list`. Before the spike, `grok leader list` printed "No background service processes found" and `pgrep grok` found nothing.
- **Verified.** You can start one headlessly with `grok agent leader`. I started mine with `--leader-socket ~/.grok/leader-spike.sock --no-auto-update --relay-on-demand` and stopped it with SIGTERM to its PID, never with `grok leader kill`, which stops every leader. An earlier try with a socket in the scratch directory failed with `path must be shorter than SUN_LEN` because the path was longer than 104 bytes.
- **Verified.** `grok usage --json --leader-socket <running leader>` still exits 1 with "`grok usage` can't show your plan's usage here yet". The debug log is empty because the CLI refuses before doing anything.
- **Verified** from the docs embedded in the binary: Grok has two internal modes, the "shell route" and the "daemon route". `grok usage` with no session ID only works on the daemon route. On the shell route it refuses "without reading your account". This account is on the shell route: in the signed settings cache, `leader_mode` is `false` and `[cli] use_leader` is unset. The `GROK_CONFIG` overlay cannot set `[cli]`, because its allowlist only covers `models`, `features`, `toolset` and similar.
- **Inferred.** The daemon route depends on xAI's server-side rollout or user config, so the app can't rely on `grok usage` today.
- **Side effect.** Stopping my leader removed its socket but left an empty `~/.grok/leader-spike.lock`. Because of that, `grok leader list` now shows `PID ? (Stale)`. I didn't delete it because of the rule against editing files in ~/.grok. The user can run `rm ~/.grok/leader-spike.lock` to clear it.

**2. Plan usage over ACP: this is the way in**
- **Verified.** `grok agent stdio` answers the extension method **`_x.ai/billing`** with params `{}` right after `initialize`. It needs no leader, no `session/new` and no prompt. Calling it without the leading underscore returns `-32601 Method not found`. A full spawn, initialize, call and exit takes **about 1.6 s wall time** and peaks at about 150 MB RSS in a short-lived process.
- **Verified.** The response has one **weekly** window (`USAGE_PERIOD_TYPE_WEEKLY`), `creditUsagePercent` (2.0 here), period `start` and `end` (the reset), and `subscription_tier` (`"SuperGrok"`). The TUI's strings ("You hit your weekly limit", "credit limit", "Pay as you go") match a weekly credit pool, not a 5-hour window.
- **Verified.** The debug log shows `xai_grok_shell::extensions::billing: handling billing config request`. Grok refreshes its own token in this path, which fits the §5.1 rule that the app never refreshes tokens itself.
- **Verified.** Spawning grok has side effects. By default it sends grok's own Mixpanel telemetry. With `GROK_TELEMETRY_ENABLED=0 GROK_TELEMETRY_MIXPANEL_ENABLED=false` set, the log shows `telemetry=false (env)` and no Mixpanel lines. Launches also rewrite grok's caches (`models_cache.json`, `version.json`, `bundled/`). They list MCP servers but don't start them.

**3. Direct HTTP**
- **Verified** (2 calls). `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with just `Authorization: Bearer <key>` returns HTTP 200 JSON. The CLI also sends `x-grok-client-version` and `x-grok-client-mode`, but they aren't needed. The response adds `productUsage[]` and `topUpMethod`, but it has **no plan name**. A related endpoint, `/auto-topup-rule`, exists in the binary but I didn't call it.
- **Verified.** The README's auth path `."https://accounts.x.ai/sign-in".key` is out of date. The current entry key is `https://auth.x.ai::<oauth-client-id>` with `auth_mode: "oidc"`, a `refresh_token`, and `expires_at` **6 h** after `create_time`, not the README's 7 days. Direct HTTP therefore goes stale within 6 h whenever grok isn't running, and the app must never use the refresh token.

**4. Profiles**
- **Verified.** `GROK_HOME` (documented in the README's Environment Variables section) relocates the home directory. `GROK_HOME=<scratch> grok update --check` wrote `version.json`, `logs/` and `docs/` there.
- **Inferred.** `auth.json`, `config.toml`, `active_sessions.json` and `leader.sock` follow `GROK_HOME`. `GROK_LEADER_SOCKET` and `--leader-socket` override only the socket. `GROK_CONFIG_PATH` is an extra overlay, not a separate profile.

**5. Version source**
- **Verified.** `GET https://x.ai/cli/stable` returns plain text `1.0.88` without authentication. It sends `no-cache`, an ETag and `Last-Modified`. `/alpha` and `/enterprise` work the same way. The fallback is `https://storage.googleapis.com/grok-build-public-artifacts/cli/<channel>`. `install.sh` reads this channel pointer, and the channel comes from `[cli] channel`, with stable as the default.
- **Verified.** `grok update --check --json` checks without installing, but it also writes `version.json`, so I ran it only under a scratch `GROK_HOME`.
- **Verified.** Grok rewrites `~/.grok/version.json` when it launches: `checked_at` moved to 14:27:28Z when I started `grok agent stdio`. The check is throttled, though: another launch two minutes later didn't rewrite it. So the file is only as fresh as the user's last grok launch.
- **Update command:** `grok update`, or `grok update --version X.Y.Z`. The binary also knows Homebrew and npm (`@xai-official/grok`) installs and tells those users to update through their package manager.

**6. Active sessions**
- **Verified** (shape only). `~/.grok/active_sessions.json` is a JSON array. It currently holds `[]` and was last modified on Nov 7. Each entry is a `struct ActiveSession` with fields `session_id`, `pid`, `pid_start`, `cwd` and `opened_at`. Writes are guarded by `active_sessions.lock`, and grok repairs a corrupt file into `active_sessions.json.corrupt`.
- **Inferred.** Count an entry as live only if its `pid` is alive and its start time matches `pid_start`, which guards against PID reuse. The type of `pid_start` is unconfirmed. Initializing ACP without a session didn't register an entry.

## Redacted schemas

```jsonc
// ACP: {"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}} → result
{ "config": { "creditUsagePercent": 2.0,                     // 0–100, used
    "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
                       "start": "2026-11-12T09:15:07.330+00:00", "end": "2026-11-19T09:15:07.330+00:00" },
    "prepaidBalance": { "val": 0 },                          // unit unknown
    "isUnifiedBillingUser": true,
    "billingPeriodStart": "<iso8601>", "billingPeriodEnd": "<iso8601>" },
  "subscription_tier": "SuperGrok" }
// Optional fields in the binary's structs: monthlyLimit, onDemandCap, onDemandUsed,
// history[{billingCycle{month}, includedUsed, totalUsed}], on_demand_enabled.
// Tier strings: supergrok_lite | supergrok | supergrok_plus | supergrok_heavy | x_premium* | api_key
// Error (inferred): "Billing data requires auth with grok.com. Run `grok login` to authenticate."

// HTTP: GET cli-chat-proxy.grok.com/v1/billing?format=credits → same config object plus:
//   "productUsage": [{ "product": "GrokBuild", "usagePercent": 2.0 }], "topUpMethod": "TOP_UP_METHOD_…"
// grok update --check --json
{ "currentVersion": "1.0.88", "latestVersion": "1.0.88", "updateAvailable": false,
  "installer": "internal", "channel": "stable", "autoUpdate": null, "error": null }
// ~/.grok/version.json
{ "version": "1.0.88", "stable_version": "1.0.88", "checked_at": "2026-11-17T14:27:28.354134Z" }
// ~/.grok/active_sessions.json
[ { "session_id": "<uuid>", "pid": 0, "pid_start": "<?>", "cwd": "<path>", "opened_at": "<time>" } ]
// ~/.grok/auth.json (read nothing beyond key/expires_at, and only if using the HTTP path)
{ "https://auth.x.ai::<oauth-client-id>": { "key": "<redacted>", "auth_mode": "oidc", "expires_at": "<iso8601>",
    "refresh_token": "<never touch>", "…identity fields…": "<redacted>" } }
```

## Recommendation for the Swift adapter

`GrokACPUsageProvider` replaces `GrokLeaderUsageProvider`:
1. Resolve the binary in this order: `$GROK_HOME/bin/grok`, `~/.grok/bin/grok`, then `PATH` (Homebrew).
2. Launch `grok agent stdio` with `Process`, using an empty app-owned temp directory as `cwd` so no project config or hooks load. Set `GROK_HOME` per profile, plus `GROK_TELEMETRY_ENABLED=0`, `GROK_TELEMETRY_MIXPANEL_ENABLED=false` and `GROK_DISABLE_AUTOUPDATER=1`.
3. Talk newline-delimited JSON-RPC: send `initialize` (`protocolVersion: 1`, no fs or terminal capabilities), then `_x.ai/billing` with `{}`. Ignore notifications. Close stdin, and SIGTERM after a 10 s timeout. Never send `session/new`.
4. Map the result to one **Weekly** window: `usedPercent = creditUsagePercent`, `windowStart = currentPeriod.start` (for pace and at-risk), `resetsAt = currentPeriod.end`, `planName = subscription_tier`.
5. Poll every 10–15 min. The window is weekly, and each poll costs about 1.6 s and a short-lived 150 MB process. Also refresh when the popover opens if the data is more than 5 min old.
6. Optional: when the documented `grok usage --json` starts exiting 0 (once this account is on the daemon route), log its output and switch over to it.
7. Don't use the direct HTTP endpoint as the main path, because the token expires after 6 h. If it's ever needed, call it only while `expires_at` is more than 5 min away, and never refresh.

**Versions:** poll `https://x.ai/cli/<channel>` for the latest version and run `grok --version` for the installed one. Use `version.json` only as a hint. Run `grok update` only after a user click.

**Fallback UX:** keep showing the last good bar with its age, and show a row state:
- Not signed in: "Run `grok login`".
- Method not found or unexpected JSON: "Grok usage unavailable in this version. Run `/usage` in grok", with an Open Terminal button.
- Team-metered: "Usage managed by your team".

## Remaining risks

- `_x.ai/billing` is an undocumented internal ACP extension and could change or disappear in any weekly release. Mitigations: parse tolerantly, detect "method not found", and use the fallback UX above.
- Only one SuperGrok account has been tested. Heavy, Lite, team and enterprise plans might use other `USAGE_PERIOD_TYPE_*` values or several `productUsage` entries. The unit of `prepaidBalance` is unknown.
- Every poll spawns grok, which rewrites grok's caches and, if the env vars stop working, sends telemetry.
- Concurrent token refresh between the app's ACP process and a running TUI relies on grok's own `auth.json.lock`. That looked safe here but wasn't stress-tested.
- `active_sessions.json` liveness and the format of `pid_start` haven't been checked against a live session.
- **Requirements changes:**
  - §5.1 Grok: confidence goes from Low to Medium, with the source "ACP `_x.ai/billing`, weekly window".
  - §5.2: the latest-version source becomes `x.ai/cli/<channel>`.
  - §7: rename the provider to `GrokACPUsageProvider`.
  - §8: Grok usage can move from M4 to M1.
  - §9: the Grok risk shrinks to "undocumented ACP method".
