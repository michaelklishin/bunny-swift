## 0.13.0 (in development)

No changes yet.


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
