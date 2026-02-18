// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImmichVaultModules",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "ImmichClient", targets: ["ImmichClient"]),
        .library(name: "PhotosScanner", targets: ["PhotosScanner"]),
        .library(name: "TranscodeEngine", targets: ["TranscodeEngine"]),
        .library(name: "MetadataEngine", targets: ["MetadataEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        // MARK: - Core
        .target(
            name: "Core",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Core"
        ),

        // MARK: - ImmichClient
        .target(
            name: "ImmichClient",
            dependencies: ["Core"],
            path: "Sources/ImmichClient"
        ),

        // MARK: - PhotosScanner
        .target(
            name: "PhotosScanner",
            dependencies: ["Core"],
            path: "Sources/PhotosScanner"
        ),

        // MARK: - TranscodeEngine
        .target(
            name: "TranscodeEngine",
            dependencies: ["Core", "MetadataEngine"],
            path: "Sources/TranscodeEngine"
        ),

        // MARK: - MetadataEngine
        .target(
            name: "MetadataEngine",
            dependencies: ["Core"],
            path: "Sources/MetadataEngine"
        ),

        // MARK: - Tests
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "ImmichClientTests",
            dependencies: ["ImmichClient"],
            path: "Tests/ImmichClientTests"
        ),
    ]
)
