// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift

@main
struct NewTask {
    static func main() async throws {
        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let queue = try await channel.queue("task_queue", durable: true)

        let args = CommandLine.arguments.dropFirst()
        let message = args.isEmpty ? "Hello World!" : args.joined(separator: " ")

        try await channel.basicPublish(
            body: message.data(using: .utf8)!,
            routingKey: queue.name,
            properties: .persistent
        )
        print(" [x] Sent '\(message)'")

        try await connection.close()
    }
}
