// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing
@testable import Recovery
@testable import AMQPProtocol

@Suite("Topology Registry Tests")
struct TopologyRegistryTests {

    // MARK: - Exchange Tests

    @Test("Record and retrieve exchange")
    func recordExchange() async {
        let registry = TopologyRegistry()
        let exchange = RecordedExchange(
            name: "test.exchange",
            type: "topic",
            durable: true,
            autoDelete: false,
            internal: false,
            arguments: [:]
        )

        await registry.recordExchange(exchange)
        let exchanges = await registry.allExchanges()

        #expect(exchanges.count == 1)
        #expect(exchanges.first?.name == "test.exchange")
        #expect(exchanges.first?.type == "topic")
        #expect(exchanges.first?.durable == true)
    }

    @Test("Delete exchange removes exchange and related bindings")
    func deleteExchange() async {
        let registry = TopologyRegistry()

        let exchange = RecordedExchange(
            name: "logs",
            type: "fanout",
            durable: false,
            autoDelete: false,
            internal: false,
            arguments: [:]
        )
        await registry.recordExchange(exchange)

        let queue = RecordedQueue(
            name: "worker",
            durable: false,
            exclusive: false,
            autoDelete: false,
            arguments: [:]
        )
        await registry.recordQueue(queue)

        let binding = RecordedQueueBinding(
            queue: "worker",
            exchange: "logs",
            routingKey: "",
            arguments: [:]
        )
        await registry.recordQueueBinding(binding)

        await registry.deleteExchange(named: "logs")

        let exchanges = await registry.allExchanges()
        let bindings = await registry.allQueueBindings()

        #expect(exchanges.isEmpty)
        #expect(bindings.isEmpty)
    }

    // MARK: - Queue Tests

    @Test("Record and retrieve queue")
    func recordQueue() async {
        let registry = TopologyRegistry()
        let queue = RecordedQueue(
            name: "my-queue",
            durable: true,
            exclusive: false,
            autoDelete: false,
            arguments: ["x-message-ttl": .int32(60000)]
        )

        await registry.recordQueue(queue)
        let queues = await registry.allQueues()

        #expect(queues.count == 1)
        #expect(queues.first?.name == "my-queue")
        #expect(queues.first?.durable == true)
        #expect(queues.first?.arguments["x-message-ttl"]?.intValue == 60000)
    }

    @Test("Delete queue removes queue, bindings, and consumers")
    func deleteQueue() async {
        let registry = TopologyRegistry()

        let queue = RecordedQueue(
            name: "tasks",
            durable: true,
            exclusive: false,
            autoDelete: false,
            arguments: [:]
        )
        await registry.recordQueue(queue)

        let binding = RecordedQueueBinding(
            queue: "tasks",
            exchange: "amq.direct",
            routingKey: "task",
            arguments: [:]
        )
        await registry.recordQueueBinding(binding)

        let consumer = RecordedConsumer(
            consumerTag: "consumer-1",
            queue: "tasks",
            acknowledgementMode: .manual,
            exclusive: false,
            arguments: [:]
        )
        await registry.recordConsumer(consumer)

        await registry.deleteQueue(named: "tasks")

        let queues = await registry.allQueues()
        let bindings = await registry.allQueueBindings()
        let consumers = await registry.allConsumers()

        #expect(queues.isEmpty)
        #expect(bindings.isEmpty)
        #expect(consumers.isEmpty)
    }

    @Test("Update queue name for server-named queue")
    func updateQueueName() async {
        let registry = TopologyRegistry()

        let queue = RecordedQueue(
            name: "amq.gen-old",
            durable: false,
            exclusive: true,
            autoDelete: true,
            arguments: [:],
            serverNamed: true
        )
        await registry.recordQueue(queue)

        let binding = RecordedQueueBinding(
            queue: "amq.gen-old",
            exchange: "logs",
            routingKey: "",
            arguments: [:]
        )
        await registry.recordQueueBinding(binding)

        let consumer = RecordedConsumer(
            consumerTag: "tag-1",
            queue: "amq.gen-old",
            acknowledgementMode: .manual,
            exclusive: false,
            arguments: [:]
        )
        await registry.recordConsumer(consumer)

        await registry.updateQueueName(from: "amq.gen-old", to: "amq.gen-new")

        let queues = await registry.allQueues()
        let bindings = await registry.allQueueBindings()
        let consumers = await registry.allConsumers()

        #expect(queues.count == 1)
        #expect(queues.first?.name == "amq.gen-new")
        #expect(bindings.first?.queue == "amq.gen-new")
        #expect(consumers.first?.queue == "amq.gen-new")
    }

