// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// BunnySwift Tests

import AMQPProtocol
import Testing

@testable import BunnySwift

@Suite("BunnySwift Tests")
struct BunnySwiftTests {
  @Test("Module imports correctly")
  func moduleImports() {
    // Placeholder for future tests
  }
}

// MARK: - QueueType

@Suite("QueueType Tests")
struct QueueTypeTests {
  @Test("rawValue returns correct strings")
  func rawValueReturnsCorrectStrings() {
    #expect(QueueType.classic.rawValue == "classic")
    #expect(QueueType.quorum.rawValue == "quorum")
    #expect(QueueType.stream.rawValue == "stream")
    #expect(QueueType.delayed.rawValue == "delayed")
    #expect(QueueType.jms.rawValue == "jms")
    #expect(QueueType.custom("x-my-type").rawValue == "x-my-type")
  }

  @Test("custom type preserves arbitrary values")
  func customTypePreservesArbitraryValues() {
    let custom1 = QueueType.custom("x-priority-queue")
    let custom2 = QueueType.custom("x-custom-queue")

    #expect(custom1.rawValue == "x-priority-queue")
    #expect(custom2.rawValue == "x-custom-queue")
  }

  @Test("asTableValue wraps rawValue in FieldValue.string")
  func asTableValueWrapsRawValue() {
    #expect(QueueType.classic.asTableValue == .string("classic"))
    #expect(QueueType.quorum.asTableValue == .string("quorum"))
    #expect(QueueType.stream.asTableValue == .string("stream"))
    #expect(QueueType.delayed.asTableValue == .string("delayed"))
    #expect(QueueType.jms.asTableValue == .string("jms"))
    #expect(QueueType.custom("x-test").asTableValue == .string("x-test"))
  }

  @Test("QueueType is Hashable")
  func queueTypeIsHashable() {
    var set = Set<QueueType>()
    set.insert(.classic)
    set.insert(.quorum)
    set.insert(.stream)
    set.insert(.delayed)
    set.insert(.jms)
    set.insert(.custom("x-test"))

    #expect(set.count == 6)
    #expect(set.contains(.classic))
    #expect(set.contains(.delayed))
    #expect(set.contains(.jms))
    #expect(set.contains(.custom("x-test")))
  }

  @Test("QueueType equality")
  func queueTypeEquality() {
    #expect(QueueType.classic == QueueType.classic)
    #expect(QueueType.quorum != QueueType.stream)
    #expect(QueueType.delayed == QueueType.delayed)
    #expect(QueueType.jms == QueueType.jms)
    #expect(QueueType.delayed != QueueType.jms)
    #expect(QueueType.custom("x-a") == QueueType.custom("x-a"))
    #expect(QueueType.custom("x-a") != QueueType.custom("x-b"))
  }

  @Test("custom with same rawValue as built-in is not equal")
  func customNotEqualToBuiltIn() {
    #expect(QueueType.custom("classic") != QueueType.classic)
    #expect(QueueType.custom("quorum") != QueueType.quorum)
    #expect(QueueType.custom("stream") != QueueType.stream)
    #expect(QueueType.custom("delayed") != QueueType.delayed)
    #expect(QueueType.custom("jms") != QueueType.jms)
  }

  @Test(
    "asTableValue round-trips through rawValue for all built-in types",
    arguments: [
      QueueType.classic, .quorum, .stream, .delayed, .jms,
    ]
  )
  func asTableValueMatchesRawValue(type: QueueType) {
    #expect(type.asTableValue == .string(type.rawValue))
  }

  @Test(
    "custom type rawValue round-trips for arbitrary strings",
    arguments: [
      "", "classic", "x-custom-queue", "my-plugin-queue",
      "with spaces", "UPPERCASE", "emoji-🐰",
    ]
  )
  func customRawValueRoundTrip(value: String) {
    let qt = QueueType.custom(value)
    #expect(qt.rawValue == value)
    #expect(qt.asTableValue == .string(value))
  }

  @Test("all built-in types produce unique rawValues")
  func builtInTypesUniqueRawValues() {
    let builtInTypes: [QueueType] = [.classic, .quorum, .stream, .delayed, .jms]
    let rawValues = Set(builtInTypes.map(\.rawValue))
    #expect(rawValues.count == builtInTypes.count)
  }

  @Test("duplicate custom values hash equally")
  func duplicateCustomValuesHashEqually() {
    var set = Set<QueueType>()
    set.insert(.custom("same"))
    set.insert(.custom("same"))
    #expect(set.count == 1)
  }

