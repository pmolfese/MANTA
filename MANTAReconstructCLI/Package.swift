// swift-tools-version: 6.0
import PackageDescription

// A standalone command-line photogrammetry reconstruction tool for MANTA.
//
// It links MANTACore (the pure detection/export core) via a local path
// dependency and drives RealityKit's Object Capture (PhotogrammetrySession)
// to turn a captured `.manta` bundle into a reconstructed USDZ model, poses,
// and alignment diagnostics. Because it is its own package, it compiles and
// runs independently of the MANTA app / receiver targets — reconstruct a
// heavy capture from the terminal while continuing to work in MANTA.
let package = Package(
    name: "MANTAReconstructCLI",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../MANTACore")
    ],
    targets: [
        .executableTarget(
            name: "manta-reconstruct",
            dependencies: [
                .product(name: "MANTACore", package: "MANTACore")
            ],
            // The reconstruction driver was ported from the receiver, which is
            // written for Swift 6 concurrency; the v5 language mode keeps this
            // small CLI free of strict-concurrency friction around its
            // synchronous progress/log callbacks.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
