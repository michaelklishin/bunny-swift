// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import NIO
import NIOFoundationCompat
import NIOSSL
import AMQPProtocol

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

/// Encoder added after handshake to avoid type conflicts with raw ByteBuffer writes
private struct PlainChannelInitializer: @unchecked Sendable {
    let frameMax: UInt32
    let continuation: AsyncStream<Frame>.Continuation

    func initialize(_ channel: NIO.Channel) -> EventLoopFuture<Void> {
        channel.pipeline.addHandler(ByteToMessageHandler(AMQPFrameDecoder(maxFrameSize: frameMax))).flatMap {
            channel.pipeline.addHandler(FrameForwardingHandler(continuation: self.continuation))
        }
    }
}

private struct TLSChannelInitializer: @unchecked Sendable {
    let frameMax: UInt32
    let sslContext: NIOSSLContext
    let hostname: String
    let continuation: AsyncStream<Frame>.Continuation

    func initialize(_ channel: NIO.Channel) -> EventLoopFuture<Void> {
        do {
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)
            return channel.pipeline.addHandler(sslHandler).flatMap {
                channel.pipeline.addHandler(ByteToMessageHandler(AMQPFrameDecoder(maxFrameSize: self.frameMax)))
            }.flatMap {
                channel.pipeline.addHandler(FrameForwardingHandler(continuation: self.continuation))
            }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
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
            let channel = try await createChannel(configuration: configuration, continuation: continuation)
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
        let frameMax = configuration.frameMax
        let host = configuration.host
        let port = configuration.port

        if let tlsConfig = configuration.tls {
            return try await createTLSChannel(
                host: host,
                port: port,
                frameMax: frameMax,
                tlsConfig: tlsConfig,
                timeout: configuration.connectionTimeout,
                continuation: continuation
            )
        } else {
            return try await createPlainChannel(
                host: host,
                port: port,
                frameMax: frameMax,
                timeout: configuration.connectionTimeout,
                continuation: continuation
            )
        }
    }

    private func createPlainChannel(
        host: String,
        port: Int,
        frameMax: UInt32,
        timeout: TimeAmount,
        continuation: AsyncStream<Frame>.Continuation
    ) async throws -> Channel {
        let promise = eventLoopGroup.next().makePromise(of: Channel.self)
        let initializer = PlainChannelInitializer(frameMax: frameMax, continuation: continuation)

        ClientBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(timeout)
            .channelInitializer(initializer.initialize)
            .connect(host: host, port: port)
            .cascade(to: promise)

        return try await promise.futureResult.get()
    }

    private func createTLSChannel(
        host: String,
        port: Int,
        frameMax: UInt32,
        tlsConfig: TLSConfiguration,
        timeout: TimeAmount,
        continuation: AsyncStream<Frame>.Continuation
    ) async throws -> Channel {
        let sslContext = try NIOSSLContext(configuration: tlsConfig.toNIOSSLConfiguration())
        let promise = eventLoopGroup.next().makePromise(of: Channel.self)
        let initializer = TLSChannelInitializer(
            frameMax: frameMax,
            sslContext: sslContext,
            hostname: host,
            continuation: continuation
        )

        ClientBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(timeout)
            .channelInitializer(initializer.initialize)
            .connect(host: host, port: port)
            .cascade(to: promise)

        return try await promise.futureResult.get()
    }

    private func performHandshake(configuration: ConnectionConfiguration) async throws -> NegotiatedParameters {
        guard let channel = channel else {
            throw ConnectionError.notConnected
        }

        var header = channel.allocator.buffer(capacity: 8)
        header.writeBytes(amqpProtocolHeader)
        try await writeRaw(header)

        guard let startFrame = await nextFrame(),
              case .method(channelID: 0, method: .connectionStart(let start)) = startFrame else {
            throw ConnectionError.protocolError("Expected Connection.Start")
        }

        var clientProperties: Table = [
            "product": .string("Bunny.Swift"),
            "platform": .string("Swift"),
            "version": .string("0.10.0-dev"),
            "capabilities": .table([
                "publisher_confirms": true,
                "consumer_cancel_notify": true,
                "exchange_exchange_bindings": true,
                "basic.nack": true,
                "connection.blocked": true,
                "authentication_failure_close": true
            ])
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
              case .method(channelID: 0, method: .connectionTune(let tune)) = tuneFrame else {
            throw ConnectionError.protocolError("Expected Connection.Tune")
        }

        let channelMax = min(configuration.channelMax, tune.channelMax == 0 ? UInt16.max : tune.channelMax)
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
        try await channel.pipeline.addHandler(encoder, position: .first).get()
    }

    private func setupHeartbeat(interval: UInt16) async throws {
        guard let channel = channel else { return }

        let handler = HeartbeatHandler(interval: interval) { [weak self] in
            Task { [weak self] in
                await self?.handleHeartbeatTimeout()
            }
        }
        try await channel.pipeline.addHandler(handler, name: "heartbeat").get()
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

private final class FrameForwardingHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
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
