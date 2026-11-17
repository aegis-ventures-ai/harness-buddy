// swift-tools-version: 6.0
// Library survey: does each Swift TOML library preserve formatting on write?
// One executable per library, because swift-toml's `TOML` module and
// swift-toml-edit's `Toml` module collide on a case-insensitive filesystem.
// Run each in its own scratch path (shared .build fails on the TOML/Toml clash):
//   for e in survey-tomlkit survey-swift-toml survey-tomldecoder survey-toml-edit; do
//     swift run --scratch-path .build/$e $e; done
import PackageDescription

let package = Package(
    name: "survey",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.1.1"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git", exact: "3.0.1"),
    ],
    targets: [
        .target(name: "SurveyKit"),
        .executableTarget(name: "survey-tomlkit", dependencies: ["SurveyKit", .product(name: "TOMLKit", package: "TOMLKit")]),
        .executableTarget(name: "survey-swift-toml", dependencies: ["SurveyKit", .product(name: "TOML", package: "swift-toml")]),
        .executableTarget(name: "survey-tomldecoder", dependencies: ["SurveyKit", .product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .executableTarget(name: "survey-toml-edit", dependencies: ["SurveyKit", .product(name: "Toml", package: "swift-toml-edit")]),
    ]
)
