// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import AMQPProtocol

// MARK: - Recorded Entities

public struct RecordedExchange: Sendable, Equatable, Hashable {
    public let name: String
    public let type: String
    public let durable: Bool
    public let autoDelete: Bool
    public let `internal`: Bool
    public let arguments: Table

    public init(
        name: String,
        type: String,
        durable: Bool,
        autoDelete: Bool,
        internal: Bool,
        arguments: Table
    ) {
        self.name = name
        self.type = type
        self.durable = durable
        self.autoDelete = autoDelete
        self.internal = `internal`
        self.arguments = arguments
    }
}

public struct RecordedQueue: Sendable, Equatable, Hashable {
    public let name: String
    public let durable: Bool
    public let exclusive: Bool
    public let autoDelete: Bool
    public let arguments: Table
    public var serverNamed: Bool

    public init(
        name: String,
        durable: Bool,
        exclusive: Bool,
        autoDelete: Bool,
        arguments: Table,
        serverNamed: Bool = false
    ) {
        self.name = name
        self.durable = durable
        self.exclusive = exclusive
        self.autoDelete = autoDelete
        self.arguments = arguments
        self.serverNamed = serverNamed
    }
}

public struct RecordedQueueBinding: Sendable, Equatable, Hashable {
    public let queue: String
    public let exchange: String
    public let routingKey: String
    public let arguments: Table

    public init(queue: String, exchange: String, routingKey: String, arguments: Table) {
        self.queue = queue
        self.exchange = exchange
        self.routingKey = routingKey
        self.arguments = arguments
    }
}

public struct RecordedExchangeBinding: Sendable, Equatable, Hashable {
    public let destination: String
    public let source: String
    public let routingKey: String
    public let arguments: Table

    public init(destination: String, source: String, routingKey: String, arguments: Table) {
        self.destination = destination
        self.source = source
        self.routingKey = routingKey
        self.arguments = arguments
    }
}

public struct RecordedConsumer: Sendable, Equatable, Hashable {
    public let consumerTag: String
    public let queue: String
    public let acknowledgementMode: ConsumerAcknowledgementMode
    public let exclusive: Bool
    public let arguments: Table

    public init(
        consumerTag: String,
        queue: String,
        acknowledgementMode: ConsumerAcknowledgementMode,
        exclusive: Bool,
        arguments: Table
    ) {
        self.consumerTag = consumerTag
        self.queue = queue
        self.acknowledgementMode = acknowledgementMode
        self.exclusive = exclusive
        self.arguments = arguments
    }
}

// MARK: - TopologyRegistry

public actor TopologyRegistry {
    private var exchanges: [String: RecordedExchange] = [:]
    private var queues: [String: RecordedQueue] = [:]
    private var queueBindings: Set<RecordedQueueBinding> = []
    private var exchangeBindings: Set<RecordedExchangeBinding> = []
    private var consumers: [String: RecordedConsumer] = [:]

    public init() {}

    // MARK: - Exchanges

    public func recordExchange(_ exchange: RecordedExchange) {
        exchanges[exchange.name] = exchange
    }

    public func deleteExchange(named name: String) {
        exchanges.removeValue(forKey: name)
        // Remove bindings involving this exchange
        queueBindings = queueBindings.filter { $0.exchange != name }
        exchangeBindings = exchangeBindings.filter {
            $0.source != name && $0.destination != name
        }
    }

    public func allExchanges() -> [RecordedExchange] {
        Array(exchanges.values)
    }

    // MARK: - Queues

    public func recordQueue(_ queue: RecordedQueue) {
        queues[queue.name] = queue
    }

    public func deleteQueue(named name: String) {
        queues.removeValue(forKey: name)
        // Remove bindings involving this queue
        queueBindings = queueBindings.filter { $0.queue != name }
        // Remove consumers for this queue
        consumers = consumers.filter { $0.value.queue != name }
    }

    public func allQueues() -> [RecordedQueue] {
        Array(queues.values)
    }

    /// Update queue name after server-named queue is redeclared
    public func updateQueueName(from oldName: String, to newName: String) {
        guard var queue = queues.removeValue(forKey: oldName) else { return }
        queue = RecordedQueue(
            name: newName,
            durable: queue.durable,
            exclusive: queue.exclusive,
            autoDelete: queue.autoDelete,
            arguments: queue.arguments,
            serverNamed: queue.serverNamed
        )
        queues[newName] = queue

        // Update bindings
        let oldBindings = queueBindings.filter { $0.queue == oldName }
        for binding in oldBindings {
            queueBindings.remove(binding)
            queueBindings.insert(RecordedQueueBinding(
                queue: newName,
                exchange: binding.exchange,
                routingKey: binding.routingKey,
                arguments: binding.arguments
            ))
        }

        // Update consumers
        for (tag, consumer) in consumers where consumer.queue == oldName {
            consumers[tag] = RecordedConsumer(
                consumerTag: consumer.consumerTag,
                queue: newName,
                acknowledgementMode: consumer.acknowledgementMode,
                exclusive: consumer.exclusive,
                arguments: consumer.arguments
            )
        }
    }

    // MARK: - Queue Bindings

    public func recordQueueBinding(_ binding: RecordedQueueBinding) {
        queueBindings.insert(binding)
    }

    public func deleteQueueBinding(_ binding: RecordedQueueBinding) {
        queueBindings.remove(binding)
    }

    public func allQueueBindings() -> [RecordedQueueBinding] {
        Array(queueBindings)
    }

    // MARK: - Exchange Bindings

    public func recordExchangeBinding(_ binding: RecordedExchangeBinding) {
        exchangeBindings.insert(binding)
    }

    public func deleteExchangeBinding(_ binding: RecordedExchangeBinding) {
        exchangeBindings.remove(binding)
    }

    public func allExchangeBindings() -> [RecordedExchangeBinding] {
        Array(exchangeBindings)
    }

    // MARK: - Consumers

    public func recordConsumer(_ consumer: RecordedConsumer) {
        consumers[consumer.consumerTag] = consumer
    }

    public func deleteConsumer(tag: String) {
        consumers.removeValue(forKey: tag)
    }

    public func allConsumers() -> [RecordedConsumer] {
        Array(consumers.values)
    }

    public func consumer(forTag tag: String) -> RecordedConsumer? {
        consumers[tag]
    }

    // MARK: - Clear

    public func clear() {
        exchanges.removeAll()
        queues.removeAll()
        queueBindings.removeAll()
        exchangeBindings.removeAll()
        consumers.removeAll()
    }
}
