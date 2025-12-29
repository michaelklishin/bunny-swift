// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import AMQPProtocol

// MARK: - Message

public struct Message: Sendable {
    public let body: Data
    public let properties: BasicProperties
    public let deliveryInfo: DeliveryInfo
    private let channel: Channel

    internal init(body: Data, properties: BasicProperties, deliveryInfo: DeliveryInfo, channel: Channel) {
        self.body = body
        self.properties = properties
        self.deliveryInfo = deliveryInfo
        self.channel = channel
    }

    public func ack(multiple: Bool = false) async throws {
        try await channel.basicAck(deliveryTag: deliveryInfo.deliveryTag, multiple: multiple)
    }

    public func nack(multiple: Bool = false, requeue: Bool = true) async throws {
        try await channel.basicNack(deliveryTag: deliveryInfo.deliveryTag, multiple: multiple, requeue: requeue)
    }

    public func reject(requeue: Bool = true) async throws {
        try await channel.basicReject(deliveryTag: deliveryInfo.deliveryTag, requeue: requeue)
    }

    public var bodyString: String? {
        String(data: body, encoding: .utf8)
    }
}

// MARK: - GetResponse

/// Response from a polling-based `basicGet` operation.
/// - Danger: never to be used in production. See `basicConsume` (long-running subscriptions).
@_documentation(visibility: private)
public struct GetResponse: Sendable {
    public let body: Data
    public let properties: BasicProperties
    public let deliveryTag: UInt64
    public let redelivered: Bool
    public let exchange: String
    public let routingKey: String
    public let messageCount: UInt32
    private let channel: Channel

    internal init(
        body: Data,
        properties: BasicProperties,
        deliveryTag: UInt64,
        redelivered: Bool,
        exchange: String,
        routingKey: String,
        messageCount: UInt32,
        channel: Channel
    ) {
        self.body = body
        self.properties = properties
        self.deliveryTag = deliveryTag
        self.redelivered = redelivered
        self.exchange = exchange
        self.routingKey = routingKey
        self.messageCount = messageCount
        self.channel = channel
    }

    public func ack(multiple: Bool = false) async throws {
        try await channel.basicAck(deliveryTag: deliveryTag, multiple: multiple)
    }

    public func nack(multiple: Bool = false, requeue: Bool = true) async throws {
        try await channel.basicNack(deliveryTag: deliveryTag, multiple: multiple, requeue: requeue)
    }

    public func reject(requeue: Bool = true) async throws {
        try await channel.basicReject(deliveryTag: deliveryTag, requeue: requeue)
    }

    public var bodyString: String? {
        String(data: body, encoding: .utf8)
    }
}

// MARK: - ReturnedMessage

public struct ReturnedMessage: Sendable {
    public let body: Data
    public let properties: BasicProperties
    public let replyCode: UInt16
    public let replyText: String
    public let exchange: String
    public let routingKey: String

    public var bodyString: String? {
        String(data: body, encoding: .utf8)
    }
}

// MARK: - MessageStream

public struct MessageStream: AsyncSequence, Sendable {
    public typealias Element = Message
    public let consumerTag: String
    private let channel: Channel
    private let stream: AsyncStream<Message>

    internal init(channel: Channel, consumerTag: String, stream: AsyncStream<Message>) {
        self.channel = channel
        self.consumerTag = consumerTag
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }

    public func cancel() async throws {
        try await channel.basicCancel(consumerTag)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<Message>.AsyncIterator

        public mutating func next() async -> Message? {
            await iterator.next()
        }
    }
}
