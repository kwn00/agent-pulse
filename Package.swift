// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentPulse", targets: ["AgentPulse"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentPulse",
            path: "Sources/AgentPulse",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AgentPulseTests",
            dependencies: ["AgentPulse"],
            path: "Tests/AgentPulseTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
