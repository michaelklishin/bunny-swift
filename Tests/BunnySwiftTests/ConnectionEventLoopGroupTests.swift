// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import NIO
import NIOConcurrencyHelpers
import Testing

@testable import BunnySwift

/// Counts the tasks a group's loops execute, so a test can tell whether a
/// connection attempt ran on that group or on the library-wide shared one.
private final class TaskCounter: NIOEventLoopMetricsDelegate {
  private let tasks = NIOLockedValueBox(0)

  var tasksExecuted: Int { tasks.withLockedValue { $0 } }

  func processedTick(info: NIOEventLoopTickInfo) {
    tasks.withLockedValue { $0 += info.numberOfTasks }
  }
}

@Suite("Connection event loop group")
struct ConnectionEventLoopGroupTests {
  @Test("A supplied event loop group carries the connection attempt")
  func suppliedGroupCarriesTheConnectionAttempt() async throws {
    let counter = TaskCounter()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1, metricsDelegate: counter)
    let before = counter.tasksExecuted

    // Port 1 has no listener, so the attempt fails fast without a broker; what
    // matters is which group ran the bootstrap.
    let configuration = ConnectionConfiguration(host: "127.0.0.1", port: 1)
    await #expect(throws: (any Error).self) {
      _ = try await Connection.open(configuration, eventLoopGroup: group)
    }

    // The tick that ran the failure may still be finishing on the loop thread.
    var after = counter.tasksExecuted
    for _ in 0..<50 where after <= before {
      try await Task.sleep(for: .milliseconds(20))
      after = counter.tasksExecuted
    }
    #expect(after > before)
    try await group.shutdownGracefully()
  }
}
