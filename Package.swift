// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Duhcord",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Duhcord", targets: ["Duhcord"]),
        .executable(name: "DuhcordUpdater", targets: ["DuhcordUpdater"]),
    ],
    targets: [
        // Update manifest, signature checks and the installer protocol, shared by the app and the installer.
        .target(name: "DuhcordUpdateKit"),
        // Networking, models, state and markdown parsing. Foundation only, no AppKit.
        .target(name: "DuhcordCore", dependencies: ["DuhcordUpdateKit"]),
        // The AppKit user interface.
        .executableTarget(name: "Duhcord", dependencies: ["DuhcordCore", "DuhcordUpdateKit"]),
        // The installer helper (an XPC service inside the app) that swaps in verified updates.
        .executableTarget(name: "DuhcordUpdater", dependencies: ["DuhcordUpdateKit"]),
        .testTarget(name: "DuhcordCoreTests", dependencies: ["DuhcordCore", "DuhcordUpdateKit"]),
    ]
)
