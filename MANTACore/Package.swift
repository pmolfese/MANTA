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
        .library(name: "MANTACore", targets: ["MANTACore"])
    ],
    targets: [
        .target(
            name: "MANTACore",
            resources: [.copy("Schemas")]
        ),
        .testTarget(
            name: "MANTACoreTests",
            dependencies: ["MANTACore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
