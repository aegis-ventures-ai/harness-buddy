# Spike 04: Format-preserving config editing (TOML + JSON) and safe writes

Run on 2026-11-17 with macOS 27 (Darwin 27.2), Swift 6.4.2 and Xcode 27.2. Covers C-4..C-7 and §5.3.
Code: `spikes/config-edit/` (the `ConfigEdit` library and its tests) and `spikes/config-edit/survey/` (library survey).
The real `~/.codex/config.toml`, `~/.grok/config.toml`, `~/.claude/settings.json` and `~/.claude.json` were only
*read*, to learn their shape. All fixtures are synthetic. An opt-in test (`CONFIG_EDIT_REAL_FILES=1`) round-trips
the real files in memory without writing or printing anything.

## Options evaluated, with evidence

**TOML.** `survey/` parses one commented, synthetic Codex-style file with each library, writes it back unchanged,
then writes it again after setting `model` (`swift run` per library; see the comment in `survey/Package.swift`).

| Library (version, last push) | Unchanged write identical | Comments kept | Key order kept | Verdict |
|---|---|---|---|---|
| LebJe/TOMLKit 0.6.0 (toml++, 2025-01) | no | **no** | **no** (sorted) | Rewrites the file: `'single'` quotes, `[ a, b ]`, indented sub-tables. Unmaintained. |
| mattt/swift-toml 2.1.1 (toml++, 2026-11) | no | **no** | partly | Codable only (`TOMLValue` isn't `Decodable`), so unknown keys are dropped. The encoder uses a `Dictionary`, so keys inside a table get reordered, and it adds an empty `[mcp_servers]` header. |
| dduan/TOMLDecoder 0.4.5 (pure Swift, TOML 1.1, 2026-07) | n/a | n/a | n/a | Decoder only (`encode(to:)` throws `.notReallyCodable`). Good **validator**. |
| akira-toriyama/swift-toml-edit 3.0.1 (pure Swift, 2026-11) | **yes** | yes | yes | Real lossless DOM, but: `settingValue(atTable: [])` does **nothing** for root keys (`model` didn't change), `removingTable` leaves `[x.env]` sub-tables behind, misses fail silently, there's no API to add a nested table, and it has 1 star and one author (bot-maintained, created 2026-06). |
| jdfergason/swift-toml 1.0.0 | — | — | — | Parser only, last push 2020. Not built. |
| Rust `toml_edit` 0.23.10 via C FFI | yes | inline comment **dropped** with naive `doc[k] = value(v)` | yes | Built a `staticlib` (2.0 MB `.a`, opt-z+LTO, 3 s build) and linked it into a Swift binary with `swiftc -import-objc-header`: works, adds ~0.5 MB to the binary. You still have to copy the `Decor` over to keep inline comments. Codex itself writes `config.toml` with `toml_edit`. |

Build note: swift-toml's module `TOML` and swift-toml-edit's module `Toml` collide on case-insensitive APFS
(`unable to resolve module dependency`), even when used by different targets. They can't share a build directory.

**JSON.** `JSONSerialization` and `Codable` lose key order and spacing (known). Foundation has no other writer.
Real file shapes: both use 2-space `JSON.stringify(v, null, 2)` style. `settings.json` ends with `\n`;
`~/.claude.json` (~200 KB) has **no** trailing newline.

**What Claude Code does to `~/.claude.json`** (from `strings` on the 2.1.326 binary): `saveGlobalConfig` takes a
proper-lockfile **directory lock at `${path}.lock`** (`mkdir`), **re-reads the file under the lock**, applies an
updater, and writes the whole object back with JSON.stringify. If the file fails to parse, it auto-repairs it from its
in-memory cache. So the CLI re-formats the file on every save anyway, and a write that doesn't take its lock can race it.

## Chosen approach and why

**A pure-Swift, span-based "edit in place" layer for both formats, with an independent parser as a safety net.**
- A lossless scanner records byte spans: table headers, key/value lines, and value expressions. JSON gets a span tree.
  Edits splice only the target span, so untouched bytes are never re-serialized and the no-op round-trip is identical
  by construction.
- New content is rendered to match the file: the detected newline (LF/CRLF), the sibling's indentation, the JSON
  indent unit (spaces or tabs, inline vs multi-line containers), and Codex's own `[table]` / `[table.env]` layout.
- **Every TOML edit result is re-parsed by TOMLDecoder** and every JSON result by `JSONSerialization`. An edit that
  would produce invalid output (for example, redefining a table) throws and leaves the document unchanged.
  Unsupported shapes throw rather than doing nothing silently.
- Edits are **path-based operations** (`set`, `append(unique:)`, `remove`, `removeTable`), not byte patches. When a
  file changes under us, we re-apply the operation to the fresh bytes. That is a correct key-scoped merge for
  `~/.claude.json`.

Why not the alternatives: no toml++ wrapper can preserve formatting, because toml++ has no CST. swift-toml-edit is
close, but its gaps hit exactly our edits (root `model`, removing an MCP table) and its bus factor is 1. It is still
a useful reference. Rust FFI brings in a second toolchain, a C ABI and an xcframework for TOML only. It still needs
decor care, and JSON would still have to be Swift. Our own layer is ~1,050 LOC (TOML ~480, JSON ~390, safe write ~185).

## Prototype summary and test results

`spikes/config-edit/`: `swift build` and `swift test` pass. **32 tests pass** (36 cases); the 2 opt-in real-file tests
are skipped by default and **pass** when enabled. Release build: a single edit on the 200 KB `~/.claude.json` fixture
takes about 19 ms, including validation. Removing a `Regex` from the number scanner cut this from 116 ms.

| Area | Files | What the tests prove (exact byte expectations unless noted) |
|---|---|---|
| TOML | `TOML/TOMLScanner.swift`, `TOMLDocument.swift`, `TOMLValue.swift` | No-op round-trip is identical (Codex and Grok fixtures, CRLF, no final newline). Set root `model`: the comment above and the inline `# …` comment are kept. Set inside nested and quoted tables (`[plugins."browser@…"]`, a value containing `#`). Toggle `[cli] auto_update` keeps both comments. Add `[mcp_servers.docs-search]` with `command`, `args` and `[…env]`, placed after the last `mcp_servers.*` table. Replace a server table in place, keeping its header comment. Remove a table together with its sub-tables and the comment attached above it; removing the last table leaves one trailing newline. Add a key to an existing table; create a missing table. Remove a key. Editing inside `[[array]]`, an invalid redefinition, or a missing table: each throws and leaves the bytes unchanged. Multi-line arrays with comments and `]#` inside strings, and `"""` strings, survive. |
| JSON | `JSON/JSONDocument.swift`, `JSONValue.swift` | Identical round-trip (settings, and a synthetic 200 KB `.claude.json`). Set `model`. Append an allow rule (uniquely). Create a `deny` array. Add an `mcpServers` entry: the result equals the original with only the insertion spliced in, and still has no trailing newline. Replace and remove an entry. Insert into `{}`. Create a missing `mcpServers` key. Tab indent and inline containers. Unknown keys and number spellings (`2.50`, `-3e2`, `\/`) survive. Strict parse rejects trailing commas and `01`. |
| Safe write | `SafeWrite/SafeFileWriter.swift` | Backup holds the exact loaded bytes, with mode 0600. Mode 0600/0644 preserved. External change → `externalChange`, nothing written, no backup. Invalid content never reaches disk. A symlink is kept and its target updated. Foundation `.atomic` **replaces a symlink with a regular file** (evidence test). `update()` retries after a concurrent writer and keeps both changes. The `.lock` directory blocks; a stale lock is broken. |

**Write sequence as implemented:** `load` runs `realpath(3)`, reads the file, and records dev/inode/size/mtime(ns)/mode
plus a SHA-256. Then: validate the new bytes → re-stat, re-hash and re-resolve the path, and refuse on any difference →
write the backup (`O_EXCL`, 0600, in a 0700 dir; the name includes a timestamp and a short hash) → `mkstemp` in the
*target's* directory, write, `fchmod(original mode)`, `fsync` → `rename` over the target → `fsync` the directory →
re-read and compare the bytes. For `~/.claude.json`, wrap the whole `update` in `withLock("~/.claude.json.lock")`.

**Symlinks:** dotfile managers (stow, chezmoi) often symlink `settings.json`. We resolve the link and rename onto the
target, so the link survives and the temp file briefly appears in the target's directory (for example, a dotfiles repo).
The change check also re-resolves the path, so a link repointed under us counts as an external change. Hard links are
broken by any rename-based write. Detect `st_nlink > 1` and warn. rename also drops xattrs and ACLs (for example,
`com.apple.provenance`, the `@` in `ls -l`). Decide whether to copy them over.

## Effort estimate for production quality (one engineer)

| Item | Days |
|---|---|
| TOML layer hardening: run the full `toml-test` valid corpus as byte-identical round-trips, add property tests (random edit sequences checked against a TOMLDecoder model), dotted-key tables, inline-table `env = {…}` edits, `[profiles.*]`, read-only `[[…]]`, errors with line and column | 4–5 |
| JSON layer hardening: fuzz against `JSONSerialization`, BOM, duplicate keys (last wins, matching JS), surrogates, very deep nesting, and a `value(at:)` cache for UI reads | 2 |
| Safe write → BackupManager (30-day retention, one-click restore, diff source), file watcher (DispatchSource/FSEvents → C-7 reload/merge), proper-lockfile interop (mtime refresh while held, honour the CLI's staleness), xattr policy, error UX | 3–4 |
| Per-harness adapters mapping curated fields (C-2, C-3) to paths, plus tests against fixtures per harness version | 3 (M3) |
| **Total** | **≈ 12–14 days**, of which ≈ 9–11 are this spike's scope |

Fallback, if the TOML layer turns out harder than expected: Rust `toml_edit` FFI, adding ~3 days for xcframework, CI and
the wrapper. We can switch behind the same `TOMLDocument` API.

## Risks

- **Scanner gaps** in TOML corner cases (dotted keys that extend tables, TOML 1.1 multi-line inline tables). Mitigated
  because every edit is re-validated and unsupported shapes throw. The toml-test corpus is required before M3.
- **Validator vs harness parser mismatch.** TOMLDecoder accepts TOML 1.1; Codex's `toml_edit` 0.23 is 1.0-only. A 1.1-only
  file written from the raw editor (C-4) could pass our check and still break Codex. Our renderer only emits 1.0 syntax.
  The raw editor needs a 1.0-strict check, or a "run `codex`/`grok inspect` to verify" step.
- **`~/.claude.json` contention.** Without the CLI's `.lock` directory there is a millisecond race between our check
  and the rename. With the lock, the CLI re-reads our result under its own lock. Lock-protocol details (staleness,
  mtime refresh) are reverse-engineered and can change between CLI versions, so re-verify them on each Claude Code
  update. Invalid JSON gets "auto-repaired" by the CLI from its cache, which silently undoes the write.
- **Byte preservation in `~/.claude.json` is short-lived.** The CLI re-stringifies the file on its next save. That is
  harmless because we emit JSON.stringify style, but diffs and backups will show CLI churn outside our key.
- **Secrets in backups.** Env blocks hold tokens. Backups must stay 0600 and local, and never be shown in full in
  logs or diagnostics.
- **Real files have no comments today.** Codex and Grok files here are machine-written. C-6 still matters for
  hand-edited files and costs little.

## Changes to requirements suggested by this spike

1. §5.3 / C-5: for `~/.claude.json`, take the CLI's `~/.claude.json.lock` directory lock around read, merge and write.
   Merge means re-applying key-scoped operations, not patching bytes.
2. C-5: say how symlinks are handled ("write through to the resolved target; keep the link"), and warn about hard links.
3. NFR Safety: backups 0600 in a 0700 directory, because they contain secrets.
4. C-3/C-6: editing entries inside `[[array-of-tables]]` (for example, Grok `marketplace.sources`) is raw-editor-only in v1.
5. C-4: raw TOML saves need TOML **1.0**-strict validation, matching the harness parser.
