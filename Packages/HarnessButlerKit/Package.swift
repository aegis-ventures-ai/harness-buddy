// swift-tools-version: 6.2
// Core logic for Harness Butler: subscriptions, usage providers, refresh scheduling.
// Everything here is UI-free so it can be unit-tested with `swift test`.
import PackageDescription

let package = Package(
    name: "HarnessButlerKit",
    platforms: [.macOS("27.0")],
    products: [.library(name: "HarnessButlerKit", targets: ["HarnessButlerKit"])],
    dependencies: [
        // Independent TOML parser, used only to validate every config edit (spike 04).
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "HarnessButlerKit", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .executableTarget(name: "hb-probe", dependencies: ["HarnessButlerKit"]),
        .testTarget(name: "HarnessButlerKitTests", dependencies: ["HarnessButlerKit", .product(name: "TOMLDecoder", package: "TOMLDecoder")]),
    ]
)
