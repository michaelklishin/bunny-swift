// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import AMQPProtocol

/// Well-known optional argument ("x-argument") keys for queue, stream and exchange declaration.
///
/// See [Queue Arguments](https://www.rabbitmq.com/docs/queues#optional-arguments).
public enum XArguments {
  // MARK: - Queue Types

  /// Queue type argument key
  public static let queueType = "x-queue-type"

  // MARK: - TTL and Expiration

  /// Per-message TTL in milliseconds
  public static let messageTTL = "x-message-ttl"

  /// Queue expiration (TTL) in milliseconds.
  /// The queue will be deleted after this time of being unused.
  public static let expires = "x-expires"

  // MARK: - Length Limits

  /// Maximum number of messages in the queue
  public static let maxLength = "x-max-length"

  /// Maximum total size of messages in bytes
  public static let maxLengthBytes = "x-max-length-bytes"

  // MARK: - Dead Lettering

  /// Dead letter exchange name
  public static let deadLetterExchange = "x-dead-letter-exchange"

  /// Dead letter routing key
  public static let deadLetterRoutingKey = "x-dead-letter-routing-key"

  /// Dead letter strategy ("at-most-once" or "at-least-once")
  public static let deadLetterStrategy = "x-dead-letter-strategy"

  // MARK: - Overflow Behavior

  /// Overflow behavior when queue length limit is reached.
  /// Values: "drop-head", "reject-publish", "reject-publish-dlx"
  public static let overflow = "x-overflow"

  // MARK: - Priority Queues

  /// Maximum priority level
  public static let maxPriority = "x-max-priority"

  // MARK: - Headers Exchange Binding

  /// Match mode for headers exchange bindings.
  /// See ``HeadersMatch`` for valid values.
  public static let headersMatch = "x-match"

  // MARK: - Consumer Options

  /// Enable single active consumer mode
  public static let singleActiveConsumer = "x-single-active-consumer"

  // MARK: - Queue Leader Locator

  /// Queue leader locator strategy.
  /// Values: "client-local", "balanced"
  public static let queueLeaderLocator = "x-queue-leader-locator"

  // MARK: - Quorum Queue Options

  /// Initial quorum group size for quorum queues
  public static let quorumInitialGroupSize = "x-quorum-initial-group-size"

  /// Target quorum group size for quorum queues
  public static let quorumTargetGroupSize = "x-quorum-target-group-size"

  /// Delivery limit before dead-lettering (quorum queues)
  public static let deliveryLimit = "x-delivery-limit"

  // MARK: - Stream Options

  /// Maximum age for stream retention (e.g., "7D", "1h")
  public static let maxAge = "x-max-age"

  /// Maximum segment size in bytes for streams
  public static let streamMaxSegmentSizeBytes = "x-stream-max-segment-size-bytes"

  /// Bloom filter size in bytes for streams (16-255)
  public static let streamFilterSizeBytes = "x-stream-filter-size-bytes"

  /// Initial cluster size for streams
  public static let initialClusterSize = "x-initial-cluster-size"

  /// Stream offset specification for consumers
  public static let streamOffset = "x-stream-offset"

  // MARK: - Delayed Queue Options (Tanzu RabbitMQ)

  /// Retry strategy for delayed queues.
  /// See ``DelayedRetryType`` for valid values.
  public static let delayedRetryType = "x-delayed-retry-type"

  /// Minimum retry delay in milliseconds for delayed queues
  public static let delayedRetryMin = "x-delayed-retry-min"

  /// Maximum retry delay in milliseconds for delayed queues
  public static let delayedRetryMax = "x-delayed-retry-max"

  // MARK: - Consumer Disconnected Timeout (Tanzu RabbitMQ)

  /// Time in milliseconds before a disconnected consumer's messages
  /// are redelivered. Supported by delayed and JMS queue types.
  public static let consumerDisconnectedTimeout = "x-consumer-disconnected-timeout"

  // MARK: - JMS Queue Options (Tanzu RabbitMQ)

  /// Fields available for JMS selector expressions.
  /// Value is an AMQP 0-9-1 array of strings, or `["*"]` for all application
  /// properties. Prefer ``Channel/jmsQueue(_:selectorFields:selectorFieldMaxBytes:consumerDisconnectedTimeout:durable:arguments:)``
  /// which accepts `[String]` directly.
  public static let selectorFields = "x-selector-fields"

  /// Maximum byte size per selector field
  public static let selectorFieldMaxBytes = "x-selector-field-max-bytes"

  // MARK: - JMS Consumer Options (Tanzu RabbitMQ)

  /// JMS message selector expression, passed as a consumer argument.
  /// Uses a SQL92-subset syntax (e.g. `"priority > 5 AND region = 'EU'"`).
  public static let jmsSelector = "x-jms-selector"
}

/// Match mode for headers exchange bindings (`x-match` argument).
public enum HeadersMatch: String, Sendable, CaseIterable {
  /// All specified headers must match
  case all
  /// At least one specified header must match
  case any
  /// Like `all`, but also matches `x-` prefixed headers
  case allWithX = "all-with-x"
  /// Like `any`, but also matches `x-` prefixed headers
  case anyWithX = "any-with-x"

  /// Converts to an AMQP 0-9-1 field value
  public var asFieldValue: FieldValue {
    .string(rawValue)
  }
}

/// Standard overflow behavior values for the `x-overflow` argument.
public enum OverflowBehavior: String, Sendable, CaseIterable {
  /// Drop messages from the head of the queue
  case dropHead = "drop-head"
  /// Reject new publishes with basic.nack responses (publisher confirms)
  case rejectPublish = "reject-publish"
  /// Reject new publishes via publisher confirms and dead-letter them
  case rejectPublishDLX = "reject-publish-dlx"

  /// Converts to an AMQP 0-9-1 field value
  public var asFieldValue: FieldValue {
    .string(rawValue)
  }
}

/// Queue leader locator strategies for the `x-queue-leader-locator` argument.
public enum QueueLeaderLocator: String, Sendable, CaseIterable {
  /// Place leader on the node the client is connected to
  case clientLocal = "client-local"
  /// Dynamically picks one of the two strategies internally depending on how many
  /// queues there are in the system
  case balanced = "balanced"

  /// Converts to an AMQP 0-9-1 field value
  public var asFieldValue: FieldValue {
    .string(rawValue)
  }
}

/// Dead letter strategy for the `x-dead-letter-strategy` argument.
public enum DeadLetterStrategy: String, Sendable, CaseIterable {
  /// At most once delivery, less safe but more performant
  case atMostOnce = "at-most-once"
  /// At least once delivery, safe, less performance, quorum queues-specific
  case atLeastOnce = "at-least-once"

  /// Converts to an AMQP 0-9-1 field value
  public var asFieldValue: FieldValue {
    .string(rawValue)
  }
}

/// Delayed queue retry type for the `x-delayed-retry-type` argument (Tanzu RabbitMQ).
public enum DelayedRetryType: String, Sendable, CaseIterable {
  /// Retry all messages
  case all
  /// Retry only messages that failed to be delivered to a consumer
  case failed
  /// Retry only messages returned by the broker (e.g. unroutable)
  case returned

  /// Converts to an AMQP 0-9-1 field value
  public var asFieldValue: FieldValue {
    .string(rawValue)
  }
}
