# Spike 01 — Claude Code subscription usage & version source

Run 2026-11-17 on macOS 27 (Darwin 27.2) against Claude Code **2.1.326** (native install, `~/.local/bin/claude`).
Evidence comes from `strings` on the Bun-compiled binary (minified JS is embedded verbatim), Keychain *attribute*
listings, and live HTTP calls (2 real-token calls, 3 bogus/no-auth calls). No secrets, emails, IDs or names recorded.

## Questions

1. How is the Keychain item named when `CLAUDE_CONFIG_DIR` is non-default?
2. What is the credential JSON shape, and can a separately signed Swift app read it without a prompt?
3. What does `GET /api/oauth/usage` return, which headers are required, and what does a bad token return?
4. Where does the plan tier come from?
5. Where do `settings.json` and the global `.claude.json` live under `CLAUDE_CONFIG_DIR`?
6. What does `claude update` use as its latest-version source, and is it public?

## Findings

**1. Keychain naming — verified.** From the bundled JS (function that builds the service name):
```js
f5(n=""){ let e=env.CLAUDE_SECURESTORAGE_CONFIG_DIR, t = e!==undefined ? !e : !env.CLAUDE_CONFIG_DIR,
  r = e!==undefined ? e.normalize("NFC") : Ye(),          // Ye() = (CLAUDE_CONFIG_DIR ?? join(homedir(),".claude")).normalize("NFC")
  a = t ? "" : `-${sha256(r).hex.substring(0,8)}`;
  return `Claude Code${OAUTH_FILE_SUFFIX}${n}${a}` }       // called as f5("-credentials"); OAUTH_FILE_SUFFIX is "" in prod
```
- **Rule:** service = `Claude Code-credentials` if `CLAUDE_CONFIG_DIR` is unset or empty; otherwise
  `Claude Code-credentials-` + first 8 lowercase hex chars of `sha256(UTF-8(NFC(CLAUDE_CONFIG_DIR)))`.
  `CLAUDE_SECURESTORAGE_CONFIG_DIR`, if set, overrides the hashed path. Non-prod builds insert `-staging-oauth`,
  `-local-oauth` or `-custom-oauth` before `-credentials`.
- **Account** (`acct`) = `$USER`, falling back to `os.userInfo().username`, or `claude-code-user` if it has chars outside `[a-zA-Z0-9._-]`.
- **The path is hashed raw:** no `~` expansion, no trailing-slash trim, no realpath. On this Mac,
  `sha256("/Users/<user>/.claude_personal")[:8] = 5f272631`, which matches an existing item `Claude Code-credentials-5f272631`. The same path with a trailing `/` hashes to `d5ab91fa`, with no item. Setting `CLAUDE_CONFIG_DIR=~/.claude` *explicitly* gives `-2e9a8162`, a different item from the default.
- 21 suffixed items exist here. Most are orphans (old or temp config dirs), and the hash can't be reversed, so the app must start from known config dirs and hash forwards.
- Plaintext fallback: when the Keychain write fails, creds go to `<configDir>/.credentials.json`. Neither dir has that file here.

**2. Credential shape — verified.** Top-level `{ claudeAiOauth, mcpOAuth }`.
- `claudeAiOauth`: `accessToken` str (`sk-ant-oat01-…`, 108 chars), `refreshToken` str (`sk-ant-ort01-…`),
  `expiresAt` int (**epoch ms**; ~3 h left when read), `refreshTokenExpiresAt` int (ms), `scopes` [str]
  (`user:inference`, `user:profile`, `user:sessions:claude_code`, `user:mcp_servers`, `user:plugins`, `user:file_upload`),
  `subscriptionType` str (`enterprise` / `max`), `subscriptionTypeSource` str (`sign_in`), `rateLimitTier` str
  (`default_claude_max_5x` / `default_claude_max_20x`).
- `mcpOAuth`: a map keyed `"plugin:<plugin>:<server>|<hash>"`. Each entry holds **third-party MCP OAuth tokens**
  (`accessToken`, sometimes `refreshToken`, `clientId`, `expiresAt`, `scope`…). The blob holds far more than the Claude token.
- **Prompt behaviour — verified.** `security find-generic-password -a "$USER" -w -s <svc>` returns at once with no GUI.
  ACL (`dump-keychain -a`): `decrypt` is granted only to `/usr/bin/security` (`identifier "com.apple.security" and anchor apple`), with `partition_id` = `apple-tool:`. Claude Code itself reads and writes only by spawning `security` (`add-generic-password -U … -X <hex>`), so the ACL stays that way.
