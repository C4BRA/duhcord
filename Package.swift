// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Duhcord",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Duhcord", targets: ["Duhcord"]),
    ],
    targets: [
        // Networking, models, state and markdown parsing. Foundation only, no AppKit.
        .target(name: "DuhcordCore"),
        // The AppKit user interface.
        .executableTarget(name: "Duhcord", dependencies: ["DuhcordCore"]),
        .testTarget(name: "DuhcordCoreTests", dependencies: ["DuhcordCore"]),
    ]
)
