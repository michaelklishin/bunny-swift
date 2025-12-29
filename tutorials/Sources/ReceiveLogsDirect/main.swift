// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift

@main
struct ReceiveLogsDirect {
    static func main() async throws {
        let severities = Array(CommandLine.arguments.dropFirst())
        guard !severities.isEmpty else {
            print("Usage: ReceiveLogsDirect [info] [warning] [error]")
            return
        }

        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let exchange = try await channel.direct("direct_logs")
        let queue = try await channel.queue("", exclusive: true)

        for severity in severities {
            try await queue.bind(to: exchange, routingKey: severity)
        }

        print(" [*] Waiting for logs. To exit press CTRL+C")

        let stream = try await channel.basicConsume(queue: queue.name, acknowledgementMode: .automatic)
        for try await message in stream {
            print(" [x] \(message.deliveryInfo.routingKey):\(message.bodyString ?? "")")
        }
    }
}
