// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.4")
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
