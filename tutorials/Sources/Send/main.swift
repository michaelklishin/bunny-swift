// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift

@main
struct Send {
    static func main() async throws {
        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let queue = try await channel.queue("hello")

        try await channel.basicPublish(
            body: "Hello World!".data(using: .utf8)!,
            routingKey: queue.name
        )
        print(" [x] Sent 'Hello World!'")

        try await connection.close()
    }
}
