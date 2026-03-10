// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing

@testable import AMQPProtocol
@testable import Recovery

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

  // MARK: - Auto-Delete Cascading Tests

  @Test("Cancelling last consumer on auto-delete queue removes queue, bindings, and exchange")
  func autoDeleteQueueCascade() async {
    let registry = TopologyRegistry()

    let exchange = RecordedExchange(
      name: "events",
      type: "fanout",
      durable: false,
      autoDelete: true,
      internal: false,
      arguments: [:]
    )
    await registry.recordExchange(exchange)

    let queue = RecordedQueue(
      name: "events.worker",
      durable: false,
      exclusive: false,
      autoDelete: true,
      arguments: [:]
    )
    await registry.recordQueue(queue)

    let binding = RecordedQueueBinding(
      queue: "events.worker",
      exchange: "events",
      routingKey: "",
      arguments: [:]
    )
    await registry.recordQueueBinding(binding)

    let consumer = RecordedConsumer(
      consumerTag: "ctag-1",
      queue: "events.worker",
      acknowledgementMode: .manual,
      exclusive: false,
      arguments: [:]
    )
    await registry.recordConsumer(consumer)

    // Cancelling the last consumer should cascade:
    // consumer -> auto-delete queue -> binding -> auto-delete exchange
    await registry.deleteConsumer(tag: "ctag-1")

    #expect(await registry.allConsumers().isEmpty)
    #expect(await registry.allQueues().isEmpty)
    #expect(await registry.allQueueBindings().isEmpty)
    #expect(await registry.allExchanges().isEmpty)
  }

  @Test("Auto-delete queue is kept when other consumers remain")
  func autoDeleteQueueKeptWithRemainingConsumers() async {
    let registry = TopologyRegistry()

    let queue = RecordedQueue(
      name: "shared",
      durable: false,
      exclusive: false,
      autoDelete: true,
      arguments: [:]
    )
    await registry.recordQueue(queue)

    await registry.recordConsumer(
      RecordedConsumer(
        consumerTag: "c1", queue: "shared", acknowledgementMode: .manual,
        exclusive: false, arguments: [:]))
    await registry.recordConsumer(
      RecordedConsumer(
        consumerTag: "c2", queue: "shared", acknowledgementMode: .manual,
        exclusive: false, arguments: [:]))

    await registry.deleteConsumer(tag: "c1")

    #expect(await registry.allQueues().count == 1)
    #expect(await registry.allConsumers().count == 1)
  }

  @Test("Auto-delete exchange is kept when other bindings remain")
  func autoDeleteExchangeKeptWithRemainingBindings() async {
    let registry = TopologyRegistry()

    let exchange = RecordedExchange(
      name: "events",
      type: "fanout",
      durable: false,
      autoDelete: true,
      internal: false,
      arguments: [:]
    )
    await registry.recordExchange(exchange)

    await registry.recordQueueBinding(
      RecordedQueueBinding(
        queue: "q1", exchange: "events", routingKey: "", arguments: [:]))
    await registry.recordQueueBinding(
      RecordedQueueBinding(
        queue: "q2", exchange: "events", routingKey: "", arguments: [:]))

    await registry.deleteQueueBinding(
      RecordedQueueBinding(
        queue: "q1", exchange: "events", routingKey: "", arguments: [:]))

    #expect(await registry.allExchanges().count == 1)
    #expect(await registry.allQueueBindings().count == 1)
  }

  @Test("Deleting queue cascades to auto-delete exchange via bindings")
  func deleteQueueCascadesToAutoDeleteExchange() async {
    let registry = TopologyRegistry()

    let exchange = RecordedExchange(
      name: "logs",
      type: "topic",
      durable: false,
      autoDelete: true,
      internal: false,
      arguments: [:]
    )
    await registry.recordExchange(exchange)

    let queue = RecordedQueue(
      name: "log-consumer",
      durable: false,
      exclusive: false,
      autoDelete: false,
      arguments: [:]
    )
    await registry.recordQueue(queue)

    await registry.recordQueueBinding(
      RecordedQueueBinding(
        queue: "log-consumer", exchange: "logs", routingKey: "#", arguments: [:]))

    await registry.deleteQueue(named: "log-consumer")

    #expect(await registry.allQueues().isEmpty)
    #expect(await registry.allQueueBindings().isEmpty)
    #expect(await registry.allExchanges().isEmpty)
  }

  @Test("Non-auto-delete entities are not removed by cascading")
  func nonAutoDeleteEntitiesNotCascaded() async {
    let registry = TopologyRegistry()

    let exchange = RecordedExchange(
      name: "durable.exchange",
      type: "direct",
      durable: true,
      autoDelete: false,
      internal: false,
      arguments: [:]
    )
    await registry.recordExchange(exchange)

    let queue = RecordedQueue(
      name: "durable.queue",
      durable: true,
      exclusive: false,
      autoDelete: false,
      arguments: [:]
    )
    await registry.recordQueue(queue)

    await registry.recordQueueBinding(
      RecordedQueueBinding(
        queue: "durable.queue", exchange: "durable.exchange", routingKey: "key", arguments: [:]))

    let consumer = RecordedConsumer(
      consumerTag: "c1", queue: "durable.queue", acknowledgementMode: .manual,
      exclusive: false, arguments: [:])
    await registry.recordConsumer(consumer)

    await registry.deleteConsumer(tag: "c1")

    // Queue and exchange should remain since they are not auto-delete
    #expect(await registry.allQueues().count == 1)
    #expect(await registry.allExchanges().count == 1)
    #expect(await registry.allQueueBindings().count == 1)
  }

  // MARK: - Duplicate Recording

  @Test("Recording the same exchange twice overwrites the first")
  func exchangeOverwrite() async {
    let registry = TopologyRegistry()

    await registry.recordExchange(
      RecordedExchange(
        name: "ex", type: "direct", durable: false,
        autoDelete: false, internal: false, arguments: [:]))
    await registry.recordExchange(
      RecordedExchange(
        name: "ex", type: "fanout", durable: true,
        autoDelete: false, internal: false, arguments: [:]))

    let exchanges = await registry.allExchanges()
    #expect(exchanges.count == 1)
    #expect(exchanges.first?.type == "fanout")
    #expect(exchanges.first?.durable == true)
  }

  @Test("Recording the same queue twice overwrites the first")
  func queueOverwrite() async {
    let registry = TopologyRegistry()

    await registry.recordQueue(
      RecordedQueue(
        name: "q", durable: false, exclusive: false,
        autoDelete: false, arguments: [:]))
    await registry.recordQueue(
      RecordedQueue(
        name: "q", durable: true, exclusive: false,
        autoDelete: true, arguments: [:]))

    let queues = await registry.allQueues()
    #expect(queues.count == 1)
    #expect(queues.first?.durable == true)
    #expect(queues.first?.autoDelete == true)
  }

  @Test("Duplicate queue binding is stored only once")
  func duplicateQueueBinding() async {
    let registry = TopologyRegistry()
    let binding = RecordedQueueBinding(
      queue: "q", exchange: "ex", routingKey: "rk", arguments: [:])

    await registry.recordQueueBinding(binding)
    await registry.recordQueueBinding(binding)

    #expect(await registry.allQueueBindings().count == 1)
  }

  @Test("Duplicate exchange binding is stored only once")
  func duplicateExchangeBinding() async {
    let registry = TopologyRegistry()
    let binding = RecordedExchangeBinding(
      destination: "dst", source: "src", routingKey: "rk", arguments: [:])

    await registry.recordExchangeBinding(binding)
    await registry.recordExchangeBinding(binding)

    #expect(await registry.allExchangeBindings().count == 1)
  }

  @Test("Recording the same consumer tag overwrites the first")
  func consumerOverwrite() async {
    let registry = TopologyRegistry()

    await registry.recordConsumer(
      RecordedConsumer(
        consumerTag: "tag", queue: "q1",
        acknowledgementMode: .manual, exclusive: false, arguments: [:]))
    await registry.recordConsumer(
      RecordedConsumer(
        consumerTag: "tag", queue: "q2",
        acknowledgementMode: .automatic, exclusive: true, arguments: [:]))

    let consumers = await registry.allConsumers()
    #expect(consumers.count == 1)
    #expect(consumers.first?.queue == "q2")
    #expect(consumers.first?.exclusive == true)
  }

  // MARK: - Edge Cases

  @Test("Deleting a nonexistent exchange is a no-op")
  func deleteNonexistentExchange() async {
    let registry = TopologyRegistry()
    await registry.deleteExchange(named: "ghost")
    #expect(await registry.allExchanges().isEmpty)
  }

  @Test("Deleting a nonexistent queue is a no-op")
  func deleteNonexistentQueue() async {
    let registry = TopologyRegistry()
    await registry.deleteQueue(named: "ghost")
    #expect(await registry.allQueues().isEmpty)
  }

  @Test("Deleting a nonexistent consumer is a no-op")
  func deleteNonexistentConsumer() async {
    let registry = TopologyRegistry()
    await registry.deleteConsumer(tag: "ghost")
    #expect(await registry.allConsumers().isEmpty)
  }

  @Test("Updating a nonexistent queue name is a no-op")
  func updateNonexistentQueueName() async {
    let registry = TopologyRegistry()
    await registry.recordQueue(
      RecordedQueue(
        name: "existing", durable: false, exclusive: false,
        autoDelete: false, arguments: [:]))

    await registry.updateQueueName(from: "ghost", to: "new")

    let queues = await registry.allQueues()
    #expect(queues.count == 1)
    #expect(queues.first?.name == "existing")
  }

  @Test("Auto-delete exchange cascade cleans up exchange bindings where it is the destination")
  func autoDeleteExchangeCleansUpDestinationBindings() async {
    let registry = TopologyRegistry()

    await registry.recordExchange(
      RecordedExchange(
        name: "src", type: "fanout", durable: false,
        autoDelete: false, internal: false, arguments: [:]))
    await registry.recordExchange(
      RecordedExchange(
        name: "ad-dst", type: "fanout", durable: false,
        autoDelete: true, internal: false, arguments: [:]))
    await registry.recordQueue(
      RecordedQueue(
        name: "q", durable: false, exclusive: false,
        autoDelete: false, arguments: [:]))

    // ad-dst has one queue binding (makes it the source) and one e2e binding (as destination)
    await registry.recordQueueBinding(
      RecordedQueueBinding(queue: "q", exchange: "ad-dst", routingKey: "", arguments: [:]))
    await registry.recordExchangeBinding(
      RecordedExchangeBinding(
        destination: "ad-dst", source: "src", routingKey: "", arguments: [:]))

    // Remove the queue binding; ad-dst should be auto-deleted since it has
    // no remaining source bindings. The e2e binding from "src" should also
    // be cleaned up so it doesn't linger as a stale entry.
    await registry.deleteQueueBinding(
      RecordedQueueBinding(queue: "q", exchange: "ad-dst", routingKey: "", arguments: [:]))

    #expect(await registry.allExchanges().count == 1, "Only src should remain")
    #expect(await registry.allExchangeBindings().isEmpty, "Stale e2e binding should be removed")
  }

  @Test("Exchange binding cascading: deleting source removes binding record")
  func exchangeBindingSourceDeletion() async {
    let registry = TopologyRegistry()

    await registry.recordExchange(
      RecordedExchange(
        name: "src", type: "fanout", durable: false,
        autoDelete: false, internal: false, arguments: [:]))
    await registry.recordExchange(
      RecordedExchange(
        name: "dst", type: "fanout", durable: false,
        autoDelete: false, internal: false, arguments: [:]))
    await registry.recordExchangeBinding(
      RecordedExchangeBinding(
        destination: "dst", source: "src", routingKey: "", arguments: [:]))

    await registry.deleteExchange(named: "src")

    #expect(await registry.allExchangeBindings().isEmpty)
    #expect(await registry.allExchanges().count == 1)
  }

  @Test("Exchange binding cascading: deleting destination removes binding record")
  func exchangeBindingDestinationDeletion() async {
    let registry = TopologyRegistry()

    await registry.recordExchange(
      RecordedExchange(
        name: "src", type: "fanout", durable: false,
        autoDelete: false, internal: false, arguments: [:]))
    await registry.recordExchange(
      RecordedExchange(
        name: "dst", type: "fanout", durable: false,
        autoDelete: false, internal: false, arguments: [:]))
    await registry.recordExchangeBinding(
      RecordedExchangeBinding(
        destination: "dst", source: "src", routingKey: "", arguments: [:]))

    await registry.deleteExchange(named: "dst")

    #expect(await registry.allExchangeBindings().isEmpty)
    #expect(await registry.allExchanges().count == 1)
  }

  // MARK: - Property-Based Tests

  @Test("Queue name update preserves serverNamed flag", arguments: [true, false])
  func updateQueueNamePreservesFlags(serverNamed: Bool) async {
    let registry = TopologyRegistry()

    await registry.recordQueue(
      RecordedQueue(
        name: "old-name", durable: true, exclusive: true,
        autoDelete: true, arguments: [:], serverNamed: serverNamed))

    await registry.updateQueueName(from: "old-name", to: "new-name")

    let queue = await registry.allQueues().first
    #expect(queue?.name == "new-name")
    #expect(queue?.serverNamed == serverNamed)
    #expect(queue?.durable == true)
    #expect(queue?.exclusive == true)
    #expect(queue?.autoDelete == true)
  }

  @Test(
    "Adding N queues then clearing leaves the registry empty",
    arguments: [0, 1, 5, 50]
  )
  func clearAfterNQueues(n: Int) async {
    let registry = TopologyRegistry()

    for i in 0..<n {
      await registry.recordQueue(
        RecordedQueue(
          name: "q-\(i)", durable: false, exclusive: false,
          autoDelete: false, arguments: [:]))
    }
    #expect(await registry.allQueues().count == n)

    await registry.clear()
    #expect(await registry.allQueues().isEmpty)
  }

  @Test(
    "Auto-delete cascade depth: exchange → queue binding → queue → consumer",
    arguments: [1, 3, 5]
  )
  func autoDeleteCascadeWithMultipleConsumers(consumerCount: Int) async {
    let registry = TopologyRegistry()

    await registry.recordExchange(
      RecordedExchange(
        name: "cascade.ex", type: "fanout", durable: false,
        autoDelete: true, internal: false, arguments: [:]))
    await registry.recordQueue(
      RecordedQueue(
        name: "cascade.q", durable: false, exclusive: false,
        autoDelete: true, arguments: [:]))
    await registry.recordQueueBinding(
      RecordedQueueBinding(
        queue: "cascade.q", exchange: "cascade.ex",
        routingKey: "", arguments: [:]))

    for i in 0..<consumerCount {
      await registry.recordConsumer(
        RecordedConsumer(
          consumerTag: "c-\(i)", queue: "cascade.q",
          acknowledgementMode: .manual, exclusive: false, arguments: [:]))
    }

    // Cancel all but the last consumer
    for i in 0..<(consumerCount - 1) {
      await registry.deleteConsumer(tag: "c-\(i)")
      // Queue should still exist because one consumer remains
      #expect(await registry.allQueues().count == 1)
    }

    // Cancel the last consumer: full cascade
    await registry.deleteConsumer(tag: "c-\(consumerCount - 1)")
    #expect(await registry.allConsumers().isEmpty)
    #expect(await registry.allQueues().isEmpty)
    #expect(await registry.allQueueBindings().isEmpty)
    #expect(await registry.allExchanges().isEmpty)
  }

  @Test(
    "Queue name update propagates to all bindings with that queue",
    arguments: [1, 3, 10]
  )
  func queueNameUpdatePropagation(bindingCount: Int) async {
    let registry = TopologyRegistry()

    await registry.recordQueue(
      RecordedQueue(
        name: "amq.gen-old", durable: false, exclusive: true,
        autoDelete: true, arguments: [:], serverNamed: true))

    for i in 0..<bindingCount {
      await registry.recordQueueBinding(
        RecordedQueueBinding(
          queue: "amq.gen-old", exchange: "ex-\(i)",
          routingKey: "rk-\(i)", arguments: [:]))
    }

    await registry.updateQueueName(from: "amq.gen-old", to: "amq.gen-new")

    let bindings = await registry.allQueueBindings()
    #expect(bindings.count == bindingCount)
    for binding in bindings {
      #expect(binding.queue == "amq.gen-new")
    }
  }

  @Test(
    "Queue name update propagates to all consumers on that queue",
    arguments: [1, 3, 10]
  )
  func queueNameUpdateConsumerPropagation(consumerCount: Int) async {
    let registry = TopologyRegistry()

    await registry.recordQueue(
      RecordedQueue(
        name: "amq.gen-old", durable: false, exclusive: true,
        autoDelete: true, arguments: [:], serverNamed: true))

    for i in 0..<consumerCount {
      await registry.recordConsumer(
        RecordedConsumer(
          consumerTag: "c-\(i)", queue: "amq.gen-old",
          acknowledgementMode: .manual, exclusive: false, arguments: [:]))
    }

    await registry.updateQueueName(from: "amq.gen-old", to: "amq.gen-new")

    let consumers = await registry.allConsumers()
    #expect(consumers.count == consumerCount)
    for consumer in consumers {
      #expect(consumer.queue == "amq.gen-new")
    }
  }

  // MARK: - Clear Tests

  @Test("Clear removes all entries")
  func clear() async {
    let registry = TopologyRegistry()

    await registry.recordExchange(
      RecordedExchange(
        name: "ex1", type: "direct", durable: false, autoDelete: false, internal: false,
        arguments: [:]
      ))
    await registry.recordExchange(
      RecordedExchange(
        name: "ex2", type: "fanout", durable: false, autoDelete: false, internal: false,
        arguments: [:]
      ))
    await registry.recordQueue(
      RecordedQueue(
        name: "q1", durable: false, exclusive: false, autoDelete: false, arguments: [:]
      ))
    await registry.recordQueueBinding(
      RecordedQueueBinding(
        queue: "q1", exchange: "ex1", routingKey: "", arguments: [:]
      ))
    await registry.recordExchangeBinding(
      RecordedExchangeBinding(
        destination: "ex2", source: "ex1", routingKey: "", arguments: [:]
      ))
    await registry.recordConsumer(
      RecordedConsumer(
        consumerTag: "c1", queue: "q1", acknowledgementMode: .manual, exclusive: false,
        arguments: [:]
      ))

    await registry.clear()

    #expect(await registry.allExchanges().isEmpty)
    #expect(await registry.allQueues().isEmpty)
    #expect(await registry.allQueueBindings().isEmpty)
    #expect(await registry.allExchangeBindings().isEmpty)
    #expect(await registry.allConsumers().isEmpty)
  }
}

