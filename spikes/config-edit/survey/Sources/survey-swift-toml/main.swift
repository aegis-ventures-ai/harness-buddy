import SurveyKit
import TOML

// swift-toml exposes only Codable; TOMLValue is not itself Decodable, so the
// best a config editor could do is a typed model (unknown keys are dropped).
struct Config: Codable {
    struct CLI: Codable { var auto_update: Bool }
    struct Server: Codable { var command: String; var args: [String]; var env: [String: String]? }
    var model: String
    var model_reasoning_effort: String
    var approval_policy: String
    var cli: CLI
    var mcp_servers: [String: Server]
}

var c = try TOMLDecoder().decode(Config.self, from: fixture)
let enc = TOMLEncoder()
let unchanged = try enc.encodeToString(c)
c.model = "gpt-6-mini"
report("mattt/swift-toml 2.1.1 (toml++)", unchanged: unchanged, edited: try enc.encodeToString(c),
       note: "Codable only; the encoder builds a [String: TOMLValue] Dictionary, so key order is hash order, and unknown keys vanish")
