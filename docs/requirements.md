# Harness Butler — Scope & Requirements (draft v0.4)

_Status: draft v0.4 · 2026-11-17 · M0 spike results folded in (see [`docs/spikes/`](spikes/))_

A native macOS menubar app that shows, at a glance, how much of each AI coding subscription you have left, tells you when your local CLI harnesses are out of date, and lets you edit their configuration without hand-editing JSON/TOML.

Mockups: [`docs/mockups/index.html`](mockups/index.html)

---

## 1. Decisions so far

| Topic | Decision |
|---|---|
| Name | **Harness Butler** |
| Platform | Native macOS, Swift + SwiftUI (`MenuBarExtra` window style), AppKit where needed |
| Audience | Personal / team-internal. Undocumented provider endpoints are acceptable; no App Store, no licensing |
| Multiple subscriptions | (a) multiple harness config dirs per provider (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, Grok home), and (b) API/Admin keys for org-level API spend |
| Config management | Curated settings UI for the common settings + raw editor fallback, with diff-before-save and backups. **User-level files only** |
| Subscription naming | **User-defined free-text name** per subscription; no presets (no built-in "personal"/"work"); **must be unique** |
| Menubar default | **Percent mode** (glyph + % left per pinned subscription); **every** pinned subscription is shown, never truncated |
| xAI scope | **Grok Build subscription only**; no xAI API spend tracking |
| Harness updates | **Click-to-update only**; never unattended |
| Minimum OS | **macOS 27** |

## 2. Glossary

- **Provider** — the vendor: Anthropic, OpenAI, xAI.
- **Harness** — the local CLI agent: Claude Code (`claude`), Codex (`codex`), Grok Build (`grok`).
- **Subscription** — one tracked account. Either a *harness login* (bound to a config dir) or an *API key* (org spend/usage). A provider can have many. Each has a **name** the user chooses (e.g. "Acme Claude", "Side projects").
- **Usage window** — a rate-limit bucket with a reset time (e.g. Claude 5-hour session, weekly all-models, weekly Opus; Codex primary 5h / secondary 7d).
- **At risk** — a usage window whose linear projection runs out before it resets (see U-8). Low remaining % alone does not make a window at risk.
- **Pace** — usage vs. time elapsed in the window. "39% behind" = you've used 39 points less than a linear burn would predict (good). "12% ahead" = burning faster than the window allows (at risk).
- **Pinned** — a subscription the user chose to show in the menubar itself.

## 3. Goals / non-goals

