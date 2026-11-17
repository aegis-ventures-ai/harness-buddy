// SYNTHETIC fixtures. Their structure is modelled on real ~/.codex/config.toml,
// ~/.grok/config.toml, ~/.claude/settings.json and ~/.claude.json files, but every
// value is invented. Never paste real config files here: env blocks hold secrets.
import Foundation

enum Fixtures {
    static let codex = #"""
# Codex CLI configuration (synthetic test fixture)
notify = ["/usr/local/bin/notifier", "--app", "codex"]

# Default model for new sessions
model = "gpt-6"   # bumped 2026-10
model_reasoning_effort = "high"
sandbox_mode = 'workspace-write'
approval_policy = "on-request"

[desktop]
conversationDetailMode = "compact"
enabled-reasoning-efforts = ["low", "medium", "high"]

[desktop.appearanceDarkChromeTheme]
accent = "#6E56CF"  # real comment; the first hash is inside the string
ink = "#EDEDED"

[plugins."browser@openai-bundled"]
enabled = true

# Local REPL helper
[mcp_servers.node_repl]
command = "/opt/tools/node_repl"
args = [
  "--stdio", # transport
  "--name=repl]#odd",
]
startup_timeout_sec = 30

[mcp_servers.node_repl.env]
NODE_REPL_TOKEN = "synthetic-not-a-secret"
LOG_LEVEL = "info"

[mcp_servers.computer-use]
command = "/opt/tools/cua"
args = []
enabled = false

[projects."/Users/example/dev/app"]
trust_level = "trusted"

[features]
memories = true
release_notes = """
multi-line text with "quotes" and [brackets]
"""

[tui.model_availability_nux]
"gpt-6-sol" = 1

"""#

    static let grok = #"""
[cli]
installer = "self"
# self-update on launch
auto_update = true # set by grok onboarding

[marketplace]
official_marketplace_auto_installed = true

[[marketplace.sources]]
name = "community"
git = "https://example.invalid/skills.git"

[ui]
max_thoughts_width = 80
compact_mode = false

[privacy]
privacy_banner_acked = true

"""#

    /// Shaped like ~/.claude/settings.json (2-space indent, trailing newline).
    static let claudeSettings = #"""
{
  "attribution": {
    "commit": "",
    "pr": ""
  },
  "env": {
    "EXAMPLE_FLAG": "1"
  },
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "WebSearch"
    ],
    "defaultMode": "default"
  },
  "theme": "dark",
  "unknownFutureKey": {
    "nested": [1, 2.50, -3e2, null, "é\/"]
  }
}

"""#

    /// Shaped like ~/.claude.json: ~200 KB, 2-space indent, mcpServers in the
    /// middle of many CLI-owned keys, and *no* trailing newline.
    static let claudeJSON: String = {
        var s = "{\n  \"numStartups\": 69,\n  \"installMethod\": \"native\",\n  \"tipsHistory\": {\n"
        s += (0..<400).map { "    \"tip-\($0)\": \($0)" }.joined(separator: ",\n") + "\n  },\n"
        s += "  \"projects\": {\n"
        s += (0..<600).map { i in
            """
                "/Users/example/dev/project-\(i)": {
                  "allowedTools": [],
                  "history": [
                    {
                      "display": "fix the build \(i) — ünïcödé",
                      "pastedContents": {}
                    }
                  ],
                  "lastCost": 0.\(i),
                  "hasTrustDialogAccepted": \(i % 2 == 0)
                }
            """
        }.joined(separator: ",\n") + "\n  },\n"
        s += """
          "mcpServers": {
            "notes-server": {
              "type": "stdio",
              "command": "/opt/tools/notes-server",
              "args": [
                "serve"
              ],
              "env": {}
            }
          },
          "cachedFeatureFlags": {
        """ + "\n"
        s += (0..<800).map { "    \"flag_\($0)\": { \"on\": \($0 % 3 == 0), \"v\": \"\(String(repeating: "x", count: 40))\" }" }.joined(separator: ",\n")
        s += "\n  },\n  \"userID\": \"0000-synthetic\"\n}"
        return s
    }()
}

extension String {
    var bytes: [UInt8] { Array(utf8) }
}
