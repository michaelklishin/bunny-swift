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

final class AMQPFrameDecoder: ByteToMessageDecoder, RemovableChannelHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = Frame

  private let maxFrameSize: UInt32
  private let codec = FrameCodec()

  init(maxFrameSize: UInt32 = FrameDefaults.maxSize) {
    self.maxFrameSize = maxFrameSize
  }

  func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    while buffer.readableBytes >= FrameDefaults.headerSize + 1 {
      guard let frame = try decodeFrame(from: &buffer) else {
        return .needMoreData
      }
      context.fireChannelRead(wrapInboundOut(frame))
    }
    return .needMoreData
  }

  private func decodeFrame(from buffer: inout ByteBuffer) throws -> Frame? {
    let readerIndex = buffer.readerIndex

    guard let frameType = buffer.readInteger(as: UInt8.self),
      let channelID = buffer.readInteger(endianness: .big, as: UInt16.self),
      let payloadSize = buffer.readInteger(endianness: .big, as: UInt32.self)
    else {
      buffer.moveReaderIndex(to: readerIndex)
      return nil
    }

    // Validate payload size against max frame size
    let maxPayload = maxFrameSize - UInt32(FrameDefaults.headerSize) - 1
    guard payloadSize <= maxPayload else {
      throw WireFormatError.frameTooLarge(size: payloadSize, maxSize: maxFrameSize)
    }

    guard buffer.readableBytes >= Int(payloadSize) + 1 else {
      buffer.moveReaderIndex(to: readerIndex)
      return nil
    }

    guard let payload = buffer.readSlice(length: Int(payloadSize)),
      let frameEnd = buffer.readInteger(as: UInt8.self)
    else {
      buffer.moveReaderIndex(to: readerIndex)
      return nil
    }

    guard frameEnd == AMQPProtocol.frameEnd else {
      throw WireFormatError.invalidFrameEnd(expected: AMQPProtocol.frameEnd, actual: frameEnd)
    }

    return try parseFrame(type: frameType, channelID: channelID, payload: payload)
  }

  private func parseFrame(type: UInt8, channelID: UInt16, payload: ByteBuffer) throws -> Frame {
    guard let frameType = FrameType(rawValue: type) else {
      throw WireFormatError.unknownFrameType(type)
    }

    switch frameType {
    case .method:
      return try parseMethodFrame(channelID: channelID, payload: payload)

    case .header:
      var buf = payload
      guard let classID = buf.readInteger(endianness: .big, as: UInt16.self),
        buf.readInteger(endianness: .big, as: UInt16.self) != nil,  // weight (reserved)
        let bodySize = buf.readInteger(endianness: .big, as: UInt64.self)
      else {
        throw WireFormatError.insufficientData(needed: 12, available: payload.readableBytes)
      }
      let propsBytes = buf.readableBytes
      let propsData = buf.readData(length: propsBytes) ?? Data()
      var decoder = propsData.wireDecoder()
      let properties = try BasicProperties.decode(from: &decoder)
      return .header(
        channelID: channelID, classID: classID, bodySize: bodySize, properties: properties)

    case .body:
      var buf = payload
      let bodyData = buf.readData(length: buf.readableBytes) ?? Data()
      return .body(channelID: channelID, payload: bodyData)

    case .heartbeat:
      return .heartbeat
    }
  }

  /// Decode method frames with a fast path for BasicDeliver, the hottest
  /// inbound method on the consumer path.
  private func parseMethodFrame(channelID: UInt16, payload: ByteBuffer) throws -> Frame {
    var buf = payload
    guard let classID = buf.readInteger(endianness: .big, as: UInt16.self),
      let methodID = buf.readInteger(endianness: .big, as: UInt16.self)
    else {
      throw WireFormatError.insufficientData(needed: 4, available: payload.readableBytes)
    }

    // Fast path: Basic.Deliver (class 60, method 60)
    if classID == 60 && methodID == 60 {
      return try .method(
        channelID: channelID,
        method: .basicDeliver(decodeBasicDeliver(from: &buf)))
    }

    // All other methods go through the generic codec
    let data = Data(buffer: payload)
    let method = try codec.decodeMethod(from: data)
    return .method(channelID: channelID, method: method)
  }

  /// Decode Basic.Deliver fields directly from ByteBuffer, avoiding
  /// a ByteBuffer→Data copy and the WireDecoder intermediary.
  private func decodeBasicDeliver(from buf: inout ByteBuffer) throws -> BasicDeliver {
    // Consumer tag (short string)
    guard let tagLen = buf.readInteger(as: UInt8.self),
      let consumerTag = buf.readString(length: Int(tagLen))
    else {
      throw WireFormatError.insufficientData(needed: 1, available: buf.readableBytes)
    }

    // Delivery tag (uint64) + flags byte (redelivered)
    guard let deliveryTag = buf.readInteger(endianness: .big, as: UInt64.self),
      let flagsByte = buf.readInteger(as: UInt8.self)
    else {
      throw WireFormatError.insufficientData(needed: 9, available: buf.readableBytes)
    }
    let redelivered = (flagsByte & 0x01) != 0

    // Exchange (short string)
    guard let exchLen = buf.readInteger(as: UInt8.self),
      let exchange = buf.readString(length: Int(exchLen))
    else {
      throw WireFormatError.insufficientData(needed: 1, available: buf.readableBytes)
    }

    // Routing key (short string)
    guard let rkLen = buf.readInteger(as: UInt8.self),
      let routingKey = buf.readString(length: Int(rkLen))
    else {
      throw WireFormatError.insufficientData(needed: 1, available: buf.readableBytes)
    }

    return BasicDeliver(
      consumerTag: consumerTag,
      deliveryTag: deliveryTag,
      redelivered: redelivered,
      exchange: exchange,
      routingKey: routingKey
    )
  }

  func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws
    -> DecodingState
  {
    try decode(context: context, buffer: &buffer)
  }
}