  @Test("delayed queue type produces correct declaration table")
  func delayedDeclarationTable() {
    var table: Table = [:]
    table[XArguments.queueType] = QueueType.delayed.asTableValue
    table[XArguments.delayedRetryType] = DelayedRetryType.failed.asFieldValue
    table[XArguments.delayedRetryMin] = .int64(1_000)
    table[XArguments.delayedRetryMax] = .int64(60_000)

    #expect(table[XArguments.queueType] == .string("delayed"))
    #expect(table[XArguments.delayedRetryType] == .string("failed"))
    #expect(table[XArguments.delayedRetryMin] == .int64(1_000))
    #expect(table[XArguments.delayedRetryMax] == .int64(60_000))
  }

  @Test("JMS queue type produces correct declaration table")
  func jmsDeclarationTable() {
    var table: Table = [:]
    table[XArguments.queueType] = QueueType.jms.asTableValue
    table[XArguments.selectorFields] = .array([.string("priority"), .string("region")])
    table[XArguments.selectorFieldMaxBytes] = .int64(256)

    #expect(table[XArguments.queueType] == .string("jms"))
    #expect(
      table[XArguments.selectorFields] == .array([.string("priority"), .string("region")]))
    #expect(table[XArguments.selectorFieldMaxBytes] == .int64(256))
  }
}

// MARK: - ExchangeType

@Suite("ExchangeType Tests")
struct ExchangeTypeTests {
  @Test("standard exchange type rawValues")
  func standardRawValues() {
    #expect(ExchangeType.direct.rawValue == "direct")
    #expect(ExchangeType.fanout.rawValue == "fanout")
    #expect(ExchangeType.topic.rawValue == "topic")
    #expect(ExchangeType.headers.rawValue == "headers")
  }

  @Test("all exchange types produce unique rawValues")
  func allTypesUniqueRawValues() {
    let allTypes: [ExchangeType] = [.direct, .fanout, .topic, .headers]
    let rawValues = Set(allTypes.map(\.rawValue))
    #expect(rawValues.count == allTypes.count)
  }
}

// MARK: - XArguments

/// All keys defined in XArguments, used by multiple tests.
private let allXArgumentKeys = [
  XArguments.queueType,
  XArguments.messageTTL,
  XArguments.expires,
  XArguments.maxLength,
  XArguments.maxLengthBytes,
  XArguments.deadLetterExchange,
  XArguments.deadLetterRoutingKey,
  XArguments.deadLetterStrategy,
  XArguments.overflow,
  XArguments.headersMatch,
  XArguments.maxPriority,
  XArguments.singleActiveConsumer,
  XArguments.queueLeaderLocator,
  XArguments.quorumInitialGroupSize,
  XArguments.quorumTargetGroupSize,
  XArguments.deliveryLimit,
  XArguments.maxAge,
  XArguments.streamMaxSegmentSizeBytes,
  XArguments.streamFilterSizeBytes,
  XArguments.initialClusterSize,
  XArguments.streamOffset,
  XArguments.delayedRetryType,
  XArguments.delayedRetryMin,
  XArguments.delayedRetryMax,
  XArguments.consumerDisconnectedTimeout,
  XArguments.selectorFields,
  XArguments.selectorFieldMaxBytes,
  XArguments.jmsSelector,
]

@Suite("XArguments Tests")
struct XArgumentsTests {
  @Test("delayed queue argument keys")
  func delayedQueueKeys() {
    #expect(XArguments.delayedRetryType == "x-delayed-retry-type")
    #expect(XArguments.delayedRetryMin == "x-delayed-retry-min")
    #expect(XArguments.delayedRetryMax == "x-delayed-retry-max")
  }

  @Test("headers exchange argument key")
  func headersExchangeKey() {
    #expect(XArguments.headersMatch == "x-match")
  }

  @Test("JMS queue argument keys")
  func jmsQueueKeys() {
    #expect(XArguments.selectorFields == "x-selector-fields")
    #expect(XArguments.selectorFieldMaxBytes == "x-selector-field-max-bytes")
    #expect(XArguments.jmsSelector == "x-jms-selector")
  }

  @Test("consumer disconnected timeout key")
  func consumerDisconnectedTimeoutKey() {
    #expect(XArguments.consumerDisconnectedTimeout == "x-consumer-disconnected-timeout")
  }

  @Test("all XArguments keys start with x-")
  func allKeysStartWithXDash() {
    for key in allXArgumentKeys {
      #expect(key.hasPrefix("x-"), "Expected \(key) to start with x-")
    }
  }

  @Test("no duplicate keys among all XArguments")
  func noDuplicateKeys() {
    let unique = Set(allXArgumentKeys)
    #expect(unique.count == allXArgumentKeys.count, "Found duplicate XArguments keys")
  }