- **Separately signed Swift app — verified for direct API.** An ad-hoc-signed Swift binary using `SecItemCopyMatching`
  with UI disabled can **enumerate attributes** (status 0, all 21 items) but **cannot read data** (`-25293`). With UI allowed this would be a Keychain prompt. Because the partition list is `apple-tool:` only, "Always Allow" would also need the login-keychain password (inferred), and that is fragile across updates. Spawning `/usr/bin/security` from the app is the path that needs no prompt. It is verified from a non-Apple parent process; *inferred* not to work under App Sandbox.

**3. Usage endpoint — verified.** `GET https://api.anthropic.com/api/oauth/usage`, `Authorization: Bearer <accessToken>` → `200 application/json`, about 0.5 s.
- The `anthropic-beta: oauth-2025-04-20` header is **not required today** (200 without it). Send it anyway: the CLI defines that constant for OAuth.
- Response headers include `anthropic-organization-id` and `request-id`. **Never log response headers.**
- The CLI also uses `?skip_spend=1`, `?at_wall=1`, `?cedar_ember=1`. Plain GET is the full read.
- The CLI remembers a 429/403 per bearer for `retry-after` (else a default) and stops asking until then. A 401 is treated as `auth_rejected` and triggers its own refresh.
- Bogus token (with or without beta) → `401 {"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."},"request_id":"req_…"}`.
- No auth header → `401 authentication_error "x-api-key header is required"`.
- Expired token: *inferred* to be a 401 with message `OAuth token has expired` and/or error code `token_expired` (both strings appear in the CLI's 401 handling). Not tested: no real expired token was sent.
- Semantics, from docs bundled in the CLI: `utilization`/`percent` are whole percents 0–100 and **can go above 100**. `resets_at` is ISO 8601 UTC. Money is in minor units (cents). The live response sends `utilization` as a float (`4.0`).

**4. Plan tier — verified.** The usage response has **no plan field**. Sources:
- Keychain `claudeAiOauth.subscriptionType` (`pro|max|team|enterprise`) and `rateLimitTier`.
- `<global .claude.json>.oauthAccount`: `organizationType` (`claude_max`, `claude_enterprise`), `seatTier` (`enterprise_tier_1`),
  `organizationRateLimitTier`, `userRateLimitTier`, `billingType`, and on the Max account `planDisplayName`.
  The CLI renders the label as `Claude ${planDisplayName}`, falling back to `Claude Max/Pro/Team/Enterprise` from `subscriptionType`.
  The same object also holds email, name and org fields: read only the keys you need.
- Multiplier: `default_claude_max_5x` → "Max 5×", `default_claude_max_20x` → "Max 20×".

**5. Config locations — verified.** User settings = `join(Ye(), "settings.json")`, i.e. `$CLAUDE_CONFIG_DIR/settings.json`
(`cowork_settings.json` if `CLAUDE_CODE_USE_COWORK_PLUGINS`). Global config = `join(CLAUDE_CONFIG_DIR || homedir, ".claude.json")`.
So **with `CLAUDE_CONFIG_DIR` set, `.claude.json` (holding `mcpServers`) moves inside that dir.** Confirmed on disk at `~/.claude_personal/.claude.json`.
Without it, the file stays at `~/.claude.json` (not `~/.claude/.claude.json`).

**5b. Bonus passive source — verified.** Each global `.claude.json` has `cachedUsageUtilization = { fetchedAtMs, accountUuid, utilization: <full usage response> }`,
written by the CLI. It was 6 minutes old for both accounts when checked. This gives usage with no Keychain or network access while the CLI is in use.

**6. Latest version — verified.** The native updater does `GET https://downloads.claude.ai/claude-code-releases/<channel>` → `text/plain`
version (3 retries, 30 s timeout). **No auth needed**: `latest` → `2.1.326`, `stable` → `2.1.311`. Channel = settings
`autoUpdatesChannel` (`latest|stable|rc`; unset = `latest`). Per-version `…/<ver>/manifest.json` (public) has
`platforms["darwin-arm64"].{binary,checksum,size}`. Homebrew installs track `formulae.brew.sh/api/cask/claude-code[@latest].json` instead.
Respect `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` (the CLI skips the lookup).

## Response schema (redacted example, trimmed)

```jsonc
{
  "five_hour":  { "utilization": 4.0,  "resets_at": "2026-11-17T18:49:59.828031+00:00",
                  "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null },
  "seven_day":  { "utilization": 17.0, "resets_at": "2026-11-20T16:59:59.828057+00:00", "...": "same shape" },
  "seven_day_opus": null, "seven_day_sonnet": null, "seven_day_oauth_apps": null, "seven_day_cowork": null,
  // + ~20 more codenamed keys (tangelo, iguana_necktie, amber_gauge, pace, indicator, ...) all null here: ignore unknowns
  "extra_usage": { "is_enabled": true, "monthly_limit": 20000, "used_credits": 0.0, "utilization": null, "currency": "USD",
                   "decimal_places": 2, "disabled_reason": null, "user_disabled": false, "spend_limit_reached": false,
                   "credits_ever_enabled": true, "daily": null, "weekly": null },
  "limits": [   // generic, forward-compatible rows: prefer these over the fixed keys
    { "kind": "session",       "group": "session", "percent": 4,  "severity": "normal", "resets_at": "…", "scope": null, "is_active": false },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 17, "severity": "normal", "resets_at": "…", "scope": null, "is_active": true },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 0,  "severity": "normal", "resets_at": "…",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
  ],
  "spend": { "used": {"amount_minor":0,"currency":"USD","exponent":2}, "limit": {"amount_minor":20000,"currency":"USD","exponent":2},
             "percent": 0, "severity": "normal", "enabled": true, "cap": {"money": null, "credits": {"amount_minor":20000,"exponent":2}},
             "balance": null, "auto_reload": null, "disclaimer": "…", "can_purchase_credits": false, "can_toggle": false },
  "member_dashboard_available": false, "seven_day_breakdown": null,
  "weekly_scoped_shares": [ { "limit_index": 2, "used_percent_of_weekly": 0, "allowance_percent_of_weekly": 50 } ]
}
```

## Recommendation for `ClaudeOAuthUsageProvider`

1. **Discovery:** default dir `~/.claude`, plus user-added dirs (and optionally `~/.claude*` dirs that contain `.claude.json`).
   Store each dir **exactly as the user's shell exports it**. Show the computed service name in Settings so mismatches (trailing `/`, `~`) can be spotted.
2. **Passive first:** read `cachedUsageUtilization` from that dir's global `.claude.json`. If `fetchedAtMs` is newer than the poll interval, use it with no network call.
3. **Creds:** spawn `/usr/bin/security find-generic-password -a <user> -w -s <service>` via `Process`, 2 s timeout. Exit 44 = not logged in; 36 = keychain locked.
   Parse with `JSONSerialization`, keep only `claudeAiOauth.{accessToken,expiresAt,subscriptionType,rateLimitTier}` in memory, and zero or drop the rest (MCP tokens). Never cache the token on disk.
   Ship **non-sandboxed** (Hardened Runtime + notarization are fine). Fallback: `<dir>/.credentials.json` if present.
   Cheap change detection: attribute-only `SecItemCopyMatching` (no prompt) on `kSecAttrModificationDate`.
4. **Active poll:** default every **5 min** (the CLI's own gateway-usage cadence), at most once per 60 s on manual refresh, paused on sleep and backed off on battery.
   Send `Authorization`, `anthropic-beta: oauth-2025-04-20` and an honest `User-Agent` (`HarnessButler/<ver>`). On 429/403, honour `retry-after` (else 5 → 10 → 30 min).
5. **Stale handling:** if `expiresAt <= now + 60s`, don't call. Show last-good data with its age and "run `claude` to refresh".
   On 401, mark stale the same way and do not retry until the Keychain item's mdat changes. Never touch `refreshToken`.
6. **Model:** build rows from `limits[]` (`kind`, `group`, `percent`, `resets_at`, `scope.model.display_name`, `severity`). Fall back to `five_hour` and `seven_day`.
   Decode `utilization` as `Double`, allow values over 100, and ignore unknown keys. Show `extra_usage`/`spend` as an optional "usage credits" line.
7. **Plan label:** `oauthAccount.planDisplayName` → else `subscriptionType` (+ multiplier from `rateLimitTier`).
8. **Version:** `GET downloads.claude.ai/claude-code-releases/{autoUpdatesChannel ?? "latest"}` once every 6–12 h. Compare as semver.

## Remaining risks

- The endpoint is undocumented and fast-moving: around 20 codenamed fields, and Opus/Sonnet keys are now null in favour of `limits[]`. Decode defensively.
- The naming rule depends on the hash input matching the CLI's env value byte-for-byte. Launch agents, aliases and direnv may export a different form of the path than the user types.
- `security` CLI dependence: if Claude Code moves to a signed helper or Data Protection keychain, the ACL changes and reads will prompt. Re-check on each CLI update.
- Sandboxed distribution (e.g. Mac App Store) is likely incompatible with prompt-free reads (unverified).
- `CLAUDE_CODE_OAUTH_TOKEN` / `setup-token` users have no Keychain item: such a row shows "unsupported".
- The expired-token error body is unverified (inferred from CLI strings).
- `.claude.json` holds PII (email, names, org): the parser must read only the whitelisted keys and never log the file.