**Goals (v1)**
1. Glanceable remaining-quota for every subscription, with pace and reset countdown.
2. Multiple subscriptions per provider, each independently pinnable to the menubar.
3. Detect outdated harness installs and update them in one click (using the harness's own install method).
4. Safe, curated editing of each harness's config files.
5. Zero secrets leave the machine except to the provider that issued them.

**Non-goals (v1)**
- Windows/Linux. Cloud sync of settings. Team dashboards / sharing usage with others.
- Running or proxying agent sessions. Billing management (upgrading plans, buying credits).
- Editing auth files or performing logins on the harness's behalf.
- Project-level harness config (`.claude/`, `.codex/`, `.grok/` inside repos) — user-level only.
- xAI API spend/usage tracking.
- Unattended / scheduled harness updates.

## 4. Functional requirements

Priority: **P0** = v1 must-have, **P1** = v1 if cheap / fast-follow, **P2** = later.

### 4.1 Subscriptions & usage

| ID | Requirement | Pri |
|---|---|---|
| U-1 | Auto-discover harness logins on first launch: default dirs (`~/.claude`, `~/.codex`, `~/.grok`) plus any extra dirs the user adds. | P0 |
| U-2 | Add/remove/rename subscriptions. Name is free text chosen by the user (required, defaults to the harness name, e.g. "Claude Code"); no preset categories. The name is the row title everywhere (popover, menubar tooltip, settings sidebar, notifications); detected plan tier is shown alongside it, not in place of it. Names **must be unique** across all subscriptions: compared case-insensitively after trimming whitespace; the Add / Rename action stays disabled with an inline error until the name is unique and non-empty. | P0 |
| U-3 | Add API subscriptions via Admin key (Anthropic Admin API, OpenAI org usage/costs). Keys stored in Keychain only. xAI is Grok Build login only. | P0 |
| U-4 | For each subscription show every usage window: % left, segmented bar, pace marker, pace delta, reset countdown. | P0 |
| U-5 | Show plan name/tier when available (e.g. "max 20×", "enterprise 5×", "team"). | P0 |
| U-6 | Show extra/overage usage or credits balance where the provider reports it. | P1 |
| U-7 | API subscriptions: month-to-date spend, optional user-set budget, daily run rate, projected month-end. | P0 |
| U-8 | Status grouping in the popover: **at risk**, **on track**, **limited** (0 left), **stale/error**. A window is *at risk* when its linear projection reaches 100% used before `resets_at`: `used% ÷ elapsed fraction ≥ 100`, i.e. you are ahead of pace. A subscription is at risk if any of its windows is. **Guard:** don't evaluate until 10% of the window has elapsed, so a burst right after a reset doesn't flag. API spend rows use the same rule against the budget and billing month when a budget is set. | P0 |
| U-9 | Detail view per subscription: all windows, 7-day history sparkline, source path, last refresh, harness version. | P0 |
| U-10 | Locally persisted usage history (SQLite) for sparklines and trends. | P1 |
| U-11 | Active session count per harness (from harness session/state files). | P1 |
| U-12 | Refresh cadence per source (from spikes): Claude and Codex every **5 min**; Grok every **10–15 min** (each poll spawns a short-lived `grok` process). On popover open, refresh any source older than 60 s (Grok: 5 min). Also refresh right after a window's reset time passes. Manual refresh is limited to once per 60 s per source. Honour `retry-after`, otherwise back off 5 → 10 → 30 min. Pause while asleep; back off on battery. | P0 |

### 4.2 Menubar

| ID | Requirement | Pri |
|---|---|---|
| M-1 | User selects which subscriptions are pinned to the menubar (0..n). **All** pinned subscriptions are shown, in a user-defined order (drag to reorder in Settings → Menubar); none are truncated or collapsed. Because macOS hides status items that don't fit (e.g. beside the notch), Settings shows the item's estimated width and warns when it gets wide. | P0 |
| M-2 | Display modes: **percent** (glyph + % left per pinned sub) — **default**; **worst-of** (single gauge for the most constrained pinned sub) and **mini bars** as options. | P0 (percent) / P1 (worst-of, mini bars) |
| M-6 | Hovering the menubar item shows a tooltip listing pinned subscriptions by name with % left and reset time. | P1 |
| M-3 | Colour encodes status (normal / at risk / limited); never colour-only — at-risk also gets a dot/glyph. | P0 |
| M-4 | Update-available badge dot on the menubar icon (toggleable). | P0 |
| M-5 | Left-click opens popover; right-click opens a small menu (Refresh, Settings…, Quit). | P0 |

### 4.3 Harness updates

| ID | Requirement | Pri |
|---|---|---|
| H-1 | Detect each harness binary on `PATH` and common locations; resolve version via `--version`. | P0 |
| H-2 | Detect install method (native installer, Homebrew, npm/pnpm/bun global, self-updater) so the update action matches. | P0 |
| H-3 | Check latest version from the authoritative source per method (see §5.2). Don't trust harness caches blindly (Codex's local `version.json` is stale on this machine: says latest 0.166.0 while 0.167.2 is installed). | P0 |
| H-4 | "Update" button runs the harness's own updater (`claude update`, `brew upgrade codex`, `grok update`, …) with streamed output and success/failure result. Updates only ever start from an explicit click; the app has no auto-update setting for harnesses. (A harness's *own* auto-update flag, e.g. Grok's `[cli] auto_update`, stays editable in its config page.) | P0 |
| H-5 | Show release notes / changelog excerpt for the pending version. | P1 |
| H-6 | Notification when an update becomes available (opt-in). | P1 |
| H-7 | Warn if an update would run while sessions are active. | P1 |

### 4.4 Configuration management

