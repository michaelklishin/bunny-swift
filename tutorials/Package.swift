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
    name: "Tutorials",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        // Tutorial 1: Hello World
        .executableTarget(name: "Send", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
        .executableTarget(name: "Receive", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),

        // Tutorial 2: Work Queues
        .executableTarget(name: "NewTask", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
        .executableTarget(name: "Worker", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),

        // Tutorial 3: Publish/Subscribe
        .executableTarget(name: "EmitLog", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
        .executableTarget(name: "ReceiveLogs", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),

        // Tutorial 4: Routing
        .executableTarget(name: "EmitLogDirect", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
        .executableTarget(name: "ReceiveLogsDirect", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),

        // Tutorial 5: Topics
        .executableTarget(name: "EmitLogTopic", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
        .executableTarget(name: "ReceiveLogsTopic", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),

        // Tutorial 6: RPC
        .executableTarget(name: "RPCServer", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
        .executableTarget(name: "RPCClient", dependencies: [.product(name: "BunnySwift", package: "bunny-swift")]),
    ]
)
