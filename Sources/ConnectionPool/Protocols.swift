// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin
//
// Portions derived from PostgresNIO (MIT License)
// Copyright (c) 2017-2024 Vapor

public protocol PooledConnection: AnyObject, Sendable {
    associatedtype ID: Hashable & Sendable

    var id: ID { get }
    func onClose(_ closure: @escaping @Sendable ((any Error)?) -> Void)
    func close()
}

public protocol ConnectionRequestProtocol: Sendable {
    associatedtype ID: Hashable & Sendable
    associatedtype Connection: PooledConnection

    var id: ID { get }
    func complete(with result: Result<ConnectionLease<Connection>, ConnectionPoolError>)
}

public protocol ConnectionKeepAliveBehavior: Sendable {
    associatedtype Connection: PooledConnection

    var keepAliveFrequency: Duration? { get }
    func runKeepAlive(for connection: Connection) async throws
}

public struct NoKeepAliveBehavior<Connection: PooledConnection>: ConnectionKeepAliveBehavior {
    public var keepAliveFrequency: Duration? { nil }

    public init() {}

    public func runKeepAlive(for connection: Connection) async throws {}
}

public protocol ConnectionPoolObservabilityDelegate: Sendable {
    associatedtype ConnectionID: Hashable & Sendable

    func connectionCreated(id: ConnectionID)
    func connectionClosed(id: ConnectionID)
    func requestQueued()
    func requestDequeued()
    func requestFailed()
}

public struct NoOpConnectionPoolObservabilityDelegate<ConnectionID: Hashable & Sendable>:
    ConnectionPoolObservabilityDelegate
{
    public init() {}

    public func connectionCreated(id: ConnectionID) {}
    public func connectionClosed(id: ConnectionID) {}
    public func requestQueued() {}
    public func requestDequeued() {}
    public func requestFailed() {}
}
