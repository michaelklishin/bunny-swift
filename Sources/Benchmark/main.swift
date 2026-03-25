// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import BunnySwift
import Foundation

struct Workload {
  let label: String
  let bodySize: Int
  let messageCount: Int
}

let workloads: [Workload] = [
  Workload(label: "100K x 12 B", bodySize: 12, messageCount: 100_000),
  Workload(label: "500K x 12 B", bodySize: 12, messageCount: 500_000),
  Workload(label: "100K x 128 B", bodySize: 128, messageCount: 100_000),
  Workload(label: "100K x 1 KB", bodySize: 1024, messageCount: 100_000),
  Workload(label: "500K x 1 KB", bodySize: 1024, messageCount: 500_000),
]

let prefetch: UInt16 = 500
let multiAckEvery = 100
let queueName = "bunny-swift.bench"

func runWorkload(_ workload: Workload) async throws {
  let payload = Data(repeating: 0xAB, count: workload.bodySize)

  // Two separate connections: one for publishing, one for consuming
  let pubConfig = ConnectionConfiguration(
    automaticRecovery: false
  )
  let conConfig = ConnectionConfiguration(
    automaticRecovery: false
  )

  let pubConn = try await Connection.open(pubConfig)
  let conConn = try await Connection.open(conConfig)

  let pubCh = try await pubConn.openChannel()
  let conCh = try await conConn.openChannel()

  // Declare an auto-delete classic queue
  let q = try await conCh.queue(queueName, autoDelete: true)
  // Purge any leftover messages
  _ = try await conCh.queuePurge(q.name)

  try await conCh.basicQos(prefetchCount: prefetch)

  let stream = try await conCh.basicConsume(queue: q.name)

  let start = ContinuousClock.now

  // Publisher task
  let publisherTask = Task {
    for _ in 0..<workload.messageCount {
      try await pubCh.publish(
        body: payload,
        routingKey: q.name
      )
    }
    await pubCh.flush()
  }

  // Consumer task
  let consumerTask = Task {
    var received = 0
    for await message in stream {
      received += 1
      if received % multiAckEvery == 0 || received == workload.messageCount {
        try await message.ack(multiple: true)
      }
      if received >= workload.messageCount {
        break
      }
    }
  }

  try await publisherTask.value
  try await consumerTask.value

  let elapsed = start.duration(to: ContinuousClock.now)
  let ms =
    Double(elapsed.components.seconds) * 1000.0
    + Double(elapsed.components.attoseconds) / 1e15

  let rate = Double(workload.messageCount) * 1000.0 / ms
  let mbSec = rate * Double(workload.bodySize) / (1024.0 * 1024.0)

  let padded = workload.label.padding(toLength: 18, withPad: " ", startingAt: 0)
  print(
    "\(padded)  \(String(format: "%8.0f", rate)) msg/sec  \(String(format: "%6.1f", mbSec)) MB/sec  (\(String(format: "%.0f", ms)) ms)"
  )

  try await stream.cancel()
  try await pubConn.close()
  try await conConn.close()
}

print("bunny-swift benchmark")
print("Prefetch: \(prefetch), multi-ack every \(multiAckEvery)")
print(String(repeating: "-", count: 64))

for workload in workloads {
  try await runWorkload(workload)
}
