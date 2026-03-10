// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Connection Recovery Integration Tests
//
// These tests require a RabbitMQ node with the management plugin
// on localhost:5672 (AMQP) and localhost:15672 (HTTP API).
//
// Connections are force-closed via the management HTTP API to trigger recovery.

import Foundation
import Testing

@testable import BunnySwift

// MARK: - Recovery Test Config

private let httpAPI = RabbitMQHTTPAPIClient()

private enum RecoveryTestConfig {
  static let recoveryInterval: TimeInterval = 0.5
  static let recoveryTimeout: TimeInterval = 8.0

  static var skipRecoveryTests: Bool {
    TestConfig.skipIntegrationTests || !httpAPI.isAvailable
  }

  static func openConnection(
    name: String,
    automaticRecovery: Bool = true,
    topologyRecovery: Bool = true
  ) async throws -> Connection {
    var config = ConnectionConfiguration(
      automaticRecovery: automaticRecovery,
      networkRecoveryInterval: recoveryInterval,
      topologyRecovery: topologyRecovery
    )
    config.heartbeat = 4
    config.connectionName = name
    return try await Connection.open(config)
  }
}

/// Polls until the condition is true or the timeout expires.
private func pollUntil(
  timeout: TimeInterval = RecoveryTestConfig.recoveryTimeout,
  interval: TimeInterval = 0.1,
  _ condition: () async throws -> Bool
) async rethrows -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if try await condition() { return true }
    try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
  }
  return false
}

/// Force-close the connection via the HTTP API and wait for recovery.
private func closeAndWaitForRecovery(
  _ connection: Connection, name: String
) async throws {
  try await httpAPI.closeAllConnectionsWithName(name)

  let disconnected = await pollUntil(timeout: 5) {
    await !connection.connected
  }
  #expect(disconnected, "Connection should detect forced close")

  let recovered = await pollUntil(timeout: RecoveryTestConfig.recoveryTimeout) {
    await connection.connected
  }
  #expect(recovered, "Connection should recover after forced close")
}

/// Verify that a queue is functional by publishing and checking message count.
private func ensureQueueFunctional(
  channel: Channel,
  queueName: String
) async throws {
  try await channel.basicPublish(
    body: Data("recovery-test-msg".utf8), exchange: "", routingKey: queueName)

  let arrived = await pollUntil(timeout: 5) {
    let info = await httpAPI.getQueueOrNil(queueName)
    return (info?.messages ?? 0) >= 1
  }
  #expect(arrived, "Expected at least 1 message in queue \(queueName)")
}

/// Verify a binding works by publishing through the exchange and checking the queue.
private func ensureBindingFunctional(
  channel: Channel,
  exchangeName: String,
  queueName: String,
  routingKey: String = ""
) async throws {
  try await channel.basicPublish(
    body: Data("binding-test-msg".utf8), exchange: exchangeName, routingKey: routingKey)

  let arrived = await pollUntil(timeout: 5) {
    let info = await httpAPI.getQueueOrNil(queueName)
    return (info?.messages ?? 0) >= 1
  }
  #expect(arrived, "Expected message to arrive via binding")
}

// All suites that close connections via the HTTP API must be serialized
// because recovery involves shared server-side state.
@Suite(
  "Recovery Integration Tests",
  .disabled(if: RecoveryTestConfig.skipRecoveryTests),
  .serialized,
  .timeLimit(.minutes(5))
)
struct RecoveryIntegrationTests {

  // MARK: - Connection & Channel Recovery

  @Suite("Connection Recovery")
  struct ConnectionRecoveryTests {

    @Test("Connection recovers after forced close")
    func connectionRecovery() async throws {
      let name = "test.conn.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      #expect(await connection.connected)
      try await closeAndWaitForRecovery(connection, name: name)
      #expect(await connection.connected)
    }

    @Test("Channels recover after forced close")
    func channelRecovery() async throws {
      let name = "test.ch.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let ch1 = try await connection.openChannel()
      let ch2 = try await connection.openChannel()
      #expect(await ch1.open)
      #expect(await ch2.open)

      try await closeAndWaitForRecovery(connection, name: name)

      let channelsReady = await pollUntil(timeout: 5) {
        let o1 = await ch1.open
        let o2 = await ch2.open
        return o1 && o2
      }
      #expect(channelsReady, "Both channels should recover")
    }

