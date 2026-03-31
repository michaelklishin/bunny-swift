// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import AMQPProtocol
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSL

/// Shared EventLoopGroup for all connections to reduce thread overhead
public enum SharedEventLoopGroup {
  private static let _shared = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

  /// Shared EventLoopGroup using System.coreCount threads
  public static var shared: EventLoopGroup { _shared }
}

/// Exposes an AsyncStream<Frame> iterator as a Sendable reference type.
/// Thread-safe only when accessed by a single reader at a time.
public final class FrameIterator: @unchecked Sendable {
  private var iterator: AsyncStream<Frame>.AsyncIterator

  init(_ iterator: AsyncStream<Frame>.AsyncIterator) {
    self.iterator = iterator
  }

  public func next() async -> Frame? {
    await iterator.next()
  }
}

private struct PipelineInitializer: @unchecked Sendable {
  let frameMax: UInt32
  let sslContext: NIOSSLContext?
  let hostname: String
  let continuation: AsyncStream<Frame>.Continuation

  func initialize(_ channel: NIO.Channel) -> EventLoopFuture<Void> {
    var future = channel.eventLoop.makeSucceededVoidFuture()

    if let sslContext = sslContext {
      do {
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)
        future = channel.pipeline.addHandler(sslHandler)
      } catch {
        return channel.eventLoop.makeFailedFuture(error)
      }
    }

    return future.flatMap {
      channel.pipeline.addHandler(
        ByteToMessageHandler(AMQPFrameDecoder(maxFrameSize: self.frameMax)))
    }.flatMap {
      channel.pipeline.addHandler(FrameForwardingHandler(continuation: self.continuation))
    }
  }
}

