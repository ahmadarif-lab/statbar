// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StatBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "StatKit",
            path: "Sources/StatKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "StatBar",
            dependencies: ["StatKit"],
            path: "Sources/StatBar"
        ),
        .testTarget(
            name: "StatKitTests",
            dependencies: ["StatKit"],
            path: "Tests/StatKitTests"
        ),
    ]
)
