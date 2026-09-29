// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnboardCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // Shared by the app and the daemon. OnboardCLI rides in the same
        // product so the onboardd target gets it without extra project
        // wiring (structural pbxproj changes need manual Xcode steps).
        .library(name: "OnboardCore", targets: ["OnboardCore", "OnboardCLI"]),
        // SwiftUI views. Separate product so every preview builds without the app target.
        .library(name: "OnboardUI", targets: ["OnboardUI"]),
    ],
    dependencies: [
        // Pre-approved by the build spec (§0).
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "OnboardCore"),
        .target(name: "OnboardCLI", dependencies: [
            "OnboardCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // The String Catalog has to be declared, or it is not compiled into
        // the module bundle and every lookup falls back to its key.
        .target(
            name: "OnboardUI",
            dependencies: ["OnboardCore"],
            resources: [.process("Resources")]
        ),
        // OnboardUI too, so the String Catalog can be tested: a package's
        // localization fails *silently*, and only resolving a string proves
        // the module bundle is being reached.
        .testTarget(name: "OnboardCoreTests", dependencies: ["OnboardCore", "OnboardUI", "OnboardCLI"]),
    ]
)
