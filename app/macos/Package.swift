// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "Raven",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(
            name: "Raven",
            path: "sources/Raven",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "RavenTests",
            dependencies: ["Raven"],
            path: "tests/RavenTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
