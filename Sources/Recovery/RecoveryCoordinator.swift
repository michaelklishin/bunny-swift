// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import AMQPProtocol
import Transport

// MARK: - Recovery Configuration

/// Configuration for automatic connection recovery
public struct RecoveryConfiguration: Sendable {
    /// Whether automatic recovery is enabled
    public var automaticRecovery: Bool

    /// Initial delay before first recovery attempt (in seconds)
    public var networkRecoveryInterval: TimeInterval

    /// Maximum number of recovery attempts (nil for unlimited)
    public var maxRecoveryAttempts: Int?

    /// Multiplier for exponential backoff
    public var backoffMultiplier: Double

    /// Maximum delay between recovery attempts (in seconds)
    public var maxRecoveryInterval: TimeInterval

    public init(
        automaticRecovery: Bool = true,
        networkRecoveryInterval: TimeInterval = 5.0,
        maxRecoveryAttempts: Int? = nil,
        backoffMultiplier: Double = 2.0,
        maxRecoveryInterval: TimeInterval = 60.0
    ) {
        self.automaticRecovery = automaticRecovery
        self.networkRecoveryInterval = networkRecoveryInterval
        self.maxRecoveryAttempts = maxRecoveryAttempts
        self.backoffMultiplier = backoffMultiplier
        self.maxRecoveryInterval = maxRecoveryInterval
    }

    /// Default configuration with automatic recovery enabled
    public static let `default` = RecoveryConfiguration()

    /// Configuration with automatic recovery disabled
    public static let noRecovery = RecoveryConfiguration(automaticRecovery: false)
}

// MARK: - Recovery State

/// Current state of the recovery process
public enum RecoveryState: Sendable {
    case idle
    case recovering(attempt: Int)
    case recovered
    case failed(Error)
}

// MARK: - Recovery Callbacks

/// Callbacks for receiving recovery events
public struct RecoveryCallbacks: Sendable {
    public var onRecoveryWillBegin: (@Sendable (Int) async -> Void)?
    public var onRecoveryDidComplete: (@Sendable () async -> Void)?
    public var onRecoveryDidFail: (@Sendable (Error) async -> Void)?
    public var onTopologyRecoveryDidBegin: (@Sendable () async -> Void)?
    public var onTopologyRecoveryDidComplete: (@Sendable () async -> Void)?

    public init(
        onRecoveryWillBegin: (@Sendable (Int) async -> Void)? = nil,
        onRecoveryDidComplete: (@Sendable () async -> Void)? = nil,
        onRecoveryDidFail: (@Sendable (Error) async -> Void)? = nil,
        onTopologyRecoveryDidBegin: (@Sendable () async -> Void)? = nil,
        onTopologyRecoveryDidComplete: (@Sendable () async -> Void)? = nil
    ) {
        self.onRecoveryWillBegin = onRecoveryWillBegin
        self.onRecoveryDidComplete = onRecoveryDidComplete
        self.onRecoveryDidFail = onRecoveryDidFail
        self.onTopologyRecoveryDidBegin = onTopologyRecoveryDidBegin
        self.onTopologyRecoveryDidComplete = onTopologyRecoveryDidComplete
    }
}

// MARK: - RecoveryCoordinator

/// Coordinates automatic connection recovery
public actor RecoveryCoordinator {
    private let configuration: RecoveryConfiguration
    private let topology: TopologyRegistry
    private let callbacks: RecoveryCallbacks
    private var state: RecoveryState = .idle
    private var recoveryTask: Task<Void, Never>?

    public init(
        configuration: RecoveryConfiguration = .default,
        topology: TopologyRegistry,
        callbacks: RecoveryCallbacks = RecoveryCallbacks()
    ) {
        self.configuration = configuration
        self.topology = topology
        self.callbacks = callbacks
    }

    /// Current recovery state
    public var currentState: RecoveryState {
        state
    }

    /// Begin recovery process
    public func beginRecovery(
        reconnect: @escaping () async throws -> Void,
        redeclare: @escaping (TopologyRegistry) async throws -> Void
    ) async {
        guard configuration.automaticRecovery else { return }
        guard case .idle = state else { return }

        state = .recovering(attempt: 1)

        recoveryTask = Task {
            var attempt = 1
            var currentInterval = configuration.networkRecoveryInterval

            while !Task.isCancelled {
                if let maxAttempts = configuration.maxRecoveryAttempts, attempt > maxAttempts {
                    let error = ConnectionError.protocolError("Max recovery attempts exceeded")
                    state = .failed(error)
                    await callbacks.onRecoveryDidFail?(error)
                    return
                }

                await callbacks.onRecoveryWillBegin?(attempt)
                state = .recovering(attempt: attempt)

                do {
                    try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
                } catch {
                    return
                }

                do {
                    try await reconnect()

                    await callbacks.onTopologyRecoveryDidBegin?()
                    try await redeclare(topology)
                    await callbacks.onTopologyRecoveryDidComplete?()

                    state = .recovered
                    await callbacks.onRecoveryDidComplete?()
                    return

                } catch {
                    attempt += 1
                    currentInterval = min(
                        currentInterval * configuration.backoffMultiplier,
                        configuration.maxRecoveryInterval
                    )
                }
            }
        }
    }

    /// Cancel ongoing recovery
    public func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        state = .idle
    }

    /// Reset coordinator state
    public func reset() {
        cancelRecovery()
        state = .idle
    }
}

// Note: Topology redeclaration is handled by Connection during recovery.
// The TopologyRegistry provides the recorded entities, and the Connection
// uses Channel methods to redeclare them in the correct order:
// 1. Exchanges (for E2E bindings)
// 2. Queues (updating server-named queue names)
// 3. Queue bindings
// 4. Exchange bindings
// 5. Consumers
