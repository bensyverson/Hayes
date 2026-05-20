// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Use the sibling Operator checkout for co-development when it's present;
/// otherwise fall back to the published repo so CI and fresh clones (which
/// only check out this repo) can resolve the dependency. `branch: "main"`
/// mirrors how Operator itself depends on LLM.
let operatorCheckout = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Hayes/
    .deletingLastPathComponent() // parent of Hayes/
    .appendingPathComponent("Operator/Package.swift")
let operatorDependency: Package.Dependency = FileManager.default
    .fileExists(atPath: operatorCheckout.path)
    ? .package(path: "../Operator")
    : .package(url: "https://github.com/bensyverson/Operator", branch: "main")

let package = Package(
    name: "Hayes",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HayesCore", targets: ["HayesCore"]),
        .executable(name: "hayes", targets: ["HayesCommand"]),
    ],
    dependencies: [
        operatorDependency,
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
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
            dependencies: [
                "HayesCore",
                .product(name: "Operator", package: "Operator"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HayesCoreTests",
            dependencies: ["HayesCore"]
        ),
        .testTarget(
            name: "HayesCommandTests",
            dependencies: ["HayesCommand"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
