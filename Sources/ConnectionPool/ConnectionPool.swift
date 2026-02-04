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

public final class ConnectionPool<
    Connection: PooledConnection,
    ConnectionIDGenerator: ConnectionIDGeneratorProtocol,
    KeepAliveBehavior: ConnectionKeepAliveBehavior,
    ObservabilityDelegate: ConnectionPoolObservabilityDelegate
>: Sendable where
    Connection.ID == ConnectionIDGenerator.ID,
    KeepAliveBehavior.Connection == Connection,
    ObservabilityDelegate.ConnectionID == Connection.ID
{
    public typealias ConnectionFactory = @Sendable (Connection.ID) async throws -> Connection

    // MARK: - Request Type

    struct Request: ConnectionRequestProtocol, Sendable {
        typealias ID = Int

        let id: ID
        let continuation: CheckedContinuation<ConnectionLease<Connection>, any Error>

        func complete(with result: Result<ConnectionLease<Connection>, ConnectionPoolError>) {
            continuation.resume(with: result.mapError { $0 as any Error })
        }
    }

    // MARK: - Timer Cancellation

    struct TimerCancellationToken: Hashable, Sendable {
        let id: Int
    }

    // MARK: - State Machine Alias

    typealias StateMachine = PoolStateMachine<Connection, ConnectionIDGenerator, Request, TimerCancellationToken>

    // MARK: - Pool Actions

    private enum PoolAction: Sendable {
        case runStateMachineActions(StateMachine.Action)
        case shutdown
    }

    // MARK: - Properties

    private let factory: ConnectionFactory
    private let configuration: ConnectionPoolConfiguration
    private let keepAliveBehavior: KeepAliveBehavior
    private let observabilityDelegate: ObservabilityDelegate
    private let idGenerator: ConnectionIDGenerator

    private struct State: Sendable {
        var stateMachine: StateMachine
        var timerContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let stateBox: LockedValueBox<State>
    private let actionStream: AsyncStream<PoolAction>
    private let actionContinuation: AsyncStream<PoolAction>.Continuation
    private let requestIDGenerator = ManagedAtomic<Int>(0)
    private let timerIDGenerator = ManagedAtomic<Int>(0)

    // MARK: - Initialization

    public init(
        configuration: ConnectionPoolConfiguration,
        idGenerator: ConnectionIDGenerator,
        keepAliveBehavior: KeepAliveBehavior,
        observabilityDelegate: ObservabilityDelegate,
        factory: @escaping ConnectionFactory
    ) {
        self.factory = factory
        self.configuration = configuration
        self.keepAliveBehavior = keepAliveBehavior
        self.observabilityDelegate = observabilityDelegate
        self.idGenerator = idGenerator

        let smConfig = StateMachine.Configuration(
            minimumConnectionCount: configuration.minimumConnectionCount,
            maximumConnectionSoftLimit: configuration.maximumConnectionSoftLimit,
            maximumConnectionHardLimit: configuration.maximumConnectionHardLimit,
            keepAliveFrequency: configuration.keepAliveFrequency,
            idleTimeout: configuration.idleTimeout,
            circuitBreakerTripAfter: configuration.circuitBreakerTripAfter
        )

        let stateMachine = StateMachine(configuration: smConfig, idGenerator: idGenerator)
        self.stateBox = LockedValueBox(State(stateMachine: stateMachine))

        (self.actionStream, self.actionContinuation) = AsyncStream.makeStream()
    }

    // MARK: - Public API

    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for await action in actionStream {
                switch action {
                case .runStateMachineActions(let smAction):
                    self.executeAction(smAction, in: &group)
                case .shutdown:
                    group.cancelAll()
                    return
                }
            }
        }
    }

    public func leaseConnection() async throws -> ConnectionLease<Connection> {
        let requestID = requestIDGenerator.loadThenWrappingIncrement(ordering: .relaxed)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = Request(id: requestID, continuation: continuation)
                let action = stateBox.withLockedValue { state in
                    state.stateMachine.leaseConnection(request)
                }
                enqueueAction(action)
            }
        } onCancel: {
            let action = stateBox.withLockedValue { state in
                state.stateMachine.cancelRequest(requestID)
            }
            enqueueAction(action)
        }
    }

    public func withConnection<Result: Sendable>(
        _ closure: (Connection) async throws -> Result
    ) async throws -> Result {
        let lease = try await leaseConnection()
        defer { lease.release() }
        return try await closure(lease.connection)
    }

    public func releaseConnection(_ connection: Connection) {
        let action = stateBox.withLockedValue { state in
            state.stateMachine.releaseConnection(connection)
        }
        enqueueAction(action)
    }

    public func shutdown() {
        let action = stateBox.withLockedValue { state in
            state.stateMachine.triggerShutdown()
        }
        enqueueAction(action)
        actionContinuation.yield(.shutdown)
    }

    // MARK: - Action Execution

    private func enqueueAction(_ action: StateMachine.Action) {
        actionContinuation.yield(.runStateMachineActions(action))
    }

    private func executeAction(_ action: StateMachine.Action, in group: inout TaskGroup<Void>) {
        executeRequestAction(action.request)
        executeConnectionAction(action.connection, in: &group)
    }

    private func executeRequestAction(_ action: StateMachine.RequestAction) {
        switch action {
        case .leaseConnection(let request, let connection):
            let lease = ConnectionLease(connection: connection) { [weak self] conn in
                self?.releaseConnection(conn)
            }
            request.complete(with: .success(lease))
            observabilityDelegate.requestDequeued()

        case .queueRequest:
            observabilityDelegate.requestQueued()

        case .failRequest(let request, let error):
            request.complete(with: .failure(error))
            observabilityDelegate.requestFailed()

        case .failRequests(let requests, let error):
            for request in requests {
                request.complete(with: .failure(error))
                observabilityDelegate.requestFailed()
            }

        case .none:
            break
        }
    }

    private func executeConnectionAction(_ action: StateMachine.ConnectionAction, in group: inout TaskGroup<Void>) {
        switch action {
        case .createConnection(let connectionID):
            group.addTask {
                await self.createConnection(connectionID)
            }

        case .scheduleTimers(let timers):
            for timer in timers {
                scheduleTimer(timer, in: &group)
            }

        case .runKeepAlive(let connection):
            group.addTask {
                await self.runKeepAlive(for: connection)
            }

        case .closeConnection(let connection, let timersToCancel):
            for token in timersToCancel {
                cancelTimer(token)
            }
            connection.close()
            observabilityDelegate.connectionClosed(id: connection.id)

        case .cancelTimers(let tokens):
            cancelTimers(tokens)

        case .shutdown(let context):
            cancelTimers(context.timersToCancel)
            for connection in context.connections {
                connection.close()
                observabilityDelegate.connectionClosed(id: connection.id)
            }

        case .none:
            break
        }
    }

    // MARK: - Connection Creation

    private func createConnection(_ connectionID: Connection.ID) async {
        do {
            let connection = try await factory(connectionID)
            observabilityDelegate.connectionCreated(id: connection.id)

            connection.onClose { [weak self] _ in
                guard let self = self else { return }
                let action = self.stateBox.withLockedValue { state in
                    state.stateMachine.connectionClosed(connectionID)
                }
                self.enqueueAction(action)
            }

            let action = stateBox.withLockedValue { state in
                state.stateMachine.connectionEstablished(connection)
            }
            enqueueAction(action)
        } catch {
            let action = stateBox.withLockedValue { state in
                state.stateMachine.connectionCreationFailed(connectionID, error: error)
            }
            enqueueAction(action)
        }
    }

    // MARK: - Keep-Alive

    private func runKeepAlive(for connection: Connection) async {
        do {
            try await keepAliveBehavior.runKeepAlive(for: connection)
            let action = stateBox.withLockedValue { state in
                state.stateMachine.keepAliveSucceeded(connection)
            }
            enqueueAction(action)
        } catch {
            let action = stateBox.withLockedValue { state in
                state.stateMachine.keepAliveFailed(connection.id)
            }
            enqueueAction(action)
        }
    }

    // MARK: - Timer Management

    private func scheduleTimer(_ timer: StateMachine.Timer, in group: inout TaskGroup<Void>) {
        let tokenID = timerIDGenerator.loadThenWrappingIncrement(ordering: .relaxed)
        let token = TimerCancellationToken(id: tokenID)

        stateBox.withLockedValue { state in
            state.stateMachine.timerScheduled(timer, cancellationToken: token)
        }

        group.addTask {
            await self.runTimer(timer, token: token)
        }
    }

    private func runTimer(_ timer: StateMachine.Timer, token: TimerCancellationToken) async {
        let shouldTrigger = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(for: timer.duration)
                    return true
                } catch {
                    return false
                }
            }

            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.stateBox.withLockedValue { state in
                        state.timerContinuations[token.id] = continuation
                    }
                }
                return false
            }

            let result = await group.next()!
            group.cancelAll()
            return result
        }

        stateBox.withLockedValue { state in
            state.timerContinuations.removeValue(forKey: token.id)
        }

        if shouldTrigger {
            let action = stateBox.withLockedValue { state in
                state.stateMachine.timerTriggered(timer)
            }
            enqueueAction(action)
        }
    }

    private func cancelTimer(_ token: TimerCancellationToken) {
        let continuation = stateBox.withLockedValue { state in
            state.timerContinuations.removeValue(forKey: token.id)
        }
        continuation?.resume()
    }

    private func cancelTimers(_ tokens: some Sequence<TimerCancellationToken>) {
        for token in tokens {
            cancelTimer(token)
        }
    }
}

