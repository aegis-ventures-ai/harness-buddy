import SurveyKit
import TOMLDecoder

let t = try TOMLTable(source: fixture)
report("dduan/TOMLDecoder 0.4.5 (pure Swift)", unchanged: nil, edited: nil,
       note: "parses (top-level keys \(t.keys.sorted())); there is no encoder: TOMLTable.encode(to:) throws .notReallyCodable")
