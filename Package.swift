// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ahenk",
    defaultLocalization: "en",
    // LSMinimumSystemVersion is 14.2 (process taps); SwiftPM cannot express a
    // minor version here, so 14.2-only APIs sit behind `#available` checks.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AhenkKit", targets: ["AhenkKit"]),
        .executable(name: "Ahenk", targets: ["AhenkApp"]),
    ],
    targets: [
        // Lock-free atomics and a seqlock for the real-time audio path, as
        // static inline C (Swift's Synchronization.Atomic needs macOS 15).
        // Imported by AhenkKit only, never re-exported.
        .target(name: "AhenkAtomics"),
        // Pure logic: settings, models, protocols, demo content, DSP. No AppKit
        // or SwiftUI. Strict Swift 6 concurrency; every type is unit-tested.
        .target(
            name: "AhenkKit",
            dependencies: ["AhenkAtomics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // AppKit + SwiftUI app. Swift 5 mode at the UI interop boundary; the
        // concurrency-sensitive logic lives in AhenkKit.
        .executableTarget(
            name: "AhenkApp",
            dependencies: ["AhenkKit"],
            resources: [
                // Turkish UI strings (English keys are the source text).
                .process("Resources/tr.lproj"),
                // Metal sources, compiled at runtime (see docs/PROGRESS.md).
                .copy("Resources/Shaders"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AhenkKitTests",
            dependencies: ["AhenkKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
