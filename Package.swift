// swift-tools-version: 6.0
// SPM dependencies resolved by rules_swift_package_manager for Bazel.

import PackageDescription

let package = Package(
    name: "durian",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/pkl-swift", from: "0.8.2"),
    ]
)
