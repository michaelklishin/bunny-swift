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

  // MARK: - TLS Configuration

  /// Path to the directory containing `tls-gen`-generated certificates.
  /// Set TLS_CERTS_DIR to override; falls back to the local tls-gen checkout.
  static var tlsCertsDir: String? {
    ProcessInfo.processInfo.environment["TLS_CERTS_DIR"]
      ?? {
        let fallback =
          NSString(
            string: "~/Development/Opensource/tls-gen.git/basic/result"
          ).expandingTildeInPath
        return FileManager.default.fileExists(atPath: fallback + "/ca_certificate.pem")
          ? fallback : nil
      }()
  }

  static var skipTLSTests: Bool {
    tlsCertsDir == nil
  }

  /// Creates a TLS connection configuration using tls-gen certificates
  static func tlsConnectionConfiguration() throws -> ConnectionConfiguration {
    guard let certsDir = tlsCertsDir else {
      throw ConnectionError.protocolError("TLS certificates not found")
    }

    let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
    let tls = try TLSConfiguration.fromPEMFiles(
      certificatePath: "\(certsDir)/client_certificate.pem",
      keyPath: "\(certsDir)/client_key.pem",
      caCertificatePath: "\(certsDir)/ca_certificate.pem",
      verifyPeer: false
    )

    return ConnectionConfiguration(
      port: 5671,
      tls: tls,
      enableTCPNoDelay: !isCI,
      enableTCPKeepAlive: !isCI
    )
  }

  /// Opens a TLS connection using tls-gen certificates
  static func openTLSConnection() async throws -> Connection {
    return try await Connection.open(tlsConnectionConfiguration())
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

// MARK: - Update Secret Tests

@Suite("UpdateSecret Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct UpdateSecretIntegrationTests {

  // With the internal (non-OAuth) auth backend, the server accepts
  // update-secret but treats it as a no-op.
  @Test("update-secret succeeds with the internal auth backend", .timeLimit(.minutes(1)))
  func updateSecretSucceeds() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    try await connection.updateSecret("guest", reason: "token refresh")
    let isConnected = await connection.connected
    #expect(isConnected)
  }

  @Test("update-secret can be called multiple times", .timeLimit(.minutes(1)))
  func updateSecretMultipleTimes() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    for i in 1...3 {
      try await connection.updateSecret("secret-\(i)", reason: "refresh #\(i)")
    }
    let isConnected = await connection.connected
    #expect(isConnected)
  }

  @Test("connection is usable after update-secret", .timeLimit(.minutes(1)))
  func connectionUsableAfterUpdateSecret() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    try await connection.updateSecret("guest", reason: "refresh")

    let channel = try await connection.openChannel()
    let q = try await channel.queue("", exclusive: true)
    let queueName = await q.name
    #expect(!queueName.isEmpty)
    try await channel.close()
  }

  @Test("publish and consume work after update-secret", .timeLimit(.minutes(1)))
  func publishAndConsumeAfterUpdateSecret() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    try await connection.updateSecret("guest", reason: "refresh")

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let body = "after-update-secret"
    try await queue.publish(body)

    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response?.bodyString == body)

    _ = try await queue.delete()
  }

  @Test("update-secret with an active consumer", .timeLimit(.minutes(1)))
  func updateSecretWithActiveConsumer() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()
    let stream = try await queue.consume(acknowledgementMode: .automatic)

    try await connection.updateSecret("guest", reason: "refresh while consuming")

    // Publish after the secret update and verify delivery through the active consumer
    try await queue.publish("delivered-after-refresh")

    var received: String?
    for try await message in stream {
      received = message.bodyString
      break
    }
    #expect(received == "delivered-after-refresh")

    try await stream.cancel()
    _ = try await queue.delete()
  }

  @Test("update-secret with a 255-byte reason", .timeLimit(.minutes(1)))
  func updateSecretMaxLengthReason() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try? await connection.close() } }

    let reason = String(repeating: "r", count: 255)
    try await connection.updateSecret("guest", reason: reason)

    let isConnected = await connection.connected
    #expect(isConnected)
  }

  @Test("update-secret on a closed connection throws", .timeLimit(.minutes(1)))
  func updateSecretAfterClose() async throws {
    let connection = try await TestConfig.openConnection()
    try await connection.close()

    await #expect(throws: ConnectionError.self) {
      try await connection.updateSecret("guest", reason: "too late")
    }
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

  @Test("withChannel closes channel after operation", .timeLimit(.minutes(1)))
  func withChannelClosesAfterOperation() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    var capturedChannel: Channel?
    try await connection.withChannel { channel in
      capturedChannel = channel
      #expect(await channel.open)
    }

    #expect(await !capturedChannel!.open)
  }

  @Test("withChannel returns value from operation", .timeLimit(.minutes(1)))
  func withChannelReturnsValue() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let result = try await connection.withChannel { channel in
      await channel.number
    }

    #expect(result > 0)
  }

  @Test("withChannel closes channel on error", .timeLimit(.minutes(1)))
  func withChannelClosesOnError() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    struct TestError: Error {}

    var capturedChannel: Channel?
    do {
      try await connection.withChannel { channel in
        capturedChannel = channel
        throw TestError()
      }
      Issue.record("Expected error to be thrown")
    } catch is TestError {}

    #expect(await !capturedChannel!.open)
  }

  @Test("withChannel allows queue operations", .timeLimit(.minutes(1)))
  func withChannelAllowsQueueOperations() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let messageBody = "withChannel test"
    let received = try await connection.withChannel { channel in
      let queue = try await channel.temporaryQueue()
      try await queue.publish(messageBody)
      let response = try await queue.get(acknowledgementMode: .automatic)
      _ = try await queue.delete()
      return response?.bodyString
    }

    #expect(received == messageBody)
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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

    // Publish some messages
    for i in 0..<5 {
      try await queue.publish("message \(i)")
    }

    // Give the server a moment
    try await Task.sleep(for: .milliseconds(100))

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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

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

  @Test("Publish and get empty-body message", .timeLimit(.minutes(1)))
  func publishAndGetEmptyBody() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await queue.publish(Data())

    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response != nil)
    #expect(response?.body == Data())

    _ = try await queue.delete()
  }

  @Test("Consume empty-body message via async stream", .timeLimit(.minutes(1)))
  func consumeEmptyBodyViaStream() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let stream = try await queue.consume(acknowledgementMode: .automatic)

    try await queue.publish(Data())

    for try await msg in stream {
      #expect(msg.body == Data())
      break
    }

    try await stream.cancel()
    _ = try await queue.delete()
  }

  @Test("Consume with async stream", .timeLimit(.minutes(1)))
  func consumeWithAsyncStream() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    // Start consuming BEFORE publishing to avoid race condition
    let stream = try await queue.consume(acknowledgementMode: .automatic)

    let messageCount = 5
    for i in 0..<messageCount {
      try await queue.publish("message \(i)")
    }

    // Collect messages
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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

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
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let initialSeqNo = await channel.publishSeqNo
    try await queue.publish("message 1")
    try await queue.publish("message 2")

    let finalSeqNo = await channel.publishSeqNo
    #expect(finalSeqNo == initialSeqNo + 2)

    _ = try await queue.delete()
  }
}

