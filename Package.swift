// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ingest",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CIngest"),
        .target(name: "IngestCore", dependencies: ["CIngest"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ingestctl", dependencies: ["IngestCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "IngestApp", dependencies: ["IngestCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "IngestCoreTests", dependencies: ["IngestCore", "CIngest"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
