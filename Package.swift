// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Fibonacci",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FibonacciCore", targets: ["FibonacciCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0"),
    ],
    targets: [
        .target(
            name: "FibonacciCore",
            dependencies: ["BigInt"],
            path: "fibonacci/fibonacci",
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "DesignTokens.swift",
                "FibonacciApp.swift",
                "FibonacciViewModel.swift",
            ],
            sources: [
                "FibonacciEngine.swift",
                "FFTMultiplier.swift",
                "MPSGraphFFTBackend.swift",
                "NTTMultiplier.swift",
                "Zrt5.swift",
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShadersGraph"),
            ]
        ),
        .testTarget(
            name: "FibonacciCoreTests",
            dependencies: ["FibonacciCore", "BigInt"],
            path: "Tests/FibonacciCoreTests"
        ),
    ]
)
