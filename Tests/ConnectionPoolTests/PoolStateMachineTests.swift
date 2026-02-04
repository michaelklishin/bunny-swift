// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing

@testable import ConnectionPool

// MARK: - Test Fixtures

final class MockConnection: PooledConnection, @unchecked Sendable {
    let id: Int
    private var closeHandlers: [@Sendable ((any Error)?) -> Void] = []
    var isClosed = false

    init(id: Int) {
        self.id = id
    }

    func onClose(_ closure: @escaping @Sendable ((any Error)?) -> Void) {
        closeHandlers.append(closure)
    }

    func close() {
        isClosed = true
        for handler in closeHandlers {
            handler(nil)
        }
    }

    func simulateClose(error: (any Error)? = nil) {
        for handler in closeHandlers {
            handler(error)
        }
    }
}

struct MockRequest: ConnectionRequestProtocol {
    typealias ID = Int
    typealias Connection = MockConnection

    let id: Int
    var completionResult: Result<ConnectionLease<MockConnection>, ConnectionPoolError>?

    func complete(with result: Result<ConnectionLease<MockConnection>, ConnectionPoolError>) {
        // In tests, we just track the result
    }
}

struct MockTimerToken: Hashable, Sendable {
    let id: Int
}

typealias TestStateMachine = PoolStateMachine<MockConnection, ConnectionIDGenerator, MockRequest, MockTimerToken>

func makeStateMachine(
    minimumConnections: Int = 0,
    softLimit: Int = 4,
    hardLimit: Int = 4,
    idleTimeout: Duration = .seconds(60)
) -> TestStateMachine {
    let config = TestStateMachine.Configuration(
        minimumConnectionCount: minimumConnections,
        maximumConnectionSoftLimit: softLimit,
        maximumConnectionHardLimit: hardLimit,
        keepAliveFrequency: nil,
        idleTimeout: idleTimeout,
        circuitBreakerTripAfter: .seconds(15)
    )
    return TestStateMachine(configuration: config, idGenerator: ConnectionIDGenerator())
}

// MARK: - Tests

@Suite("Pool State Machine Tests")
struct PoolStateMachineTests {

    @Test("Lease request with no connections creates a new connection")
    func leaseCreatesConnection() {
        var sm = makeStateMachine()
        let request = MockRequest(id: 1)

        let action = sm.leaseConnection(request)

        if case .createConnection(let id) = action.connection {
            #expect(id >= 0)
        } else {
            Issue.record("Expected createConnection action")
        }
    }

    @Test("Lease request reuses idle connection")
    func leaseReusesIdleConnection() {
        var sm = makeStateMachine()
        let conn = MockConnection(id: 1)

        _ = sm.connectionEstablished(conn)
        _ = sm.releaseConnection(conn)

        let request = MockRequest(id: 2)
        let action = sm.leaseConnection(request)

        if case .leaseConnection(let req, let leasedConn) = action.request {
            #expect(req.id == 2)
            #expect(leasedConn.id == conn.id)
        } else {
            Issue.record("Expected leaseConnection action")
        }
    }

    @Test("Multiple requests are queued when at connection limit")
    func requestsQueuedAtLimit() {
        var sm = makeStateMachine(hardLimit: 1)
        let conn = MockConnection(id: 0)

        _ = sm.connectionEstablished(conn)

        let request1 = MockRequest(id: 1)
        let request2 = MockRequest(id: 2)

        let action1 = sm.leaseConnection(request1)
        let action2 = sm.leaseConnection(request2)

        if case .leaseConnection = action1.request {
            // First request gets the connection
        } else {
            Issue.record("First request should get connection")
        }

        // Second request should be queued (no connection action since at limit)
        if case .none = action2.connection {
            // Expected - no new connection created
        } else {
            Issue.record("Should not create connection when at limit")
        }
    }

    @Test("Released connection services queued request")
    func releasedConnectionServicesQueue() {
        var sm = makeStateMachine(hardLimit: 1)
        let conn = MockConnection(id: 0)

        _ = sm.connectionEstablished(conn)

        let request1 = MockRequest(id: 1)
        let request2 = MockRequest(id: 2)

        _ = sm.leaseConnection(request1)
        _ = sm.leaseConnection(request2)

        let releaseAction = sm.releaseConnection(conn)

        if case .leaseConnection(let req, _) = releaseAction.request {
            #expect(req.id == 2)
        } else {
            Issue.record("Should lease to queued request")
        }
    }

    @Test("Connection closed removes from pool")
    func connectionClosedRemovesFromPool() {
        var sm = makeStateMachine()
        let conn = MockConnection(id: 0)

        _ = sm.connectionEstablished(conn)
        _ = sm.releaseConnection(conn)

        let action = sm.connectionClosed(0)

        // Should not crash and return some action
        if case .none = action.request {
            // Expected
        }
    }

