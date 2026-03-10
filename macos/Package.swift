// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ech0Mac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Ech0Mac", targets: ["Ech0Mac"]),
    ],
    targets: [
        .executableTarget(
            name: "Ech0Mac",
            path: "Sources/Ech0Mac"
        ),
        .testTarget(
            name: "Ech0MacTests",
            dependencies: ["Ech0Mac"],
            path: "Tests/Ech0MacTests"
        ),
    ]
)
