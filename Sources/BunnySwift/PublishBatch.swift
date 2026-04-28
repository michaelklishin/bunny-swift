// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation

/// Incrementally buffers messages for a single exchange and routing key,
/// then flushes them in one go.
///
/// Each `add` call writes to the transport buffer without flushing.
/// Call `publish` to flush. To wait for broker acknowledgement when publisher
/// confirms are enabled, call `channel.waitForConfirms()` afterwards.
///
/// ```swift
/// let batch = channel.publishBatch(routingKey: queue.name)
/// for item in items {
///     try await batch.add(item.data)
/// }
/// await batch.publish()
/// try await channel.waitForConfirms()  // only when confirms are enabled
/// ```
public struct PublishBatch: Sendable {
  private let channel: Channel
  private let exchange: String
  private let routingKey: String
  private let mandatory: Bool
  private let properties: BasicProperties

  internal init(
    channel: Channel,
    exchange: String,
    routingKey: String,
    mandatory: Bool,
    properties: BasicProperties
  ) {
    self.channel = channel
    self.exchange = exchange
    self.routingKey = routingKey
    self.mandatory = mandatory
    self.properties = properties
  }

  /// Buffers a single message without flushing.
  public func add(_ body: Data) async throws {
    try await channel.publish(
      body: body,
      exchange: exchange,
      routingKey: routingKey,
      mandatory: mandatory,
      properties: properties
    )
  }

  /// Buffers a UTF-8 encoded string message without flushing.
  public func add(_ message: String) async throws {
    try await add(Data(message.utf8))
  }

  /// Flushes all buffered messages.
  public func publish() async {
    await channel.flush()
  }
}