// MARK: - TopologyRecoveryFilter Tests

@Suite("Topology Recovery Filter Tests")
struct TopologyRecoveryFilterTests {

  @Test("Default filter allows everything")
  func defaultFilter() {
    let filter = TopologyRecoveryFilter()
    #expect(filter.exchangeFilter == nil)
    #expect(filter.queueFilter == nil)
    #expect(filter.queueBindingFilter == nil)
    #expect(filter.exchangeBindingFilter == nil)
    #expect(filter.consumerFilter == nil)
  }

  @Test("Exchange filter excludes matching exchanges")
  func exchangeFilter() {
    let filter = TopologyRecoveryFilter(
      exchangeFilter: { !$0.name.hasPrefix("temp.") }
    )
    let kept = RecordedExchange(
      name: "events", type: "topic", durable: true,
      autoDelete: false, internal: false, arguments: [:])
    let excluded = RecordedExchange(
      name: "temp.scratch", type: "fanout", durable: false,
      autoDelete: true, internal: false, arguments: [:])

    #expect(filter.exchangeFilter!(kept) == true)
    #expect(filter.exchangeFilter!(excluded) == false)
  }

  @Test("Queue filter excludes matching queues")
  func queueFilter() {
    let filter = TopologyRecoveryFilter(
      queueFilter: { $0.durable }
    )
    let kept = RecordedQueue(
      name: "orders", durable: true, exclusive: false,
      autoDelete: false, arguments: [:])
    let excluded = RecordedQueue(
      name: "temp", durable: false, exclusive: false,
      autoDelete: true, arguments: [:])

    #expect(filter.queueFilter!(kept) == true)
    #expect(filter.queueFilter!(excluded) == false)
  }

