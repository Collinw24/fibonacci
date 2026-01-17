// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FibBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "FibBench",
            dependencies: ["BigInt"],
            path: "Sources"
        )
    ]
)
