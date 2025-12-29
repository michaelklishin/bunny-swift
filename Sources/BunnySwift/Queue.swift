// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import AMQPProtocol

/// Queue type determines the queue implementation used by RabbitMQ.
///
/// See [Queue Types](https://www.rabbitmq.com/docs/queues#queue-types) for details.
public enum QueueType: Sendable, Hashable {
    /// Classic queues
    case classic
    /// Quorum queues: replicated, durable queues
    case quorum
    /// Streams: replicated append-only log with non-destructive consumption.
    /// AMQP 0-9-1 clients such as BunnySwift can only use certain basic stream features;
    /// consider using a RabbitMQ Stream Protocol client instead.
    case stream
    /// Custom or plugin-provided queue types.
    case custom(String)

    /// The string value sent to RabbitMQ
    public var rawValue: String {
        switch self {
        case .classic: return "classic"
        case .quorum: return "quorum"
        case .stream: return "stream"
        case .custom(let value): return value
        }
    }

    /// Converts to the AMQP 0-9-1 table value for the `x-queue-type` argument
    public var asTableValue: FieldValue {
        .string(rawValue)
    }
}

public struct Queue: Sendable {
    public let name: String
    public let messageCount: UInt32
    public let consumerCount: UInt32
    private let channel: Channel

    internal init(channel: Channel, name: String, messageCount: UInt32 = 0, consumerCount: UInt32 = 0) {
        self.channel = channel
        self.name = name
        self.messageCount = messageCount
        self.consumerCount = consumerCount
    }

    // MARK: - Binding

    @discardableResult
    public func bind(to exchange: Exchange, routingKey: String = "", arguments: Table = [:]) async throws -> Queue {
        try await channel.queueBind(queue: name, exchange: exchange.name, routingKey: routingKey, arguments: arguments)
        return self
    }

    @discardableResult
    public func bind(to exchangeName: String, routingKey: String = "", arguments: Table = [:]) async throws -> Queue {
        try await channel.queueBind(queue: name, exchange: exchangeName, routingKey: routingKey, arguments: arguments)
        return self
    }

    @discardableResult
    public func unbind(from exchange: Exchange, routingKey: String = "", arguments: Table = [:]) async throws -> Queue {
        try await channel.queueUnbind(queue: name, exchange: exchange.name, routingKey: routingKey, arguments: arguments)
        return self
    }

    @discardableResult
    public func unbind(from exchangeName: String, routingKey: String = "", arguments: Table = [:]) async throws -> Queue {
        try await channel.queueUnbind(queue: name, exchange: exchangeName, routingKey: routingKey, arguments: arguments)
        return self
    }

    // MARK: - Consuming

    public func consume(
        consumerTag: String = "",
        acknowledgementMode: ConsumerAcknowledgementMode = .manual,
        exclusive: Bool = false,
        arguments: Table = [:]
    ) async throws -> MessageStream {
        try await channel.basicConsume(
            queue: name,
            consumerTag: consumerTag,
            acknowledgementMode: acknowledgementMode,
            exclusive: exclusive,
            arguments: arguments
        )
    }

    /// Synchronously fetch a single message from this queue (pull API).
    ///
    /// - Warning: This method is inefficient and strongly discouraged for production use.
    ///   Use ``consume(consumerTag:acknowledgementMode:exclusive:arguments:)`` instead.
    ///
    /// Suitable only for tests, debugging, or administrative tools.
    @_documentation(visibility: private)
    public func get(acknowledgementMode: ConsumerAcknowledgementMode = .manual) async throws -> GetResponse? {
        try await channel.basicGet(queue: name, acknowledgementMode: acknowledgementMode)
    }

    // MARK: - Publishing

    /// Uses default exchange with queue name as routing key
    public func publish(
        _ body: Data,
        properties: BasicProperties = .persistent,
        mandatory: Bool = false
    ) async throws {
        try await channel.basicPublish(
            body: body,
            exchange: "",
            routingKey: name,
            mandatory: mandatory,
            properties: properties
        )
    }

    public func publish(
        _ message: String,
        properties: BasicProperties = .persistent,
        mandatory: Bool = false
    ) async throws {
        guard let data = message.data(using: .utf8) else {
            throw ConnectionError.protocolError("Failed to encode message as UTF-8")
        }
        try await publish(data, properties: properties, mandatory: mandatory)
    }

    // MARK: - Management

    /// Returns number of messages purged
    public func purge() async throws -> UInt32 {
        try await channel.queuePurge(name)
    }

    /// Returns number of messages deleted
    public func delete(ifUnused: Bool = false, ifEmpty: Bool = false) async throws -> UInt32 {
        try await channel.queueDelete(name, ifUnused: ifUnused, ifEmpty: ifEmpty)
    }
}
