// swift-tools-version: 6.2
import PackageDescription

// MANTACore: the pure, platform-agnostic detection/export core shared by the
// MANTA iOS app and the (planned) macOS receiver. No ARKit/UIKit — simd +
// Foundation only — so it builds for macOS and its tests run on the host via
// `swift test` (much faster than the app's xcodebuild-on-simulator loop).
let package = Package(
    name: "MANTACore",
    platforms: [
        .iOS(.v26),
        .macOS(.v13)
    ],
    products: [
        .library(name: "MANTACore", targets: ["MANTACore"]),
        .library(name: "MANTAProcessing", targets: ["MANTAProcessing"])
    ],
    targets: [
        .target(name: "MANTAProcessing", dependencies: ["MANTACore"]),
        .target(
            name: "MANTACore",
            resources: [.copy("Schemas")]
        ),
        .testTarget(
            name: "MANTACoreTests",
            dependencies: ["MANTACore", "MANTAProcessing"],
            resources: [.copy("Fixtures")]
        )
    ]
)