    @Test("Shutdown fails pending requests")
    func shutdownFailsPendingRequests() {
        var sm = makeStateMachine(hardLimit: 1)
        let conn = MockConnection(id: 0)

        _ = sm.connectionEstablished(conn)

        let request1 = MockRequest(id: 1)
        let request2 = MockRequest(id: 2)

        _ = sm.leaseConnection(request1)
        _ = sm.leaseConnection(request2)

        let shutdownAction = sm.triggerShutdown()

        if case .failRequests(let requests, let error) = shutdownAction.request {
            #expect(requests.count == 1)
            #expect(error == .poolShutdown)
        } else {
            Issue.record("Should fail queued requests")
        }
    }

    @Test("Shutdown prevents new leases")
    func shutdownPreventsNewLeases() {
        var sm = makeStateMachine()

        _ = sm.triggerShutdown()

        let request = MockRequest(id: 1)
        let action = sm.leaseConnection(request)

        if case .failRequest(_, let error) = action.request {
            #expect(error == .poolShutdown)
        } else {
            Issue.record("Should fail request after shutdown")
        }
    }

    @Test("Cancel request removes from queue")
    func cancelRequestRemovesFromQueue() {
        var sm = makeStateMachine(hardLimit: 1)
        let conn = MockConnection(id: 0)

        _ = sm.connectionEstablished(conn)

        let request1 = MockRequest(id: 1)
        let request2 = MockRequest(id: 2)

        _ = sm.leaseConnection(request1)
        _ = sm.leaseConnection(request2)

        let cancelAction = sm.cancelRequest(2)

        if case .failRequest(let req, let error) = cancelAction.request {
            #expect(req.id == 2)
            #expect(error == .requestCancelled)
        } else {
            Issue.record("Should fail cancelled request")
        }
    }

    @Test("Connection above soft limit is closed on parking")
    func connectionAboveSoftLimitClosed() {
        var sm = makeStateMachine(softLimit: 1, hardLimit: 2)
        let conn1 = MockConnection(id: 0)
        let conn2 = MockConnection(id: 1)

        _ = sm.connectionEstablished(conn1)
        let action2 = sm.connectionEstablished(conn2)

        if case .closeConnection(let conn, _) = action2.connection {
            #expect(conn.id == 1)
        } else {
            Issue.record("Should close connection above soft limit when parked")
        }
    }

    @Test("Connection established services queued request")
    func connectionEstablishedServicesQueue() {
        var sm = makeStateMachine(hardLimit: 1)
        let request = MockRequest(id: 1)

        _ = sm.leaseConnection(request)

        let conn = MockConnection(id: 0)
        let action = sm.connectionEstablished(conn)

        if case .leaseConnection(let req, let leasedConn) = action.request {
            #expect(req.id == 1)
            #expect(leasedConn.id == 0)
        } else {
            Issue.record("Should lease to queued request")
        }
    }

    @Test("Cancel non-existent request returns none")
    func cancelNonExistentRequest() {
        var sm = makeStateMachine()
        let action = sm.cancelRequest(999)

        if case .none = action.request {
            // Expected
        } else {
            Issue.record("Should return none for non-existent request")
        }
    }

    @Test("Release unknown connection returns none")
    func releaseUnknownConnection() {
        var sm = makeStateMachine()
        let conn = MockConnection(id: 999)

        let action = sm.releaseConnection(conn)

        if case .none = action.request {
            // Expected
        } else {
            Issue.record("Should return none for unknown connection")
        }
    }
}

@Suite("Backoff Calculation Tests")
struct BackoffCalculationTests {

    @Test("First attempt backoff is around 100ms")
    func firstAttemptBackoff() {
        let backoff = TestStateMachine.calculateBackoff(failedAttempt: 1)
        let nanoseconds = backoff.components.attoseconds / 1_000_000_000

        #expect(nanoseconds >= 90_000_000)
        #expect(nanoseconds <= 110_000_000)
    }

    @Test("Backoff increases with attempts")
    func backoffIncreases() {
        let backoff1 = TestStateMachine.calculateBackoff(failedAttempt: 1)
        let backoff5 = TestStateMachine.calculateBackoff(failedAttempt: 5)
        let backoff10 = TestStateMachine.calculateBackoff(failedAttempt: 10)

        #expect(backoff5 > backoff1)
        #expect(backoff10 > backoff5)
    }

    @Test("Backoff is capped at 60 seconds")
    func backoffIsCapped() {
        let backoff = TestStateMachine.calculateBackoff(failedAttempt: 100)
        #expect(backoff <= .seconds(62))
    }
}

@Suite("Connection Pool Error Tests")
struct ConnectionPoolErrorTests {

