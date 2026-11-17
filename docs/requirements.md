# Harness Butler — Scope & Requirements (draft v0.3)

_Status: draft v0.3 · 2026-11-17 · round-3 answers applied; no open product questions_

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
| U-12 | Refresh cadence: default 2 min while popover closed, 30 s while open, manual refresh; exponential backoff on errors. | P0 |

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
| C-4 | Raw editor tab for the underlying file with syntax validation. | P0 |
| C-5 | Every write: diff preview → timestamped backup → atomic write → re-read to verify. One-click restore from backup. | P0 |
| C-6 | Preserve formatting/comments and unknown keys (round-trip safe). TOML must be comment-preserving. | P0 |
| C-7 | Watch files for external changes; if a file changed under an open editor, block save and offer reload/merge. | P0 |
| C-8 | Read-only view of user-level hooks and plugins/skills. | P1 |
| C-11 | Scope is user-level files only; project-level config files are never read or written. | P0 |
| C-9 | Copy an MCP server definition from one harness to another. | P2 |
| C-10 | Never read or write auth/credential files except the minimum read needed for usage (§5.1). | P0 |

### 4.5 Notifications (P1)

- Threshold alerts per subscription (default 80% and 95% used, per window).
- "Window reset" notification for limited subscriptions.
- Update available (see H-6).

## 5. Data sources & feasibility

Verified on this machine unless marked _(verify)_.

### 5.1 Usage

| Harness / source | Where the data comes from | Confidence |
|---|---|---|
| Claude Code (subscription) | OAuth access token from macOS Keychain item `Claude Code-credentials` (present). Call undocumented `GET api.anthropic.com/api/oauth/usage` → 5h / 7d / 7d-Opus utilisation + `resets_at`. Non-default `CLAUDE_CONFIG_DIR` uses a differently-suffixed Keychain item _(verify naming)_. | Medium — undocumented endpoint |
| Codex (subscription) | **Passive:** latest `rate_limits` event in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — verified: `primary {used_percent, window_minutes:300, resets_at}`, `secondary {window_minutes:10080}`, `credits`. **Active:** `codex app-server` rate-limit read _(verify)_ or ChatGPT backend usage endpoint _(verify)_. Per-`CODEX_HOME`. | High (passive) / Medium (active) |
| Grok Build (subscription) | `grok usage --json` exists ("plan's usage limit") but requires Grok's background **leader** service; it refused here. Options: talk to `~/.grok/leader.sock`, spawn the leader on demand, or fall back to "open grok to refresh". | **Low — spike needed** |
| Anthropic API | Admin API usage & cost reports (`sk-ant-admin…` key). | High — documented |
| OpenAI API | Organization usage + costs endpoints (admin key). | High — documented |