| ID | Requirement | Pri |
|---|---|---|
| C-1 | Settings window with a sidebar entry per harness, and per config dir ("profile") under it, labelled with the subscription name bound to that dir. | P0 |
| C-2 | Curated forms for common settings: default model, reasoning effort, approval/permission mode, permission allow/deny rules, env vars, auto-update flag. | P0 |
| C-3 | MCP servers: list, add, edit, enable/disable, remove (user scope) for all three harnesses. | P0 |
| C-4 | Raw editor tab for the underlying file with syntax validation. TOML validation must be **TOML 1.0-strict**: Codex rejects TOML 1.1, which our parser would otherwise accept. | P0 |
| C-5 | Every write: diff preview → mtime/hash check against load → timestamped backup → atomic write (temp file in same dir + rename, permissions preserved) → re-read to verify. One-click restore from backup. For `.claude.json`, take Claude Code's own `.claude.json.lock` directory lock and re-read under it. Symlinks: write through to the target and keep the link. Warn on hard links (a rename-based write breaks them). | P0 |
| C-6 | Preserve formatting/comments and unknown keys (round-trip safe). Implemented as an in-house span-based editor for TOML and JSON; every result is re-parsed by an independent parser, and edits it can't do safely fail loudly. Editing entries inside array tables (`[[…]]`, e.g. Grok `marketplace.sources`) is raw-editor-only in v1. | P0 |
| C-7 | Watch files for external changes; if a file changed under an open editor, block save and offer reload/merge. | P0 |
| C-8 | Read-only view of user-level hooks and plugins/skills. | P1 |
| C-11 | Scope is user-level files only; project-level config files are never read or written. | P0 |
| C-9 | Copy an MCP server definition from one harness to another. | P2 |
| C-10 | Never read or write auth/credential files except the minimum read needed for usage (§5.1). | P0 |
| C-12 | Backups are mode 0600 in a 0700 directory, because they can contain secrets from env blocks. | P0 |

### 4.5 Notifications (P1)

- Threshold alerts per subscription (default 80% and 95% used, per window).
- "Window reset" notification for limited subscriptions.
- Update available (see H-6).

## 5. Data sources & feasibility

Verified on this machine unless marked _(verify)_.

### 5.1 Usage

| Harness / source | Where the data comes from | Confidence |
|---|---|---|
| Claude Code (subscription) | **Passive:** `cachedUsageUtilization` (+ `fetchedAtMs`) in that dir's `.claude.json`, which the CLI keeps fresh while running. No Keychain or network access needed. **Active:** read the OAuth token by spawning `/usr/bin/security find-generic-password` (only `security` is on the item's ACL, so a direct Keychain API call would prompt). Then call the undocumented `GET api.anthropic.com/api/oauth/usage`, using its generic `limits[]` array plus `extra_usage`/`spend`. Keychain service is `Claude Code-credentials` for the default dir; with `CLAUDE_CONFIG_DIR` set, it is `Claude Code-credentials-` + the first 8 hex of sha256(path as given), account `$USER`. Plan comes from creds `subscriptionType`/`rateLimitTier`. | High (passive) / Medium (active, undocumented) |
| Codex (subscription) | **Active:** spawn `codex app-server` (stdio JSON-RPC) per refresh, `initialize`, then `account/rateLimits/read` (5h + 7d windows, credits) and `account/read` (plan). Takes about 1 s; Codex handles its own token refresh, so the app never touches tokens. Kill the process afterwards; it peaks around 90 MB. **Passive fallback:** the latest `rate_limits` event in `$CODEX_HOME/sessions/**/rollout-*.jsonl`. Don't call `wham/usage` directly. `CODEX_HOME` = one subscription; `-p` profiles share a login. | High |
| Grok Build (subscription) | Spawn `grok agent stdio` (ACP), `initialize`, then call the undocumented `_x.ai/billing` method → one **weekly** window (% used, period start/end) + plan name. Takes about 1.6 s; Grok refreshes its own token. Set `GROK_TELEMETRY_ENABLED=0` and `GROK_TELEMETRY_MIXPANEL_ENABLED=false`. `grok usage --json` fails for this account even with a leader running. The direct HTTP billing endpoint is a last resort, because the `auth.json` token lives only 6 h. `GROK_HOME` = one subscription. | Medium — undocumented ACP method |
| Anthropic API | Admin API usage & cost reports (`sk-ant-admin…` key). | High — documented |
| OpenAI API | Organization usage + costs endpoints (admin key). | High — documented |

