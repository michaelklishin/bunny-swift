// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift

@main
struct EmitLogDirect {
    static func main() async throws {
        let connection = try await Connection.open()
        let channel = try await connection.openChannel()

        let exchange = try await channel.direct("direct_logs")

        var args = Array(CommandLine.arguments.dropFirst())
        let severity = args.isEmpty ? "info" : args.removeFirst()
        let message = args.isEmpty ? "Hello World!" : args.joined(separator: " ")

        try await channel.basicPublish(
            body: message.data(using: .utf8)!,
            exchange: exchange.name,
            routingKey: severity
        )
        print(" [x] Sent '\(severity):\(message)'")

        try await connection.close()
    }
}