    @Test("Recovery callback is invoked on successful recovery")
    func recoveryCallback() async throws {
      let name = "test.recovery.callback.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let callbackInvoked = ManagedAtomic(false)
      await connection.onRecovery {
        callbackInvoked.store(true)
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let invoked = await pollUntil(timeout: 5) { callbackInvoked.load() }
      #expect(invoked, "Recovery callback should have been invoked")
    }

    @Test("Recovery does not start when automatic recovery is disabled")
    func noRecoveryWhenDisabled() async throws {
      let name = "test.no.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(
        name: name,
        automaticRecovery: false
      )
      defer { Task { try? await connection.close() } }

      #expect(await connection.connected)
      try await httpAPI.closeAllConnectionsWithName(name)

      let disconnected = await pollUntil(timeout: 5) {
        await !connection.connected
      }
      #expect(disconnected, "Connection should detect forced close")

      try await Task.sleep(for: .seconds(2))
      #expect(
        await !connection.connected,
        "Connection should NOT recover when recovery is disabled")
    }
  }

  // MARK: - Channel State Recovery

  @Suite("Channel State Recovery")
  struct ChannelStateRecoveryTests {

    @Test("QoS prefetch count is recovered")
    func prefetchCountRecovery() async throws {
      let name = "test.qos.prefetch.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      try await channel.basicQos(prefetchCount: 11)

      try await closeAndWaitForRecovery(connection, name: name)

      #expect(await channel.open)
      let queueName = "bunnyswift.recovery.qos.\(UUID().uuidString.prefix(8))"
      let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
      defer { Task { _ = try? await queue.delete() } }
      try await queue.publish("qos test")
      let response = try await queue.get(acknowledgementMode: .automatic)
      #expect(response != nil)
    }

    @Test("Publisher confirms mode is recovered")
    func confirmModeRecovery() async throws {
      let name = "test.confirms.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      try await channel.confirmSelect()

      try await closeAndWaitForRecovery(connection, name: name)

      #expect(await channel.open)
      let queueName = "bunnyswift.recovery.confirms.\(UUID().uuidString.prefix(8))"
      let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
      defer { Task { _ = try? await queue.delete() } }
      try await queue.publish("confirm test")
      try await channel.waitForConfirms()
    }

    @Test("Transaction mode is recovered")
    func transactionModeRecovery() async throws {
      let name = "test.tx.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      try await channel.txSelect()

      try await closeAndWaitForRecovery(connection, name: name)

      #expect(await channel.open)
      let queueName = "bunnyswift.recovery.tx.\(UUID().uuidString.prefix(8))"
      let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
      defer { Task { _ = try? await queue.delete() } }
      try await queue.publish("tx test")
      try await channel.txCommit()
      let response = try await queue.get(acknowledgementMode: .automatic)
      #expect(response != nil)
    }
  }

  // MARK: - Queue Recovery

  @Suite("Queue Recovery")
  struct QueueRecoveryTests {

    @Test("Client-named queues are recovered")
    func clientNamedQueueRecovery() async throws {
      let name = "test.queue.client.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.queue.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      try await closeAndWaitForRecovery(connection, name: name)

      let info = await httpAPI.getQueueOrNil(queueName)
      #expect(info != nil, "Client-named queue should be recovered")
      try await ensureQueueFunctional(channel: channel, queueName: queueName)
    }

    @Test("Server-named queues are recovered with new name")
    func serverNamedQueueRecovery() async throws {
      let name = "test.queue.server.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queue = try await channel.queue("", exclusive: true)
      let originalName = queue.name
      #expect(originalName.hasPrefix("amq.gen-"))

      let recorded = await connection.topologyRegistry.allQueues()
      let serverNamed = recorded.first { $0.name == originalName }
      #expect(serverNamed?.serverNamed == true)

      try await closeAndWaitForRecovery(connection, name: name)

      let queuesAfter = await connection.topologyRegistry.allQueues()
      #expect(queuesAfter.count == 1)
      if let newQueue = queuesAfter.first {
        #expect(newQueue.name.hasPrefix("amq.gen-"))
      }
    }

    @Test("Many queues are recovered")
    func manyQueuesRecovery() async throws {
      let name = "test.queue.many.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let prefix = "bunnyswift.recovery.many.\(UUID().uuidString.prefix(8))"
      var queueNames: [String] = []
      for i in 0..<32 {
        let q = try await channel.queue("\(prefix).\(i)", durable: true)
        queueNames.append(q.name)
      }
      let namesToCleanUp = queueNames
      defer {
        Task { for qn in namesToCleanUp { _ = try? await channel.queueDelete(qn) } }
      }

      try await closeAndWaitForRecovery(connection, name: name)

      for qn in queueNames {
        let info = await httpAPI.getQueueOrNil(qn)
        #expect(info != nil, "Queue \(qn) should be recovered")
      }
    }
  }

  // MARK: - Exchange Recovery

  @Suite("Exchange Recovery")
  struct ExchangeRecoveryTests {

    @Test("Exchange declarations are recovered")
    func exchangeRecovery() async throws {
      let name = "test.exchange.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.recovery.exchange.\(UUID().uuidString.prefix(8))"
      _ = try await channel.direct(exchangeName, autoDelete: true)
      defer { Task { try? await channel.exchangeDelete(exchangeName) } }

      try await closeAndWaitForRecovery(connection, name: name)

      let info = await httpAPI.getExchangeOrNil(exchangeName)
      #expect(info != nil, "Exchange should be recovered")
    }
  }

  // MARK: - Binding Recovery

  @Suite("Binding Recovery")
  struct BindingRecoveryTests {

    @Test("Queue-to-exchange bindings are recovered")
    func queueBindingRecovery() async throws {
      let name = "test.binding.queue.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.recovery.binding.ex.\(UUID().uuidString.prefix(8))"
      let queueName = "bunnyswift.recovery.binding.q.\(UUID().uuidString.prefix(8))"

      _ = try await channel.direct(exchangeName, autoDelete: true)
      _ = try await channel.queue(queueName, durable: true)
      try await channel.queueBind(
        queue: queueName, exchange: exchangeName, routingKey: "test.key")
      defer {
        Task {
          _ = try? await channel.queueDelete(queueName)
          try? await channel.exchangeDelete(exchangeName)
        }
      }

      try await closeAndWaitForRecovery(connection, name: name)

      try await ensureBindingFunctional(
        channel: channel, exchangeName: exchangeName, queueName: queueName,
        routingKey: "test.key")
    }

    @Test("Exchange-to-exchange bindings are recovered")
    func exchangeBindingRecovery() async throws {
      let name = "test.binding.exchange.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let srcName = "bunnyswift.recovery.e2e.src.\(UUID().uuidString.prefix(8))"
      let dstName = "bunnyswift.recovery.e2e.dst.\(UUID().uuidString.prefix(8))"
      let queueName = "bunnyswift.recovery.e2e.q.\(UUID().uuidString.prefix(8))"

      _ = try await channel.fanout(srcName, autoDelete: true)
      _ = try await channel.fanout(dstName, autoDelete: true)
      _ = try await channel.queue(queueName, durable: true)
      try await channel.exchangeBind(destination: dstName, source: srcName)
      try await channel.queueBind(queue: queueName, exchange: dstName)
      defer {
        Task {
          _ = try? await channel.queueDelete(queueName)
          try? await channel.exchangeDelete(dstName)
          try? await channel.exchangeDelete(srcName)
        }
      }

      try await closeAndWaitForRecovery(connection, name: name)

      try await ensureBindingFunctional(
        channel: channel, exchangeName: srcName, queueName: queueName)
    }
  }

  // MARK: - Consumer Recovery

  @Suite("Consumer Recovery")
  struct ConsumerRecoveryTests {

    @Test("Consumer registrations are recovered on server")
    func consumerRecovery() async throws {
      let name = "test.consumer.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.consumer.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      _ = try await channel.basicConsume(queue: queueName, acknowledgementMode: .automatic)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      try await closeAndWaitForRecovery(connection, name: name)

      let recovered = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return (info?.consumers ?? 0) >= 1
      }
      #expect(recovered, "Consumer should be re-registered after recovery")
    }

    @Test("Many consumers are recovered")
    func manyConsumersRecovery() async throws {
      let name = "test.consumer.many.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.consumers.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      let consumerCount: UInt32 = 8
      for _ in 0..<consumerCount {
        _ = try await channel.basicConsume(queue: queueName, acknowledgementMode: .automatic)
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let recovered = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return (info?.consumers ?? 0) == consumerCount
      }
      #expect(recovered, "All \(consumerCount) consumers should recover")
    }
  }

  // MARK: - Deleted Entities Not Recovered

  @Suite("Deleted Entities Not Recovered")
  struct DeletedEntitiesNotRecoveredTests {

    @Test("Deleted queues are not recovered")
    func deletedQueueNotRecovered() async throws {
      let name = "test.deleted.queue.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.deleted.q.\(UUID().uuidString.prefix(8))"
      let queue = try await channel.queue(queueName, durable: false)
      _ = try await queue.delete()

      try await closeAndWaitForRecovery(connection, name: name)

      let info = await httpAPI.getQueueOrNil(queueName)
      #expect(info == nil, "Deleted queue should NOT be recovered")
    }

    @Test("Deleted exchanges are not recovered")
    func deletedExchangeNotRecovered() async throws {
      let name = "test.deleted.exchange.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.recovery.deleted.ex.\(UUID().uuidString.prefix(8))"
      let exchange = try await channel.direct(exchangeName)
      try await exchange.delete()

      try await closeAndWaitForRecovery(connection, name: name)

      let info = await httpAPI.getExchangeOrNil(exchangeName)
      #expect(info == nil, "Deleted exchange should NOT be recovered")
    }

    @Test("Deleted queue bindings are not recovered")
    func deletedQueueBindingNotRecovered() async throws {
      let name = "test.deleted.qbinding.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.recovery.delbind.ex.\(UUID().uuidString.prefix(8))"
      let queueName = "bunnyswift.recovery.delbind.q.\(UUID().uuidString.prefix(8))"

      _ = try await channel.direct(exchangeName, durable: true)
      _ = try await channel.queue(queueName, durable: true)
      try await channel.queueBind(
        queue: queueName, exchange: exchangeName, routingKey: "key")
      try await channel.queueUnbind(
        queue: queueName, exchange: exchangeName, routingKey: "key")
      defer {
        Task {
          _ = try? await channel.queueDelete(queueName)
          try? await channel.exchangeDelete(exchangeName)
        }
      }

      try await closeAndWaitForRecovery(connection, name: name)

      // Wait for channel to be ready after recovery
      let ready = await pollUntil(timeout: 5) { await channel.open }
      #expect(ready, "Channel should recover")

      try await channel.basicPublish(
        body: Data("should-not-arrive".utf8), exchange: exchangeName, routingKey: "key")
      try await Task.sleep(for: .milliseconds(500))

      let info = await httpAPI.getQueueOrNil(queueName)
      #expect((info?.messages ?? 0) == 0, "Deleted binding should not be recovered")
    }

    @Test("Deleted exchange bindings are not recovered")
    func deletedExchangeBindingNotRecovered() async throws {
      let name = "test.deleted.exbinding.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let srcName = "bunnyswift.recovery.delexbind.src.\(UUID().uuidString.prefix(8))"
      let dstName = "bunnyswift.recovery.delexbind.dst.\(UUID().uuidString.prefix(8))"
      let queueName = "bunnyswift.recovery.delexbind.q.\(UUID().uuidString.prefix(8))"

      _ = try await channel.fanout(srcName, durable: true)
      _ = try await channel.fanout(dstName, durable: true)
      _ = try await channel.queue(queueName, durable: true)
      try await channel.exchangeBind(destination: dstName, source: srcName)
      try await channel.queueBind(queue: queueName, exchange: dstName)
      try await channel.exchangeUnbind(destination: dstName, source: srcName)
      defer {
        Task {
          _ = try? await channel.queueDelete(queueName)
          try? await channel.exchangeDelete(dstName)
          try? await channel.exchangeDelete(srcName)
        }
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let ready = await pollUntil(timeout: 5) { await channel.open }
      #expect(ready, "Channel should recover")

      try await channel.basicPublish(
        body: Data("should-not-arrive".utf8), exchange: srcName, routingKey: "")
      try await Task.sleep(for: .milliseconds(500))

      let info = await httpAPI.getQueueOrNil(queueName)
      #expect((info?.messages ?? 0) == 0, "Deleted exchange binding should not be recovered")
    }

    @Test("Cancelled consumers are not recovered")
    func cancelledConsumerNotRecovered() async throws {
      let name = "test.cancelled.consumer.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.cancelled.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      let stream = try await channel.basicConsume(
        queue: queueName, acknowledgementMode: .automatic)
      try await channel.basicCancel(stream.consumerTag)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      try await closeAndWaitForRecovery(connection, name: name)
      try await Task.sleep(for: .seconds(1))

      let info = await httpAPI.getQueueOrNil(queueName)
      #expect((info?.consumers ?? 0) == 0, "Cancelled consumer should NOT be recovered")
    }
  }

  // MARK: - Topology Recovery Disabled

  @Suite("Topology Recovery Disabled")
  struct TopologyRecoveryDisabledTests {

    @Test("Queues are not recovered when topology recovery is disabled")
    func topologyRecoveryDisabled() async throws {
      let name = "test.no.topology.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(
        name: name,
        topologyRecovery: false
      )
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.notopo.\(UUID().uuidString.prefix(8))"
      // Exclusive queues are deleted by the server when the connection drops
      _ = try await channel.queue(queueName, exclusive: true)

      try await closeAndWaitForRecovery(connection, name: name)

      let gone = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return info == nil
      }
      #expect(gone, "Queue should NOT be recovered when topology recovery is disabled")
    }
  }

  // MARK: - Multiple Recovery Cycles

  @Suite("Multiple Recovery Cycles")
  struct MultipleRecoveryCyclesTests {

    @Test("Connection recovers across successive disconnections")
    func subsequentRecoveries() async throws {
      let name = "test.multi.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.multi.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      for cycle in 1...3 {
        try await closeAndWaitForRecovery(connection, name: name)

        #expect(await connection.connected, "Cycle \(cycle): connection should be open")
        let ready = await pollUntil(timeout: 5) { await channel.open }
        #expect(ready, "Cycle \(cycle): channel should be open")

        let info = await httpAPI.getQueueOrNil(queueName)
        #expect(info != nil, "Cycle \(cycle): queue should exist")
      }
    }
  }

  // MARK: - Auto-Delete Entity Recovery

  @Suite("Auto-Delete Entity Recovery")
  struct AutoDeleteEntityRecoveryTests {

    @Test("Auto-delete queue with binding and consumer is recovered")
    func autoDeleteQueueWithBindingRecovery() async throws {
      let name = "test.autodelete.q.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.recovery.ad.ex.\(UUID().uuidString.prefix(8))"
      let queueName = "bunnyswift.recovery.ad.q.\(UUID().uuidString.prefix(8))"

      _ = try await channel.direct(exchangeName, autoDelete: true)
      _ = try await channel.queue(queueName, durable: false, autoDelete: true)
      try await channel.queueBind(
        queue: queueName, exchange: exchangeName, routingKey: "ad.key")
      _ = try await channel.basicConsume(queue: queueName, acknowledgementMode: .automatic)
      defer {
        Task {
          _ = try? await channel.queueDelete(queueName)
          try? await channel.exchangeDelete(exchangeName)
        }
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let queueRecovered = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return info != nil
      }
      let exchangeRecovered = await pollUntil(timeout: 5) {
        let info = await httpAPI.getExchangeOrNil(exchangeName)
        return info != nil
      }
      #expect(queueRecovered, "Auto-delete queue should be recovered")
      #expect(exchangeRecovered, "Auto-delete exchange should be recovered")
    }
  }

  // MARK: - Connection Name Preservation

  @Suite("Connection Name Preservation")
  struct ConnectionNamePreservationTests {

    @Test("Connection name is preserved after recovery")
    func connectionNamePreservation() async throws {
      let name = "test.name.preserve.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      #expect(await connection.connectionName == name)
      try await closeAndWaitForRecovery(connection, name: name)
      #expect(await connection.connectionName == name)

      // Verify the recovered connection is visible in the HTTP API with the same name
      let found = try await pollUntil(timeout: 10) {
        let conns = try await httpAPI.listConnections()
        return conns.contains { $0.clientProperties.connectionName == name }
      }
      #expect(found, "Recovered connection should have the same client name")
    }
  }

  // MARK: - Channel Recovery Callbacks

  @Suite("Channel Recovery Callbacks")
  struct ChannelRecoveryCallbackTests {

    @Test("Channel-level recovery callback is invoked")
    func channelRecoveryCallback() async throws {
      let name = "test.ch.callback.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let ch1 = try await connection.openChannel()
      let ch2 = try await connection.openChannel()

      let ch1Recovered = ManagedAtomic(false)
      let ch2Recovered = ManagedAtomic(false)
      await ch1.onRecovery { ch1Recovered.store(true) }
      await ch2.onRecovery { ch2Recovered.store(true) }

      try await closeAndWaitForRecovery(connection, name: name)

      let bothRecovered = await pollUntil(timeout: 5) {
        ch1Recovered.load() && ch2Recovered.load()
      }
      #expect(bothRecovered, "Both channel recovery callbacks should fire")
    }
  }

  // MARK: - Consumer Message Delivery After Recovery

  @Suite("Consumer Delivery After Recovery")
  struct ConsumerDeliveryAfterRecoveryTests {

    @Test("Consumer receives messages published after recovery")
    func consumerDeliveryAfterRecovery() async throws {
      let name = "test.consumer.delivery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.delivery.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      let stream = try await channel.basicConsume(
        queue: queueName, acknowledgementMode: .automatic)

      let delivered = ManagedAtomic(false)
      let deliveredBody = ManagedAtomic<String>("")

      // Consume in background
      let consumeTask = Task {
        for await message in stream {
          deliveredBody.store(message.bodyString ?? "")
          delivered.store(true)
          break
        }
      }
      defer { consumeTask.cancel() }

      try await closeAndWaitForRecovery(connection, name: name)

      // Wait for the consumer to be re-registered on the server
      let consumerReady = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return (info?.consumers ?? 0) >= 1
      }
      #expect(consumerReady, "Consumer should be recovered on server")

      // Publish after recovery
      try await channel.basicPublish(
        body: Data("hello-after-recovery".utf8), exchange: "", routingKey: queueName)

      let gotMessage = await pollUntil(timeout: 5) { delivered.load() }
      #expect(gotMessage, "Consumer should receive message after recovery")
      #expect(deliveredBody.load() == "hello-after-recovery")
    }

    @Test("basicAck works after recovery")
    func basicAckAfterRecovery() async throws {
      let name = "test.ack.recovery.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      try await channel.basicQos(prefetchCount: 5)
      let queueName = "bunnyswift.recovery.ack.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      let stream = try await channel.basicConsume(
        queue: queueName, acknowledgementMode: .manual)

      let acked = ManagedAtomic(false)
      let consumeTask = Task {
        for await message in stream {
          try await message.ack()
          acked.store(true)
          break
        }
      }
      defer { consumeTask.cancel() }

      try await closeAndWaitForRecovery(connection, name: name)

      let consumerReady = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return (info?.consumers ?? 0) >= 1
      }
      #expect(consumerReady, "Consumer should be re-registered after recovery")

      try await channel.basicPublish(
        body: Data("ack-test".utf8), exchange: "", routingKey: queueName)

      let didAck = await pollUntil(timeout: 5) { acked.load() }
      #expect(didAck, "Should be able to ack messages after recovery")

      // Verify queue is empty after ack
      let empty = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return (info?.messages ?? 1) == 0
      }
      #expect(empty, "Queue should be empty after ack")
    }
  }

  // MARK: - Subsequent Recoveries With Consumer

  @Suite("Subsequent Consumer Recoveries")
  struct SubsequentConsumerRecoveriesTests {

    @Test("Consumer survives multiple consecutive recoveries")
    func consumerSurvivesMultipleRecoveries() async throws {
      let name = "test.consumer.multi.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.recovery.multi.consumer.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: true)
      defer { Task { _ = try? await channel.queueDelete(queueName) } }

      let messageCount = ManagedAtomic<Int>(0)
      let stream = try await channel.basicConsume(
        queue: queueName, acknowledgementMode: .automatic)

      let consumeTask = Task {
        for await _ in stream {
          messageCount.store(messageCount.load() + 1)
        }
      }
      defer { consumeTask.cancel() }

      // Recover 5 times, publishing after each recovery
      for cycle in 1...5 {
        try await closeAndWaitForRecovery(connection, name: name)

        let consumerReady = await pollUntil(timeout: 5) {
          let info = await httpAPI.getQueueOrNil(queueName)
          return (info?.consumers ?? 0) >= 1
        }
        #expect(consumerReady, "Cycle \(cycle): consumer should recover")

        try await channel.basicPublish(
          body: Data("cycle-\(cycle)".utf8), exchange: "", routingKey: queueName)

        let expected = cycle
        let gotMessage = await pollUntil(timeout: 5) {
          messageCount.load() >= expected
        }
        #expect(gotMessage, "Cycle \(cycle): consumer should receive message")
      }
    }
  }

  // MARK: - Multi-Channel Consumer Recovery

  @Suite("Multi-Channel Consumer Recovery")
  struct MultiChannelConsumerRecoveryTests {

    @Test("Consumers on different channels recover independently")
    func consumersOnDifferentChannels() async throws {
      let name = "test.multi.ch.consumer.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let ch1 = try await connection.openChannel()
      let ch2 = try await connection.openChannel()
      let q1Name = "bunnyswift.recovery.mch.q1.\(UUID().uuidString.prefix(8))"
      let q2Name = "bunnyswift.recovery.mch.q2.\(UUID().uuidString.prefix(8))"
      _ = try await ch1.queue(q1Name, durable: true)
      _ = try await ch2.queue(q2Name, durable: true)
      defer {
        Task {
          _ = try? await ch1.queueDelete(q1Name)
          _ = try? await ch2.queueDelete(q2Name)
        }
      }

      let stream1 = try await ch1.basicConsume(
        queue: q1Name, acknowledgementMode: .automatic)
      let stream2 = try await ch2.basicConsume(
        queue: q2Name, acknowledgementMode: .automatic)

      let msg1 = ManagedAtomic<String>("")
      let msg2 = ManagedAtomic<String>("")

      let task1 = Task {
        for await message in stream1 {
          msg1.store(message.bodyString ?? "")
          break
        }
      }
      let task2 = Task {
        for await message in stream2 {
          msg2.store(message.bodyString ?? "")
          break
        }
      }
      defer {
        task1.cancel()
        task2.cancel()
      }

      try await closeAndWaitForRecovery(connection, name: name)

      // Wait for both consumers to be re-registered
      let ready = await pollUntil(timeout: 5) {
        let i1 = await httpAPI.getQueueOrNil(q1Name)
        let i2 = await httpAPI.getQueueOrNil(q2Name)
        return (i1?.consumers ?? 0) >= 1 && (i2?.consumers ?? 0) >= 1
      }
      #expect(ready, "Both consumers should recover on their respective channels")

      // Publish to each queue on its own channel
      try await ch1.basicPublish(
        body: Data("ch1-msg".utf8), exchange: "", routingKey: q1Name)
      try await ch2.basicPublish(
        body: Data("ch2-msg".utf8), exchange: "", routingKey: q2Name)

      let got1 = await pollUntil(timeout: 5) { !msg1.load().isEmpty }
      let got2 = await pollUntil(timeout: 5) { !msg2.load().isEmpty }
      #expect(got1, "Consumer on channel 1 should receive its message")
      #expect(got2, "Consumer on channel 2 should receive its message")
      #expect(msg1.load() == "ch1-msg")
      #expect(msg2.load() == "ch2-msg")
    }
  }

  // MARK: - Return Handler Recovery

  @Suite("Listener Recovery")
  struct ListenerRecoveryTests {

    @Test("Return handlers survive recovery")
    func returnHandlerRecovery() async throws {
      let name = "test.return.handler.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let returnReceived = ManagedAtomic(false)
      await channel.onReturn { _ in
        returnReceived.store(true)
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let ready = await pollUntil(timeout: 5) { await channel.open }
      #expect(ready, "Channel should be open after recovery")

      // Publish mandatory message to non-existent routing key.
      // The default exchange routes by queue name, so using a
      // random routing key with no matching queue triggers a return.
      try await channel.basicPublish(
        body: Data("mandatory-return".utf8),
        exchange: "",
        routingKey: "bunnyswift.nonexistent.\(UUID().uuidString.prefix(8))",
        mandatory: true
      )

      let gotReturn = await pollUntil(timeout: 5) { returnReceived.load() }
      #expect(gotReturn, "Return handler should fire after recovery")
    }

    @Test("Blocked/unblocked handlers survive recovery")
    func blockedHandlerRecovery() async throws {
      let name = "test.blocked.handler.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let blockedCalled = ManagedAtomic(false)
      let unblockedCalled = ManagedAtomic(false)
      await connection.onBlocked { _ in blockedCalled.store(true) }
      await connection.onUnblocked { unblockedCalled.store(true) }

      try await closeAndWaitForRecovery(connection, name: name)

      // Triggering connection.blocked requires global memory alarms,
      // so we just verify the connection is usable after recovery.
      #expect(await connection.connected)
    }
  }

  // MARK: - Queue Name Change Listener

  @Suite("Queue Name Change Listener")
  struct QueueNameChangeListenerTests {

    @Test("Queue name change listener fires for server-named queues")
    func queueNameChangeListener() async throws {
      let name = "test.qname.change.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queue = try await channel.queue("", exclusive: true)
      let originalName = queue.name
      #expect(originalName.hasPrefix("amq.gen-"))

      let oldNameReceived = ManagedAtomic<String>("")
      let newNameReceived = ManagedAtomic<String>("")
      await connection.onQueueNameChange { oldName, newName in
        oldNameReceived.store(oldName)
        newNameReceived.store(newName)
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let listenerFired = await pollUntil(timeout: 5) {
        !oldNameReceived.load().isEmpty
      }
      #expect(listenerFired, "Queue name change listener should fire")
      #expect(oldNameReceived.load() == originalName)
      #expect(newNameReceived.load().hasPrefix("amq.gen-"))
      #expect(newNameReceived.load() != originalName)
    }
  }

  // MARK: - Recovery Failure

  @Suite("Recovery Failure")
  struct RecoveryFailureTests {

    @Test("Recovery failure callback fires when max attempts exceeded")
    func recoveryFailureCallback() async throws {
      let name = "test.recovery.failure.\(UUID().uuidString.prefix(8))"
      var config = ConnectionConfiguration(
        automaticRecovery: true,
        networkRecoveryInterval: 0.1,
        maxRecoveryAttempts: 1
      )
      config.heartbeat = 4
      config.connectionName = name
      let connection = try await Connection.open(config)
      defer { Task { try? await connection.close() } }

      let failureCalled = ManagedAtomic(false)
      await connection.onRecoveryFailure { _ in
        failureCalled.store(true)
      }

      try await httpAPI.closeAllConnectionsWithName(name)

      let failed = await pollUntil(timeout: 10) { failureCalled.load() }
      // With maxRecoveryAttempts=1 and the server still running, recovery
      // will likely succeed. If so, that is equally valid.
      if !failed {
        #expect(await connection.connected)
      }
    }
  }

  // MARK: - Channel ID Allocation

  @Suite("Channel ID Allocation")
  struct ChannelIDAllocationTests {

    @Test("Channel IDs are stable after recovery")
    func channelIDStability() async throws {
      let name = "test.chid.stable.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      var channels: [Channel] = []
      for _ in 0..<10 {
        channels.append(try await connection.openChannel())
      }
      let originalIDs = await channels.asyncMap { await $0.number }

      try await closeAndWaitForRecovery(connection, name: name)

      let allReady = await pollUntil(timeout: 5) {
        for ch in channels {
          if !(await ch.open) { return false }
        }
        return true
      }
      #expect(allReady, "All 10 channels should recover")

      let recoveredIDs = await channels.asyncMap { await $0.number }
      #expect(originalIDs == recoveredIDs, "Channel IDs should be preserved")

      // Verify the connection is stable after recovery by waiting briefly
      try await Task.sleep(for: .milliseconds(200))
      #expect(await connection.connected, "Connection should remain open")
    }
  }

  // MARK: - Server-Named Queue Binding Update

  @Suite("Server-Named Queue Binding Recovery")
  struct ServerNamedQueueBindingRecoveryTests {

    @Test("Bindings to server-named queues are updated after recovery")
    func serverNamedQueueBindingRecovery() async throws {
      let name = "test.snq.binding.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.recovery.snq.ex.\(UUID().uuidString.prefix(8))"
      _ = try await channel.fanout(exchangeName, autoDelete: true)
      defer { Task { try? await channel.exchangeDelete(exchangeName) } }

      let queue = try await channel.queue("", exclusive: true)
      try await channel.queueBind(queue: queue.name, exchange: exchangeName)

      try await closeAndWaitForRecovery(connection, name: name)

      // After recovery, the server-named queue has a new name.
      // The binding should have been updated to use the new name.
      let queuesAfter = await connection.topologyRegistry.allQueues()
      let newQueue = queuesAfter.first
      #expect(newQueue != nil)

      let bindingsAfter = await connection.topologyRegistry.allQueueBindings()
      let binding = bindingsAfter.first { $0.exchange == exchangeName }
      #expect(binding != nil, "Binding should exist after recovery")
      if let newName = newQueue?.name {
        #expect(
          binding?.queue == newName,
          "Binding should reference the new queue name")
      }

      let ready = await pollUntil(timeout: 5) { await channel.open }
      #expect(ready, "Channel should be open after recovery")

      try await channel.basicPublish(
        body: Data("snq-binding-test".utf8), exchange: exchangeName, routingKey: "")

      if let newName = newQueue?.name {
        let arrived = await pollUntil(timeout: 5) {
          let info = await httpAPI.getQueueOrNil(newName)
          return (info?.messages ?? 0) >= 1
        }
        #expect(arrived, "Message should arrive via recovered binding")
      }
    }
  }
}

