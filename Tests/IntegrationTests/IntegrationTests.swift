// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Integration Tests
// These tests require a running RabbitMQ server at localhost:5672

import Foundation
import Testing

@testable import BunnySwift

// MARK: - Configuration

/// Test configuration - set RABBITMQ_URL environment variable to customize
struct TestConfig {
  static var rabbitmqURL: String {
    ProcessInfo.processInfo.environment["RABBITMQ_URL"] ?? "amqp://guest:guest@localhost:5672/"
  }

  static var skipIntegrationTests: Bool {
    ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] == "1"
  }

  /// Creates a connection configuration suitable for the test environment.
  /// On CI (when CI=true), disables socket options that may require elevated permissions.
  static func connectionConfiguration() -> ConnectionConfiguration {
    let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
    return ConnectionConfiguration(
      enableTCPNoDelay: !isCI,
      enableTCPKeepAlive: !isCI
    )
  }

  /// Opens a connection using test configuration
  static func openConnection() async throws -> Connection {
    return try await Connection.open(connectionConfiguration())
  }
}

// MARK: - Placeholder Test

@Suite("Integration Tests")
struct IntegrationTests {
  @Test("Placeholder for future integration tests")
  func placeholder() async throws {
    // Integration tests require a running RabbitMQ server
    // Set SKIP_INTEGRATION_TESTS=1 to skip these tests
  }
}

// MARK: - Connection Tests

@Suite("Connection Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct ConnectionIntegrationTests {

  @Test("Connect with default configuration", .timeLimit(.minutes(1)))
  func connectWithDefaults() async throws {
    let connection = try await TestConfig.openConnection()
    let isConnected = await connection.connected
    #expect(isConnected)
    try await connection.close()
    let isDisconnected = await !connection.connected
    #expect(isDisconnected)
  }

  @Test("Connect with URI", .timeLimit(.minutes(1)))
  func connectWithURI() async throws {
    var config = TestConfig.connectionConfiguration()
    let uri = try ConnectionConfiguration.from(uri: TestConfig.rabbitmqURL)
    config.host = uri.host
    config.port = uri.port
    config.username = uri.username
    config.password = uri.password
    config.virtualHost = uri.virtualHost
    let connection = try await Connection.open(config)
    let isConnected = await connection.connected
    #expect(isConnected)
    try await connection.close()
  }

  @Test("Server properties are available", .timeLimit(.minutes(1)))
  func serverProperties() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let props = await connection.serverProperties
    #expect(props != nil)
    let hasProduct = props?["product"] != nil
    #expect(hasProduct)
  }

  @Test("Negotiated parameters are reasonable", .timeLimit(.minutes(1)))
  func negotiatedParameters() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let frameMax = await connection.frameMax
    let channelMax = await connection.channelMax
    #expect(frameMax > 0)
    #expect(channelMax > 0)
  }
}

// MARK: - Channel Tests

@Suite("Channel Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct ChannelIntegrationTests {

  @Test("Open and close channel", .timeLimit(.minutes(1)))
  func openAndCloseChannel() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let isOpen = await channel.open
    let channelNumber = await channel.number
    #expect(isOpen)
    #expect(channelNumber > 0)

    try await channel.close()
    let isClosed = await !channel.open
    #expect(isClosed)
  }

  @Test("Open multiple channels", .timeLimit(.minutes(1)))
  func openMultipleChannels() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel1 = try await connection.openChannel()
    let channel2 = try await connection.openChannel()
    let channel3 = try await connection.openChannel()

    let num1 = await channel1.number
    let num2 = await channel2.number
    let num3 = await channel3.number
    #expect(num1 != num2)
    #expect(num2 != num3)

    try await channel1.close()
    try await channel2.close()
    try await channel3.close()
  }
}

// MARK: - Queue Tests

