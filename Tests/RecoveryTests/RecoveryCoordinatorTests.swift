// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing
import Foundation
@testable import Recovery
@testable import Transport

// Thread-safe container for test state
private actor TestState<T: Sendable> {
    var value: T

    init(_ initial: T) {
        self.value = initial
    }

    func set(_ newValue: T) {
        value = newValue
    }

    func get() -> T {
        value
    }
}

@Suite("Recovery Coordinator Tests")
struct RecoveryCoordinatorTests {

    @Test("Default configuration has automatic recovery enabled")
    func defaultConfiguration() {
        let config = RecoveryConfiguration.default
        #expect(config.automaticRecovery == true)
        #expect(config.networkRecoveryInterval == 5.0)
        #expect(config.maxRecoveryAttempts == nil)
        #expect(config.backoffMultiplier == 2.0)
        #expect(config.maxRecoveryInterval == 60.0)
    }

    @Test("No recovery configuration disables automatic recovery")
    func noRecoveryConfiguration() {
        let config = RecoveryConfiguration.noRecovery
        #expect(config.automaticRecovery == false)
    }

    @Test("Recovery coordinator initial state is idle")
    func initialStateIsIdle() async {
        let registry = TopologyRegistry()
        let coordinator = RecoveryCoordinator(topology: registry)

        let state = await coordinator.currentState
        if case .idle = state {
            // Pass
        } else {
            Issue.record("Expected idle state, got \(state)")
        }
    }

    @Test("Recovery does not start when automatic recovery is disabled")
    func noRecoveryWhenDisabled() async throws {
        let registry = TopologyRegistry()
        let config = RecoveryConfiguration.noRecovery
        let coordinator = RecoveryCoordinator(configuration: config, topology: registry)

        let reconnectCalled = TestState(false)
        await coordinator.beginRecovery(
            reconnect: { await reconnectCalled.set(true) },
            redeclare: { _ in }
        )

        // Give it a moment
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await reconnectCalled.get() == false)
    }

    @Test("Cancel recovery stops the process")
    func cancelRecovery() async throws {
        let registry = TopologyRegistry()
        let config = RecoveryConfiguration(
            automaticRecovery: true,
            networkRecoveryInterval: 10.0  // Long interval so we can cancel
        )
        let coordinator = RecoveryCoordinator(configuration: config, topology: registry)

        await coordinator.beginRecovery(
            reconnect: { throw ConnectionError.notConnected },
            redeclare: { _ in }
        )

        // Cancel immediately
        await coordinator.cancelRecovery()

        let state = await coordinator.currentState
        if case .idle = state {
            // Pass
        } else {
            Issue.record("Expected idle state after cancel, got \(state)")
        }
    }

    @Test("Reset returns coordinator to idle state")
    func resetReturnsToIdle() async {
        let registry = TopologyRegistry()
        let coordinator = RecoveryCoordinator(topology: registry)

        await coordinator.reset()

        let state = await coordinator.currentState
        if case .idle = state {
            // Pass
        } else {
            Issue.record("Expected idle state after reset, got \(state)")
        }
    }

    @Test("Recovery callbacks are called on recovery will begin")
    func callbackOnRecoveryWillBegin() async throws {
        let registry = TopologyRegistry()
        let config = RecoveryConfiguration(
            automaticRecovery: true,
            networkRecoveryInterval: 0.01,  // Very short interval
            maxRecoveryAttempts: 1
        )

        let attemptNumber = TestState<Int?>(nil)
        let callbacks = RecoveryCallbacks(
            onRecoveryWillBegin: { attempt in
                await attemptNumber.set(attempt)
            }
        )
        let coordinator = RecoveryCoordinator(
            configuration: config,
            topology: registry,
            callbacks: callbacks
        )

        await coordinator.beginRecovery(
            reconnect: { },  // Succeed immediately
            redeclare: { _ in }
        )

        // Wait for recovery to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await attemptNumber.get() == 1)
    }

    @Test("Recovery callbacks are called on successful recovery")
    func callbackOnRecoveryComplete() async throws {
        let registry = TopologyRegistry()
        let config = RecoveryConfiguration(
            automaticRecovery: true,
            networkRecoveryInterval: 0.01
        )

        let didComplete = TestState(false)
        let callbacks = RecoveryCallbacks(
            onRecoveryDidComplete: {
                await didComplete.set(true)
            }
        )
        let coordinator = RecoveryCoordinator(
            configuration: config,
            topology: registry,
            callbacks: callbacks
        )

        await coordinator.beginRecovery(
            reconnect: { },
            redeclare: { _ in }
        )

        // Wait for recovery to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await didComplete.get() == true)

        let state = await coordinator.currentState
        if case .recovered = state {
            // Pass
        } else {
            Issue.record("Expected recovered state, got \(state)")
        }
    }

    @Test("Recovery fails after max attempts exceeded")
    func failsAfterMaxAttempts() async throws {
        let registry = TopologyRegistry()
        let config = RecoveryConfiguration(
            automaticRecovery: true,
            networkRecoveryInterval: 0.01,
            maxRecoveryAttempts: 2
        )

        let failedError = TestState<(any Error)?>(nil)
        let callbacks = RecoveryCallbacks(
            onRecoveryDidFail: { error in
                await failedError.set(error)
            }
        )
        let coordinator = RecoveryCoordinator(
            configuration: config,
            topology: registry,
            callbacks: callbacks
        )

        await coordinator.beginRecovery(
            reconnect: { throw ConnectionError.notConnected },
            redeclare: { _ in }
        )

        // Wait for recovery attempts to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await failedError.get() != nil)

        let state = await coordinator.currentState
        if case .failed = state {
            // Pass
        } else {
            Issue.record("Expected failed state, got \(state)")
        }
    }

    @Test("Topology recovery callbacks are called")
    func topologyRecoveryCallbacks() async throws {
        let registry = TopologyRegistry()
        let config = RecoveryConfiguration(
            automaticRecovery: true,
            networkRecoveryInterval: 0.01
        )

        let topologyBegan = TestState(false)
        let topologyComplete = TestState(false)
        let callbacks = RecoveryCallbacks(
            onTopologyRecoveryDidBegin: {
                await topologyBegan.set(true)
            },
            onTopologyRecoveryDidComplete: {
                await topologyComplete.set(true)
            }
        )
        let coordinator = RecoveryCoordinator(
            configuration: config,
            topology: registry,
            callbacks: callbacks
        )

        await coordinator.beginRecovery(
            reconnect: { },
            redeclare: { _ in }
        )

        // Wait for recovery
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await topologyBegan.get() == true)
        #expect(await topologyComplete.get() == true)
    }
}