**Token-handling rule:** the app **never refreshes** harness OAuth tokens itself. Refresh tokens rotate; refreshing out-of-band can silently log the CLI out. If the access token is expired, mark the subscription *stale* with "run `claude` to refresh" (or trigger the harness's own non-interactive refresh if one exists).

### 5.2 Versions

| Harness | Installed (here) | Install method (here) | Latest-version source | Update command |
|---|---|---|---|---|
| Claude Code | 2.1.326 | native (`~/.local/bin/claude`) | native release channel / npm `@anthropic-ai/claude-code` dist-tags | `claude update` |
| Codex | 0.167.2 | Homebrew (`/opt/homebrew/bin/codex`) | Homebrew formula/cask JSON, GitHub releases `openai/codex`, or npm `@openai/codex` | `brew upgrade codex` / `npm i -g @openai/codex` |
| Grok Build | 1.0.88 | self-installer (`~/.grok/bin/grok`) | `~/.grok/version.json` `stable_version` (fresh), or `grok update` check | `grok update` |

### 5.3 Config files (v1 targets)

| Harness | Files | Notes |
|---|---|---|
| Claude Code | `~/.claude/settings.json` (model, permissions, env, hooks, plugins, outputStyle); `~/.claude.json` (user-scope MCP servers) | `~/.claude.json` is also live CLI state, written frequently → merge-write only the `mcpServers` key, with change detection. |
| Codex | `~/.codex/config.toml` (model, reasoning effort, approval policy, sandbox, `[mcp_servers.*]`, `[profiles.*]`) | Needs comment-preserving TOML editing. |
| Grok Build | `~/.grok/config.toml` (`[cli] auto_update`, `[ui]`, model, MCP servers) | Same TOML requirement; `grok inspect` can show effective config. |

## 6. Non-functional requirements

- **Footprint:** <40 MB RAM idle, negligible CPU; no background polling when the Mac is asleep / on low-power, back off further on battery.
- **Privacy:** no telemetry. Network calls only to providers and version sources. Admin keys in Keychain. Usage history stored locally only.
- **Safety:** read-only by default for everything except explicit config saves and update actions. Backups kept for 30 days.
- **Resilience:** one provider failing never blanks the others; each row shows its own error state and last-good data with age.
- **Appearance:** follows system light/dark; monospace, terminal-inspired look (see mockups); full VoiceOver labels for bars ("Claude Code work, weekly all models, 84 percent left, resets in 3 days").
- **Distribution:** signed + notarized DMG via GitHub Releases for the team; Sparkle for self-update (P1).
- **Minimum OS:** macOS 27. No back-deployment shims; use current SwiftUI, Observation, and Swift concurrency APIs freely, and adopt the current system design language for materials and controls.

## 7. Architecture sketch

```
HarnessButlerApp (SwiftUI MenuBarExtra + Settings scene)
├── UsageStore (@Observable) ── Poller (per-subscription schedule, backoff)
│     └── UsageProvider protocol
│           ├── ClaudeOAuthUsageProvider   (Keychain → /api/oauth/usage)
│           ├── CodexRolloutUsageProvider  (tail rollout jsonl; app-server later)
│           ├── GrokLeaderUsageProvider    (spike)
│           ├── AnthropicAdminUsageProvider / OpenAIAdminUsageProvider
├── HarnessStore ── HarnessDetector (path, version, install method)
│                └── VersionSource per method; Updater (Process + streamed output)
├── ConfigStore ── ConfigAdapter protocol (Claude JSON, Codex TOML, Grok TOML)
│                └── FileWatcher, BackupManager, DiffService
└── HistoryDB (SQLite via GRDB)
```

Each provider/harness is an adapter behind a protocol so adding a fourth (e.g. Gemini CLI, Cursor) is additive.

## 8. Milestones (proposed)

1. **M0 — Spikes (≈2–3 days):** Claude multi-config-dir Keychain naming; Codex active rate-limit read; Grok leader/usage; comment-preserving TOML in Swift.
2. **M1 — Usage MVP:** discovery, popover with groups/bars/pace, pinning, percent + worst-of menubar modes, Claude + Codex.
3. **M2 — Updates:** detection, version sources, one-click update with log.
4. **M3 — Config:** settings window, curated forms + MCP for all three, raw editor, diff/backup/restore.
5. **M4 — API spend + polish:** Anthropic/OpenAI admin usage, budgets, notifications, history sparklines, Grok usage (depending on spike), worst-of and mini-bar menubar modes.

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Undocumented usage endpoints change/break | Rows go stale | Adapter isolation, passive fallbacks (Codex rollout files), clear stale state, fast patch releases |
| Out-of-band token refresh logs user out of a CLI | High annoyance | Never refresh; read-only token use (§5.1) |
| Corrupting a harness config | High | Round-trip-safe parsers, diff, backups, atomic writes, external-change detection |
| Grok plan usage not accessible headlessly | Grok row has limited data | Spike in M0; fallback to "open grok" + versions/config only |
| Concurrent writes to `~/.claude.json` by running CLI | Lost changes | Key-scoped merge, mtime/hash check immediately before write, retry |

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

No open product questions. Remaining unknowns are technical and are covered by the M0 spikes (§8).