@Suite("Queue Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct QueueIntegrationTests {

  @Test("Declare and delete queue", .timeLimit(.minutes(1)))
  func declareAndDeleteQueue() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queueName = "bunnyswift.test.\(UUID().uuidString)"

    let queue = try await channel.queue(
      queueName, durable: false, exclusive: false, autoDelete: true)
    #expect(queue.name == queueName)

    let deletedCount = try await queue.delete()
    #expect(deletedCount >= 0)
  }

  @Test("Declare server-named queue", .timeLimit(.minutes(1)))
  func serverNamedQueue() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    #expect(!queue.name.isEmpty)
    #expect(queue.name.hasPrefix("amq.gen-"))

    _ = try await queue.delete()
  }

  @Test("Declare durable queue", .timeLimit(.minutes(1)))
  func durableQueue() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queueName = "bunnyswift.durable.\(UUID().uuidString)"

    let queue = try await channel.queue(queueName, durable: true)
    #expect(queue.name == queueName)

    _ = try await queue.delete()
  }

  @Test("Purge queue", .timeLimit(.minutes(1)))
  func purgeQueue() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    // Publish some messages
    for i in 0..<5 {
      try await queue.publish("message \(i)")
    }

    // Give the server a moment
    try await Task.sleep(nanoseconds: 100_000_000)

    let purgedCount = try await queue.purge()
    #expect(purgedCount >= 0)

    _ = try await queue.delete()
  }
}

// MARK: - Exchange Tests

@Suite("Exchange Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct ExchangeIntegrationTests {

  @Test("Declare and delete exchange", .timeLimit(.minutes(1)))
  func declareAndDeleteExchange() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.test.\(UUID().uuidString)"

    let exchange = try await channel.direct(exchangeName, durable: false, autoDelete: true)
    #expect(exchange.name == exchangeName)

    _ = try await exchange.delete()
  }

  @Test("Declare fanout exchange", .timeLimit(.minutes(1)))
  func fanoutExchange() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.fanout.\(UUID().uuidString)"

    let exchange = try await channel.fanout(exchangeName, autoDelete: true)
    #expect(exchange.name == exchangeName)

    _ = try await exchange.delete()
  }

  @Test("Declare topic exchange", .timeLimit(.minutes(1)))
  func topicExchange() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.topic.\(UUID().uuidString)"

    let exchange = try await channel.topic(exchangeName, autoDelete: true)
    #expect(exchange.name == exchangeName)

    _ = try await exchange.delete()
  }
}

// MARK: - Binding Tests

@Suite("Binding Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct BindingIntegrationTests {

  @Test("Bind queue to exchange", .timeLimit(.minutes(1)))
  func bindQueueToExchange() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let exchangeName = "bunnyswift.bind.\(UUID().uuidString)"
    let exchange = try await channel.direct(exchangeName, autoDelete: true)
    let queue = try await channel.queue("", exclusive: true)

    _ = try await queue.bind(to: exchange, routingKey: "test.key")

    // Should not throw
    _ = try await queue.unbind(from: exchange, routingKey: "test.key")

    _ = try await queue.delete()
    _ = try await exchange.delete()
  }
}

// MARK: - Publish/Consume Tests

@Suite("Publish/Consume Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct PublishConsumeIntegrationTests {

  @Test("Publish and consume single message", .timeLimit(.minutes(1)))
  func publishAndConsumeSingle() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    let messageBody = "Hello, BunnySwift!"
    try await queue.publish(messageBody)

    // Get the message
    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response != nil)
    #expect(response?.bodyString == messageBody)

    _ = try await queue.delete()
  }

  @Test("Publish with properties", .timeLimit(.minutes(1)))
  func publishWithProperties() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    let properties = BasicProperties.persistent
      .withContentType("text/plain")
      .withCorrelationId("test-123")

    try await queue.publish("test message".data(using: .utf8)!, properties: properties)

    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response != nil)
    #expect(response?.properties.contentType == "text/plain")
    #expect(response?.properties.correlationId == "test-123")

    _ = try await queue.delete()
  }

  @Test("Consume with async stream", .timeLimit(.minutes(1)))
  func consumeWithAsyncStream() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    let messageCount = 5
    for i in 0..<messageCount {
      try await queue.publish("message \(i)")
    }

    let stream = try await queue.consume(acknowledgementMode: .automatic)

    // Collect messages with timeout
    var receivedCount = 0
    for try await _ in stream {
      receivedCount += 1
      if receivedCount >= messageCount {
        break
      }
    }

    #expect(receivedCount == messageCount)

    try await stream.cancel()
    _ = try await queue.delete()
  }
}