// MARK: - Outbound Data

/// Wrapper for outbound data: either an AMQP frame to encode or a pre-encoded buffer.
enum AMQPOutboundData: Sendable {
  case frame(Frame)
  case encoded(ByteBuffer)
}

// MARK: - Frame Encoder

/// Encodes AMQP frames directly to ByteBuffer for zero-copy performance
final class AMQPFrameEncoder: ChannelOutboundHandler, RemovableChannelHandler, @unchecked Sendable {
  typealias OutboundIn = AMQPOutboundData
  typealias OutboundOut = ByteBuffer

  private let maxFrameSize: UInt32
  private let codec: FrameCodec

  init(maxFrameSize: UInt32 = FrameDefaults.maxSize) {
    self.maxFrameSize = maxFrameSize
    self.codec = FrameCodec(maxFrameSize: maxFrameSize)
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let outbound = unwrapOutboundIn(data)
    switch outbound {
    case .encoded(let buffer):
      context.write(wrapOutboundOut(buffer), promise: promise)
    case .frame(let frame):
      do {
        var buffer = context.channel.allocator.buffer(capacity: estimateFrameSize(frame))
        try encodeFrame(frame, to: &buffer)
        context.write(wrapOutboundOut(buffer), promise: promise)
      } catch {
        promise?.fail(error)
      }
    }
  }

  private func estimateFrameSize(_ frame: Frame) -> Int {
    switch frame {
    case .body(_, let payload):
      return 8 + payload.count + 1
    case .heartbeat:
      return 8
    case .header:
      return 128  // Properties vary, reasonable estimate
    case .method:
      return 256  // Method args vary, reasonable estimate
    }
  }

