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
  Workload(label: "100K x 64 B", bodySize: 64, messageCount: 100_000),
  Workload(label: "100K x 512 B", bodySize: 512, messageCount: 100_000),
  Workload(label: "100K x 1 KB", bodySize: 1024, messageCount: 100_000),
  Workload(label: "100K x 2 KB", bodySize: 2048, messageCount: 100_000),
  Workload(label: "100K x 4 KB", bodySize: 4096, messageCount: 100_000),
  Workload(label: "100K x 8 KB", bodySize: 8192, messageCount: 100_000),
  Workload(label: "50K x 64 KB", bodySize: 65_536, messageCount: 50_000),
  Workload(label: "10K x 512 KB", bodySize: 524_288, messageCount: 10_000),
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

enum PublishMode {
  case publish
  case basicPublishBatch
  case publishBatchBuilder
  case publishWithConfirms
  case basicPublishBatchWithConfirms
  case publishBatchBuilderWithConfirms
}

func openConnection() async throws -> Connection {
  let config = ConnectionConfiguration(automaticRecovery: false)
  return try await Connection.open(config)
}

func runWorkload(_ workload: Workload, mode: PublishMode) async throws -> RunResult {
  let payload = Data(repeating: 0xAB, count: workload.bodySize)

  let pubConn = try await openConnection()
  let conConn = try await openConnection()

  let pubCh = try await pubConn.openChannel()
  let conCh = try await conConn.openChannel()

  let q = try await conCh.queue(queueName, durable: true, autoDelete: true)
  _ = try await conCh.queuePurge(q.name)

  try await conCh.basicQos(prefetchCount: prefetch)

  let stream = try await conCh.basicConsume(queue: q.name)

  switch mode {
  case .publishWithConfirms, .basicPublishBatchWithConfirms, .publishBatchBuilderWithConfirms:
    try await pubCh.confirmSelect()
  default:
    break
  }

  let start = ContinuousClock.now

  let publisherTask = Task {
    switch mode {
    case .publish, .publishWithConfirms:
      for _ in 0..<workload.messageCount {
        try await pubCh.publish(
          body: payload, routingKey: q.name, properties: .transient)
      }
      await pubCh.flush()
      if case .publishWithConfirms = mode {
        try await pubCh.waitForConfirms()
      }

    case .basicPublishBatch, .basicPublishBatchWithConfirms:
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
      if case .basicPublishBatchWithConfirms = mode {
        try await pubCh.waitForConfirms()
      }

    case .publishBatchBuilder, .publishBatchBuilderWithConfirms:
      let fullBatches = workload.messageCount / batchSize
      let remainder = workload.messageCount % batchSize
      for _ in 0..<fullBatches {
        let batch = pubCh.publishBatch(
          routingKey: q.name, properties: .transient)
        for _ in 0..<batchSize {
          try await batch.add(payload)
        }
        await batch.publish()
      }
      if remainder > 0 {
        let batch = pubCh.publishBatch(
          routingKey: q.name, properties: .transient)
        for _ in 0..<remainder {
          try await batch.add(payload)
        }
        await batch.publish()
      }
      if case .publishBatchBuilderWithConfirms = mode {
        try await pubCh.waitForConfirms()
      }
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

do {
  let testConn = try await openConnection()
  try await testConn.close()
} catch {
  print("Cannot connect to RabbitMQ at localhost:5672 (\(error)).")
  exit(1)
}

print("bunny-swift benchmark")
print("Prefetch: \(prefetch), multi-ack every \(multiAckEvery), batch size \(batchSize)")
print(String(repeating: "-", count: 72))

var publishResults: [RunResult] = []
var batchResults: [RunResult] = []
var builderResults: [RunResult] = []
var publishConfirmResults: [RunResult] = []
var batchConfirmResults: [RunResult] = []
var builderConfirmResults: [RunResult] = []

do {
  // Without confirms

  print()
  print("## publish (buffered)")
  print()

  for workload in workloads {
    let r = try await runWorkload(workload, mode: .publish)
    publishResults.append(r)
    printResult(r)
  }

  print()
  print("## basicPublishBatch (\(batchSize))")
  print()

  for workload in workloads {
    let r = try await runWorkload(workload, mode: .basicPublishBatch)
    batchResults.append(r)
    printResult(r)
  }

  print()
  print("## publishBatch builder (\(batchSize))")
  print()

  for workload in workloads {
    let r = try await runWorkload(workload, mode: .publishBatchBuilder)
    builderResults.append(r)
    printResult(r)
  }

  // With confirms

  print()
  print("## publish + waitForConfirms")
  print()

  for workload in workloads {
    let r = try await runWorkload(workload, mode: .publishWithConfirms)
    publishConfirmResults.append(r)
    printResult(r)
  }

  print()
  print("## basicPublishBatch + waitForConfirms (\(batchSize))")
  print()

  for workload in workloads {
    let r = try await runWorkload(workload, mode: .basicPublishBatchWithConfirms)
    batchConfirmResults.append(r)
    printResult(r)
  }

  print()
  print("## publishBatch builder + confirms (\(batchSize))")
  print()

  for workload in workloads {
    let r = try await runWorkload(workload, mode: .publishBatchBuilderWithConfirms)
    builderConfirmResults.append(r)
    printResult(r)
  }
} catch {
  print("Benchmark failed: \(error)")
  exit(1)
}

// Summary table

print()
print(String(repeating: "-", count: 100))
print(
  "| Workload           | publish     | batch       | builder     | pub+conf    | batch+conf  | build+conf  |"
)
print(
  "|:-------------------|------------:|------------:|------------:|------------:|------------:|------------:|"
)
for i in 0..<workloads.count {
  let padded = workloads[i].label.padding(toLength: 18, withPad: " ", startingAt: 0)
  print(
    "| \(padded) | \(String(format: "%6.0f", publishResults[i].rate)) msg/s | \(String(format: "%6.0f", batchResults[i].rate)) msg/s | \(String(format: "%6.0f", builderResults[i].rate)) msg/s | \(String(format: "%6.0f", publishConfirmResults[i].rate)) msg/s | \(String(format: "%6.0f", batchConfirmResults[i].rate)) msg/s | \(String(format: "%6.0f", builderConfirmResults[i].rate)) msg/s |"
  )
}
print(String(repeating: "-", count: 100))
