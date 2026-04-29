// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NetPulse",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "NetPulse",
            targets: ["NetPulse"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "NetPulse"
        ),
        .testTarget(
            name: "NetPulseTests",
            dependencies: ["NetPulse"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
