// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift

@main
struct EmitLog {
    static func main() async throws {
        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let exchange = try await channel.fanout("logs")

        let args = CommandLine.arguments.dropFirst()
        let message = args.isEmpty ? "Hello World!" : args.joined(separator: " ")

        try await channel.basicPublish(
            body: message.data(using: .utf8)!,
            exchange: exchange.name,
            routingKey: ""
        )
        print(" [x] Sent '\(message)'")

        try await connection.close()
    }
}
