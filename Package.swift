// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-photo-index",
    platforms: [
        // The floor is set by swift-speech-transcriber (SpeechAnalyzer), which
        // the --audio path rides. Everything else here runs on far older systems.
        .macOS(.v26)
    ],
    products: [
        .library(name: "PhotoIndex", targets: ["PhotoIndex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arraypress/swift-speech-transcriber.git", from: "1.3.0"),
        // The audit's checkers: Luhn and network tables for card-shaped
        // numbers, and the secret-pattern catalogue for keys in screenshots.
        // Both are small, pure Swift, and already the fleet's own.
        .package(url: "https://github.com/arraypress/swift-credit-card-validator.git", from: "1.0.0"),
        .package(url: "https://github.com/arraypress/swift-secret-scanner.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "PhotoIndex",
            dependencies: [
                .product(name: "SpeechTranscriber", package: "swift-speech-transcriber"),
                .product(name: "CreditCardValidator", package: "swift-credit-card-validator"),
                .product(name: "SecretScanner", package: "swift-secret-scanner"),
            ]
        ),
        .testTarget(name: "PhotoIndexTests", dependencies: ["PhotoIndex"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