  @Test("delayed queue arguments are usable as Table keys")
  func delayedKeysUsableAsTableKeys() {
    let table: Table = [
      XArguments.delayedRetryType: DelayedRetryType.failed.asFieldValue,
      XArguments.delayedRetryMin: .int64(1_000),
      XArguments.delayedRetryMax: .int64(60_000),
    ]
    #expect(table[XArguments.delayedRetryType] == .string("failed"))
    #expect(table[XArguments.delayedRetryMin] == .int64(1_000))
    #expect(table[XArguments.delayedRetryMax] == .int64(60_000))
  }

  @Test("JMS queue arguments are usable as Table keys")
  func jmsQueueKeysUsableAsTableKeys() {
    let table: Table = [
      XArguments.selectorFields: .array([.string("priority"), .string("region")]),
      XArguments.selectorFieldMaxBytes: .int64(512),
    ]
    #expect(table[XArguments.selectorFields] == .array([.string("priority"), .string("region")]))
    #expect(table[XArguments.selectorFieldMaxBytes] == .int64(512))
  }

  @Test("JMS selector consumer argument is usable as Table key")
  func jmsSelectorAsTableKey() {
    let table: Table = [
      XArguments.jmsSelector: .string("priority > 5 AND region = 'EU'")
    ]
    #expect(table[XArguments.jmsSelector]?.stringValue == "priority > 5 AND region = 'EU'")
  }

  @Test("consumer disconnected timeout is usable as Table key")
  func consumerDisconnectedTimeoutAsTableKey() {
    let table: Table = [
      XArguments.consumerDisconnectedTimeout: .int64(30_000)
    ]
    #expect(table[XArguments.consumerDisconnectedTimeout] == .int64(30_000))
  }
}

// MARK: - DelayedRetryType

@Suite("DelayedRetryType Tests")
struct DelayedRetryTypeTests {
  @Test("rawValues match broker-expected strings")
  func rawValues() {
    #expect(DelayedRetryType.all.rawValue == "all")
    #expect(DelayedRetryType.failed.rawValue == "failed")
    #expect(DelayedRetryType.returned.rawValue == "returned")
  }

  @Test("asFieldValue wraps rawValue in FieldValue.string")
  func asFieldValueWrapsRawValue() {
    for c in DelayedRetryType.allCases {
      #expect(c.asFieldValue == .string(c.rawValue))
    }
  }

  @Test(
    "round-trips through RawRepresentable",
    arguments: ["all", "failed", "returned"]
  )
  func roundTrip(raw: String) {
    let value = DelayedRetryType(rawValue: raw)
    #expect(value != nil)
    #expect(value?.rawValue == raw)
  }

  @Test(
    "rejects unknown values",
    arguments: ["", "exponential", "linear", "ALL", "Failed"]
  )
  func rejectsUnknown(raw: String) {
    #expect(DelayedRetryType(rawValue: raw) == nil)
  }

  @Test("all cases produce unique rawValues")
  func uniqueRawValues() {
    let rawValues = Set(DelayedRetryType.allCases.map(\.rawValue))
    #expect(rawValues.count == DelayedRetryType.allCases.count)
  }
}

// MARK: - OverflowBehavior

@Suite("OverflowBehavior Tests")
struct OverflowBehaviorTests {
  @Test("rawValues match broker-expected strings")
  func rawValues() {
    #expect(OverflowBehavior.dropHead.rawValue == "drop-head")
    #expect(OverflowBehavior.rejectPublish.rawValue == "reject-publish")
    #expect(OverflowBehavior.rejectPublishDLX.rawValue == "reject-publish-dlx")
  }

  @Test("asFieldValue wraps rawValue in FieldValue.string")
  func asFieldValueWrapsRawValue() {
    for c in OverflowBehavior.allCases {
      #expect(c.asFieldValue == .string(c.rawValue))
    }
  }

  @Test(
    "round-trips through RawRepresentable",
    arguments: ["drop-head", "reject-publish", "reject-publish-dlx"]
  )
  func roundTrip(raw: String) {
    let value = OverflowBehavior(rawValue: raw)
    #expect(value != nil)
    #expect(value?.rawValue == raw)
  }

  @Test(
    "rejects unknown values",
    arguments: ["", "dropHead", "reject", "DROP-HEAD"]
  )
  func rejectsUnknown(raw: String) {
    #expect(OverflowBehavior(rawValue: raw) == nil)
  }

  @Test("all cases produce unique rawValues")
  func uniqueRawValues() {
    let rawValues = Set(OverflowBehavior.allCases.map(\.rawValue))
    #expect(rawValues.count == OverflowBehavior.allCases.count)
  }
}

// MARK: - QueueLeaderLocator

