import SurveyKit
import Toml

let doc = try Toml.Annotated(parsing: fixture)
let edited = doc.settingValue(.string("gpt-6-mini"), atTable: [], forKey: "model")
    .settingValue(.bool(false), atTable: ["cli"], forKey: "auto_update")
let removed = edited.removingTable(at: ["mcp_servers", "docs"]).render()
let missing = doc.settingValue(.string("x"), atTable: ["no", "such"], forKey: "k").render()
report("akira-toriyama/swift-toml-edit 3.0.1 (pure Swift, lossless DOM)", unchanged: doc.render(), edited: edited.render(),
       note: "removingTable([mcp_servers, docs]) leaves [mcp_servers.docs.env] behind = \(removed.contains("[mcp_servers.docs.env]")); "
           + "setting into a missing table creates it = \(missing.contains("[no.such]"))")