    // MARK: - Binding Tests

    @Test("Record and retrieve queue bindings")
    func recordQueueBinding() async {
        let registry = TopologyRegistry()

        let binding1 = RecordedQueueBinding(
            queue: "q1",
            exchange: "ex1",
            routingKey: "key1",
            arguments: [:]
        )
        let binding2 = RecordedQueueBinding(
            queue: "q1",
            exchange: "ex1",
            routingKey: "key2",
            arguments: [:]
        )

        await registry.recordQueueBinding(binding1)
        await registry.recordQueueBinding(binding2)

        let bindings = await registry.allQueueBindings()
        #expect(bindings.count == 2)
    }

    @Test("Delete queue binding")
    func deleteQueueBinding() async {
        let registry = TopologyRegistry()

        let binding = RecordedQueueBinding(
            queue: "q1",
            exchange: "ex1",
            routingKey: "key1",
            arguments: [:]
        )

        await registry.recordQueueBinding(binding)
        await registry.deleteQueueBinding(binding)

        let bindings = await registry.allQueueBindings()
        #expect(bindings.isEmpty)
    }

    @Test("Record and delete exchange bindings")
    func exchangeBindings() async {
        let registry = TopologyRegistry()

        let binding = RecordedExchangeBinding(
            destination: "dest.ex",
            source: "src.ex",
            routingKey: "*.critical",
            arguments: [:]
        )

        await registry.recordExchangeBinding(binding)
        let bindings = await registry.allExchangeBindings()
        #expect(bindings.count == 1)

        await registry.deleteExchangeBinding(binding)
        let bindingsAfter = await registry.allExchangeBindings()
        #expect(bindingsAfter.isEmpty)
    }

    // MARK: - Consumer Tests

    @Test("Record and retrieve consumer")
    func recordConsumer() async {
        let registry = TopologyRegistry()

        let consumer = RecordedConsumer(
            consumerTag: "my-consumer",
            queue: "tasks",
            acknowledgementMode: .manual,
            exclusive: true,
            arguments: [:]
        )

        await registry.recordConsumer(consumer)

        let retrieved = await registry.consumer(forTag: "my-consumer")
        #expect(retrieved?.consumerTag == "my-consumer")
        #expect(retrieved?.queue == "tasks")
        #expect(retrieved?.exclusive == true)
    }

    @Test("Delete consumer")
    func deleteConsumer() async {
        let registry = TopologyRegistry()

        let consumer = RecordedConsumer(
            consumerTag: "tag-to-delete",
            queue: "q1",
            acknowledgementMode: .manual,
            exclusive: false,
            arguments: [:]
        )

        await registry.recordConsumer(consumer)
        await registry.deleteConsumer(tag: "tag-to-delete")

        let retrieved = await registry.consumer(forTag: "tag-to-delete")
        #expect(retrieved == nil)
    }

    // MARK: - Clear Tests

    @Test("Clear removes all entries")
    func clear() async {
        let registry = TopologyRegistry()

        await registry.recordExchange(RecordedExchange(
            name: "ex1", type: "direct", durable: false, autoDelete: false, internal: false, arguments: [:]
        ))
        await registry.recordQueue(RecordedQueue(
            name: "q1", durable: false, exclusive: false, autoDelete: false, arguments: [:]
        ))
        await registry.recordQueueBinding(RecordedQueueBinding(
            queue: "q1", exchange: "ex1", routingKey: "", arguments: [:]
        ))
        await registry.recordConsumer(RecordedConsumer(
            consumerTag: "c1", queue: "q1", acknowledgementMode: .manual, exclusive: false, arguments: [:]
        ))

        await registry.clear()

        #expect(await registry.allExchanges().isEmpty)
        #expect(await registry.allQueues().isEmpty)
        #expect(await registry.allQueueBindings().isEmpty)
        #expect(await registry.allConsumers().isEmpty)
    }
}
