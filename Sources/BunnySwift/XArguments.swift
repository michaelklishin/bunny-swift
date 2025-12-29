// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

/// This enum contains standard, well known optional argument ("x-argument") keys for queue, stream and exchange declaration.
///
/// See [Queue Arguments](https://www.rabbitmq.com/docs/queues#optional-arguments)
/// to learn more.
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
}

/// Standard overflow behavior values for the `x-overflow` argument.
public enum OverflowBehavior: String, Sendable {
    /// Drop messages from the head of the queue
    case dropHead = "drop-head"
    /// Reject new publishes with basic.nack responses (publisher confirms)
    case rejectPublish = "reject-publish"
    /// Reject new publishes via publisher confirms and dead-letter them
    case rejectPublishDLX = "reject-publish-dlx"
}

/// Queue leader locator strategies for the `x-queue-leader-locator` argument.
public enum QueueLeaderLocator: String, Sendable {
    /// Place leader on the node the client is connected to
    case clientLocal = "client-local"
    /// Dynamically picks one of the two strategies internally depending on how many
    // queues there are in the system
    case balanced = "balanced"
}

/// Dead letter strategy for the `x-dead-letter-strategy` argument.
public enum DeadLetterStrategy: String, Sendable {
    /// At most once delivery, less safe but more performant
    case atMostOnce = "at-most-once"
    /// At least once delivery, safe, less performance, quorum queues-specific
    case atLeastOnce = "at-least-once"
}
