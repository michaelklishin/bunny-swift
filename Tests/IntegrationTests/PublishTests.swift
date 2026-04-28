// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import Testing

@testable import BunnySwift

// MARK: - Buffered Publish + waitForConfirms

@Suite("Buffered Publish Integration Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct BufferedPublishTests {

  @Test("publish buffers writes and waitForConfirms awaits them", .timeLimit(.minutes(1)))
  func publishThenWaitForConfirms() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let messageCount = 50
    for i in 0..<messageCount {
      try await channel.publish(
        body: Data("buffered-\(i)".utf8), routingKey: queue.name)
    }

    await channel.flush()
    try await channel.waitForConfirms()

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == messageCount)

    _ = try await queue.delete()
  }

  @Test("publish does not flush per message", .timeLimit(.minutes(1)))
  func publishDoesNotFlushPerMessage() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true)

    // Publish many messages; they should buffer without blocking on confirms
    let messageCount = 200
    for i in 0..<messageCount {
      try await channel.publish(
        body: Data("fast-\(i)".utf8), routingKey: queue.name)
    }

    await channel.flush()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == UInt64(messageCount) + 1)

    _ = try await queue.delete()
  }

  @Test("waitForConfirms returns immediately when nothing is pending", .timeLimit(.minutes(1)))
  func waitForConfirmsNoPending() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    try await channel.confirmSelect()

    // No publishes, should return immediately
    try await channel.waitForConfirms()
  }

  @Test("waitForConfirms without confirm mode is a no-op", .timeLimit(.minutes(1)))
  func waitForConfirmsWithoutConfirmMode() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    try await channel.waitForConfirms()
  }

  @Test("publish with confirms and varying body sizes", .timeLimit(.minutes(1)))
  func publishVaryingBodySizes() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let sizes = [0, 1, 12, 128, 1024, 4096, 65_536, 200_000]
    for size in sizes {
      let body = Data(repeating: 0xAB, count: size)
      try await channel.publish(body: body, routingKey: queue.name)
    }

    await channel.flush()
    try await channel.waitForConfirms()

    var received: [Int] = []
    while let msg = try await queue.get(acknowledgementMode: .automatic) {
      received.append(msg.body.count)
    }

    #expect(received.sorted() == sizes.sorted())
    _ = try await queue.delete()
  }

  @Test("multiple waitForConfirms calls in sequence", .timeLimit(.minutes(1)))
  func multipleWaitForConfirmsCalls() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    // First batch
    for i in 0..<20 {
      try await channel.publish(
        body: Data("batch1-\(i)".utf8), routingKey: queue.name)
    }
    await channel.flush()
    try await channel.waitForConfirms()

    // Second batch
    for i in 0..<20 {
      try await channel.publish(
        body: Data("batch2-\(i)".utf8), routingKey: queue.name)
    }
    await channel.flush()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 41)

    _ = try await queue.delete()
  }

  @Test(
    "publish with backpressure via outstanding confirms limit",
    .timeLimit(.minutes(1)))
  func publishWithBackpressure() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true, outstandingLimit: 10)

    // Publish more than the limit; backpressure should prevent unbounded growth
    let messageCount = 50
    for i in 0..<messageCount {
      try await channel.publish(
        body: Data("bp-\(i)".utf8), routingKey: queue.name)
    }

    await channel.flush()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == UInt64(messageCount) + 1)

    _ = try await queue.delete()
  }
}

// MARK: - basicPublishBatch Confirm Tracking

@Suite(
  "Batch Confirm Tracking Tests",
  .disabled(if: TestConfig.skipIntegrationTests))
struct BatchConfirmTrackingTests {

  @Test(
    "basicPublishBatch with confirms uses batch tracking",
    .timeLimit(.minutes(1)))
  func batchWithConfirmTracking() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true)

    let bodies = (0..<100).map { Data("batch-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 101)

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == 100)

    _ = try await queue.delete()
  }

  @Test(
    "basicPublishBatch without tracking increments seqNo but does not block",
    .timeLimit(.minutes(1)))
  func batchWithoutTracking() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let bodies = (0..<50).map { Data("notrack-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 51)

    // Explicit waitForConfirms still works
    try await channel.waitForConfirms()

    _ = try await queue.delete()
  }

  @Test(
    "basicPublishBatch followed by waitForConfirms",
    .timeLimit(.minutes(1)))
  func batchFollowedByWaitForConfirms() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    // Batch publish without tracking
    let bodies = (0..<30).map { Data("wait-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    // Explicit wait ensures all are confirmed
    try await channel.waitForConfirms()

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == 30)

    _ = try await queue.delete()
  }

  @Test(
    "batch sizes from 1 to a few hundred",
    .timeLimit(.minutes(1)),
    arguments: [1, 2, 5, 10, 50, 100, 300])
  func batchSizeRange(size: Int) async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true)

    let bodies = (0..<size).map { Data("sz-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == UInt64(size) + 1)

    _ = try await queue.delete()
  }
}

// MARK: - PublishBatch Builder

