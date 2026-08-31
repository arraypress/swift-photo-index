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
    ],
    targets: [
        .target(
            name: "PhotoIndex",
            dependencies: [
                .product(name: "SpeechTranscriber", package: "swift-speech-transcriber"),
            ]
        ),
        .testTarget(name: "PhotoIndexTests", dependencies: ["PhotoIndex"]),
    ]
)