  private func encodeFrame(_ frame: Frame, to buffer: inout ByteBuffer) throws {
    switch frame {
    case .body(let channelID, let payload):
      // Fast path: encode body frame directly
      buffer.writeInteger(FrameType.body.rawValue)
      buffer.writeInteger(channelID, endianness: .big)
      buffer.writeInteger(UInt32(payload.count), endianness: .big)
      buffer.writeContiguousBytes(payload)
      buffer.writeInteger(frameEnd)

    case .heartbeat:
      buffer.writeInteger(FrameType.heartbeat.rawValue)
      buffer.writeInteger(UInt16(0), endianness: .big)
      buffer.writeInteger(UInt32(0), endianness: .big)
      buffer.writeInteger(frameEnd)

    case .method(let channelID, let method):
      if case .basicPublish(let publish) = method {
        // Hot path: encode BasicPublish directly
        encodeBasicPublish(channelID: channelID, publish: publish, to: &buffer)
      } else {
        let encoded = try codec.encode(frame)
        buffer.writeContiguousBytes(encoded)
      }

    case .header(let channelID, let classID, let bodySize, let properties):
      try encodeHeader(
        channelID: channelID, classID: classID, bodySize: bodySize, properties: properties,
        to: &buffer)
    }
  }

  private func encodeHeader(
    channelID: UInt16, classID: UInt16, bodySize: UInt64, properties: BasicProperties,
    to buffer: inout ByteBuffer
  ) throws {
    // Encode properties to temp buffer to get size
    var propsEncoder = WireEncoder()
    try properties.encode(to: &propsEncoder)
    let propsData = propsEncoder.encodedData

    // Payload: classID(2) + weight(2) + bodySize(8) + properties(variable)
    let payloadSize = 2 + 2 + 8 + propsData.count

    buffer.writeInteger(FrameType.header.rawValue)
    buffer.writeInteger(channelID, endianness: .big)
    buffer.writeInteger(UInt32(payloadSize), endianness: .big)

    buffer.writeInteger(classID, endianness: .big)
    buffer.writeInteger(UInt16(0), endianness: .big)  // weight (reserved)
    buffer.writeInteger(bodySize, endianness: .big)
    buffer.writeContiguousBytes(propsData)

    buffer.writeInteger(frameEnd)
  }

  private func encodeBasicPublish(
    channelID: UInt16, publish: BasicPublish, to buffer: inout ByteBuffer
  ) {
    // Payload: classID(2) + methodID(2) + reserved1(2) + exchange(1+len) + routingKey(1+len) + flags(1)
    let exchangeBytes = publish.exchange.utf8
    let routingKeyBytes = publish.routingKey.utf8
    let payloadSize = 2 + 2 + 2 + 1 + exchangeBytes.count + 1 + routingKeyBytes.count + 1

    buffer.writeInteger(FrameType.method.rawValue)
    buffer.writeInteger(channelID, endianness: .big)
    buffer.writeInteger(UInt32(payloadSize), endianness: .big)

    // Class ID (60) and Method ID (40)
    buffer.writeInteger(UInt16(60), endianness: .big)
    buffer.writeInteger(UInt16(40), endianness: .big)

    // Reserved1
    buffer.writeInteger(publish.reserved1, endianness: .big)

    // Exchange (short string)
    buffer.writeInteger(UInt8(exchangeBytes.count))
    buffer.writeBytes(exchangeBytes)

    // Routing key (short string)
    buffer.writeInteger(UInt8(routingKeyBytes.count))
    buffer.writeBytes(routingKeyBytes)

    // Flags (mandatory, immediate)
    var flags: UInt8 = 0
    if publish.mandatory { flags |= 0x01 }
    if publish.immediate { flags |= 0x02 }
    buffer.writeInteger(flags)

    buffer.writeInteger(frameEnd)
  }
}

// MARK: - Protocol Header Handler