@Suite("PublishBatch Builder Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct PublishBatchBuilderTests {

  @Test("builder publishes all messages", .timeLimit(.minutes(1)))
  func builderPublishesAll() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let batch = channel.publishBatch(routingKey: queue.name)
    for i in 0..<50 {
      try await batch.add("builder-\(i)")
    }
    await batch.publish()

    try await Task.sleep(for: .milliseconds(200))

    var received = 0
    while let msg = try await queue.get(acknowledgementMode: .automatic) {
      #expect(msg.bodyString?.hasPrefix("builder-") == true)
      received += 1
    }
    #expect(received == 50)

    _ = try await queue.delete()
  }

  @Test("builder with publisher confirms", .timeLimit(.minutes(1)))
  func builderWithConfirms() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let batch = channel.publishBatch(routingKey: queue.name)
    for i in 0..<30 {
      try await batch.add(Data("confirmed-\(i)".utf8))
    }
    await batch.publish()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 31)

    _ = try await queue.delete()
  }

  @Test("builder with custom properties", .timeLimit(.minutes(1)))
  func builderWithProperties() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let props = BasicProperties.persistent
      .withContentType("application/json")
      .withCorrelationId("builder-batch")

    let batch = channel.publishBatch(
      routingKey: queue.name, properties: props)
    try await batch.add("{\"n\":1}")
    try await batch.add("{\"n\":2}")
    await batch.publish()

    try await Task.sleep(for: .milliseconds(100))

    let msg = try await queue.get(acknowledgementMode: .automatic)
    #expect(msg?.properties.contentType == "application/json")
    #expect(msg?.properties.correlationId == "builder-batch")

    _ = try await queue.delete()
  }

  @Test("builder with empty batch is a no-op", .timeLimit(.minutes(1)))
  func builderEmptyBatch() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()

    let batch = channel.publishBatch(routingKey: "nonexistent")
    await batch.publish()
  }

  @Test("builder with Data bodies", .timeLimit(.minutes(1)))
  func builderWithDataBodies() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let batch = channel.publishBatch(routingKey: queue.name)
    try await batch.add(Data([0x00, 0x01, 0x02]))
    try await batch.add(Data())
    try await batch.add(Data(repeating: 0xFF, count: 1024))
    await batch.publish()

    try await Task.sleep(for: .milliseconds(100))

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == 3)

    _ = try await queue.delete()
  }

  @Test("builder consumed via async stream", .timeLimit(.minutes(1)))
  func builderConsumedViaStream() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    let stream = try await queue.consume(acknowledgementMode: .automatic)

    let messageCount = 100
    let batch = channel.publishBatch(routingKey: queue.name)
    for i in 0..<messageCount {
      try await batch.add("stream-\(i)")
    }
    await batch.publish()

    var received = 0
    for try await _ in stream {
      received += 1
      if received >= messageCount { break }
    }
    #expect(received == messageCount)

    try await stream.cancel()
    _ = try await queue.delete()
  }

  @Test(
    "builder with varying batch sizes",
    .timeLimit(.minutes(1)),
    arguments: [1, 2, 10, 50, 200])
  func builderBatchSizes(size: Int) async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect()

    let batch = channel.publishBatch(routingKey: queue.name)
    for i in 0..<size {
      try await batch.add("param-\(i)")
    }
    await batch.publish()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == UInt64(size) + 1)

    _ = try await queue.delete()
  }
}

// MARK: - Mixed Publish Modes

@Suite("Mixed Publish Mode Tests", .disabled(if: TestConfig.skipIntegrationTests))
struct MixedPublishModeTests {

  @Test(
    "basicPublish and publish can be mixed on the same channel",
    .timeLimit(.minutes(1)))
  func mixBasicPublishAndPublish() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true)

    // basicPublish auto-waits for confirm
    try await channel.basicPublish(
      body: Data("basic-1".utf8), routingKey: queue.name)

    // publish buffers
    for i in 0..<10 {
      try await channel.publish(
        body: Data("buffered-\(i)".utf8), routingKey: queue.name)
    }

    // basicPublish again
    try await channel.basicPublish(
      body: Data("basic-2".utf8), routingKey: queue.name)

    await channel.flush()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 13)

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == 12)

    _ = try await queue.delete()
  }

  @Test(
    "basicPublishBatch and builder on the same channel",
    .timeLimit(.minutes(1)))
  func mixBatchAndBuilder() async throws {
    let connection = try await TestConfig.openConnection()
    defer { Task { try await connection.close() } }

    let channel = try await connection.openChannel()
    let queue = try await channel.temporaryQueue()

    try await channel.confirmSelect(tracking: true)

    // Batch API
    let bodies = (0..<20).map { Data("array-\($0)".utf8) }
    try await channel.basicPublishBatch(
      bodies: bodies, routingKey: queue.name)

    // Builder API
    let batch = channel.publishBatch(routingKey: queue.name)
    for i in 0..<20 {
      try await batch.add("builder-\(i)")
    }
    await batch.publish()
    try await channel.waitForConfirms()

    let seqNo = await channel.publishSeqNo
    #expect(seqNo == 41)

    var received = 0
    while (try await queue.get(acknowledgementMode: .automatic)) != nil {
      received += 1
    }
    #expect(received == 40)

    _ = try await queue.delete()
  }
}