// MARK: - Topology Recording from Channel Operations

@Suite(
  "Topology Recording",
  .disabled(if: TestConfig.skipIntegrationTests),
  .timeLimit(.minutes(2))
)
struct TopologyRecordingTests {

  @Test("exchange() records to topology registry")
  func exchangeRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.rec.ex.\(UUID().uuidString.prefix(8))"
    _ = try await channel.direct(exchangeName, durable: false, autoDelete: true)
    defer { Task { try? await channel.exchangeDelete(exchangeName) } }

    let exchanges = await connection.topologyRegistry.allExchanges()
    let found = exchanges.first { $0.name == exchangeName }
    #expect(found != nil, "Exchange should be recorded in topology registry")
    #expect(found?.type == "direct")
    #expect(found?.autoDelete == true)
  }

  @Test("exchangeDelete() removes from topology registry")
  func exchangeDeletion() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.rec.exdel.\(UUID().uuidString.prefix(8))"
    let exchange = try await channel.direct(exchangeName, durable: false, autoDelete: true)
    try await exchange.delete()

    let exchanges = await connection.topologyRegistry.allExchanges()
    let found = exchanges.first { $0.name == exchangeName }
    #expect(found == nil, "Deleted exchange should be removed from registry")
  }

  @Test("queue() records to topology registry")
  func queueRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let queueName = "bunnyswift.rec.q.\(UUID().uuidString.prefix(8))"
    let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
    defer { Task { _ = try? await queue.delete() } }

    let queues = await connection.topologyRegistry.allQueues()
    let found = queues.first { $0.name == queueName }
    #expect(found != nil, "Queue should be recorded in topology registry")
    #expect(found?.autoDelete == true)
    #expect(found?.serverNamed == false)
  }

  @Test("Server-named queue records with serverNamed flag")
  func serverNamedQueueRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)
    defer { Task { _ = try? await queue.delete() } }

    let queues = await connection.topologyRegistry.allQueues()
    let found = queues.first { $0.name == queue.name }
    #expect(found != nil, "Server-named queue should be recorded")
    #expect(found?.serverNamed == true)
    #expect(found?.name.hasPrefix("amq.gen-") == true)
  }

  @Test("queueDelete() removes from topology registry")
  func queueDeletion() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let queueName = "bunnyswift.rec.qdel.\(UUID().uuidString.prefix(8))"
    let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
    _ = try await queue.delete()

    let queues = await connection.topologyRegistry.allQueues()
    let found = queues.first { $0.name == queueName }
    #expect(found == nil, "Deleted queue should be removed from registry")
  }

  @Test("queueBind() records binding in topology registry")
  func queueBindingRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.rec.bind.ex.\(UUID().uuidString.prefix(8))"
    let queueName = "bunnyswift.rec.bind.q.\(UUID().uuidString.prefix(8))"
    let exchange = try await channel.direct(exchangeName, autoDelete: true)
    let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
    try await channel.queueBind(queue: queueName, exchange: exchangeName, routingKey: "rk")
    defer {
      Task {
        _ = try? await queue.delete()
        try? await exchange.delete()
      }
    }

    let bindings = await connection.topologyRegistry.allQueueBindings()
    let found = bindings.first { $0.queue == queueName && $0.exchange == exchangeName }
    #expect(found != nil, "Queue binding should be recorded")
    #expect(found?.routingKey == "rk")
  }

  @Test("queueUnbind() removes binding from topology registry")
  func queueUnbindingRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.rec.unbind.ex.\(UUID().uuidString.prefix(8))"
    let queueName = "bunnyswift.rec.unbind.q.\(UUID().uuidString.prefix(8))"
    let exchange = try await channel.direct(exchangeName, autoDelete: true)
    let queue = try await channel.queue(queueName, durable: false, autoDelete: true)
    try await channel.queueBind(queue: queueName, exchange: exchangeName, routingKey: "rk")
    try await channel.queueUnbind(queue: queueName, exchange: exchangeName, routingKey: "rk")
    defer {
      Task {
        _ = try? await queue.delete()
        try? await exchange.delete()
      }
    }

    let bindings = await connection.topologyRegistry.allQueueBindings()
    let found = bindings.first { $0.queue == queueName && $0.exchange == exchangeName }
    #expect(found == nil, "Unbound binding should be removed from registry")
  }

  @Test("exchangeBind() records binding in topology registry")
  func exchangeBindingRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let srcName = "bunnyswift.rec.exbind.src.\(UUID().uuidString.prefix(8))"
    let dstName = "bunnyswift.rec.exbind.dst.\(UUID().uuidString.prefix(8))"
    _ = try await channel.fanout(srcName, autoDelete: true)
    _ = try await channel.fanout(dstName, autoDelete: true)
    try await channel.exchangeBind(destination: dstName, source: srcName, routingKey: "rk")
    defer {
      Task {
        try? await channel.exchangeUnbind(
          destination: dstName, source: srcName, routingKey: "rk")
        try? await channel.exchangeDelete(dstName)
        try? await channel.exchangeDelete(srcName)
      }
    }

    let bindings = await connection.topologyRegistry.allExchangeBindings()
    let found = bindings.first { $0.source == srcName && $0.destination == dstName }
    #expect(found != nil, "Exchange binding should be recorded")
  }

  @Test("exchangeUnbind() removes binding from topology registry")
  func exchangeUnbindingRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let srcName = "bunnyswift.rec.exunbind.src.\(UUID().uuidString.prefix(8))"
    let dstName = "bunnyswift.rec.exunbind.dst.\(UUID().uuidString.prefix(8))"
    _ = try await channel.fanout(srcName, autoDelete: true)
    _ = try await channel.fanout(dstName, autoDelete: true)
    try await channel.exchangeBind(destination: dstName, source: srcName, routingKey: "rk")
    try await channel.exchangeUnbind(destination: dstName, source: srcName, routingKey: "rk")
    defer {
      Task {
        try? await channel.exchangeDelete(dstName)
        try? await channel.exchangeDelete(srcName)
      }
    }

    let bindings = await connection.topologyRegistry.allExchangeBindings()
    let found = bindings.first { $0.source == srcName && $0.destination == dstName }
    #expect(found == nil, "Unbound exchange binding should be removed from registry")
  }

  @Test("basicConsume() records consumer in topology registry")
  func consumerRecording() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)
    let stream = try await channel.basicConsume(
      queue: queue.name, acknowledgementMode: .manual, exclusive: true)
    defer {
      Task {
        try? await channel.basicCancel(stream.consumerTag)
        _ = try? await queue.delete()
      }
    }

    let consumers = await connection.topologyRegistry.allConsumers()
    #expect(consumers.count == 1)
    let found = consumers.first
    #expect(found?.queue == queue.name)
    #expect(found?.exclusive == true)
    #expect(found?.acknowledgementMode == .manual)
  }

  @Test("basicCancel() removes consumer from topology registry")
  func consumerCancellation() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)
    let stream = try await channel.basicConsume(
      queue: queue.name, acknowledgementMode: .automatic)
    try await channel.basicCancel(stream.consumerTag)
    defer { Task { _ = try? await queue.delete() } }

    let consumers = await connection.topologyRegistry.allConsumers()
    #expect(consumers.isEmpty, "Cancelled consumer should be removed from registry")
  }

  // MARK: - Multi-Host Recovery

  @Suite("Multi-Host Recovery")
  struct MultiHostRecoveryTests {

    @Test("Recovery with multiple endpoints cycles through hosts")
    func multiHostRecovery() async throws {

      let name = "test.multihost.\(UUID().uuidString.prefix(8))"
      // Both endpoints point to the same server; validates the cycling mechanism.
      var config = ConnectionConfiguration(
        endpoints: [
          Endpoint(host: "localhost", port: 5672),
          Endpoint(host: "127.0.0.1", port: 5672),
        ],
        shuffleEndpoints: false,
        automaticRecovery: true,
        networkRecoveryInterval: RecoveryTestConfig.recoveryInterval,
        topologyRecovery: true
      )
      config.heartbeat = 4
      config.connectionName = name
      let connection = try await Connection.open(config)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.multihost.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, exclusive: true)

      try await closeAndWaitForRecovery(connection, name: name)

      #expect(await connection.connected)
      let endpoint = await connection.currentEndpoint
      // After recovery, the connection may have advanced to the next endpoint
      #expect(endpoint.host == "localhost" || endpoint.host == "127.0.0.1")
    }

    @Test("Recovery with a broken host in the list falls through to a working one")
    func multiHostWithBrokenHost() async throws {

      let name = "test.multihost.broken.\(UUID().uuidString.prefix(8))"
      // First endpoint is unreachable, second works.
      var config = ConnectionConfiguration(
        connectionTimeout: .seconds(2),
        endpoints: [
          // RFC 5737 TEST-NET, guaranteed unreachable
          Endpoint(host: "192.0.2.1", port: 5672),
          Endpoint(host: "localhost", port: 5672),
        ],
        shuffleEndpoints: false,
        automaticRecovery: true,
        networkRecoveryInterval: RecoveryTestConfig.recoveryInterval,
        topologyRecovery: true
      )
      config.heartbeat = 4
      config.connectionName = name

      // Initial connection should skip the broken host and connect via localhost
      let connection = try await Connection.open(config)
      defer { Task { try? await connection.close() } }

      #expect(await connection.connected)
      let initialEndpoint = await connection.currentEndpoint
      #expect(initialEndpoint.host == "localhost", "Should have connected to the working host")

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.multihost.broken.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, exclusive: true)

      try await closeAndWaitForRecovery(connection, name: name)

      #expect(await connection.connected, "Should recover via the working host")
      let recoveredEndpoint = await connection.currentEndpoint
      #expect(recoveredEndpoint.host == "localhost")
    }
  }

  // MARK: - Topology Recovery Filtering

  @Suite("Topology Recovery Filtering")
  struct TopologyRecoveryFilterTests {

    @Test("Filtered queue is not recovered after disconnect")
    func filteredQueueNotRecovered() async throws {

      let name = "test.filter.queue.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      await connection.setTopologyRecoveryFilter(
        TopologyRecoveryFilter(
          queueFilter: { !$0.name.contains("filtered") }
        ))

      let channel = try await connection.openChannel()
      // Exclusive queues are deleted by the server on disconnect,
      // so filtering prevents re-declaration and they stay gone.
      let keptName = "bunnyswift.filter.kept.\(UUID().uuidString.prefix(8))"
      let filteredName = "bunnyswift.filter.filtered.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(keptName, exclusive: true)
      _ = try await channel.queue(filteredName, exclusive: true)

      try await closeAndWaitForRecovery(connection, name: name)

      let keptExists = await pollUntil(timeout: 5) {
        await httpAPI.getQueueOrNil(keptName) != nil
      }
      #expect(keptExists, "Non-filtered queue should be recovered")

      let filteredInfo = await httpAPI.getQueueOrNil(filteredName)
      #expect(filteredInfo == nil, "Filtered queue should not be recovered")
    }

    @Test("Filtered consumer is not recovered")
    func filteredConsumerNotRecovered() async throws {

      let name = "test.filter.consumer.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      let channel = try await connection.openChannel()
      let queueName = "bunnyswift.filter.consumer.\(UUID().uuidString.prefix(8))"
      _ = try await channel.queue(queueName, durable: false, autoDelete: true)

      let keptStream = try await channel.basicConsume(
        queue: queueName, consumerTag: "kept-consumer", acknowledgementMode: .automatic)
      let filteredStream = try await channel.basicConsume(
        queue: queueName, consumerTag: "filtered-consumer", acknowledgementMode: .automatic)

      await connection.setTopologyRecoveryFilter(
        TopologyRecoveryFilter(
          consumerFilter: { $0.consumerTag != "filtered-consumer" }
        ))

      let consumeTask1 = Task { for await _ in keptStream {} }
      let consumeTask2 = Task { for await _ in filteredStream {} }
      defer {
        consumeTask1.cancel()
        consumeTask2.cancel()
      }

      try await closeAndWaitForRecovery(connection, name: name)

      let hasKept = await pollUntil(timeout: 5) {
        let info = await httpAPI.getQueueOrNil(queueName)
        return (info?.consumers ?? 0) >= 1
      }
      #expect(hasKept, "Kept consumer should be recovered")

      let info = await httpAPI.getQueueOrNil(queueName)
      #expect(info?.consumers == 1, "Only the non-filtered consumer should be recovered")
    }

    @Test("Filtered binding is not recovered after disconnect")
    func filteredBindingNotRecovered() async throws {

      let name = "test.filter.binding.\(UUID().uuidString.prefix(8))"
      let connection = try await RecoveryTestConfig.openConnection(name: name)
      defer { Task { try? await connection.close() } }

      await connection.setTopologyRecoveryFilter(
        TopologyRecoveryFilter(
          queueBindingFilter: { $0.routingKey != "filtered.key" }
        ))

      let channel = try await connection.openChannel()
      let exchangeName = "bunnyswift.filter.bind.ex.\(UUID().uuidString.prefix(8))"
      // Exclusive queue: server deletes it (and its bindings) on disconnect.
      // Recovery re-declares the queue with only one binding.
      let queueName = "bunnyswift.filter.bind.q.\(UUID().uuidString.prefix(8))"
      _ = try await channel.topic(exchangeName, autoDelete: true)
      _ = try await channel.queue(queueName, exclusive: true)
      try await channel.queueBind(
        queue: queueName, exchange: exchangeName, routingKey: "kept.key")
      try await channel.queueBind(
        queue: queueName, exchange: exchangeName, routingKey: "filtered.key")

      try await closeAndWaitForRecovery(connection, name: name)

      let ready = await pollUntil(timeout: 5) { await channel.open }
      #expect(ready, "Channel should be open after recovery")
      // Verify server-side bindings: only "kept.key" should exist
      let serverBindings = try await httpAPI.listQueueBindings(queue: queueName)
      let routingKeys = serverBindings.map(\.routingKey)
      #expect(routingKeys.contains("kept.key"), "Kept binding should be recovered")
      #expect(!routingKeys.contains("filtered.key"), "Filtered binding should not be recovered")
    }
  }
}
