// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin
//
// Portions derived from PostgresNIO (MIT License)
// Copyright (c) 2017-2024 Vapor

public struct ConnectionLease<Connection: PooledConnection>: Sendable {
    public let connection: Connection

    @usableFromInline
    let releaseHandler: @Sendable (Connection) -> Void

    @inlinable
    public init(connection: Connection, release: @escaping @Sendable (Connection) -> Void) {
        self.connection = connection
        self.releaseHandler = release
    }

    @inlinable
    public func release() {
        releaseHandler(connection)
    }
}
