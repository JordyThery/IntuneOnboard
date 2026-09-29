// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnboardCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // Shared by the app and the daemon. Includes OnboardCLI so the
        // daemon target needs no separate package dependency.
        .library(name: "OnboardCore", targets: ["OnboardCore", "OnboardCLI"]),
        // SwiftUI views; a separate product so previews build independently.
        .library(name: "OnboardUI", targets: ["OnboardUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "OnboardCore"),
        .target(name: "OnboardCLI", dependencies: [
            "OnboardCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // Declared so the String Catalog is compiled into the module bundle.
        .target(
            name: "OnboardUI",
            dependencies: ["OnboardCore"],
            resources: [.process("Resources")]
        ),
        // OnboardUI too, so tests can resolve strings from its catalog.
        .testTarget(name: "OnboardCoreTests", dependencies: ["OnboardCore", "OnboardUI", "OnboardCLI"]),
    ]
)