    @Test("Errors are equatable")
    func errorsAreEquatable() {
        #expect(ConnectionPoolError.requestCancelled == ConnectionPoolError.requestCancelled)
        #expect(ConnectionPoolError.poolShutdown == ConnectionPoolError.poolShutdown)
        #expect(ConnectionPoolError.requestCancelled != ConnectionPoolError.poolShutdown)
    }

    @Test("Errors are hashable")
    func errorsAreHashable() {
        let set: Set<ConnectionPoolError> = [.requestCancelled, .poolShutdown, .circuitBreakerTripped]
        #expect(set.count == 3)
    }
}

@Suite("Configuration Tests")
struct ConfigurationTests {

    @Test("Default configuration has reasonable values")
    func defaultConfiguration() {
        let config = ConnectionPoolConfiguration.default

        #expect(config.minimumConnectionCount == 0)
        #expect(config.maximumConnectionSoftLimit == 4)
        #expect(config.maximumConnectionHardLimit == 4)
        #expect(config.idleTimeout == .seconds(60))
    }

    @Test("Configuration is customizable")
    func customConfiguration() {
        let config = ConnectionPoolConfiguration(
            minimumConnectionCount: 2,
            maximumConnectionSoftLimit: 10,
            maximumConnectionHardLimit: 20,
            idleTimeout: .seconds(120)
        )

        #expect(config.minimumConnectionCount == 2)
        #expect(config.maximumConnectionSoftLimit == 10)
        #expect(config.maximumConnectionHardLimit == 20)
        #expect(config.idleTimeout == .seconds(120))
    }
}

@Suite("Utility Tests")
struct UtilityTests {

    @Test("TinyFastSequence handles empty case")
    func tinyFastSequenceEmpty() {
        let seq = TinyFastSequence<Int>()
        #expect(seq.isEmpty)
        #expect(seq.count == 0)
        #expect(Array(seq) == [])
    }

    @Test("TinyFastSequence handles single element")
    func tinyFastSequenceSingle() {
        let seq = TinyFastSequence(42)
        #expect(!seq.isEmpty)
        #expect(seq.count == 1)
        #expect(Array(seq) == [42])
    }

    @Test("TinyFastSequence handles two elements")
    func tinyFastSequenceTwo() {
        let seq = TinyFastSequence(contentsOf: [1, 2])
        #expect(seq.count == 2)
        #expect(Array(seq) == [1, 2])
    }

    @Test("TinyFastSequence handles multiple elements")
    func tinyFastSequenceMultiple() {
        let seq = TinyFastSequence(contentsOf: [1, 2, 3, 4, 5])
        #expect(seq.count == 5)
        #expect(Array(seq) == [1, 2, 3, 4, 5])
    }

    @Test("TinyFastSequence append works")
    func tinyFastSequenceAppend() {
        var seq = TinyFastSequence<Int>()
        seq.append(1)
        seq.append(2)
        seq.append(3)
        #expect(Array(seq) == [1, 2, 3])
    }

    @Test("Max2Sequence handles zero to two elements")
    func max2Sequence() {
        var seq = Max2Sequence<Int>()
        #expect(seq.isEmpty)

        seq.append(1)
        #expect(Array(seq) == [1])

        seq.append(2)
        #expect(Array(seq) == [1, 2])
    }

    @Test("ConnectionIDGenerator produces unique IDs")
    func idGeneratorUnique() {
        let gen = ConnectionIDGenerator()
        let id1 = gen.next()
        let id2 = gen.next()
        let id3 = gen.next()

        #expect(id1 != id2)
        #expect(id2 != id3)
        #expect(id1 != id3)
    }

    @Test("ConnectionIDGenerator is monotonic")
    func idGeneratorMonotonic() {
        let gen = ConnectionIDGenerator()
        let id1 = gen.next()
        let id2 = gen.next()
        let id3 = gen.next()

        #expect(id2 == id1 + 1)
        #expect(id3 == id2 + 1)
    }
}

@Suite("Connection Lease Tests")
struct ConnectionLeaseTests {

    @Test("Lease holds connection reference")
    func leaseHoldsConnection() {
        let conn = MockConnection(id: 42)
        let released = LockedValueBox(false)

        let lease = ConnectionLease(connection: conn) { _ in
            released.withLockedValue { $0 = true }
        }

        #expect(lease.connection.id == 42)
        #expect(!released.withLockedValue { $0 })
    }

    @Test("Lease release calls handler")
    func leaseReleaseCallsHandler() {
        let conn = MockConnection(id: 42)
        let released = LockedValueBox(false)

        let lease = ConnectionLease(connection: conn) { _ in
            released.withLockedValue { $0 = true }
        }

        lease.release()
        #expect(released.withLockedValue { $0 })
    }
}
