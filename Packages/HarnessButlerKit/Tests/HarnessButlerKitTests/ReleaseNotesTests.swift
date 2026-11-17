import Foundation
import Testing
@testable import HarnessButlerKit

private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }
private let docs = URL(string: "https://example.com/notes")!

@Suite struct ReleaseNotesParsingTests {
    /// Claude Code's CHANGELOG.md shape.
    static let claude = """
    # Changelog

    ## 2.1.326

    - Added Ctrl+O to show hidden startup notices
    - Fixed `cp` of a file being refused when only its source was covered by a
      permission rule
      - nested detail

    ## 2.1.325

    - Improved **startup** time

    ## 2.1.323

    - Older change
    """

    /// Grok's `<version>.external.md` shape: versions at level 1, categories at level 2.
    static let grok = """
    # 1.0.88 — 2026-11-16

    ## Features

    - **`/release-notes`** now opens when the dashboard is active.

    ## Bug Fixes

    - **Prompt border** truncates long names.

    # 1.0.87 — 2026-11-14

    ## Bug Fixes

    - A fix in 1.0.87.
    """

    @Test func splitsClaudeChangelogByVersion() throws {
        let entries = ReleaseNotesParser.versionedMarkdown(Self.claude)
        #expect(entries.map(\.version) == [v("2.1.326"), v("2.1.325"), v("2.1.323")])
        let first = try #require(entries.first)
        #expect(first.blocks == [
            .item("Added Ctrl+O to show hidden startup notices", level: 0),
            .item("Fixed `cp` of a file being refused when only its source was covered by a permission rule", level: 0),
            .item("nested detail", level: 1),
        ])
        #expect(first.itemCount == 3)
    }

    @Test func keepsCategoryHeadingsAndDatesInGrokNotes() throws {
        let entries = ReleaseNotesParser.versionedMarkdown(Self.grok)
        #expect(entries.map(\.version) == [v("1.0.88"), v("1.0.87")])
        let first = try #require(entries.first)
        #expect(first.date == "2026-11-16")
        #expect(first.blocks == [
            .heading("Features"),
            .item("**`/release-notes`** now opens when the dashboard is active.", level: 0),
            .heading("Bug Fixes"),
            .item("**Prompt border** truncates long names.", level: 0),
        ])
    }

    @Test func dropsTheCutOffSectionOfARangeRequest() {
        // The body stops partway through 2.1.323, so that section may be incomplete.
        let cut = String(Self.claude.dropLast(4))
        #expect(ReleaseNotesParser.versionedMarkdown(cut, complete: false).map(\.version) == [v("2.1.326"), v("2.1.325")])
    }

    @Test func readsStableGitHubReleasesAndDropsPRLists() throws {
        let json = """
        [
          {"tag_name": "rust-v0.171.0-alpha.12", "prerelease": true, "body": "Release 0.171.0-alpha.12"},
          {"tag_name": "rust-v0.169.0", "prerelease": false, "draft": false, "published_at": "2026-11-14T18:00:00Z",
           "body": "## New Features\\n\\n- Search older tasks by name. (#60286)\\n- Collapse turn details. (#60554, #60555)\\n\\n## Chores\\n\\n- Bump deps (#1)\\n\\n## Changelog\\n\\nFull Changelog: https://github.com/openai/codex/compare/a...b\\n\\n- #60286 Search tasks @someone"},
          {"tag_name": "rust-v0.168.0", "prerelease": false, "body": "## Bug Fixes\\n\\n- A fix."},
          {"tag_name": "other-1.0.0", "prerelease": false, "body": "- not codex"}
        ]
        """
        let entries = ReleaseNotesParser.githubReleases(Data(json.utf8), tagPrefix: "rust-v")
        #expect(entries.map(\.version) == [v("0.169.0"), v("0.168.0")])
        let first = try #require(entries.first)
        #expect(first.date == "2026-11-14")
        #expect(first.blocks == [
            .heading("New Features"),
            .item("Search older tasks by name.", level: 0),
            .item("Collapse turn details.", level: 0),
        ])
    }

    @Test func selectsVersionsAfterTheInstalledOneUpToTheTarget() {
        let entries = ReleaseNotesParser.versionedMarkdown(Self.claude)
        let notes = ReleaseNotes.select(entries, installed: v("2.1.323"), target: v("2.1.325"), fullNotesURL: docs)
        #expect(notes.entries.map(\.version) == [v("2.1.325")])
        #expect(!notes.isPartial)

        let behind = ReleaseNotes.select(entries, installed: v("2.1.300"), target: v("2.1.326"), fullNotesURL: docs)
        #expect(behind.entries.map(\.version) == [v("2.1.326"), v("2.1.325"), v("2.1.323")])
        #expect(behind.isPartial) // the excerpt doesn't reach back to 2.1.300
    }

    @Test func sourcesDontDependOnInstallMethod() {
        let codex = ReleaseNotesSource.forHarness(.codex, target: v("0.169.0"))
        #expect(codex.fullNotesURL.absoluteString == "https://github.com/openai/codex/releases/tag/rust-v0.169.0")
        let grok = ReleaseNotesSource.forHarness(.grok, target: v("1.0.88"))
        #expect(grok.url.absoluteString == "https://x.ai/cli/changelogs/1.0.88.external.md")
        #expect(ReleaseNotesSource.forHarness(.claude, target: v("2.1.326")).rangeBytes != nil)
    }
}

@Suite struct UpdateNotificationLedgerTests {
    private func status(installed: String, latest: String) -> HarnessStatus {
        var status = HarnessStatus()
        status.installation = HarnessInstallation(
            harness: .codex, binary: URL(filePath: "/x"), resolvedBinary: URL(filePath: "/x"),
            version: v(installed), versionOutput: nil, method: .unknown, channel: nil, detectedAt: .now
        )
        status.latest = v(latest)
        return status
    }

    @Test func announcesEachVersionOnce() throws {
        var ledger = UpdateNotificationLedger()
        let statuses: [Harness: HarnessStatus] = [.codex: status(installed: "0.167.2", latest: "0.169.0"), .claude: status(installed: "2.1.326", latest: "2.1.326")]
        let pending = ledger.pending(statuses)
        #expect(pending.map(\.harness) == [.codex])
        ledger.record(try #require(pending.first))
        #expect(ledger.pending(statuses).isEmpty)

        // A newer release announces again.
        #expect(ledger.pending([.codex: status(installed: "0.167.2", latest: "0.170.0")]).map(\.latest) == [v("0.170.0")])
        // An older one (channel switch) doesn't.
        #expect(ledger.pending([.codex: status(installed: "0.160.0", latest: "0.168.0")]).isEmpty)
    }

    @Test func survivesARoundTrip() throws {
        var ledger = UpdateNotificationLedger()
        ledger.record(.init(harness: .grok, installed: v("1.0.87"), latest: v("1.0.88")))
        let decoded = try JSONDecoder().decode(UpdateNotificationLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }
}
