// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Shared test utilities used across integration test files.

import Foundation

// MARK: - Thread-Safe Atomic

/// Minimal lock-based atomic for test synchronization.
final class ManagedAtomic<Value: Sendable>: @unchecked Sendable {
  private var _value: Value
  private let lock = NSLock()

  init(_ value: Value) {
    self._value = value
  }

  func load() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }

  func store(_ value: Value) {
    lock.lock()
    defer { lock.unlock() }
    _value = value
  }
}

// MARK: - Async Collection Helpers

extension Array where Element: Sendable {
  /// Map over an array with an async transform, preserving order.
  func asyncMap<T: Sendable>(_ transform: (Element) async -> T) async -> [T] {
    var result: [T] = []
    result.reserveCapacity(count)
    for element in self {
      result.append(await transform(element))
    }
    return result
  }
}
