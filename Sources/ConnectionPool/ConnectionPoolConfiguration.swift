// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin
//
// Portions derived from PostgresNIO (MIT License)
// Copyright (c) 2017-2024 Vapor

public struct ConnectionPoolConfiguration: Sendable {
    public var minimumConnectionCount: Int
    public var maximumConnectionSoftLimit: Int
    public var maximumConnectionHardLimit: Int
    public var idleTimeout: Duration
    public var keepAliveFrequency: Duration?
    public var circuitBreakerTripAfter: Duration

    public init(
        minimumConnectionCount: Int = 0,
        maximumConnectionSoftLimit: Int = 4,
        maximumConnectionHardLimit: Int = 4,
        idleTimeout: Duration = .seconds(60),
        keepAliveFrequency: Duration? = nil,
        circuitBreakerTripAfter: Duration = .seconds(15)
    ) {
        self.minimumConnectionCount = minimumConnectionCount
        self.maximumConnectionSoftLimit = maximumConnectionSoftLimit
        self.maximumConnectionHardLimit = maximumConnectionHardLimit
        self.idleTimeout = idleTimeout
        self.keepAliveFrequency = keepAliveFrequency
        self.circuitBreakerTripAfter = circuitBreakerTripAfter
    }

    public static var `default`: Self { .init() }
}
