// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift
import Foundation

@main
struct RPCClient {
    static func main() async throws {
        let n = Int(CommandLine.arguments.dropFirst().first ?? "30") ?? 30

        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let replyQueue = try await channel.queue("", exclusive: true)
        let correlationId = UUID().uuidString

        print(" [x] Requesting fib(\(n))")

        try await channel.basicPublish(
            body: "\(n)".data(using: .utf8)!,
            routingKey: "rpc_queue",
            properties: BasicProperties(
                correlationId: correlationId,
                replyTo: replyQueue.name
            )
        )

        let stream = try await channel.basicConsume(queue: replyQueue.name, acknowledgementMode: .automatic)
        for try await message in stream {
            if message.properties.correlationId == correlationId {
                let result = message.bodyString ?? "?"
                print(" [.] Got \(result)")
                break
            }
        }

        try await connection.close()
    }
}
