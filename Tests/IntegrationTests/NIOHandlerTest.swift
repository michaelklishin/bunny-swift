// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Minimal NIO handler test to isolate the issue

import Testing
import Foundation
import NIO
import AMQPProtocol
@testable import Transport

// A simple handler that just uses ByteBuffer (no cross-module types)
final class SimpleByteHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

// A handler that uses Frame from AMQPProtocol
final class SimpleFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Frame
    typealias InboundOut = Frame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

// Test ByteToMessageDecoder
final class TestDecoder: ByteToMessageDecoder, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Frame

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        return .needMoreData
    }
}

// Test MessageToByteEncoder
final class TestEncoder: MessageToByteEncoder, @unchecked Sendable {
    typealias OutboundIn = Frame
    typealias OutboundOut = ByteBuffer

    func encode(data: Frame, out: inout ByteBuffer) throws {
        // Just write something
        out.writeBytes([0x00])
    }
}

@Suite("NIO Handler Debug Tests")
struct NIOHandlerDebugTests {

    @Test("Simple byte handler works")
    func simpleByteHandler() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(SimpleByteHandler())
            }
            .connect(host: "localhost", port: 5672)
            .get()

        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("Frame handler works")
    func frameHandler() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(SimpleFrameHandler())
            }
            .connect(host: "localhost", port: 5672)
            .get()

        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("ByteToMessageDecoder works")
    func decoderHandler() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(TestDecoder()))
            }
            .connect(host: "localhost", port: 5672)
            .get()

        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("MessageToByteEncoder works")
    func encoderHandler() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(MessageToByteHandler(TestEncoder()))
            }
            .connect(host: "localhost", port: 5672)
            .get()

        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("Combined decoder and encoder works")
    func combinedHandlers() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(TestDecoder())).flatMap {
                    channel.pipeline.addHandler(MessageToByteHandler(TestEncoder()))
                }
            }
            .connect(host: "localhost", port: 5672)
            .get()

        try await channel.close()
        try await group.shutdownGracefully()
    }

    @Test("Full AMQP pipeline with protocol header")
    func fullAMQPPipeline() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // Create a stream to receive frames
        let (stream, continuation) = AsyncStream<Frame>.makeStream()

        // Test with a simple pass-through outbound handler
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(AMQPFrameDecoder())).flatMap {
                    channel.pipeline.addHandler(PassThroughOutboundHandler())
                }.flatMap {
                    channel.pipeline.addHandler(TestFrameForwarder(continuation: continuation))
                }
            }
            .connect(host: "localhost", port: 5672)
            .get()

        // Send protocol header as raw bytes (no encoder needed)
        let protocolHeader = Data([0x41, 0x4D, 0x51, 0x50, 0x00, 0x00, 0x09, 0x01])
        var buffer = channel.allocator.buffer(capacity: 8)
        buffer.writeBytes(protocolHeader)
        try await channel.writeAndFlush(buffer)

        // Wait for Connection.Start
        var iterator = stream.makeAsyncIterator()
        let frame = await iterator.next()

        // We should get Connection.Start
        #expect(frame != nil)
        if case .method(channelID: 0, method: .connectionStart) = frame {
            // Good!
        } else {
            Issue.record("Expected Connection.Start, got \(String(describing: frame))")
        }

        try await channel.close()
        continuation.finish()
        try await group.shutdownGracefully()
    }
}

// Simple pass-through outbound handler for testing
private final class PassThroughOutboundHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Just pass through
        context.write(data, promise: promise)
    }
}

// Test frame forwarder
private final class TestFrameForwarder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Frame

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
    }
}
