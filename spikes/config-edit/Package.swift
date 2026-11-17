// swift-tools-version: 6.0
// Spike 04: format-preserving config editing (TOML + JSON) and a safe write protocol.
// The TOML and JSON edit layers are pure Swift. dduan/TOMLDecoder (pure Swift,
// TOML 1.1) is used only as an independent parser to validate edit results.
// The library survey lives in ./survey (a separate package).
import PackageDescription

let package = Package(
    name: "ConfigEdit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ConfigEdit", targets: ["ConfigEdit"])],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "ConfigEdit", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .testTarget(name: "ConfigEditTests", dependencies: ["ConfigEdit"]),
    ]
)
