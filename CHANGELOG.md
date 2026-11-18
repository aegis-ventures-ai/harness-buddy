# Changelog

All notable changes to Harness Butler are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-18

The first release: milestones M0–M4 from [`docs/requirements.md`](docs/requirements.md).

### Added

#### Usage at a glance
- A menubar item that shows how much is left of each AI coding subscription: Claude Code, Codex and Grok Build
  logins, found automatically from each harness's home directory, with support for several profiles per harness.
- Three menubar modes: percent left per subscription, worst-of (the most constrained subscription only) and
  mini-bars. The text and icons use the standard menubar sizes, and a short tooltip has one line per subscription.
- A popover with one row per subscription. Each row shows every limit window (5-hour session, weekly, per-model and
  extra buckets) with a usage bar, the reset countdown and the plan name.
- Pace against a linear burn ("12% ahead", "on pace") and an at-risk status when a window is projected to run out
  before it resets.
- A detail view per subscription with a 7-day usage sparkline from local history (`history.sqlite`, kept 35 days).
- Refreshes on a per-harness cadence and pauses while the Mac sleeps. Fresh cached usage is shown straight away
  after a relaunch, without re-reading.
- Fallbacks when a live read fails: the harness's own usage cache, Codex session logs, and the last good reading,
  marked as stale.

#### API spend (Admin keys)
- API subscriptions for Anthropic and OpenAI organisations: month-to-date spend from each provider's cost endpoint,
  per-day spend and the run rate.
- An optional monthly budget, treated like a usage window: percent used, pace, at-risk status, alerts and menubar
  display all work the same way.
- Admin keys are stored only in the login Keychain and are sent only to the provider they belong to.

#### Notifications
- Threshold alerts per window (80% and 95% by default, configurable per subscription) and a notice when a limited
  window resets. Each alert is sent at most once per window period, also across relaunches.
- Optional notifications when a harness update is available.

#### Harness updates
- Detects installed versions of Claude Code, Codex and Grok Build and checks for newer ones every 6 hours.
- Shows the release notes for a pending version.
- Click-to-update with the install's own updater, with streamed output and a warning when the harness is in use.
  Updates only ever start from a click.

#### Config editing
- Curated settings (general, permissions, MCP servers, environment) and a raw editor for each harness's user-level
  config files. The editor preserves formatting and comments in TOML and JSON.
- Every save shows a diff for review first, writes atomically, and keeps a backup of the previous version (mode
  0600, kept 30 days). External changes to the files are picked up while you edit.
- A read-only view of hooks, plugins and skills, and copying MCP servers from one harness to another.
- For `~/.claude.json`, only `mcpServers` is read or written, under Claude Code's own lock. Its backups hold only
  that key.

#### Developer tools
- `hb-probe`, a CLI that runs the usage providers, config parsing, extension scanning, harness detection and API
  spend reads without the UI.
- Debug-build launch flags for UI checks: demo data, opening a given Settings page, and offscreen menubar renders.

### Security and privacy
- Never refreshes harness OAuth tokens and never touches refresh tokens. It reads only what usage needs from
  credential files.
- No telemetry. Network requests go only to the providers' usage and cost endpoints and to version and release-note
  sources.
- Only user-level config files are read or written, never project-level ones.
- App data and backups are private: files are 0600 from the first byte, in 0700 folders.
- Respects provider `retry-after` (capped at a day) and backs off after failures (5, 10, then 30 minutes). The
  back-off survives relaunches.
- A usage or spend response the app can't read never replaces the last good data. Malformed spend pages fail as a
  whole instead of undercounting.
- Harness child processes run with a minimal environment, can't hang the app, and don't leave helpers running after
  a usage read.

### Known limitations
- API spend has been tested against recorded responses only, not yet with live Admin keys.
- Codex credits (U-6) and session-file reads (U-11) are planned for a later release.
- Builds are ad-hoc signed. Developer ID signing and notarisation are not set up yet.

[1.0.0]: https://github.com/aegis-ventures-ai/harness-buddy/releases/tag/v1.0.0