public actor AMQPTransport {
  private let eventLoopGroup: EventLoopGroup
  private let ownsEventLoopGroup: Bool
  private var channel: Channel?
  private var frameStream: AsyncStream<Frame>?
  private var frameIterator: FrameIterator?
  private var frameContinuation: AsyncStream<Frame>.Continuation?
  private var isConnected = false
  private var negotiatedParams: NegotiatedParameters?
  private let codec: FrameCodec

  private var pendingWrites: Int = 0
  private var flushThreshold: Int = 512
  private var scheduledFlush: Scheduled<Void>?
  private var flushInterval: TimeAmount = .milliseconds(5)

  public init(eventLoopGroup: EventLoopGroup? = nil) {
    if let group = eventLoopGroup {
      self.eventLoopGroup = group
      self.ownsEventLoopGroup = false
    } else {
      self.eventLoopGroup = SharedEventLoopGroup.shared
      self.ownsEventLoopGroup = false
    }
    self.codec = FrameCodec()
  }

  deinit {
    if ownsEventLoopGroup {
      try? eventLoopGroup.syncShutdownGracefully()
    }
  }

  public func connect(configuration: ConnectionConfiguration) async throws -> NegotiatedParameters {
    guard !isConnected else {
      throw ConnectionError.alreadyConnected
    }

    // Apply write buffer configuration
    self.flushThreshold = configuration.writeBufferFlushThreshold
    self.flushInterval = configuration.writeBufferFlushInterval

    let (stream, continuation) = AsyncStream<Frame>.makeStream()
    self.frameStream = stream
    self.frameIterator = FrameIterator(stream.makeAsyncIterator())
    self.frameContinuation = continuation

    do {
      let channel = try await createChannel(
        configuration: configuration, continuation: continuation)
      self.channel = channel
      self.isConnected = true

      let params = try await performHandshake(configuration: configuration)
      self.negotiatedParams = params
      return params
    } catch {
      await close()
      throw ConnectionError.connectionFailed(underlying: error)
    }
  }

  private func createChannel(
    configuration: ConnectionConfiguration,
    continuation: AsyncStream<Frame>.Continuation
  ) async throws -> Channel {
    let sslContext: NIOSSLContext? =
      if let tlsConfig = configuration.tls {
        try NIOSSLContext(configuration: tlsConfig.toNIOSSLConfiguration())
      } else {
        nil
      }

    let initializer = PipelineInitializer(
      frameMax: configuration.frameMax,
      sslContext: sslContext,
      hostname: configuration.host,
      continuation: continuation
    )

    let promise = eventLoopGroup.next().makePromise(of: Channel.self)

    var bootstrap = ClientBootstrap(group: eventLoopGroup)
      .channelOption(.socketOption(.so_reuseaddr), value: 1)
      .connectTimeout(configuration.connectionTimeout)
      .channelInitializer(initializer.initialize)

    if configuration.enableTCPKeepAlive {
      bootstrap = bootstrap.channelOption(.socketOption(.so_keepalive), value: 1)
    }
    if configuration.enableTCPNoDelay {
      // TCP_NODELAY is a TCP-level socket option (SOL_TCP/IPPROTO_TCP), not a SOL_SOCKET option.
      bootstrap = bootstrap.channelOption(.tcpOption(.tcp_nodelay), value: 1)
    }

    bootstrap.connect(host: configuration.host, port: configuration.port).cascade(to: promise)

    return try await promise.futureResult.get()
  }

  private func performHandshake(configuration: ConnectionConfiguration) async throws
    -> NegotiatedParameters
  {
    guard let channel = channel else {
      throw ConnectionError.notConnected
    }

    var header = channel.allocator.buffer(capacity: 8)
    header.writeBytes(amqpProtocolHeader)
    try await writeRaw(header)

    guard let startFrame = await nextFrame(),
      case .method(channelID: 0, method: .connectionStart(let start)) = startFrame
    else {
      throw ConnectionError.protocolError("Expected Connection.Start")
    }

    var clientProperties: Table = [
      "product": .string("Bunny.Swift"),
      "platform": .string("Swift"),
      "version": .string("0.11.0-dev"),
      "capabilities": .table([
        "publisher_confirms": true,
        "consumer_cancel_notify": true,
        "exchange_exchange_bindings": true,
        "basic.nack": true,
        "connection.blocked": true,
        "authentication_failure_close": true,
      ]),
    ]
    if let name = configuration.connectionName {
      clientProperties["connection_name"] = .string(name)
    }

    let startOk = ConnectionStartOk.plainAuth(
      username: configuration.username,
      password: configuration.password,
      clientProperties: clientProperties
    )
    try await sendRaw(.method(channelID: 0, method: .connectionStartOk(startOk)))

    guard let tuneFrame = await nextFrame(),
      case .method(channelID: 0, method: .connectionTune(let tune)) = tuneFrame
    else {
      throw ConnectionError.protocolError("Expected Connection.Tune")
    }

    let channelMax = negotiatedMaxValue(configuration.channelMax, tune.channelMax)
    let frameMax = negotiatedMaxValue(configuration.frameMax, tune.frameMax)
    let heartbeat = negotiatedMaxValue(configuration.heartbeat, tune.heartbeat)

    let tuneOk = ConnectionTuneOk(channelMax: channelMax, frameMax: frameMax, heartbeat: heartbeat)
    try await sendRaw(.method(channelID: 0, method: .connectionTuneOk(tuneOk)))

    let open = ConnectionOpen(virtualHost: configuration.virtualHost)
    try await sendRaw(.method(channelID: 0, method: .connectionOpen(open)))

    guard let openOkFrame = await nextFrame() else {
      throw ConnectionError.protocolError("Connection closed during handshake")
    }

    switch openOkFrame {
    case .method(channelID: 0, method: .connectionOpenOk):
      break
    case .method(channelID: 0, method: .connectionClose(let close)):
      throw ConnectionError.authenticationFailed(
        username: configuration.username,
        vhost: configuration.virtualHost,
        reason: close.replyText
      )
    default:
      throw ConnectionError.protocolError("Expected Connection.OpenOk, got \(openOkFrame)")
    }

    try await installEncoder(frameMax: frameMax)

    if heartbeat > 0 {
      try await setupHeartbeat(interval: heartbeat)
    }

    return NegotiatedParameters(
      channelMax: channelMax,
      frameMax: frameMax,
      heartbeat: heartbeat,
      serverProperties: start.serverProperties
    )
  }

  private func writeRaw(_ buffer: ByteBuffer) async throws {
    guard let channel = channel else {
      throw ConnectionError.notConnected
    }
    try await channel.writeAndFlush(buffer).get()
  }

  private func sendRaw(_ frame: Frame) async throws {
    guard let channel = channel else {
      throw ConnectionError.notConnected
    }
    let encoded = try codec.encode(frame)
    var buffer = channel.allocator.buffer(capacity: encoded.count)
    buffer.writeBytes(encoded)
    try await writeRaw(buffer)
  }

  private func installEncoder(frameMax: UInt32) async throws {
    guard let channel = channel else {
      throw ConnectionError.notConnected
    }
    let encoder = AMQPFrameEncoder(maxFrameSize: frameMax)
    // Must sit before the forwarding handler so outbound frames are
    // encoded to ByteBuffer before reaching the TLS handler.
    let anchor = try await channel.pipeline.handler(type: FrameForwardingHandler.self).get()
    try await channel.pipeline.addHandler(encoder, position: .before(anchor)).get()
  }

  private func setupHeartbeat(interval: UInt16) async throws {
    guard let channel = channel else { return }

    let handler = HeartbeatHandler(interval: interval) { [weak self] in
      Task { [weak self] in
        await self?.handleHeartbeatTimeout()
      }
    }
    // Must sit before the forwarding handler to see inbound frames.
    let anchor = try await channel.pipeline.handler(type: FrameForwardingHandler.self).get()
    try await channel.pipeline.addHandler(handler, name: "heartbeat", position: .before(anchor))
      .get()
  }

  private func handleHeartbeatTimeout() {
    frameContinuation?.finish()
  }

  /// Sends frame with immediate flush for RPC operations
  public func send(_ frame: Frame) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }
    try await channel.writeAndFlush(AMQPOutboundData.frame(frame)).get()
  }

  /// Buffers frame; auto-flushes at threshold or timer
  public func write(_ frame: Frame) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }
    channel.write(AMQPOutboundData.frame(frame), promise: nil)
    pendingWrites += 1
    maybeFlush(channel: channel)
  }

  public func writeBatch(_ frames: [Frame]) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }
    for frame in frames {
      channel.write(AMQPOutboundData.frame(frame), promise: nil)
    }
    pendingWrites += frames.count
    maybeFlush(channel: channel)
  }

  /// Encodes method + header + body into a single ByteBuffer and buffers the write.
  /// Bypasses the per-frame encoder pipeline for maximum publish throughput.
  public func writePublish(
    channelID: UInt16,
    exchange: String,
    routingKey: String,
    mandatory: Bool,
    immediate: Bool,
    properties: BasicProperties,
    body: Data,
    frameMax: UInt32
  ) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }

    let maxBodySize = Int(frameMax) - 8
    let methodSize = 14 + exchange.utf8.count + routingKey.utf8.count + 9
    // Frame overhead + fixed header fields + properties estimate
    let headerSize = 8 + 12 + 64 + 1
    let bodyOverhead = body.isEmpty ? 0 : ((body.count + maxBodySize - 1) / maxBodySize) * 9
    var buffer = channel.allocator.buffer(
      capacity: methodSize + headerSize + body.count + bodyOverhead)

    // BasicPublish method frame
    let exchangeBytes = exchange.utf8
    let routingKeyBytes = routingKey.utf8
    let methodPayloadSize = 2 + 2 + 2 + 1 + exchangeBytes.count + 1 + routingKeyBytes.count + 1
    buffer.writeInteger(FrameType.method.rawValue)
    buffer.writeInteger(channelID, endianness: .big)
    buffer.writeInteger(UInt32(methodPayloadSize), endianness: .big)
    // Basic class (60), Publish method (40)
    buffer.writeInteger(UInt16(60), endianness: .big)
    buffer.writeInteger(UInt16(40), endianness: .big)
    // reserved1
    buffer.writeInteger(UInt16(0), endianness: .big)
    buffer.writeInteger(UInt8(exchangeBytes.count))
    buffer.writeBytes(exchangeBytes)
    buffer.writeInteger(UInt8(routingKeyBytes.count))
    buffer.writeBytes(routingKeyBytes)
    var flags: UInt8 = 0
    if mandatory { flags |= 0x01 }
    if immediate { flags |= 0x02 }
    buffer.writeInteger(flags)
    buffer.writeInteger(frameEnd)

    // Content header frame
    var propsEncoder = WireEncoder()
    try properties.encode(to: &propsEncoder)
    let propsData = propsEncoder.encodedData
    let headerPayloadSize = 2 + 2 + 8 + propsData.count
    buffer.writeInteger(FrameType.header.rawValue)
    buffer.writeInteger(channelID, endianness: .big)
    buffer.writeInteger(UInt32(headerPayloadSize), endianness: .big)
    buffer.writeInteger(ClassID.basic.rawValue, endianness: .big)
    // weight (reserved)
    buffer.writeInteger(UInt16(0), endianness: .big)
    buffer.writeInteger(UInt64(body.count), endianness: .big)
    buffer.writeContiguousBytes(propsData)
    buffer.writeInteger(frameEnd)

    // Encode body frame(s)
    if !body.isEmpty {
      if body.count <= maxBodySize {
        buffer.writeInteger(FrameType.body.rawValue)
        buffer.writeInteger(channelID, endianness: .big)
        buffer.writeInteger(UInt32(body.count), endianness: .big)
        buffer.writeContiguousBytes(body)
        buffer.writeInteger(frameEnd)
      } else {
        var offset = 0
        while offset < body.count {
          let end = min(offset + maxBodySize, body.count)
          let chunk = body[offset..<end]
          buffer.writeInteger(FrameType.body.rawValue)
          buffer.writeInteger(channelID, endianness: .big)
          buffer.writeInteger(UInt32(chunk.count), endianness: .big)
          buffer.writeContiguousBytes(chunk)
          buffer.writeInteger(frameEnd)
          offset = end
        }
      }
    }

    channel.write(AMQPOutboundData.encoded(buffer), promise: nil)
    pendingWrites += 1
    maybeFlush(channel: channel)
  }

  /// Encodes all messages into a single ByteBuffer and issues one NIO write.
  /// The shared exchange, routing key, mandatory flag, and properties are applied
  /// to every message in the batch.
  public func writePublishBatch(
    channelID: UInt16,
    exchange: String,
    routingKey: String,
    mandatory: Bool,
    properties: BasicProperties,
    bodies: [Data],
    frameMax: UInt32
  ) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }
    guard !bodies.isEmpty else { return }

    let maxBodySize = Int(frameMax) - 8
    let exchangeBytes = Array(exchange.utf8)
    let routingKeyBytes = Array(routingKey.utf8)
    let methodPayloadSize = 2 + 2 + 2 + 1 + exchangeBytes.count + 1 + routingKeyBytes.count + 1
    // Method frame overhead: 7 (type + channel + size) + payload + 1 (frame-end)
    let methodFrameSize = 8 + methodPayloadSize

    // Pre-encode properties once for the entire batch
    var propsEncoder = WireEncoder()
    try properties.encode(to: &propsEncoder)
    let propsData = propsEncoder.encodedData
    let headerPayloadSize = 2 + 2 + 8 + propsData.count
    // Header frame overhead: 7 + payload + 1
    let headerFrameSize = 8 + headerPayloadSize

    var flags: UInt8 = 0
    if mandatory { flags |= 0x01 }

    // Estimate total buffer size
    var totalSize = 0
    for body in bodies {
      totalSize += methodFrameSize + headerFrameSize
      if !body.isEmpty {
        let bodyFrameCount = (body.count + maxBodySize - 1) / maxBodySize
        totalSize += body.count + bodyFrameCount * 9
      }
    }

    var buffer = channel.allocator.buffer(capacity: totalSize)

    for body in bodies {
      // BasicPublish method frame
      buffer.writeInteger(FrameType.method.rawValue)
      buffer.writeInteger(channelID, endianness: .big)
      buffer.writeInteger(UInt32(methodPayloadSize), endianness: .big)
      buffer.writeInteger(UInt16(60), endianness: .big)
      buffer.writeInteger(UInt16(40), endianness: .big)
      buffer.writeInteger(UInt16(0), endianness: .big)
      buffer.writeInteger(UInt8(exchangeBytes.count))
      buffer.writeBytes(exchangeBytes)
      buffer.writeInteger(UInt8(routingKeyBytes.count))
      buffer.writeBytes(routingKeyBytes)
      buffer.writeInteger(flags)
      buffer.writeInteger(frameEnd)

      // Content header frame (properties are shared, only body size differs)
      buffer.writeInteger(FrameType.header.rawValue)
      buffer.writeInteger(channelID, endianness: .big)
      buffer.writeInteger(UInt32(headerPayloadSize), endianness: .big)
      buffer.writeInteger(ClassID.basic.rawValue, endianness: .big)
      buffer.writeInteger(UInt16(0), endianness: .big)
      buffer.writeInteger(UInt64(body.count), endianness: .big)
      buffer.writeContiguousBytes(propsData)
      buffer.writeInteger(frameEnd)

      // Body frame(s)
      if !body.isEmpty {
        if body.count <= maxBodySize {
          buffer.writeInteger(FrameType.body.rawValue)
          buffer.writeInteger(channelID, endianness: .big)
          buffer.writeInteger(UInt32(body.count), endianness: .big)
          buffer.writeContiguousBytes(body)
          buffer.writeInteger(frameEnd)
        } else {
          var offset = 0
          while offset < body.count {
            let end = min(offset + maxBodySize, body.count)
            let chunk = body[offset..<end]
            buffer.writeInteger(FrameType.body.rawValue)
            buffer.writeInteger(channelID, endianness: .big)
            buffer.writeInteger(UInt32(chunk.count), endianness: .big)
            buffer.writeContiguousBytes(chunk)
            buffer.writeInteger(frameEnd)
            offset = end
          }
        }
      }
    }

    channel.write(AMQPOutboundData.encoded(buffer), promise: nil)
    pendingWrites += bodies.count
    maybeFlush(channel: channel)
  }

  public func flush() async {
    guard let channel = channel, pendingWrites > 0 else { return }
    doFlush(channel: channel)
  }

  private func maybeFlush(channel: Channel) {
    if pendingWrites >= flushThreshold {
      doFlush(channel: channel)
    } else if scheduledFlush == nil {
      scheduleFlush(channel: channel)
    }
  }

  private func doFlush(channel: Channel) {
    channel.flush()
    pendingWrites = 0
    scheduledFlush?.cancel()
    scheduledFlush = nil
  }

  private func scheduleFlush(channel: Channel) {
    scheduledFlush = channel.eventLoop.scheduleTask(in: flushInterval) { @Sendable [weak self] in
      guard let self = self else { return }
      Task { await self.flush() }
    }
  }

  /// Returns the frame iterator for the caller to drive frame dispatch.
  /// The Transport gives up its reference; only one reader may exist at a time.
  public func handoffFrameIterator() -> FrameIterator? {
    let iter = frameIterator
    frameIterator = nil
    return iter
  }

  public func markDisconnected() {
    isConnected = false
    scheduledFlush?.cancel()
    scheduledFlush = nil
  }

  /// Resets internal state.
  /// Must be called before calling `connect` or after a connection failure.
  public func resetForRecovery() async {
    scheduledFlush?.cancel()
    scheduledFlush = nil
    frameContinuation?.finish()
    frameIterator = nil
    frameStream = nil
    if let channel = channel {
      try? await channel.close().get()
      self.channel = nil
    }
    isConnected = false
    negotiatedParams = nil
    pendingWrites = 0
  }

  private func nextFrame() async -> Frame? {
    await frameIterator?.next()
  }

  public func close() async {
    scheduledFlush?.cancel()
    scheduledFlush = nil

    guard isConnected, let channel = channel else {
      frameContinuation?.finish()
      return
    }

    isConnected = false

    let close = ConnectionClose(replyCode: 200, replyText: "Normal shutdown")
    try? await send(.method(channelID: 0, method: .connectionClose(close)))

    // Brief grace period for the server to process ConnectionClose
    try? await Task.sleep(for: .milliseconds(100))

    frameContinuation?.finish()
    try? await channel.close().get()
    self.channel = nil
    self.frameIterator = nil
    self.frameStream = nil
  }

  public func forceClose() async {
    isConnected = false
    scheduledFlush?.cancel()
    scheduledFlush = nil
    frameContinuation?.finish()
    frameIterator = nil
    frameStream = nil
    if let channel = channel {
      try? await channel.close().get()
      self.channel = nil
    }
  }

  public var connected: Bool { isConnected }
  public var parameters: NegotiatedParameters? { negotiatedParams }
}

private final class FrameForwardingHandler: ChannelInboundHandler, RemovableChannelHandler,
  @unchecked Sendable
{
  typealias InboundIn = Frame
  typealias InboundOut = Never

  private let continuation: AsyncStream<Frame>.Continuation

  init(continuation: AsyncStream<Frame>.Continuation) {
    self.continuation = continuation
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    continuation.yield(frame)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    continuation.finish()
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    continuation.finish()
  }
}
