// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AutoSage",
    platforms: [
        .macOS(.v10_14)
    ],
    products: [
        .library(
            name: "AutoSageCore",
            targets: ["AutoSageCore"]
        ),
        .executable(
            name: "AutoSageServer",
            targets: ["AutoSageServer"]
        )
    ],
    dependencies: [
        // No external dependencies.
    ],
    targets: [
        .target(
            name: "AutoSageCore",
            dependencies: []
        ),
        .target(
            name: "AutoSageServer",
            dependencies: ["AutoSageCore"]
        ),
        .testTarget(
            name: "AutoSageCoreTests",
            dependencies: ["AutoSageCore"]
        )
    ]
)
