import SurveyKit
import TOMLKit

let t = try TOMLTable(string: fixture)
let unchanged = t.convert(to: .toml)
t["model"] = "gpt-6-mini"
report("LebJe/TOMLKit 0.6.0 (toml++)", unchanged: unchanged, edited: t.convert(to: .toml))
