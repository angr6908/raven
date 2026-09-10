// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Raven",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Raven",
            path: "sources/Raven"
        ),
        .testTarget(
            name: "RavenTests",
            dependencies: ["Raven"],
            path: "tests/RavenTests"
        )
    ]
)
