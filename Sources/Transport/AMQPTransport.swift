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

/// Wraps AsyncIterator for actor-isolated access (@unchecked since only accessed within actor)
private final class IteratorBox<Element>: @unchecked Sendable {
  var iterator: AsyncStream<Element>.AsyncIterator

  init(_ iterator: AsyncStream<Element>.AsyncIterator) {
    self.iterator = iterator
  }

  func next() async -> Element? {
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
  private var frameIterator: IteratorBox<Frame>?
  private var frameContinuation: AsyncStream<Frame>.Continuation?
  private var frameHandler: (@Sendable (Frame) async -> Void)?
  private var frameDispatchTask: Task<Void, Never>?
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
    self.frameIterator = IteratorBox(stream.makeAsyncIterator())
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

    // Work around environments that reject client-side TCP_NODELAY setsockopt with EPERM.
    // ClientBootstrap enables TCP_NODELAY by default; toggling MPTCP on and back off
    // removes the default TCP_NODELAY option while keeping MPTCP disabled.
    var bootstrap = ClientBootstrap(group: eventLoopGroup)
      .enableMPTCP(true)
      .enableMPTCP(false)
      .connectTimeout(configuration.connectionTimeout)
      .channelInitializer(initializer.initialize)

    if configuration.enableTCPKeepAlive {
      // Intentionally skipped: some deployment environments reject client socket option
      // sets with EPERM, which prevents RabbitMQ connections from establishing.
    }
    if configuration.enableTCPNoDelay {
      // Intentionally skipped: ClientBootstrap's default TCP_NODELAY is also disabled above.
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
      "version": .string("0.10.0"),
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

    let channelMax = min(
      configuration.channelMax, tune.channelMax == 0 ? UInt16.max : tune.channelMax)
    let frameMax = min(configuration.frameMax, tune.frameMax == 0 ? UInt32.max : tune.frameMax)
    let heartbeat = min(configuration.heartbeat, tune.heartbeat)

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
    try await channel.writeAndFlush(frame).get()
  }

  /// Buffers frame; auto-flushes at threshold or timer
  public func write(_ frame: Frame) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }
    channel.write(frame, promise: nil)
    pendingWrites += 1
    maybeFlush(channel: channel)
  }

  public func writeBatch(_ frames: [Frame]) async throws {
    guard let channel = channel, isConnected else {
      throw ConnectionError.notConnected
    }
    for frame in frames {
      channel.write(frame, promise: nil)
    }
    pendingWrites += frames.count
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

  public func setFrameHandler(_ handler: @escaping @Sendable (Frame) async -> Void) {
    self.frameHandler = handler
    startFrameDispatcher()
  }

  private func startFrameDispatcher() {
    frameDispatchTask = Task { [weak self] in
      while let self = self {
        guard let frame = await self.nextFrame() else { break }
        if let handler = await self.frameHandler {
          await handler(frame)
        }
      }
    }
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
    frameDispatchTask?.cancel()
    frameDispatchTask = nil

    let close = ConnectionClose(replyCode: 200, replyText: "Normal shutdown")
    try? await send(.method(channelID: 0, method: .connectionClose(close)))

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = await self.nextFrame()
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      _ = await group.next()
      group.cancelAll()
    }

    try? await channel.close().get()
    self.channel = nil
    self.frameIterator = nil
    self.frameStream = nil
    frameContinuation?.finish()
  }

  public func forceClose() async {
    isConnected = false
    scheduledFlush?.cancel()
    scheduledFlush = nil
    frameDispatchTask?.cancel()
    frameDispatchTask = nil
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
