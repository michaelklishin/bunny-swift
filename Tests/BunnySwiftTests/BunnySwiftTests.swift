// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// BunnySwift Tests

import Testing
@testable import BunnySwift
import AMQPProtocol

@Suite("BunnySwift Tests")
struct BunnySwiftTests {
    @Test("Module imports correctly")
    func moduleImports() {
        // Placeholder for future tests
    }
}

@Suite("QueueType Tests")
struct QueueTypeTests {
    @Test("rawValue returns correct strings")
    func rawValueReturnsCorrectStrings() {
        #expect(QueueType.classic.rawValue == "classic")
        #expect(QueueType.quorum.rawValue == "quorum")
        #expect(QueueType.stream.rawValue == "stream")
        #expect(QueueType.custom("x-my-type").rawValue == "x-my-type")
    }

    @Test("custom type preserves arbitrary values")
    func customTypePreservesArbitraryValues() {
        let custom1 = QueueType.custom("x-priority-queue")
        let custom2 = QueueType.custom("x-delayed-message")

        #expect(custom1.rawValue == "x-priority-queue")
        #expect(custom2.rawValue == "x-delayed-message")
    }

    @Test("asTableValue wraps rawValue in FieldValue.string")
    func asTableValueWrapsRawValue() {
        #expect(QueueType.classic.asTableValue == .string("classic"))
        #expect(QueueType.quorum.asTableValue == .string("quorum"))
        #expect(QueueType.stream.asTableValue == .string("stream"))
        #expect(QueueType.custom("x-test").asTableValue == .string("x-test"))
    }

    @Test("QueueType is Hashable")
    func queueTypeIsHashable() {
        var set = Set<QueueType>()
        set.insert(.classic)
        set.insert(.quorum)
        set.insert(.stream)
        set.insert(.custom("x-test"))

        #expect(set.count == 4)
        #expect(set.contains(.classic))
        #expect(set.contains(.custom("x-test")))
    }

    @Test("QueueType equality")
    func queueTypeEquality() {
        #expect(QueueType.classic == QueueType.classic)
        #expect(QueueType.quorum != QueueType.stream)
        #expect(QueueType.custom("x-a") == QueueType.custom("x-a"))
        #expect(QueueType.custom("x-a") != QueueType.custom("x-b"))
    }

    @Test("custom with same rawValue as built-in is not equal")
    func customNotEqualToBuiltIn() {
        // A custom type with the same string as a built-in should still be distinct
        #expect(QueueType.custom("classic") != QueueType.classic)
        #expect(QueueType.custom("quorum") != QueueType.quorum)
        #expect(QueueType.custom("stream") != QueueType.stream)
    }
}
