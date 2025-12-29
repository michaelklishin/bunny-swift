// swift-tools-version: 6.0
//
// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import PackageDescription

let package = Package(
    name: "BunnySwift",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "BunnySwift",
            targets: ["BunnySwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.87.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        // MARK: - Main Library
        .target(
            name: "BunnySwift",
            dependencies: [
                "AMQPProtocol",
                "Transport",
                "Recovery",
            ]
        ),

        // MARK: - Internal Modules
        .target(
            name: "AMQPProtocol",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
            ]
        ),
        .target(
            name: "Transport",
            dependencies: [
                "AMQPProtocol",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "Recovery",
            dependencies: [
                "AMQPProtocol",
                "Transport",
            ]
        ),

        // MARK: - Unit Tests
        .testTarget(
            name: "AMQPProtocolTests",
            dependencies: ["AMQPProtocol"]
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["Transport"]
        ),
        .testTarget(
            name: "BunnySwiftTests",
            dependencies: ["BunnySwift"]
        ),
        .testTarget(
            name: "RecoveryTests",
            dependencies: ["Recovery"]
        ),

        // MARK: - Integration Tests
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["BunnySwift"]
        ),
    ]
)