  @Test("Consumer filter excludes matching consumers")
  func consumerFilter() {
    let filter = TopologyRecoveryFilter(
      consumerFilter: { $0.consumerTag != "ephemeral" }
    )
    let kept = RecordedConsumer(
      consumerTag: "persistent", queue: "q",
      acknowledgementMode: .automatic, exclusive: false, arguments: [:])
    let excluded = RecordedConsumer(
      consumerTag: "ephemeral", queue: "q",
      acknowledgementMode: .automatic, exclusive: false, arguments: [:])

    #expect(filter.consumerFilter!(kept) == true)
    #expect(filter.consumerFilter!(excluded) == false)
  }

  @Test("Binding filters exclude matching bindings")
  func bindingFilters() {
    let filter = TopologyRecoveryFilter(
      queueBindingFilter: { $0.routingKey != "debug.#" },
      exchangeBindingFilter: { $0.source != "internal" }
    )
    let keptQB = RecordedQueueBinding(
      queue: "q", exchange: "ex", routingKey: "events.#", arguments: [:])
    let excludedQB = RecordedQueueBinding(
      queue: "q", exchange: "ex", routingKey: "debug.#", arguments: [:])
    let keptEB = RecordedExchangeBinding(
      destination: "dst", source: "external", routingKey: "", arguments: [:])
    let excludedEB = RecordedExchangeBinding(
      destination: "dst", source: "internal", routingKey: "", arguments: [:])

    #expect(filter.queueBindingFilter!(keptQB) == true)
    #expect(filter.queueBindingFilter!(excludedQB) == false)
    #expect(filter.exchangeBindingFilter!(keptEB) == true)
    #expect(filter.exchangeBindingFilter!(excludedEB) == false)
  }
}
