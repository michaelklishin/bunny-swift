// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing

@testable import Transport

// MARK: - negotiatedMaxValue Tests

@Suite("Connection Parameter Negotiation Tests")
struct NegotiatedMaxValueTests {

  // MARK: - Heartbeat (UInt16)

  @Test("Heartbeat: both zero yields zero")
  func heartbeatBothZero() {
    #expect(negotiatedMaxValue(UInt16(0), UInt16(0)) == 0)
  }

  @Test("Heartbeat: server zero uses client value")
  func heartbeatServerZero() {
    #expect(negotiatedMaxValue(UInt16(60), UInt16(0)) == 60)
    #expect(negotiatedMaxValue(UInt16(1), UInt16(0)) == 1)
    #expect(negotiatedMaxValue(UInt16.max, UInt16(0)) == UInt16.max)
  }

  @Test("Heartbeat: client zero uses server value")
  func heartbeatClientZero() {
    #expect(negotiatedMaxValue(UInt16(0), UInt16(60)) == 60)
    #expect(negotiatedMaxValue(UInt16(0), UInt16(1)) == 1)
    #expect(negotiatedMaxValue(UInt16(0), UInt16.max) == UInt16.max)
  }

  @Test("Heartbeat: both non-zero uses smaller value")
  func heartbeatBothNonZero() {
    #expect(negotiatedMaxValue(UInt16(60), UInt16(30)) == 30)
    #expect(negotiatedMaxValue(UInt16(30), UInt16(60)) == 30)
    #expect(negotiatedMaxValue(UInt16(10), UInt16(10)) == 10)
  }

  // MARK: - frame_max (UInt32)

  @Test("Frame max: server zero uses client value")
  func frameMaxServerZero() {
    #expect(negotiatedMaxValue(UInt32(131_072), UInt32(0)) == 131_072)
  }

  @Test("Frame max: client zero uses server value")
  func frameMaxClientZero() {
    #expect(negotiatedMaxValue(UInt32(0), UInt32(131_072)) == 131_072)
  }

  @Test("Frame max: both non-zero uses smaller value")
  func frameMaxBothNonZero() {
    #expect(negotiatedMaxValue(UInt32(131_072), UInt32(65_536)) == 65_536)
    #expect(negotiatedMaxValue(UInt32(65_536), UInt32(131_072)) == 65_536)
  }

  @Test("Frame max: both zero yields zero")
  func frameMaxBothZero() {
    #expect(negotiatedMaxValue(UInt32(0), UInt32(0)) == 0)
  }

  // MARK: - channel_max (UInt16)

  @Test("Channel max: server zero uses client value")
  func channelMaxServerZero() {
    #expect(negotiatedMaxValue(UInt16(2047), UInt16(0)) == 2047)
  }

  @Test("Channel max: client zero uses server value")
  func channelMaxClientZero() {
    #expect(negotiatedMaxValue(UInt16(0), UInt16(2047)) == 2047)
  }

  @Test("Channel max: both non-zero uses smaller value")
  func channelMaxBothNonZero() {
    #expect(negotiatedMaxValue(UInt16(2047), UInt16(100)) == 100)
    #expect(negotiatedMaxValue(UInt16(100), UInt16(2047)) == 100)
  }

  // MARK: - Property-Based Tests

  @Test("Negotiation is symmetric", arguments: negotiationPairs())
  func symmetric(pair: NegotiationPair) {
    #expect(
      negotiatedMaxValue(pair.client, pair.server)
        == negotiatedMaxValue(pair.server, pair.client)
    )
  }

  @Test("Result is zero only when both inputs are zero", arguments: negotiationPairs())
  func resultZeroOnlyWhenBothZero(pair: NegotiationPair) {
    let result = negotiatedMaxValue(pair.client, pair.server)
    if pair.client > 0 || pair.server > 0 {
      #expect(result > 0, "Expected nonzero when at least one input is nonzero")
    }
  }

  @Test("Result never exceeds either input", arguments: negotiationPairs())
  func resultNeverExceedsEither(pair: NegotiationPair) {
    let result = negotiatedMaxValue(pair.client, pair.server)
    #expect(result <= max(pair.client, pair.server))
  }

  @Test(
    "One zero yields the non-zero value",
    arguments: nonZeroValues()
  )
  func oneZeroYieldsNonZero(value: UInt16) {
    #expect(negotiatedMaxValue(UInt16(0), value) == value)
    #expect(negotiatedMaxValue(value, UInt16(0)) == value)
  }

  @Test(
    "Both non-zero yields the minimum",
    arguments: nonZeroValuePairs()
  )
  func bothNonZeroYieldsMin(pair: NegotiationPair) {
    let result = negotiatedMaxValue(pair.client, pair.server)
    #expect(result == min(pair.client, pair.server))
  }
}

