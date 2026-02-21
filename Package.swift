// swift-tools-version: 5.7

import PackageDescription

let package = Package(
  name: "AutoSage",

  // MARK: Platforms
  platforms: [
    .macOS(.v11),
  ],

  // MARK: Products
  products: [
    // Shared library with router/model/tool types used by all executables.
    .library(
      name: "AutoSageCore",
      targets: ["AutoSageCore"]
    ),
    // Local command-line utility entrypoint.
    .executable(
      name: "autosage",
      targets: ["autosage"]
    ),
    // HTTP server executable exposing the API surface.
    .executable(
      name: "AutoSageServer",
      targets: ["AutoSageServer"]
    ),
    // macOS control-panel app executable.
    .executable(
      name: "AutoSageControl",
      targets: ["AutoSageControl"]
    ),
  ],

  // MARK: Dependencies
  dependencies: [
    // CLI argument parsing for server startup options.
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      from: "1.3.0"
    ),
  ],

  // MARK: Targets
  targets: [
    // Native FFI bridge modules.
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
      dependencies: [
        "CTruckFFI",
        "CPMPFFI",
        "CQuartetFFI",
        "CVTKFFI",
        "COpen3DFFI",
        "CNgspiceFFI",
      ]
    ),
    .executableTarget(
      name: "AutoSageServer",
      dependencies: [
        "AutoSageCore",
        .product(
          name: "ArgumentParser",
          package: "swift-argument-parser"
        ),
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
      // Fixture OBJ files are bundled for integration tests.
      resources: [
        .process("Fixtures"),
      ]
    ),
  ]
)
