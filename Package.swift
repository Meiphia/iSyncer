// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iSyncer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "iSyncer", targets: ["iSyncer"])],
    targets: [
        .target(name: "ClassicSync"),
        .executableTarget(name: "iSyncer", dependencies: ["ClassicSync"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ClassicSyncTests", dependencies: ["ClassicSync"]),
        .testTarget(name: "iSyncerTests", dependencies: ["iSyncer", "ClassicSync"])
    ]
)
