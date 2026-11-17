// swift-tools-version: 6.2
// Core logic for Harness Butler: subscriptions, usage providers, refresh scheduling.
// Everything here is UI-free so it can be unit-tested with `swift test`.
import PackageDescription

let package = Package(
    name: "HarnessButlerKit",
    platforms: [.macOS("27.0")],
    products: [.library(name: "HarnessButlerKit", targets: ["HarnessButlerKit"])],
    targets: [
        .target(name: "HarnessButlerKit"),
        .executableTarget(name: "hb-probe", dependencies: ["HarnessButlerKit"]),
        .testTarget(name: "HarnessButlerKitTests", dependencies: ["HarnessButlerKit"]),
    ]
)
