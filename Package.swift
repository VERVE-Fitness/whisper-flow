// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WhisperFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "WhisperFlow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/WhisperFlow",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "WhisperFlowTests",
            dependencies: ["WhisperFlow"],
            path: "Tests/WhisperFlowTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