**Token-handling rule:** the app **never refreshes** harness OAuth tokens itself. For Codex and Grok the harness process the app spawns refreshes its own tokens, which is allowed because the harness does it under its own locks. Refresh tokens rotate; refreshing out-of-band can silently log the CLI out. If the access token is expired, mark the subscription *stale* with "run `claude` to refresh" (or trigger the harness's own non-interactive refresh if one exists).

### 5.2 Versions

| Harness | Installed (here) | Install method (here) | Latest-version source | Update command |
|---|---|---|---|---|
| Claude Code | 2.1.326 | native (`~/.local/bin/claude`) | `https://downloads.claude.ai/claude-code-releases/{latest,stable}` (plain text, no auth); npm dist-tags for npm installs | `claude update` |
| Codex | 0.167.2 (0.169.0 available) | Homebrew **cask** (resolved path contains `/Caskroom/codex/`) | `formulae.brew.sh/api/cask/codex.json` for cask installs; `registry.npmjs.org/@openai/codex/latest` for npm. Local `version.json` and `brew info` are both stale; don't use them. | `brew upgrade --cask codex` / `npm i -g @openai/codex` |
| Grok Build | 1.0.88 | self-installer (`~/.grok/bin/grok`) | `https://x.ai/cli/{stable,alpha,enterprise}` (plain text, no auth). `version.json` is a hint only. | `grok update` |

### 5.3 Config files (v1 targets)

| Harness | Files | Notes |
|---|---|---|
| Claude Code | `~/.claude/settings.json` (model, permissions, env, hooks, plugins, outputStyle); `~/.claude.json` (user-scope MCP servers). With `CLAUDE_CONFIG_DIR` set, **both** live inside that dir. | `.claude.json` is also live CLI state that the CLI rewrites whole under a `.claude.json.lock` dir lock. Take the same lock and merge-write only `mcpServers`. It also contains identity fields; read only the keys we need. |
| Codex | `$CODEX_HOME/config.toml` (model, reasoning effort, approval policy, sandbox, `[mcp_servers.*]`, `[profiles.*]`) | Format-preserving TOML editing; TOML 1.0-strict validation. |
| Grok Build | `~/.grok/config.toml` (`[cli] auto_update`, `[ui]`, model, MCP servers) | Same TOML requirement; `grok inspect` can show effective config. |

## 6. Non-functional requirements

- **Footprint:** <40 MB RAM idle, negligible CPU; no background polling when the Mac is asleep / on low-power, back off further on battery.
- **Privacy:** no telemetry. Network calls only to providers and version sources. Admin keys in Keychain. Usage history stored locally only.
- **Safety:** read-only by default for everything except explicit config saves and update actions. Backups kept for 30 days.
- **Resilience:** one provider failing never blanks the others; each row shows its own error state and last-good data with age.
- **Appearance:** follows system light/dark; monospace, terminal-inspired look (see mockups); full VoiceOver labels for bars ("Claude Code work, weekly all models, 84 percent left, resets in 3 days").
- **Distribution:** **non-sandboxed** app (Developer ID, Hardened Runtime, notarized). The sandbox would block spawning `/usr/bin/security` and the harness CLIs, and reading their home dirs. Signed DMG via GitHub Releases for the team; Sparkle for self-update (P1).
- **Child processes:** every spawned harness process (`codex app-server`, `grok agent stdio`, `security`) has a timeout, is killed after use, and never outlives the app.
- **Minimum OS:** macOS 27. No back-deployment shims; use current SwiftUI, Observation, and Swift concurrency APIs freely, and adopt the current system design language for materials and controls.

## 7. Architecture sketch

```
HarnessButlerApp (SwiftUI MenuBarExtra + Settings scene)
├── UsageStore (@Observable) ── Poller (per-subscription schedule, backoff)
│     └── UsageProvider protocol
│           ├── ClaudeUsageProvider        (.claude.json cache → security + /api/oauth/usage)
│           ├── CodexAppServerUsageProvider (app-server rateLimits → rollout jsonl fallback)
│           ├── GrokACPUsageProvider       (grok agent stdio → _x.ai/billing)
│           ├── AnthropicAdminUsageProvider / OpenAIAdminUsageProvider
├── HarnessStore ── HarnessDetector (path, version, install method)
│                └── VersionSource per method; Updater (Process + streamed output)
├── ConfigStore ── ConfigAdapter protocol (Claude JSON, Codex TOML, Grok TOML)
│                ├── ConfigEdit (span-based TOML/JSON editor; prototype in spikes/config-edit)
│                └── SafeFileWriter, FileWatcher, BackupManager, DiffService
└── HistoryDB (SQLite via GRDB)
```

Each provider/harness is an adapter behind a protocol so adding a fourth (e.g. Gemini CLI, Cursor) is additive.

## 8. Milestones (proposed)

1. **M0 — Spikes: ✅ done 2026-11-17.** See `docs/spikes/01–04`.
2. **M1 — Usage MVP: ✅ done 2026-11-17.** Discovery, popover with groups/bars/pace, pinning, percent menubar mode, Claude + Codex + **Grok** (moved up from M4), passive fallbacks, snapshot cache, menubar width warning.
3. **M2 — Updates ✅ done:** detection, version sources, one-click update with log. Implemented: H-1…H-7 and M-4. H-5 shows the notes for every version after the installed one, up to the latest (collapsed to four bullets, expandable, with a link to the full notes). H-6 is off by default, asks for notification permission when it is turned on, announces each version once, and opens the harnesses page when clicked.
4. **M3 — Config:** settings window, curated forms + MCP for all three, raw editor, diff/backup/restore. Productionising `ConfigEdit` is estimated at 12–14 engineer-days.
5. **M4 — API spend + polish:** Anthropic/OpenAI admin usage, budgets, notifications, history sparklines, worst-of and mini-bar menubar modes.

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Undocumented usage endpoints/methods change (Claude `/api/oauth/usage`, Grok `_x.ai/billing`; Codex `app-server` is labelled experimental) | Rows go stale | Adapter isolation, passive fallbacks (Claude `.claude.json` cache, Codex rollout files), clear stale state, fast patch releases |
| Out-of-band token refresh logs user out of a CLI | High annoyance | Never refresh; read-only token use (§5.1) |
| Corrupting a harness config | High | Round-trip-safe parsers, diff, backups, atomic writes, external-change detection |
| Spawning harness processes for usage | CPU/RAM spikes (~90–150 MB briefly), cache writes in harness homes, Grok telemetry | Conservative cadence (U-12), kill after use, telemetry env vars off, single in-flight poll per source |
| Dependence on `/usr/bin/security` and non-sandboxed distribution | Can't ship via App Store; breaks if Claude changes its Keychain ACL | Acceptable for an internal tool; passive `.claude.json` source as fallback |
| Identity data in `.claude.json` and Keychain item (email, org, other services' MCP tokens) | Privacy | Read only needed keys; drop everything else in memory; never persist tokens |
| Users signed in with a long-lived token have no Keychain item | No active Claude data | Fall back to the passive cache; show "active refresh unavailable" |
| Concurrent writes to `~/.claude.json` by running CLI | Lost changes | Take the CLI's `.claude.json.lock`, re-read under lock, key-scoped merge, hash check, retry |

## 10. Decision log

| # | Question | Answer (2026-11-17) |
|---|---|---|
| 1 | Default menubar mode | Percent (A) |
| 2 | Subscription naming | User-defined free text; no personal/work presets |
| 3 | xAI API spend | Out of scope; Grok Build subscription only |
| 4 | Config scope | User-level only |
| 5 | Harness updates | Wait for click; never unattended |
| 6 | Minimum macOS | macOS 27 |
| 7 | App name | Harness Butler |
| 8 | At-risk rule | Projected to run out before reset (no low-% threshold) |
| 9 | Many pinned subscriptions | Show all of them |
| 10 | Duplicate names | Not allowed; names must be unique |
| 11 | At-risk early-window guard | Keep: skip at-risk evaluation until 10% of the window has elapsed |

## 11. Open questions

No open product questions. Technical follow-ups from M0:
1. Re-test the Codex token-expiry path after the current token expires; test multi-workspace ChatGPT logins and npm installs.
2. Verify Grok `active_sessions.json` liveness (`pid` + `pid_start`) against a live session, and that auth/sessions follow `GROK_HOME`.
3. Confirm Claude's real-expired-token error (only a bogus token was tested).
