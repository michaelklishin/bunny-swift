// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin
//
// Portions derived from PostgresNIO (MIT License)
// Copyright (c) 2017-2024 Vapor

import Atomics

public protocol ConnectionIDGeneratorProtocol: Sendable {
    associatedtype ID: Hashable & Sendable
    func next() -> ID
}

public struct ConnectionIDGenerator: ConnectionIDGeneratorProtocol, Sendable {
    private let counter: ManagedAtomic<Int>

    public init() {
        self.counter = ManagedAtomic(0)
    }

    public func next() -> Int {
        counter.loadThenWrappingIncrement(ordering: .relaxed)
    }
}
