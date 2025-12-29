// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift
import Foundation

@main
struct Worker {
    static func main() async throws {
        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let queue = try await channel.queue("task_queue", durable: true)

        try await channel.basicQos(prefetchCount: 1)
        print(" [*] Waiting for messages. To exit press CTRL+C")

        let stream = try await channel.basicConsume(queue: queue.name)
        for try await message in stream {
            let body = message.bodyString ?? ""
            print(" [x] Received '\(body)'")

            // Simulate work: count dots
            let dots = body.filter { $0 == "." }.count
            try await Task.sleep(for: .seconds(dots))

            print(" [x] Done")
            try await message.ack()
        }
    }
}
