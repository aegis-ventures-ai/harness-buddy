# Harness Butler

A macOS menubar app that shows how much of each AI coding subscription you have left (Claude Code, Codex, Grok Build), flags outdated harness installs, and edits their config safely.

- Scope and requirements: [`docs/requirements.md`](docs/requirements.md)
- UI mockups: [`docs/mockups/index.html`](docs/mockups/index.html)
- M0 spike write-ups: [`docs/spikes/`](docs/spikes/)

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

`hb-probe` flags: `--live` skips the harness caches and forces live reads; `--offline-codex` hides the `codex` binary to exercise the session-log fallback; `--harnesses` prints detected installs, latest versions and update commands (it never runs an update); add `--notes` to also fetch and print the release notes for each harness's latest version.

Debug-build launch flags (pass after `open … --args`): `--open-popover [harnesses]` opens the popover on launch (and keeps it open until you click the item); `--expand-notes` starts release notes expanded; `--open-settings [subscriptions|menubar|about]` opens Settings on that tab.

## Data the app keeps

Everything lives in `~/Library/Application Support/HarnessButler/` (mode 0700):
- `subscriptions.json`: names, harness, home-directory override, pinned flag and order.
- `usage-cache.json`: last good usage per subscription (percentages, reset times, plan names), so the popover isn't empty after a relaunch.

Preferences (update badge, update notifications on/off) and the list of update versions already announced are in the app's UserDefaults.

No tokens are ever written to disk.

## Network requests

Besides the providers' own usage endpoints, the app only makes unauthenticated GETs for update checks (every 6 h) and release notes (once per new version):
- Claude Code: `downloads.claude.ai/claude-code-releases/{latest|stable}`; notes from the top of `raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md` (HTTP Range, 256 KB).
- Codex: the Homebrew/npm/GitHub source matching the install; notes from `api.github.com/repos/openai/codex/releases` (stable releases only).
- Grok Build: `x.ai/cli/{channel}`; notes from `x.ai/cli/changelogs/<version>.external.md`.

## Layout

| Path | What |
|---|---|
| `App/HarnessButler/` | AppKit status item + SwiftUI popover and settings. Thin: no business logic. |
| `Packages/HarnessButlerKit/` | Subscriptions, usage providers, at-risk/pace rules, refresh scheduling, process and JSON-RPC plumbing. All unit-tested. |
| `Packages/HarnessButlerKit/Sources/hb-probe/` | Dev CLI that runs the providers against your real harness logins. |
| `spikes/config-edit/` | M0 prototype of the format-preserving TOML/JSON editor (becomes M3's `ConfigEdit`). |

## Distribution

Non-sandboxed by design (requirements §6): the app spawns `/usr/bin/security` and the harness CLIs. Release builds are to be signed with Developer ID, Hardened Runtime and notarized. Local Debug builds are ad-hoc signed.
