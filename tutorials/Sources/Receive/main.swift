// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift

@main
struct Receive {
    static func main() async throws {
        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let queue = try await channel.queue("hello")

        print(" [*] Waiting for messages. To exit press CTRL+C")

        let stream = try await channel.basicConsume(queue: queue.name, acknowledgementMode: .automatic)
        for try await message in stream {
            print(" [x] Received '\(message.bodyString ?? "")'")
        }
    }
}
