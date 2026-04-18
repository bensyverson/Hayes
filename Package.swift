// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Hayes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HayesCore", targets: ["HayesCore"]),
        .executable(name: "hayes", targets: ["HayesCommand"]),
    ],
    dependencies: [
        .package(url: "https://github.com/bensyverson/Operator", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HayesCore",
            dependencies: [
                .product(name: "Operator", package: "Operator"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "HayesCommand",
            dependencies: ["HayesCore"]
        ),
        .testTarget(
            name: "HayesCoreTests",
            dependencies: ["HayesCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
