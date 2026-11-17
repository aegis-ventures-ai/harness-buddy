// Shared synthetic fixture and verdict printer for the survey executables.
import Foundation
public let fixture = """
# Codex config (synthetic)
model = "gpt-6"   # default model
model_reasoning_effort = "high"
approval_policy = "on-request"

[cli]
# keep the CLI current
auto_update = true

[mcp_servers.docs]
command = "npx"
args = ["-y", "docs-mcp"]

[mcp_servers.docs.env]
LOG_LEVEL = "info"

"""

public func report(_ name: String, unchanged: String?, edited: String?, note: String = "") {
    func verdict(_ s: String?) -> String {
        guard let s else { return "n/a (no writer)" }
        let comments = s.contains("# default model") && s.contains("# keep the CLI current")
        let m = s.range(of: "model =")?.lowerBound, a = s.range(of: "approval_policy")?.lowerBound
        let order = m != nil && a != nil && m! < a!
        return "byteIdentical=\(s == fixture) comments=\(comments) keyOrder=\(order)"
    }
    print("## \(name)")
    print("  round-trip: \(verdict(unchanged))")
    print("  after edit: \(verdict(edited))")
    if !note.isEmpty { print("  note: \(note)") }
    if let edited { print(edited.split(separator: "\n", omittingEmptySubsequences: false).map { "  | " + $0 }.joined(separator: "\n")) }
}
