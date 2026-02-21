// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AutoSage",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "AutoSageCore",
            targets: ["AutoSageCore"]
        ),
        .executable(
            name: "autosage",
            targets: ["autosage"]
        ),
        .executable(
            name: "AutoSageServer",
            targets: ["AutoSageServer"]
        ),
        .executable(
            name: "AutoSageControl",
            targets: ["AutoSageControl"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .systemLibrary(
            name: "CTruckFFI",
            path: "Native/truck_ffi"
        ),
        .systemLibrary(
            name: "CPMPFFI",
            path: "Native/pmp_ffi"
        ),
        .systemLibrary(
            name: "CQuartetFFI",
            path: "Native/quartet_ffi"
        ),
        .systemLibrary(
            name: "CVTKFFI",
            path: "Native/vtk_ffi"
        ),
        .systemLibrary(
            name: "COpen3DFFI",
            path: "Native/open3d_ffi"
        ),
        .systemLibrary(
            name: "CNgspiceFFI",
            path: "Native/ngspice_ffi"
        ),
        .target(
            name: "AutoSageCore",
            dependencies: ["CTruckFFI", "CPMPFFI", "CQuartetFFI", "CVTKFFI", "COpen3DFFI", "CNgspiceFFI"]
        ),
        .executableTarget(
            name: "AutoSageServer",
            dependencies: [
                "AutoSageCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "autosage",
            dependencies: ["AutoSageCore"]
        ),
        .executableTarget(
            name: "AutoSageControl",
            dependencies: ["AutoSageCore"]
        ),
        .testTarget(
            name: "AutoSageCoreTests",
            dependencies: ["AutoSageCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