// MARK: - Batch Publish Tests

@Suite("Batch Publish Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct BatchPublishIntegrationTests {

  @Test("Batch publish delivers all messages", .timeLimit(.minutes(1)))
  func batchPublishDeliversAll() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let messageCount = 100
    let bodies = (0..<messageCount).map { Data("batch-msg-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    try await Task.sleep(for: .milliseconds(200))

    var received = 0
    while let msg = try await queue.get(acknowledgementMode: .automatic) {
      #expect(msg.bodyString?.hasPrefix("batch-msg-") == true)
      received += 1
    }
    #expect(received == messageCount)

    _ = try await queue.delete()
  }

  @Test("Batch publish with empty array is a no-op", .timeLimit(.minutes(1)))
  func batchPublishEmptyArray() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()

    // Should not throw
    try await channel.basicPublishBatch(bodies: [], routingKey: "nonexistent")
  }

  @Test("Batch publish with publisher confirms", .timeLimit(.minutes(1)))
  func batchPublishWithConfirms() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true)

    let messageCount = 50
    let bodies = (0..<messageCount).map { Data("confirmed-\($0)".utf8) }

    // Should not throw — all messages confirmed
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == UInt64(messageCount) + 1)

    _ = try await queue.delete()
  }

  @Test("Batch publish sequence numbers increment correctly", .timeLimit(.minutes(1)))
  func batchPublishSeqNos() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let before = await channel.publishSeqNo
    let batchSize = 20
    let bodies = (0..<batchSize).map { Data("seq-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    let after = await channel.publishSeqNo
    #expect(after == before + UInt64(batchSize))

    _ = try await queue.delete()
  }

  @Test("Batch publish with custom properties", .timeLimit(.minutes(1)))
  func batchPublishWithProperties() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let properties = BasicProperties.persistent
      .withContentType("application/json")
      .withCorrelationId("batch-123")

    let bodies = (0..<5).map { Data("{\"i\":\($0)}".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name, properties: properties)

    try await Task.sleep(for: .milliseconds(100))

    let response = try await queue.get(acknowledgementMode: .automatic)
    #expect(response != nil)
    #expect(response?.properties.contentType == "application/json")
    #expect(response?.properties.correlationId == "batch-123")

    _ = try await queue.delete()
  }

  @Test("Batch publish with large messages spanning multiple body frames", .timeLimit(.minutes(1)))
  func batchPublishLargeMessages() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    // Create messages larger than the default frame max (~128KB)
    // to exercise the multi-body-frame path
    let largeBody = Data(repeating: 0xAB, count: 200_000)
    let bodies = [largeBody, largeBody, largeBody]
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    try await Task.sleep(for: .milliseconds(500))

    var received = 0
    while let msg = try await queue.get(acknowledgementMode: .automatic) {
      #expect(msg.body.count == 200_000)
      received += 1
    }
    #expect(received == 3)

    _ = try await queue.delete()
  }

  @Test("Batch publish with empty-body messages", .timeLimit(.minutes(1)))
  func batchPublishEmptyBodies() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let bodies = [Data(), Data(), Data()]
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    try await Task.sleep(for: .milliseconds(100))

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == 3)

    _ = try await queue.delete()
  }

  @Test("Batch publish via async stream consumption", .timeLimit(.minutes(1)))
  func batchPublishConsumeViaStream() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let stream = try await queue.consume(acknowledgementMode: .automatic)

    let messageCount = 200
    let bodies = (0..<messageCount).map { Data("stream-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    var received = 0
    for try await _ in stream {
      received += 1
      if received >= messageCount { break }
    }
    #expect(received == messageCount)

    try await stream.cancel()
    _ = try await queue.delete()
  }
}
