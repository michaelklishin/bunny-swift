// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin
//
// Portions derived from PostgresNIO (MIT License)
// Copyright (c) 2017-2024 Vapor

public struct ConnectionPoolError: Error, Hashable, Sendable {
    private enum Base: Hashable, Sendable {
        case requestCancelled
        case poolShutdown
        case circuitBreakerTripped
    }

    private let base: Base

    private init(_ base: Base) {
        self.base = base
    }

    public static let requestCancelled = ConnectionPoolError(.requestCancelled)
    public static let poolShutdown = ConnectionPoolError(.poolShutdown)
    public static let circuitBreakerTripped = ConnectionPoolError(.circuitBreakerTripped)
}
