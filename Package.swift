// swift-tools-version:5.9
import Foundation
import PackageDescription

/// The voice helper links Discord's libdave, which scripts/build-libdave.sh builds into Vendor/. Without it
/// everything else still builds; release bundles require it.
let libdaveDirectory = Context.packageDirectory + "/Vendor/libdave/lib"
let hasLibdave = FileManager.default.fileExists(atPath: libdaveDirectory + "/libCDave.a")

var products: [Product] = [
    .executable(name: "Duhcord", targets: ["Duhcord"]),
    .executable(name: "DuhcordUpdater", targets: ["DuhcordUpdater"]),
    .executable(name: "DuhcordMediaDecoder", targets: ["DuhcordMediaDecoder"]),
]

let strictConcurrency: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

var targets: [Target] = [
    // Update manifest, signature checks and the installer protocol, shared by the app and the installer.
    .target(name: "DuhcordUpdateKit", swiftSettings: strictConcurrency),
    // ImageIO decoding, shared by the app's in-process fallback and its sandboxed media helper.
    .target(name: "DuhcordMediaKit", swiftSettings: strictConcurrency),
    // Networking, models, state and markdown parsing. Foundation only, no AppKit.
    .target(name: "DuhcordCore", dependencies: ["DuhcordUpdateKit"], swiftSettings: strictConcurrency),
    // The voice helper's protocol, packet format and transport encryption, shared by the app and the helper.
    .target(name: "DuhcordVoiceKit", dependencies: ["DuhcordUpdateKit"], swiftSettings: strictConcurrency),
    // The AppKit user interface.
    .executableTarget(name: "Duhcord", dependencies: ["DuhcordCore", "DuhcordUpdateKit", "DuhcordVoiceKit", "DuhcordMediaKit"],
                      swiftSettings: strictConcurrency),
    // The installer helper (an XPC service inside the app) that swaps in verified updates.
    .executableTarget(name: "DuhcordUpdater", dependencies: ["DuhcordUpdateKit"], swiftSettings: strictConcurrency),
    // Decodes untrusted still and animated images outside the app's process.
    .executableTarget(name: "DuhcordMediaDecoder", dependencies: ["DuhcordMediaKit", "DuhcordUpdateKit"],
                      swiftSettings: strictConcurrency),
    .testTarget(name: "DuhcordCoreTests", dependencies: ["DuhcordCore", "DuhcordUpdateKit", "DuhcordVoiceKit", "DuhcordMediaKit"],
                swiftSettings: strictConcurrency),
]

if hasLibdave {
    products.append(.executable(name: "DuhcordVoice", targets: ["DuhcordVoice"]))
    targets += [
        // libdave's C API, linked from the static library build-libdave.sh produced.
        .target(name: "CDave", linkerSettings: [
            .unsafeFlags(["-L", libdaveDirectory]),
            .linkedLibrary("CDave"),
            .linkedLibrary("c++"),
        ]),
        // The voice helper: an XPC service that runs calls in its own sandbox, away from the account token.
        .executableTarget(name: "DuhcordVoice", dependencies: ["CDave", "DuhcordCore", "DuhcordUpdateKit", "DuhcordVoiceKit"],
                          swiftSettings: strictConcurrency),
    ]
}

let package = Package(
    name: "Duhcord",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
