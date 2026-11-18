# Harness Butler

A macOS menubar app that shows how much of each AI coding subscription you have left (Claude Code, Codex, Grok Build), flags outdated harness installs, and edits their config safely.

- Scope and requirements: [`docs/requirements.md`](docs/requirements.md)
- UI mockups: [`docs/mockups/index.html`](docs/mockups/index.html)
- M0 spike write-ups: [`docs/spikes/`](docs/spikes/)
- Release history: [`CHANGELOG.md`](CHANGELOG.md)

## Requirements

macOS 27, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and run

```sh
make test     # HarnessButlerKit unit tests (swift test)
make build    # generate HarnessButler.xcodeproj from project.yml and build Debug
make run      # build, then launch (restarts a running copy)
make probe    # print one usage read per subscription, no UI (add --live via: cd Packages/HarnessButlerKit && swift run hb-probe --live)
```

The Xcode project is generated from `project.yml` and isn't committed. Run `make project` after pulling.

`hb-probe` flags: `--live` skips the harness caches and forces live reads; `--offline-codex` hides the `codex` binary to exercise the session-log fallback; `--config` parses each profile's config files in memory and prints whether they parse and round-trip, MCP server counts and which curated keys are set (no values; it never writes); `--extensions` prints counts of each profile's hooks, plugins and skills (event names only, never commands or descriptions); `--harnesses` prints detected installs, latest versions and update commands (it never runs an update); add `--notes` to also fetch and print the release notes for each harness's latest version; `--api-env anthropic|openai` reads month-to-date API spend with the Admin key in `$HB_ADMIN_KEY` (and an optional budget in `$HB_BUDGET`). The key stays in memory and is never printed; without this flag, saved API subscriptions are skipped so the probe never reads the Keychain.

Debug-build launch flags (pass after `open … --args`): `--open-popover [harnesses]` opens the popover on launch (and keeps it open until you click the item); `--expand-notes` starts release notes expanded; `--open-settings [subscriptions|menubar|about|claude|codex|grok]` opens Settings on that page; `--config-tab general|permissions|mcp|env|extensions|raw|backups` picks the config tab; `--demo-pending` stages one harmless edit to the Grok config in memory (it's never saved) and `--demo-review` opens its diff; `--demo-copy` opens the MCP "Copy to…" sheet for the first server (nothing is staged unless you click Copy); `--demo-api` runs on a temporary copy of the subscription list plus an Anthropic and an OpenAI API subscription answered from canned data (no Keychain, no network for those rows, nothing written to the real files). `--render-menubar DIR` draws the menubar title in every display mode, on dark and light backgrounds, to PNGs in `DIR` and quits (offscreen; nothing is captured from the screen). Any preference can be overridden for one launch without saving it, e.g. `-menuBarMode worstOf` or `-menuBarMode miniBars`. All of these are for UI checks.

## Data the app keeps

Everything lives in `~/Library/Application Support/HarnessButler/` (mode 0700, files 0600):
- `subscriptions.json`: names, harness, home-directory override, pinned flag and order; for API subscriptions the provider and monthly budget.
- `usage-cache.json`: last good usage per subscription (percentages, reset times, plan names, and for API subscriptions month-to-date spend per UTC day), so the popover isn't empty after a relaunch. For a subscription whose reads are failing it also keeps the back-off (last attempt, failure count, any provider `retry-after`, and the row's status message), so quitting and reopening the app doesn't retry early.
- `history.sqlite` (U-10): one row per window reading (subscription ID, window ID, time, percent used), unchanged readings thinned to one per 30 minutes, kept 35 days. It feeds the 7-day sparkline in the detail view. No names, plans or account data.
- `usage-alerts.json`: per window, the last reading, its reset time and the highest alert threshold already sent, so threshold and reset notifications aren't repeated (§4.5).
- `Backups/<file kind>-<hash>/`: the previous version of a harness config file, written before every save from Settings (mode 0600, kept 30 days). Env blocks can hold tokens, so these stay private to your user. Backups of `.claude.json` hold only `mcpServers`, never the identity and project data in the rest of that file (older full backups are cut down on launch).

Harness config files are only written when you click Save in the diff review. For `~/.claude.json` only the `mcpServers` key is read or written, under Claude Code's own `.claude.json.lock`.

Preferences (update badge, update and usage notifications on/off, per-subscription alert thresholds, menubar mode) and the list of update versions already announced are in the app's UserDefaults.

No tokens are ever written to disk. Admin API keys for API subscriptions are stored only in the login Keychain (generic password, service `ai.aegisventures.harnessbutler.admin-key`, one item per subscription ID), are deleted when the subscription is removed, and are only ever sent to the provider they belong to.

## Network requests

Besides the providers' own usage endpoints (for API subscriptions: `GET api.anthropic.com/v1/organizations/analytics/cost` with hourly buckets, or `GET api.openai.com/v1/organization/costs` with daily buckets, every 30 minutes), the app only makes unauthenticated GETs for update checks (every 6 h) and release notes (once per new version):
- Claude Code: `downloads.claude.ai/claude-code-releases/{latest|stable}`; notes from the top of `raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md` (HTTP Range, 256 KB).
- Codex: the Homebrew/npm/GitHub source matching the install; notes from `api.github.com/repos/openai/codex/releases` (stable releases only).
- Grok Build: `x.ai/cli/{channel}`; notes from `x.ai/cli/changelogs/<version>.external.md`.

## Layout

| Path | What |
|---|---|
| `App/HarnessButler/` | AppKit status item + SwiftUI popover and settings. Thin: no business logic. |
| `Packages/HarnessButlerKit/` | Subscriptions, usage providers, at-risk/pace rules, refresh scheduling, process and JSON-RPC plumbing. All unit-tested. |
| `Packages/HarnessButlerKit/Sources/hb-probe/` | Dev CLI that runs the providers against your real harness logins. |
| `spikes/config-edit/` | M0 prototype of the format-preserving TOML/JSON editor (now `Config/Edit` in the Kit). |

## Distribution

Non-sandboxed by design (requirements §6): the app spawns `/usr/bin/security` and the harness CLIs. Release builds are to be signed with Developer ID, Hardened Runtime and notarized. Local Debug builds are ad-hoc signed.
