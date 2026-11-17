import Foundation
import Testing
@testable import HarnessButlerKit

@Suite struct ExtensionsTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "hb-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ text: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func profile(_ harness: Harness, _ dir: String) -> ConfigProfile {
        ConfigProfile(harness: harness, home: root.appending(path: dir), homeOverride: nil, subscriptionNames: [])
    }

    @Test func claudeHooksPluginsAndSkills() throws {
        try write(".claude/settings.json", """
        {
          "hooks": {
            "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "guard.sh", "timeout": 10 }] }],
            "Stop": [{ "hooks": [{ "type": "command", "command": "say done", "timeout": 1e20 }, { "type": "http", "url": "https://example.com/h" }] }]
          },
          "enabledPlugins": { "lsp@official": true, "themes@community": false }
        }
        """)
        try write(".claude/plugins/installed_plugins.json", """
        { "version": 2, "plugins": {
            "lsp@official": [{ "scope": "user", "version": "1.2.0", "installPath": "/x" }],
            "team@corp": [{ "scope": "project", "version": "9.9.9", "projectPath": "/somewhere" }]
        } }
        """)
        try write(".claude/skills/commit/SKILL.md", "---\nname: commit\ndescription: \"Write a commit message\"\n---\n# Body\n")
        try write(".claude/skills/review/SKILL.md", "---\nname: review\ndescription: >\n  Review the diff\n  carefully.\n---\n")
        try write(".claude/skills/notes/readme.txt", "not a skill")
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: ".claude/skills/gone").path(percentEncoded: false),
                                                   withDestinationPath: "../../missing/gone")

        let inventory = ExtensionsScanner.scan(profile(.claude, ".claude"), homeDirectory: root)
        #expect(inventory.hooks.map(\.event) == ["PreToolUse", "Stop", "Stop"])
        #expect(inventory.hooks[0].matcher == "Bash" && inventory.hooks[0].target == "guard.sh" && inventory.hooks[0].timeout == 10)
        #expect(inventory.hooks[2].type == "http" && inventory.hooks[2].target == "https://example.com/h")
        #expect(inventory.hooks[1].timeout == nil)   // out of range: shown as no timeout, not a crash
        #expect(inventory.hooks[0].source == "~/.claude/settings.json")

        // Project-scope installs are project-level config and stay out (C-11).
        #expect(inventory.plugins.map(\.name) == ["lsp", "themes"])
        #expect(inventory.plugins[0].marketplace == "official" && inventory.plugins[0].version == "1.2.0" && inventory.plugins[0].isEnabled == true)
        #expect(inventory.plugins[1].isEnabled == false)

        let skills = Dictionary(uniqueKeysWithValues: inventory.skills.map { ($0.name, $0) })
        #expect(skills["commit"]?.description == "Write a commit message")
        #expect(skills["review"]?.description == "Review the diff carefully.")
        #expect(skills["notes"]?.isBroken == true)
        #expect(skills["gone"]?.isBroken == true)
        #expect(inventory.problems.isEmpty)
    }

    @Test func codexNotifyHooksFilePluginsAndBundledSkills() throws {
        try write(".codex/config.toml", """
        notify = ["/usr/local/bin/notifier", "--app", "codex"]

        [plugins."browser@bundled"]
        enabled = true

        [plugins."old@market"]
        enabled = false
        """)
        try write(".codex/hooks.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}]}}"#)
        try write(".codex/skills/mine/SKILL.md", "---\nname: mine\ndescription: Mine\n---\n")
        try write(".codex/skills/.system/imagegen/SKILL.md", "---\nname: imagegen\ndescription: Images\n---\n")

        let inventory = ExtensionsScanner.scan(profile(.codex, ".codex"), homeDirectory: root)
        #expect(inventory.hooks.map(\.event) == ["notify", "SessionStart"])
        #expect(inventory.hooks[0].target == "/usr/local/bin/notifier --app codex")
        #expect(inventory.plugins.map { "\($0.name)=\($0.isEnabled == true)" } == ["browser=true", "old=false"])
        #expect(inventory.skills.map { "\($0.name):\($0.origin)" }.sorted() == ["imagegen:bundled", "mine:~/.codex/skills"])
    }

    @Test func grokConfigHooksHookFilesPluginListsAndNestedSkills() throws {
        try write(".grok/config.toml", """
        [plugins]
        enabled = ["team-tools"]
        disabled = ["noisy"]

        [[hooks.PreToolUse]]
        matcher = "Bash|Write"
        hooks = [{ type = "command", command = "/opt/guard.sh", args = ["--strict"], timeout = 5 }]
        """)
        try write(".grok/hooks/start.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo start"}]}]}}"#)
        try write(".grok/hooks/broken.json", "{ nope")
        try write(".grok/skills/group/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship it\n---\n")
        try write(".agents/skills/shared/SKILL.md", "---\nname: shared\ndescription: Shared\n---\n")

        let inventory = ExtensionsScanner.scan(profile(.grok, ".grok"), homeDirectory: root)
        #expect(inventory.hooks.map(\.event) == ["PreToolUse", "SessionStart"])
        #expect(inventory.hooks[0].target == "/opt/guard.sh --strict" && inventory.hooks[0].matcher == "Bash|Write")
        #expect(inventory.plugins.map { "\($0.name)=\($0.isEnabled == true)" } == ["team-tools=true", "noisy=false"])
        #expect(inventory.skills.map(\.name).sorted() == ["deploy", "shared"])
        #expect(inventory.problems.count == 1 && inventory.problems[0].hasPrefix("~/.grok/hooks/broken.json"))
    }

    @Test func missingFilesGiveAnEmptyInventory() {
        let inventory = ExtensionsScanner.scan(profile(.claude, "nothing-here"), homeDirectory: root)
        #expect(inventory.hooks.isEmpty && inventory.plugins.isEmpty && inventory.skills.isEmpty && inventory.problems.isEmpty)
    }

    @Test func frontmatterVariants() {
        #expect(ExtensionsScanner.frontmatter("no frontmatter") == [:])
        #expect(ExtensionsScanner.frontmatter("---\r\nname: 'x'\r\ndescription: |\r\n  a\r\n  b\r\n---\r\n") == ["name": "x", "description": "a b"])
    }
}
