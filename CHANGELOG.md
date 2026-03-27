## 0.14.0 (in development)

### Enhancements

 * `ExchangeType` now supports non-standard exchange types (`.modulusHash`, `.localRandom`,
   `.consistentHash`, `.random`, `.jmsTopic`, `.recentHistory`) and a `.plugin(String)`
   catch-all for arbitrary plugin exchange types
 * ~20% higher publish throughput on sustained workloads thanks to single-buffer frame encoding
   and fewer actor hops on the publish path

### Internal Changes

 * Refactored negotiation of several connection parameters to exactly match what several other,
   much more mature clients do. This touches `heartbeat`, `channel_max`, `frame_max` negotiation
   when a new connection is opened


## 0.13.0 (Mar 22, 2026)

### Enhancements

 * `QueueType.delayed` and `QueueType.jms`: first-class support for
   Tanzu RabbitMQ delayed and JMS queue types

 * `Channel.delayedQueue` and `Channel.jmsQueue` convenience methods
   with type-safe parameters:

   ```swift
   let dq = try await channel.delayedQueue(
       "tasks.retry",
       retryType: .failed,
       retryMin: .seconds(1),
       retryMax: .seconds(60))

   let jq = try await channel.jmsQueue(
       "orders",
       selectorFields: ["priority", "region"],
       selectorFieldMaxBytes: 256)
   ```
   
   Note that queues are declared as durable by default.

 * `Queue.consume` accepts an optional `jmsSelector` parameter for
   JMS message selector expressions

 * `XArguments`: new keys for delayed queues (`delayedRetryType`,
   `delayedRetryMin`, `delayedRetryMax`), JMS queues
   (`selectorFields`, `selectorFieldMaxBytes`), JMS consumers
   (`jmsSelector`), and `consumerDisconnectedTimeout`

 * `DelayedRetryType` enum for the `x-delayed-retry-type` argument
   (values: `all`, `failed`, `returned`)

 * `HeadersMatch` enum and `XArguments.headersMatch` for type-safe
   headers exchange bindings

 * Value enums (`OverflowBehavior`, `QueueLeaderLocator`,
   `DeadLetterStrategy`, `DelayedRetryType`, `HeadersMatch`) now
   conform to `CaseIterable` and provide `asFieldValue` for ergonomic
   AMQP 0-9-1 table value construction


## 0.12.0 (Mar 15, 2026)

### Bug Fixes

 * Consumer did not receive messages published with an empty body. 
 
   GitHub issue: [#13](https://github.com/michaelklishin/bunny-swift/issues/13)


## 0.11.0 (Mar 9, 2026)

### Enhancements

 * Finished connection recovery integration. The feature is heavily inspired by Ruby Bunny 3.x,
   Java and .NET AMQP 0-9-1 clients
 * Support for multiple connection endpoints

### Bug Fixes

 * `TCP_NODELAY` socket option was set at `SOL_SOCKET` level instead of `IPPROTO_TCP`, causing connection failures on Linux


## 0.10.0 (Feb 17, 2026)

### Enhancements

 * `Connection.withChannel` can be used for short-lived channels, [a pattern that is discouraged](https://www.rabbitmq.com/docs/channels#high-channel-churn)
   but can be useful in integration tests

### Bug Fixes

 * NIO pipeline handler ordering caused a crash on TLS connections when opening a channel
 * Heartbeat monitor could not observe inbound frames (any traffic counts for a heartbeat)


## 0.9.0 (Dec 29, 2025)

#### Initial Release

This library, heavily inspired by a few existing AMQP 0-9-1 clients (the original Bunny, Pika, amqprs, the .NET RabbitMQ client 7.x)
is now mature enough to be publicly released.

It targets Swift 6.x and uses modern Swift's concurrency features.

In addition, this is the 2nd AMQP 0-9-1 client — after .NET client 7.x — to support
automatic publisher confirm tracking and acknowledgement.
