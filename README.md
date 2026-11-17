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

## Layout

| Path | What |
|---|---|
| `App/HarnessButler/` | AppKit status item + SwiftUI popover and settings. Thin: no business logic. |
| `Packages/HarnessButlerKit/` | Subscriptions, usage providers, at-risk/pace rules, refresh scheduling, process and JSON-RPC plumbing. All unit-tested. |
| `Packages/HarnessButlerKit/Sources/hb-probe/` | Dev CLI that runs the providers against your real harness logins. |
| `spikes/config-edit/` | M0 prototype of the format-preserving TOML/JSON editor (becomes M3's `ConfigEdit`). |

## Distribution

Non-sandboxed by design (requirements §6): the app spawns `/usr/bin/security` and the harness CLIs. Release builds are to be signed with Developer ID, Hardened Runtime and notarized. Local Debug builds are ad-hoc signed.
