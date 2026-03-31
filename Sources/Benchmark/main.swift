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
let batchSize = 500
let queueName = "bunny-swift.bench"

struct RunResult {
  let label: String
  let rate: Double
  let mbSec: Double
  let ms: Double
}

func runWorkload(_ workload: Workload, useBatch: Bool) async throws -> RunResult {
  let payload = Data(repeating: 0xAB, count: workload.bodySize)

  let pubConfig = ConnectionConfiguration(automaticRecovery: false)
  let conConfig = ConnectionConfiguration(automaticRecovery: false)

  let pubConn = try await Connection.open(pubConfig)
  let conConn = try await Connection.open(conConfig)

  let pubCh = try await pubConn.openChannel()
  let conCh = try await conConn.openChannel()

  let q = try await conCh.queue(queueName, autoDelete: true)
  _ = try await conCh.queuePurge(q.name)

  try await conCh.basicQos(prefetchCount: prefetch)

  let stream = try await conCh.basicConsume(queue: q.name)

  let start = ContinuousClock.now

  let publisherTask = Task {
    if useBatch {
      let batch = [Data](repeating: payload, count: batchSize)
      let fullBatches = workload.messageCount / batchSize
      let remainder = workload.messageCount % batchSize
      for _ in 0..<fullBatches {
        try await pubCh.basicPublishBatch(
          bodies: batch, routingKey: q.name, properties: .transient)
      }
      if remainder > 0 {
        let lastBatch = [Data](repeating: payload, count: remainder)
        try await pubCh.basicPublishBatch(
          bodies: lastBatch, routingKey: q.name, properties: .transient)
      }
    } else {
      for _ in 0..<workload.messageCount {
        try await pubCh.publish(
          body: payload, routingKey: q.name, properties: .transient)
      }
      await pubCh.flush()
    }
  }

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

  try await stream.cancel()
  try await pubConn.close()
  try await conConn.close()

  return RunResult(label: workload.label, rate: rate, mbSec: mbSec, ms: ms)
}

func printResult(_ r: RunResult) {
  let padded = r.label.padding(toLength: 18, withPad: " ", startingAt: 0)
  print(
    "\(padded)  \(String(format: "%8.0f", r.rate)) msg/sec  \(String(format: "%6.1f", r.mbSec)) MB/sec  (\(String(format: "%.0f", r.ms)) ms)"
  )
}

// MARK: - Main

print("bunny-swift benchmark")
print("Prefetch: \(prefetch), multi-ack every \(multiAckEvery), batch size \(batchSize)")
print(String(repeating: "-", count: 72))

print()
print("## publish (per-message)")
print()

var singleResults: [RunResult] = []
for workload in workloads {
  let r = try await runWorkload(workload, useBatch: false)
  singleResults.append(r)
  printResult(r)
}

print()
print("## basicPublishBatch (\(batchSize) msgs/batch)")
print()

var batchResults: [RunResult] = []
for workload in workloads {
  let r = try await runWorkload(workload, useBatch: true)
  batchResults.append(r)
  printResult(r)
}

print()
print(String(repeating: "-", count: 72))
print(
  "| Workload           | publish     | batch (\(batchSize))  | speedup |")
print(
  "|:-------------------|------------:|------------:|--------:|")
for (s, b) in zip(singleResults, batchResults) {
  let speedup = b.rate / s.rate
  let padded = s.label.padding(toLength: 18, withPad: " ", startingAt: 0)
  print(
    "| \(padded) | \(String(format: "%6.0f", s.rate)) msg/s | \(String(format: "%6.0f", b.rate)) msg/s | \(String(format: "%.2fx", speedup)) |"
  )
}
print(String(repeating: "-", count: 72))