// MARK: - Test Data

struct NegotiationPair: Sendable, CustomTestStringConvertible {
  let client: UInt16
  let server: UInt16

  var testDescription: String { "client=\(client), server=\(server)" }
}

/// A broad set of pairs covering edge cases and pseudo-random values.
private func negotiationPairs() -> [NegotiationPair] {
  var pairs: [NegotiationPair] = [
    // Edge cases
    NegotiationPair(client: 0, server: 0),
    NegotiationPair(client: 0, server: 1),
    NegotiationPair(client: 1, server: 0),
    NegotiationPair(client: 0, server: UInt16.max),
    NegotiationPair(client: UInt16.max, server: 0),
    NegotiationPair(client: 1, server: 1),
    NegotiationPair(client: UInt16.max, server: UInt16.max),
    NegotiationPair(client: 1, server: UInt16.max),
    NegotiationPair(client: UInt16.max, server: 1),
    // Typical heartbeat values
    NegotiationPair(client: 60, server: 60),
    NegotiationPair(client: 60, server: 0),
    NegotiationPair(client: 0, server: 60),
    NegotiationPair(client: 30, server: 60),
    NegotiationPair(client: 60, server: 30),
    NegotiationPair(client: 10, server: 20),
    NegotiationPair(client: 600, server: 60),
    // Typical channel_max values
    NegotiationPair(client: 2047, server: 0),
    NegotiationPair(client: 0, server: 2047),
    NegotiationPair(client: 2047, server: 100),
  ]
  // Deterministic pseudo-random spread
  var rng: UInt64 = 0xDEAD_BEEF
  for _ in 0..<50 {
    rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let client = UInt16(truncatingIfNeeded: rng >> 48)
    rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let server = UInt16(truncatingIfNeeded: rng >> 48)
    pairs.append(NegotiationPair(client: client, server: server))
  }
  return pairs
}

/// Non-zero values for one-zero tests.
private func nonZeroValues() -> [UInt16] {
  [1, 2, 10, 30, 60, 120, 600, 1000, 2047, UInt16.max / 2, UInt16.max]
}

/// Pairs where both values are non-zero.
private func nonZeroValuePairs() -> [NegotiationPair] {
  var pairs: [NegotiationPair] = []
  let values: [UInt16] = [1, 2, 10, 30, 60, 120, 600, 2047, UInt16.max]
  for a in values {
    for b in values {
      pairs.append(NegotiationPair(client: a, server: b))
    }
  }
  return pairs
}

// MARK: - HeartbeatHandler Tests

@Suite("HeartbeatHandler Tests")
struct HeartbeatHandlerTests {

  @Test("Handler interval is half the negotiated heartbeat")
  func intervalIsHalf() {
    let handler = HeartbeatHandler(interval: 60) {}
    #expect(handler.checkInterval == .seconds(30))
  }

  @Test("Handler interval minimum is 1 second")
  func intervalMinimumIsOneSecond() {
    let handler = HeartbeatHandler(interval: 1) {}
    #expect(handler.checkInterval == .seconds(1))
  }

  @Test("Handler interval for heartbeat of 2 is 1 second")
  func intervalForTwo() {
    let handler = HeartbeatHandler(interval: 2) {}
    #expect(handler.checkInterval == .seconds(1))
  }

  @Test("Handler interval for heartbeat of 3 is 1 second")
  func intervalForThree() {
    // 3 / 2 = 1 (integer division)
    let handler = HeartbeatHandler(interval: 3) {}
    #expect(handler.checkInterval == .seconds(1))
  }

  @Test("Handler interval for large heartbeat")
  func intervalForLarge() {
    let handler = HeartbeatHandler(interval: 600) {}
    #expect(handler.checkInterval == .seconds(300))
  }
}