@Suite("QueueLeaderLocator Tests")
struct QueueLeaderLocatorTests {
  @Test("rawValues match broker-expected strings")
  func rawValues() {
    #expect(QueueLeaderLocator.clientLocal.rawValue == "client-local")
    #expect(QueueLeaderLocator.balanced.rawValue == "balanced")
  }

  @Test("asFieldValue wraps rawValue in FieldValue.string")
  func asFieldValueWrapsRawValue() {
    for c in QueueLeaderLocator.allCases {
      #expect(c.asFieldValue == .string(c.rawValue))
    }
  }

  @Test(
    "round-trips through RawRepresentable",
    arguments: ["client-local", "balanced"]
  )
  func roundTrip(raw: String) {
    let value = QueueLeaderLocator(rawValue: raw)
    #expect(value != nil)
    #expect(value?.rawValue == raw)
  }

  @Test(
    "rejects unknown values",
    arguments: ["", "clientLocal", "random", "CLIENT-LOCAL"]
  )
  func rejectsUnknown(raw: String) {
    #expect(QueueLeaderLocator(rawValue: raw) == nil)
  }

  @Test("all cases produce unique rawValues")
  func uniqueRawValues() {
    let rawValues = Set(QueueLeaderLocator.allCases.map(\.rawValue))
    #expect(rawValues.count == QueueLeaderLocator.allCases.count)
  }
}

// MARK: - DeadLetterStrategy

@Suite("DeadLetterStrategy Tests")
struct DeadLetterStrategyTests {
  @Test("rawValues match broker-expected strings")
  func rawValues() {
    #expect(DeadLetterStrategy.atMostOnce.rawValue == "at-most-once")
    #expect(DeadLetterStrategy.atLeastOnce.rawValue == "at-least-once")
  }

  @Test("asFieldValue wraps rawValue in FieldValue.string")
  func asFieldValueWrapsRawValue() {
    for c in DeadLetterStrategy.allCases {
      #expect(c.asFieldValue == .string(c.rawValue))
    }
  }

  @Test(
    "round-trips through RawRepresentable",
    arguments: ["at-most-once", "at-least-once"]
  )
  func roundTrip(raw: String) {
    let value = DeadLetterStrategy(rawValue: raw)
    #expect(value != nil)
    #expect(value?.rawValue == raw)
  }

  @Test(
    "rejects unknown values",
    arguments: ["", "atMostOnce", "exactly-once", "AT-MOST-ONCE"]
  )
  func rejectsUnknown(raw: String) {
    #expect(DeadLetterStrategy(rawValue: raw) == nil)
  }

  @Test("all cases produce unique rawValues")
  func uniqueRawValues() {
    let rawValues = Set(DeadLetterStrategy.allCases.map(\.rawValue))
    #expect(rawValues.count == DeadLetterStrategy.allCases.count)
  }
}

// MARK: - HeadersMatch

@Suite("HeadersMatch Tests")
struct HeadersMatchTests {
  @Test("rawValues match broker-expected strings")
  func rawValues() {
    #expect(HeadersMatch.all.rawValue == "all")
    #expect(HeadersMatch.any.rawValue == "any")
    #expect(HeadersMatch.allWithX.rawValue == "all-with-x")
    #expect(HeadersMatch.anyWithX.rawValue == "any-with-x")
  }

  @Test("asFieldValue wraps rawValue in FieldValue.string")
  func asFieldValueWrapsRawValue() {
    for c in HeadersMatch.allCases {
      #expect(c.asFieldValue == .string(c.rawValue))
    }
  }

  @Test(
    "round-trips through RawRepresentable",
    arguments: ["all", "any", "all-with-x", "any-with-x"]
  )
  func roundTrip(raw: String) {
    let value = HeadersMatch(rawValue: raw)
    #expect(value != nil)
    #expect(value?.rawValue == raw)
  }

  @Test(
    "rejects unknown values",
    arguments: ["", "ALL", "Any", "all_with_x"]
  )
  func rejectsUnknown(raw: String) {
    #expect(HeadersMatch(rawValue: raw) == nil)
  }

  @Test("all cases produce unique rawValues")
  func uniqueRawValues() {
    let rawValues = Set(HeadersMatch.allCases.map(\.rawValue))
    #expect(rawValues.count == HeadersMatch.allCases.count)
  }

  @Test("headers exchange binding table with match mode and headers")
  func headersBindingTable() {
    let table: Table = [
      XArguments.headersMatch: HeadersMatch.all.asFieldValue,
      "priority": .string("high"),
      "region": .string("EU"),
    ]
    #expect(table[XArguments.headersMatch] == .string("all"))
    #expect(table["priority"] == .string("high"))
    #expect(table["region"] == .string("EU"))
  }
}
