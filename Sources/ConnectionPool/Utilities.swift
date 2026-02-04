// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin
//
// Portions derived from PostgresNIO (MIT License)
// Copyright (c) 2017-2024 Vapor

import Foundation

// MARK: - TinyFastSequence

/// A sequence optimized for 0-2 elements, avoiding heap allocation for small sizes.
struct TinyFastSequence<Element: Sendable>: Sequence, Sendable {
    private enum Storage: Sendable {
        case none
        case one(Element)
        case two(Element, Element)
        case array([Element])
    }

    private var storage: Storage

    init() {
        self.storage = .none
    }

    init(_ element: Element) {
        self.storage = .one(element)
    }

    init<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        let arr = Array(elements)
        switch arr.count {
        case 0: self.storage = .none
        case 1: self.storage = .one(arr[0])
        case 2: self.storage = .two(arr[0], arr[1])
        default: self.storage = .array(arr)
        }
    }

    init(_ elements: [Element]) {
        switch elements.count {
        case 0: self.storage = .none
        case 1: self.storage = .one(elements[0])
        case 2: self.storage = .two(elements[0], elements[1])
        default: self.storage = .array(elements)
        }
    }

    var isEmpty: Bool {
        if case .none = storage { return true }
        return false
    }

    var count: Int {
        switch storage {
        case .none: return 0
        case .one: return 1
        case .two: return 2
        case .array(let arr): return arr.count
        }
    }

    mutating func append(_ element: Element) {
        switch storage {
        case .none:
            storage = .one(element)
        case .one(let first):
            storage = .two(first, element)
        case .two(let first, let second):
            storage = .array([first, second, element])
        case .array(var arr):
            arr.append(element)
            storage = .array(arr)
        }
    }

    func makeIterator() -> AnyIterator<Element> {
        var index = 0
        let elements: [Element]
        switch storage {
        case .none: elements = []
        case .one(let e): elements = [e]
        case .two(let e1, let e2): elements = [e1, e2]
        case .array(let arr): elements = arr
        }
        return AnyIterator {
            guard index < elements.count else { return nil }
            defer { index += 1 }
            return elements[index]
        }
    }
}

// MARK: - Max2Sequence

/// A sequence that holds at most 2 elements.
struct Max2Sequence<Element: Sendable>: Sequence, Sendable {
    private enum Storage: Sendable {
        case none
        case one(Element)
        case two(Element, Element)
    }

    private var storage: Storage

    init() {
        self.storage = .none
    }

    init(_ element: Element) {
        self.storage = .one(element)
    }

    init(_ first: Element, _ second: Element) {
        self.storage = .two(first, second)
    }

    var isEmpty: Bool {
        if case .none = storage { return true }
        return false
    }

    mutating func append(_ element: Element) {
        switch storage {
        case .none:
            storage = .one(element)
        case .one(let first):
            storage = .two(first, element)
        case .two:
            fatalError("Max2Sequence cannot hold more than 2 elements")
        }
    }

    func makeIterator() -> AnyIterator<Element> {
        var index = 0
        let elements: [Element]
        switch storage {
        case .none: elements = []
        case .one(let e): elements = [e]
        case .two(let e1, let e2): elements = [e1, e2]
        }
        return AnyIterator {
            guard index < elements.count else { return nil }
            defer { index += 1 }
            return elements[index]
        }
    }
}

// MARK: - LockedValueBox

/// A thread-safe container for mutable state.
final class LockedValueBox<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLockedValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
