# Bunny.Swift, a Modern Swift Client for RabbitMQ

BunnySwift is a RabbitMQ client for Swift that primarily follows the API design of [Bunny](https://github.com/ruby-amqp/bunny) but also
borrows from the .NET, Java, Python (Pika) and Rust (amqprs) clients. It is built on
Swift NIO and modern Swift concurrency features such as async/await.


## Supported iOS and macOS Versions

This library targets macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, and visionOS 1+.
Swift 6.0 or later is required.


## Supported RabbitMQ Versions

Bunny.Swift targets [currently supported RabbitMQ release series](https://www.rabbitmq.com/release-information).


## Project Maturity

This is a very new project by a long time member of the RabbitMQ Core Team.
Breaking public API changes are not out of the question at this stage.


## Installation

Add BunnySwift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/michaelklishin/bunny-swift.git", from: "0.9.0")
]
```


## Quick Start

```swift
import BunnySwift

// Connect to RabbitMQ
let connection = try await Connection.open()
let channel = try await connection.openChannel()

// Declare a queue and publish a message
let queue = try await channel.queue("hello")
try await queue.publish("Hello, World!")

// Close the channel and connection. Note: this is just an example,
// real world applications should use long-lived connections as much as possible.
try await channel.close()
try await connection.close()
```


## API Examples

### Declaring Queue Types

```swift
// Classic queue (default)
let classic = try await channel.queue("events.classic")

// Quorum queue (replicated, durable)
let quorum = try await channel.queue(
    "events.quorum",
    type: .quorum,
    durable: true
)

// Stream (append-only log)
let stream = try await channel.queue(
    "events.stream",
    type: .stream,
    durable: true
)

// Custom or plugin-provided queue type (forward compatibility)
let custom = try await channel.queue(
    "events.custom",
    type: .custom("x-my-queue-type"),
    durable: true
)
```

### Publishing with Automatic Confirmation Tracking

```swift
// Enable publisher confirms with automatic tracking
// Publish methods will wait for broker confirmation before returning
try await channel.confirmSelect(tracking: true, outstandingLimit: 128)

// Each publish now waits for confirmation (blocks until confirmed)
try await queue.publish("Important message")

// Without tracking (manual mode), use waitForConfirms
try await channel.confirmSelect()
try await queue.publish("Message 1")
try await queue.publish("Message 2")
// Wait for all outstanding confirms
try await channel.waitForConfirms()
```

### Consuming with Manual Acknowledgements

```swift
// Start consuming with manual acknowledgement mode (default)
let stream = try await queue.consume(acknowledgementMode: .manual)

for try await message in stream {
    print("Received: \(message.bodyString ?? "")")

    // Process the message, then acknowledge
    try await message.ack()

    // Or reject/requeue on failure
    // try await message.nack(requeue: true)
}
```

### Connection Recovery

BunnySwift includes infrastructure for automatic connection recovery with exponential backoff:

```swift
// Use sensible defaults
let recovery = RecoveryConfiguration.default

// Or customize recovery behavior
let customRecovery = RecoveryConfiguration(
    // Enable automatic recovery
    automaticRecovery: true,
    // Initial delay before first attempt
    networkRecoveryInterval: 5.0,
    // nil for unlimited attempts
    maxRecoveryAttempts: nil,
    // Exponential backoff multiplier
    backoffMultiplier: 2.0,
    // Maximum delay between attempts
    maxRecoveryInterval: 60.0
)

// When recovery succeeds, topology (queues, exchanges, bindings, consumers)
// is automatically redeclared
```

### TLS Connections

BunnySwift supports TLS connections. The following example
uses [tls-gen](https://github.com/rabbitmq/tls-gen)-generated certificates in the PEM format:

```swift
// Mutual TLS with client certificate authentication
let tls = try TLSConfiguration.fromPEMFiles(
    certificatePath: "/path/to/tls-gen/basic/result/client_certificate.pem",
    keyPath: "/path/to/tls-gen/basic/result/client_key.pem",
    caCertificatePath: "/path/to/tls-gen/basic/result/ca_certificate.pem"
)

let config = ConnectionConfiguration(
    host: "rabbit.example.com",
    // Default TLS port
    port: 5671,
    tls: tls
)

let connection = try await Connection.open(config)
```

In the case of one-way [peer verification](https://www.rabbitmq.com/docs/ssl#peer-verification) (client verifies RabbitMQ certificate chain but does not
have its own certificate/key pair):

```swift
// TLS with server certificate verification only
let tls = try TLSConfiguration.withCACertificate(
    path: "/path/to/tls-gen/basic/result/ca_certificate.pem"
)

let config = ConnectionConfiguration(
    host: "rabbit.example.com",
    port: 5671,
    tls: tls
)

let connection = try await Connection.open(config)
```

Using an AMQPS URI:

```swift
// URI-based configuration automatically enables TLS
var config = try ConnectionConfiguration.from(uri: "amqps://rabbitmq.eng.example.com")

// Add custom TLS settings for certificate verification
config.tls = try TLSConfiguration.withCACertificate(
    path: "/path/to/ca_certificate.pem"
)

let connection = try await Connection.open(config)
```

The following example enables mutual peer verification and combines
it with a URI:

```swift
var config = try ConnectionConfiguration.from(uri: "amqps://rabbit.example.com")
config.tls = try TLSConfiguration.fromPEMFiles(
    certificatePath: "/path/to/client_certificate.pem",
    keyPath: "/path/to/client_key.pem",
    caCertificatePath: "/path/to/ca_certificate.pem"
)

let connection = try await Connection.open(config)
```

Advanced TLS configuration:

```swift
import NIOSSL

// Fine-grained TLS configuration
var tls = TLSConfiguration(
    certificateChain: [],
    privateKey: nil,
    // Use system trust store
    trustRoots: .default,
    certificateVerification: .fullVerification,
    // Minimum TLS 1.2
    minimumTLSVersion: .tlsv12,
    // Maximum TLS 1.3
    maximumTLSVersion: .tlsv13
)

// Load certificates programmatically
let caCerts = try NIOSSLCertificate.fromPEMFile("/path/to/ca.pem")
tls.trustRoots = .certificates(caCerts)

let config = ConnectionConfiguration(
    host: "rabbit.example.com",
    port: 5671,
    tls: tls
)

let connection = try await Connection.open(config)
```

For development and testing only (not recommended for production):

```swift
// Skip peer verification: THIS IS A POOR SECURITY PRACTICE, use only for development and testing
let config = ConnectionConfiguration(
    host: "localhost",
    port: 5671,
    tls: TLSConfiguration.insecure()
)

let connection = try await Connection.open(config)
```


## Documentation

### Guides

 * [Getting Started with RabbitMQ](https://www.rabbitmq.com/tutorials)
 * [AMQP 0-9-1 Model Explained](https://www.rabbitmq.com/tutorials/amqp-concepts.html)

### RabbitMQ Documentation

 * [Connections](https://www.rabbitmq.com/docs/connections)
 * [Channels](https://www.rabbitmq.com/docs/channels)
 * [Queues](https://www.rabbitmq.com/docs/queues)
 * [Quorum Queues](https://www.rabbitmq.com/docs/quorum-queues)
 * [Streams](https://www.rabbitmq.com/docs/streams)
 * [Publishers](https://www.rabbitmq.com/docs/publishers)
 * [Consumers](https://www.rabbitmq.com/docs/consumers)
 * [Publisher and Consumer Confirmations](https://www.rabbitmq.com/docs/confirms)
 * [TLS guide](https://www.rabbitmq.com/docs/ssl)


## Community and Getting Help

 * [GitHub Discussions](https://github.com/rabbitmq/bunny-swift/discussions)
 * [RabbitMQ Discord](https://rabbitmq.com/discord)
 * [RabbitMQ Mailing List](https://groups.google.com/forum/#!forum/rabbitmq-users)


## Reporting Issues

Please use [GitHub Discussions](https://github.com/rabbitmq/bunny-swift/discussions) unless
you have an executable, repeatable way to reproduce the reported behavior.


## License

This library is dual-licensed under the Apache Software License 2.0 and the MIT license.

SPDX-License-Identifier: Apache-2.0 OR MIT

Copyright (c) 2025-2026 Michael S. Klishin
