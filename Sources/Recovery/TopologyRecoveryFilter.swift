// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

/// Filters that control which entities are recovered during topology recovery.
/// Return `true` to recover the entity, `false` to skip it.
public struct TopologyRecoveryFilter: Sendable {
  public var exchangeFilter: (@Sendable (RecordedExchange) -> Bool)?
  public var queueFilter: (@Sendable (RecordedQueue) -> Bool)?
  public var queueBindingFilter: (@Sendable (RecordedQueueBinding) -> Bool)?
  public var exchangeBindingFilter: (@Sendable (RecordedExchangeBinding) -> Bool)?
  public var consumerFilter: (@Sendable (RecordedConsumer) -> Bool)?

  public init(
    exchangeFilter: (@Sendable (RecordedExchange) -> Bool)? = nil,
    queueFilter: (@Sendable (RecordedQueue) -> Bool)? = nil,
    queueBindingFilter: (@Sendable (RecordedQueueBinding) -> Bool)? = nil,
    exchangeBindingFilter: (@Sendable (RecordedExchangeBinding) -> Bool)? = nil,
    consumerFilter: (@Sendable (RecordedConsumer) -> Bool)? = nil
  ) {
    self.exchangeFilter = exchangeFilter
    self.queueFilter = queueFilter
    self.queueBindingFilter = queueBindingFilter
    self.exchangeBindingFilter = exchangeBindingFilter
    self.consumerFilter = consumerFilter
  }
}
