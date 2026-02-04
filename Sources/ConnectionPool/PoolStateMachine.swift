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

struct PoolStateMachine<
    Connection: PooledConnection,
    ConnectionIDGenerator: ConnectionIDGeneratorProtocol,
    Request: ConnectionRequestProtocol,
    TimerCancellationToken: Sendable & Hashable
>: Sendable where
    Connection.ID == ConnectionIDGenerator.ID,
    Request.Connection == Connection
{
    typealias ConnectionID = Connection.ID
    typealias RequestID = Request.ID

    // MARK: - Configuration

    struct Configuration: Sendable {
        var minimumConnectionCount: Int
        var maximumConnectionSoftLimit: Int
        var maximumConnectionHardLimit: Int
        var keepAliveFrequency: Duration?
        var idleTimeout: Duration
        var circuitBreakerTripAfter: Duration
    }

    // MARK: - Timer

    struct Timer: Hashable, Sendable {
        enum UseCase: Hashable, Sendable {
            case backoff
            case keepAlive
            case idleTimeout
        }

        let timerID: Int
        let connectionID: ConnectionID?
        let duration: Duration
        let useCase: UseCase
    }

    // MARK: - Connection State

    private enum ConnectionState: Sendable {
        case idle(Connection, idleTimerToken: TimerCancellationToken?, keepAliveTimerToken: TimerCancellationToken?)
        case leased(Connection)
        case closing(Connection)
    }

    // MARK: - Pool State

    private enum PoolState: Sendable {
        case running
        case connectionCreationFailing(FailingContext)
        case circuitBreakerOpen(FailingContext)
        case shuttingDown
        case shutDown

        struct FailingContext: Sendable {
            var timeOfFirstFailure: ContinuousClock.Instant
            var numberOfFailedAttempts: Int
            var lastError: any Error
            var retryConnectionID: ConnectionID?
        }
    }

    // MARK: - Actions

    struct Action: Sendable {
        var request: RequestAction
        var connection: ConnectionAction

        static func none() -> Action {
            Action(request: .none, connection: .none)
        }
    }

    enum RequestAction: Sendable {
        case leaseConnection(Request, Connection)
        case queueRequest(Request)
        case failRequest(Request, ConnectionPoolError)
        case failRequests(TinyFastSequence<Request>, ConnectionPoolError)
        case none
    }

    enum ConnectionAction: Sendable {
        case scheduleTimers(Max2Sequence<Timer>)
        case createConnection(ConnectionID)
        case runKeepAlive(Connection)
        case closeConnection(Connection, Max2Sequence<TimerCancellationToken>)
        case shutdown(ShutdownContext)
        case cancelTimers(TinyFastSequence<TimerCancellationToken>)
        case none

        struct ShutdownContext: Sendable {
            var connections: [Connection] = []
            var timersToCancel: [TimerCancellationToken] = []
        }
    }

    // MARK: - State

    private let configuration: Configuration
    private let idGenerator: ConnectionIDGenerator
    private var poolState: PoolState = .running
    private var connections: [ConnectionID: ConnectionState] = [:]
    private var requestQueue: [Request] = []
    private var timerIDCounter = 0
    private var timerCancellations: [Int: TimerCancellationToken] = [:]
    private var pendingConnectionCount = 0
    private let clock = ContinuousClock()

    // MARK: - Initialization

    init(configuration: Configuration, idGenerator: ConnectionIDGenerator) {
        self.configuration = configuration
        self.idGenerator = idGenerator
    }

    // MARK: - Lease Connection

    mutating func leaseConnection(_ request: Request) -> Action {
        switch poolState {
        case .running, .connectionCreationFailing:
            return handleLeaseRequest(request)
        case .circuitBreakerOpen:
            return Action(request: .failRequest(request, .circuitBreakerTripped), connection: .none)
        case .shuttingDown, .shutDown:
            return Action(request: .failRequest(request, .poolShutdown), connection: .none)
        }
    }

    private mutating func handleLeaseRequest(_ request: Request) -> Action {
        // Try to find an idle connection
        for (id, state) in connections {
            if case .idle(let conn, let idleTimer, let keepAliveTimer) = state {
                connections[id] = .leased(conn)
                var timersToCancel = TinyFastSequence<TimerCancellationToken>()
                if let token = idleTimer { timersToCancel.append(token) }
                if let token = keepAliveTimer { timersToCancel.append(token) }
                return Action(
                    request: .leaseConnection(request, conn),
                    connection: timersToCancel.isEmpty ? .none : .cancelTimers(timersToCancel)
                )
            }
        }

        // No idle connection, queue the request
        requestQueue.append(request)

        // Try to create a new connection if under limits
        let totalConnections = connections.count + pendingConnectionCount
        if totalConnections < configuration.maximumConnectionHardLimit {
            let createAction = createNewConnection()
            return Action(request: .queueRequest(request), connection: createAction.connection)
        }

        return Action(request: .queueRequest(request), connection: .none)
    }

    private mutating func createNewConnection() -> Action {
        let connectionID = idGenerator.next()
        pendingConnectionCount += 1
        return Action(request: .none, connection: .createConnection(connectionID))
    }

    // MARK: - Release Connection

    mutating func releaseConnection(_ connection: Connection) -> Action {
        let id = connection.id
        guard let state = connections[id] else { return .none() }

        switch state {
        case .leased:
            return handleConnectionBecameAvailable(connection)
        case .idle, .closing:
            return .none()
        }
    }

    private mutating func handleConnectionBecameAvailable(_ connection: Connection) -> Action {
        // Service queued requests
        if !requestQueue.isEmpty {
            let request = requestQueue.removeFirst()
            connections[connection.id] = .leased(connection)
            return Action(request: .leaseConnection(request, connection), connection: .none)
        }

        // Park the connection
        return parkConnection(connection)
    }

    private mutating func parkConnection(_ connection: Connection) -> Action {
        let totalConnections = connections.count

        // Close if above soft limit
        if totalConnections > configuration.maximumConnectionSoftLimit {
            connections[connection.id] = .closing(connection)
            return Action(request: .none, connection: .closeConnection(connection, Max2Sequence()))
        }

        // Schedule idle timeout and optional keep-alive
        var timers = Max2Sequence<Timer>()

        let idleTimer = makeTimer(for: connection.id, duration: configuration.idleTimeout, useCase: .idleTimeout)
        timers.append(idleTimer)

        if let keepAliveFrequency = configuration.keepAliveFrequency {
            let keepAliveTimer = makeTimer(for: connection.id, duration: keepAliveFrequency, useCase: .keepAlive)
            timers.append(keepAliveTimer)
        }

        connections[connection.id] = .idle(connection, idleTimerToken: nil, keepAliveTimerToken: nil)
        return Action(request: .none, connection: .scheduleTimers(timers))
    }

    // MARK: - Connection Lifecycle

    mutating func connectionEstablished(_ connection: Connection) -> Action {
        pendingConnectionCount = max(0, pendingConnectionCount - 1)
        connections[connection.id] = .leased(connection)

        // Reset pool state on successful connection
        switch poolState {
        case .connectionCreationFailing, .circuitBreakerOpen:
            poolState = .running
        case .running, .shuttingDown, .shutDown:
            break
        }

        return handleConnectionBecameAvailable(connection)
    }

    mutating func connectionCreationFailed(_ connectionID: ConnectionID, error: any Error) -> Action {
        pendingConnectionCount = max(0, pendingConnectionCount - 1)

        switch poolState {
        case .running:
            let context = PoolState.FailingContext(
                timeOfFirstFailure: clock.now,
                numberOfFailedAttempts: 1,
                lastError: error,
                retryConnectionID: connectionID
            )
            poolState = .connectionCreationFailing(context)
            return scheduleBackoffTimer(attempts: 1)

        case .connectionCreationFailing(var context):
            context.numberOfFailedAttempts += 1
            context.lastError = error
            context.retryConnectionID = connectionID

            // Check if circuit breaker should trip
            let elapsed = clock.now - context.timeOfFirstFailure
            if elapsed >= configuration.circuitBreakerTripAfter && connections.isEmpty {
                poolState = .circuitBreakerOpen(context)
                let failedRequests = TinyFastSequence(contentsOf: requestQueue)
                requestQueue.removeAll()
                return Action(
                    request: .failRequests(failedRequests, .circuitBreakerTripped),
                    connection: scheduleBackoffTimer(attempts: context.numberOfFailedAttempts).connection
                )
            }

            poolState = .connectionCreationFailing(context)
            return scheduleBackoffTimer(attempts: context.numberOfFailedAttempts)

        case .circuitBreakerOpen(var context):
            context.numberOfFailedAttempts += 1
            context.lastError = error
            context.retryConnectionID = connectionID
            poolState = .circuitBreakerOpen(context)
            return scheduleBackoffTimer(attempts: context.numberOfFailedAttempts)

        case .shuttingDown, .shutDown:
            return .none()
        }
    }

    mutating func connectionClosed(_ connectionID: ConnectionID) -> Action {
        guard let state = connections.removeValue(forKey: connectionID) else {
            return .none()
        }

        var timersToCancel = Max2Sequence<TimerCancellationToken>()
        if case .idle(_, let idleTimer, let keepAliveTimer) = state {
            if let token = idleTimer { timersToCancel.append(token) }
            if let token = keepAliveTimer { timersToCancel.append(token) }
        }

        // Check if pool should fully shut down
        if case .shuttingDown = poolState, connections.isEmpty, pendingConnectionCount == 0 {
            poolState = .shutDown
        }

        // Refill connections if needed
        if case .running = poolState {
            let totalConnections = connections.count + pendingConnectionCount
            if totalConnections < configuration.minimumConnectionCount && !requestQueue.isEmpty {
                let createAction = createNewConnection()
                if timersToCancel.isEmpty {
                    return createAction
                }
                return Action(request: .none, connection: createAction.connection)
            }
        }

        if timersToCancel.isEmpty {
            return .none()
        }
        return Action(request: .none, connection: .cancelTimers(TinyFastSequence(Array(timersToCancel))))
    }

    // MARK: - Timer Handling

    private mutating func makeTimer(for connectionID: ConnectionID?, duration: Duration, useCase: Timer.UseCase) -> Timer {
        timerIDCounter += 1
        return Timer(timerID: timerIDCounter, connectionID: connectionID, duration: duration, useCase: useCase)
    }

    mutating func timerScheduled(_ timer: Timer, cancellationToken: TimerCancellationToken) {
        timerCancellations[timer.timerID] = cancellationToken

        if let connectionID = timer.connectionID {
            if case .idle(let conn, var idleToken, var keepAliveToken) = connections[connectionID] {
                switch timer.useCase {
                case .idleTimeout:
                    idleToken = cancellationToken
                case .keepAlive:
                    keepAliveToken = cancellationToken
                case .backoff:
                    break
                }
                connections[connectionID] = .idle(conn, idleTimerToken: idleToken, keepAliveTimerToken: keepAliveToken)
            }
        }
    }

    mutating func timerTriggered(_ timer: Timer) -> Action {
        timerCancellations.removeValue(forKey: timer.timerID)

        switch timer.useCase {
        case .idleTimeout:
            return handleIdleTimeout(timer)
        case .keepAlive:
            return handleKeepAliveTimer(timer)
        case .backoff:
            return handleBackoffTimer(timer)
        }
    }

    private mutating func handleIdleTimeout(_ timer: Timer) -> Action {
        guard let connectionID = timer.connectionID,
              case .idle(let conn, _, let keepAliveToken) = connections[connectionID]
        else {
            return .none()
        }

        connections[connectionID] = .closing(conn)
        var timersToCancel = Max2Sequence<TimerCancellationToken>()
        if let token = keepAliveToken { timersToCancel.append(token) }
        return Action(request: .none, connection: .closeConnection(conn, timersToCancel))
    }

    private mutating func handleKeepAliveTimer(_ timer: Timer) -> Action {
        guard let connectionID = timer.connectionID,
              case .idle(let conn, _, _) = connections[connectionID]
        else {
            return .none()
        }

        return Action(request: .none, connection: .runKeepAlive(conn))
    }

    private mutating func handleBackoffTimer(_ timer: Timer) -> Action {
        let connectionID: ConnectionID?
        switch poolState {
        case .connectionCreationFailing(let context):
            connectionID = context.retryConnectionID
        case .circuitBreakerOpen(let context):
            connectionID = context.retryConnectionID
        default:
            return .none()
        }

        guard let connectionID = connectionID else {
            return .none()
        }

        pendingConnectionCount += 1
        return Action(request: .none, connection: .createConnection(connectionID))
    }

    private mutating func scheduleBackoffTimer(attempts: Int) -> Action {
        let backoff = Self.calculateBackoff(failedAttempt: attempts)
        let timer = makeTimer(for: nil, duration: backoff, useCase: .backoff)
        return Action(request: .none, connection: .scheduleTimers(Max2Sequence(timer)))
    }

    // MARK: - Keep-Alive Results

    mutating func keepAliveSucceeded(_ connection: Connection) -> Action {
        guard case .idle = connections[connection.id] else {
            return .none()
        }
        return parkConnection(connection)
    }

    mutating func keepAliveFailed(_ connectionID: ConnectionID) -> Action {
        guard case .idle(let conn, let idleToken, let keepAliveToken) = connections[connectionID] else {
            return .none()
        }

        connections[connectionID] = .closing(conn)
        var timersToCancel = Max2Sequence<TimerCancellationToken>()
        if let token = idleToken { timersToCancel.append(token) }
        if let token = keepAliveToken { timersToCancel.append(token) }
        return Action(request: .none, connection: .closeConnection(conn, timersToCancel))
    }

    // MARK: - Shutdown

    mutating func triggerShutdown() -> Action {
        switch poolState {
        case .running, .connectionCreationFailing, .circuitBreakerOpen:
            poolState = .shuttingDown

            var shutdown = ConnectionAction.ShutdownContext()
            for (id, state) in connections {
                switch state {
                case .idle(let conn, let idleToken, let keepAliveToken):
                    shutdown.connections.append(conn)
                    if let token = idleToken { shutdown.timersToCancel.append(token) }
                    if let token = keepAliveToken { shutdown.timersToCancel.append(token) }
                    connections[id] = .closing(conn)
                case .leased(let conn):
                    shutdown.connections.append(conn)
                    connections[id] = .closing(conn)
                case .closing:
                    break
                }
            }

            let failedRequests = TinyFastSequence(contentsOf: requestQueue)
            requestQueue.removeAll()

            if connections.isEmpty && pendingConnectionCount == 0 {
                poolState = .shutDown
            }

            return Action(
                request: failedRequests.isEmpty ? .none : .failRequests(failedRequests, .poolShutdown),
                connection: .shutdown(shutdown)
            )

        case .shuttingDown, .shutDown:
            return .none()
        }
    }

    mutating func cancelRequest(_ requestID: RequestID) -> Action {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }) else {
            return .none()
        }
        let request = requestQueue.remove(at: index)
        return Action(request: .failRequest(request, .requestCancelled), connection: .none)
    }

    // MARK: - Backoff Calculation

    static func calculateBackoff(failedAttempt attempts: Int) -> Duration {
        let baseNanoseconds: Double = 100_000_000
        let backoffNanoseconds = baseNanoseconds * pow(1.25, Double(attempts - 1))
        let cappedNanoseconds = min(backoffNanoseconds, 60_000_000_000)

        let jitterRange = Int64(cappedNanoseconds / 100) * 3
        let jitter = Int64.random(in: -jitterRange...jitterRange)

        return Duration.nanoseconds(Int64(cappedNanoseconds) + jitter)
    }
}