// MARK: - Acknowledgement Tests

@Suite("Acknowledgement Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct AcknowledgementIntegrationTests {

  @Test("Manual acknowledgement", .timeLimit(.minutes(1)))
  func manualAck() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    try await queue.publish("ack test")

    let response = try await queue.get(acknowledgementMode: .manual)
    #expect(response != nil)

    try await response?.ack()

    // Message should be gone now
    let empty = try await queue.get(acknowledgementMode: .automatic)
    #expect(empty == nil)

    _ = try await queue.delete()
  }

  @Test("Negative acknowledgement with requeue", .timeLimit(.minutes(1)))
  func nackWithRequeue() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    try await queue.publish("nack test")

    // Get and nack with requeue
    let response1 = try await queue.get(acknowledgementMode: .manual)
    #expect(response1 != nil)
    try await response1?.nack(requeue: true)

    // Should be able to get it again
    let response2 = try await queue.get(acknowledgementMode: .automatic)
    #expect(response2 != nil)
    #expect(response2?.redelivered == true)

    _ = try await queue.delete()
  }

  @Test("Reject message", .timeLimit(.minutes(1)))
  func rejectMessage() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    try await queue.publish("reject test")

    let response = try await queue.get(acknowledgementMode: .manual)
    #expect(response != nil)
    try await response?.reject(requeue: false)

    // Message should be gone
    let empty = try await queue.get(acknowledgementMode: .automatic)
    #expect(empty == nil)

    _ = try await queue.delete()
  }
}

// MARK: - QoS Tests

@Suite("QoS Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct QoSIntegrationTests {

  @Test("Set prefetch count", .timeLimit(.minutes(1)))
  func setPrefetchCount() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()

    // Should not throw
    try await channel.basicQos(prefetchCount: 10)
  }
}

// MARK: - Transaction Tests

@Suite("Transaction Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct TransactionIntegrationTests {

  @Test("Transaction commit", .timeLimit(.minutes(1)))
  func transactionCommit() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    try await channel.txSelect()
    try await queue.publish("tx message")
    try await channel.txCommit()

    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response != nil)
    #expect(response?.bodyString == "tx message")

    _ = try await queue.delete()
  }

  @Test("Transaction rollback", .timeLimit(.minutes(1)))
  func transactionRollback() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    try await channel.txSelect()
    try await queue.publish("rollback message")
    try await channel.txRollback()

    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response == nil)

    _ = try await queue.delete()
  }
}

// MARK: - Publisher Confirms Tests

@Suite("Publisher Confirms Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct PublisherConfirmsIntegrationTests {

  @Test("Enable confirm mode", .timeLimit(.minutes(1)))
  func enableConfirmMode() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()

    try await channel.confirmSelect()
    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 1)
  }

  @Test("Publish sequence number increments", .timeLimit(.minutes(1)))
  func publishSeqNoIncrements() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.queue("", exclusive: true)

    try await channel.confirmSelect()

    let initialSeqNo = await channel.publishSeqNo
    try await queue.publish("message 1")
    try await queue.publish("message 2")

    let finalSeqNo = await channel.publishSeqNo
    #expect(finalSeqNo == initialSeqNo + 2)

    _ = try await queue.delete()
  }
}