final class ProtocolHeaderHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = Frame

  private let promise: EventLoopPromise<Void>
  private var buffer = Data()

  init(promise: EventLoopPromise<Void>) {
    self.promise = promise
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)

    // Accumulate bytes
    if let bytes = buffer.readBytes(length: buffer.readableBytes) {
      self.buffer.append(contentsOf: bytes)
    }

    // Check if we received the protocol header response
    if self.buffer.count >= 8 {
      if FrameCodec.isProtocolHeader(self.buffer) {
        // Server sent protocol header back - version mismatch
        if let version = try? FrameCodec.decodeProtocolHeader(self.buffer) {
          promise.fail(
            ConnectionError.protocolError(
              "Server requires AMQP \(version.major).\(version.minor).\(version.revision)"
            ))
        } else {
          promise.fail(ConnectionError.protocolError("Invalid protocol header from server"))
        }
      } else {
        // Put the data back for the frame decoder
        var newBuffer = context.channel.allocator.buffer(capacity: self.buffer.count)
        newBuffer.writeBytes(self.buffer)
        context.fireChannelRead(NIOAny(newBuffer))

        promise.succeed(())
      }
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    promise.fail(error)
    context.close(promise: nil)
  }
}

// MARK: - Connection State Handler

/// Tracks connection state and handles connection-level methods
final class ConnectionStateHandler: ChannelInboundHandler {
  typealias InboundIn = Frame
  typealias InboundOut = Frame

  private let onClose: @Sendable (ConnectionClose) -> Void
  private let onBlocked: @Sendable (String) -> Void
  private let onUnblocked: @Sendable () -> Void

  init(
    onClose: @escaping @Sendable (ConnectionClose) -> Void,
    onBlocked: @escaping @Sendable (String) -> Void,
    onUnblocked: @escaping @Sendable () -> Void
  ) {
    self.onClose = onClose
    self.onBlocked = onBlocked
    self.onUnblocked = onUnblocked
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)

    switch frame {
    case .method(channelID: 0, method: .connectionClose(let close)):
      onClose(close)
    case .method(channelID: 0, method: .connectionBlocked(let blocked)):
      onBlocked(blocked.reason)
      context.fireChannelRead(data)
    case .method(channelID: 0, method: .connectionUnblocked):
      onUnblocked()
      context.fireChannelRead(data)
    default:
      context.fireChannelRead(data)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.fireErrorCaught(error)
  }
}

// MARK: - Heartbeat Handler

/// Handles heartbeat frames
final class HeartbeatHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
  typealias InboundIn = Frame
  typealias InboundOut = Frame
  typealias OutboundIn = AMQPOutboundData
  typealias OutboundOut = AMQPOutboundData

  /// The check interval: half the negotiated heartbeat, minimum 1 second.
  let checkInterval: TimeAmount
  private var lastReceived: NIODeadline
  private var lastSent: NIODeadline
  private var scheduledTask: Scheduled<Void>?
  private let onTimeout: @Sendable () -> Void

  init(interval: UInt16, onTimeout: @escaping @Sendable () -> Void) {
    self.checkInterval = .seconds(Int64(max(interval / 2, 1)))
    self.lastReceived = .now()
    self.lastSent = .now()
    self.onTimeout = onTimeout
  }

  func handlerAdded(context: ChannelHandlerContext) {
    if checkInterval.nanoseconds > 0 {
      scheduleHeartbeat(context: context)
    }
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    scheduledTask?.cancel()
    scheduledTask = nil
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    lastReceived = .now()

    let frame = unwrapInboundIn(data)
    if case .heartbeat = frame {
      // Heartbeat received, don't propagate
      return
    }
    context.fireChannelRead(data)
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    lastSent = .now()
    context.write(data, promise: promise)
  }

  private func scheduleHeartbeat(context: ChannelHandlerContext) {
    scheduledTask = context.eventLoop.scheduleTask(in: checkInterval) { [weak self] in
      self?.checkHeartbeat(context: context)
    }
  }

  private func checkHeartbeat(context: ChannelHandlerContext) {
    let now = NIODeadline.now()

    // Timeout after 4x the check interval (= 2x negotiated heartbeat)
    let timeout = TimeAmount.nanoseconds(checkInterval.nanoseconds * 4)
    if now - lastReceived > timeout {
      onTimeout()
      context.close(promise: nil)
      return
    }

    // Send heartbeat if we haven't sent anything recently
    if now - lastSent > checkInterval {
      context.writeAndFlush(wrapOutboundOut(.frame(.heartbeat)), promise: nil)
    }

    scheduleHeartbeat(context: context)
  }
}
