// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation

// MARK: - Frame Codec

/// Encodes and decodes AMQP frames
public struct FrameCodec: Sendable {
    /// Maximum frame size for this codec
    public let maxFrameSize: UInt32

    public init(maxFrameSize: UInt32 = FrameDefaults.maxSize) {
        self.maxFrameSize = maxFrameSize
    }

    // MARK: - Encoding

    /// Encode a frame to wire format
    public func encode(_ frame: Frame) throws -> Data {
        var encoder = WireEncoder()

        switch frame {
        case .method(let channelID, let method):
            try encodeMethodFrame(channelID: channelID, method: method, to: &encoder)

        case .header(let channelID, let classID, let bodySize, let properties):
            try encodeHeaderFrame(channelID: channelID, classID: classID, bodySize: bodySize,
                                  properties: properties, to: &encoder)

        case .body(let channelID, let payload):
            try encodeBodyFrame(channelID: channelID, payload: payload, to: &encoder)

        case .heartbeat:
            encodeHeartbeatFrame(to: &encoder)
        }

        return encoder.encodedData
    }

    /// Encode multiple body frames for large payloads
    public func encodeBodyFrames(channelID: UInt16, payload: Data) throws -> [Data] {
        let maxBodySize = Int(maxFrameSize) - FrameDefaults.headerSize - 1  // -1 for frame end
        var frames = [Data]()

        var offset = 0
        while offset < payload.count {
            let remaining = payload.count - offset
            let chunkSize = min(remaining, maxBodySize)
            let chunk = payload[offset..<offset + chunkSize]

            var encoder = WireEncoder()
            encoder.writeUInt8(FrameType.body.rawValue)
            encoder.writeUInt16(channelID)
            encoder.writeUInt32(UInt32(chunkSize))
            encoder.writeBytes(Data(chunk))
            encoder.writeUInt8(frameEnd)

            frames.append(encoder.encodedData)
            offset += chunkSize
        }

        return frames
    }

    private func encodeMethodFrame(channelID: UInt16, method: Method, to encoder: inout WireEncoder) throws {
        var payloadEncoder = WireEncoder()
        payloadEncoder.writeUInt16(method.methodID.classID)
        payloadEncoder.writeUInt16(method.methodID.methodID)
        try encodeMethodPayload(method, to: &payloadEncoder)

        let payload = payloadEncoder.encodedData
        guard payload.count <= Int(maxFrameSize) - FrameDefaults.headerSize - 1 else {
            throw WireFormatError.frameTooLarge(size: UInt32(payload.count), maxSize: maxFrameSize)
        }

        encoder.writeUInt8(FrameType.method.rawValue)
        encoder.writeUInt16(channelID)
        encoder.writeUInt32(UInt32(payload.count))
        encoder.writeBytes(payload)
        encoder.writeUInt8(frameEnd)
    }

    private func encodeHeaderFrame(
        channelID: UInt16,
        classID: UInt16,
        bodySize: UInt64,
        properties: BasicProperties,
        to encoder: inout WireEncoder
    ) throws {
        var payloadEncoder = WireEncoder()
        payloadEncoder.writeUInt16(classID)
        payloadEncoder.writeUInt16(0)  // weight (reserved)
        payloadEncoder.writeUInt64(bodySize)
        try properties.encode(to: &payloadEncoder)

        let payload = payloadEncoder.encodedData
        guard payload.count <= Int(maxFrameSize) - FrameDefaults.headerSize - 1 else {
            throw WireFormatError.frameTooLarge(size: UInt32(payload.count), maxSize: maxFrameSize)
        }

        encoder.writeUInt8(FrameType.header.rawValue)
        encoder.writeUInt16(channelID)
        encoder.writeUInt32(UInt32(payload.count))
        encoder.writeBytes(payload)
        encoder.writeUInt8(frameEnd)
    }

    private func encodeBodyFrame(channelID: UInt16, payload: Data, to encoder: inout WireEncoder) throws {
        guard payload.count <= Int(maxFrameSize) - FrameDefaults.headerSize - 1 else {
            throw WireFormatError.frameTooLarge(size: UInt32(payload.count), maxSize: maxFrameSize)
        }

        encoder.writeUInt8(FrameType.body.rawValue)
        encoder.writeUInt16(channelID)
        encoder.writeUInt32(UInt32(payload.count))
        encoder.writeBytes(payload)
        encoder.writeUInt8(frameEnd)
    }

    private func encodeHeartbeatFrame(to encoder: inout WireEncoder) {
        encoder.writeUInt8(FrameType.heartbeat.rawValue)
        encoder.writeUInt16(0)  // channel 0
        encoder.writeUInt32(0)  // no payload
        encoder.writeUInt8(frameEnd)
    }

    // MARK: - Decoding

    /// Decode a frame from wire format
    /// Returns nil if insufficient data (need more bytes)
    public func decode(from buffer: inout Data) throws -> Frame? {
        guard buffer.count >= FrameDefaults.headerSize + 1 else {
            return nil
        }

        var decoder = buffer.wireDecoder()
        let frameTypeRaw = try decoder.readUInt8()
        let channelID = try decoder.readUInt16()
        let payloadSize = try decoder.readUInt32()

        let maxPayload = maxFrameSize - UInt32(FrameDefaults.headerSize) - 1
        guard payloadSize <= maxPayload else {
            throw WireFormatError.frameTooLarge(size: payloadSize, maxSize: maxFrameSize)
        }

        let totalSize = FrameDefaults.headerSize + Int(payloadSize) + 1
        guard buffer.count >= totalSize else {
            return nil
        }

        let payload = try decoder.readBytes(Int(payloadSize))
        let actualFrameEnd = try decoder.readUInt8()
        guard actualFrameEnd == frameEnd else {
            throw WireFormatError.invalidFrameEnd(expected: frameEnd, actual: actualFrameEnd)
        }

        buffer.removeFirst(totalSize)

        guard let frameType = FrameType(rawValue: frameTypeRaw) else {
            throw WireFormatError.unknownFrameType(frameTypeRaw)
        }

        switch frameType {
        case .method:
            let method = try decodeMethodPayload(payload)
            return .method(channelID: channelID, method: method)

        case .header:
            var payloadDecoder = payload.wireDecoder()
            let classID = try payloadDecoder.readUInt16()
            _ = try payloadDecoder.readUInt16()  // weight (reserved)
            let bodySize = try payloadDecoder.readUInt64()
            let properties = try BasicProperties.decode(from: &payloadDecoder)
            return .header(channelID: channelID, classID: classID, bodySize: bodySize, properties: properties)

        case .body:
            return .body(channelID: channelID, payload: payload)

        case .heartbeat:
            return .heartbeat
        }
    }

    /// Check if buffer contains the protocol header
    public static func isProtocolHeader(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(4) == Data([0x41, 0x4D, 0x51, 0x50])  // "AMQP"
    }

    /// Decode protocol header
    public static func decodeProtocolHeader(_ data: Data) throws -> (major: UInt8, minor: UInt8, revision: UInt8)? {
        guard data.count >= 8 else { return nil }
        guard data.prefix(4) == Data([0x41, 0x4D, 0x51, 0x50]) else { return nil }
        return (data[5], data[6], data[7])
    }

    // MARK: - Method Payload Encoding

    private func encodeMethodPayload(_ method: Method, to encoder: inout WireEncoder) throws {
        switch method {
        // Connection class
        case .connectionStart(let m):
            encoder.writeUInt8(m.versionMajor)
            encoder.writeUInt8(m.versionMinor)
            try encodeTable(m.serverProperties, to: &encoder)
            encoder.writeLongString(m.mechanisms)
            encoder.writeLongString(m.locales)

        case .connectionStartOk(let m):
            try encodeTable(m.clientProperties, to: &encoder)
            try encoder.writeShortString(m.mechanism)
            encoder.writeLongString(m.response)
            try encoder.writeShortString(m.locale)

        case .connectionSecure(let m):
            encoder.writeLongString(m.challenge)

        case .connectionSecureOk(let m):
            encoder.writeLongString(m.response)

        case .connectionTune(let m):
            encoder.writeUInt16(m.channelMax)
            encoder.writeUInt32(m.frameMax)
            encoder.writeUInt16(m.heartbeat)

        case .connectionTuneOk(let m):
            encoder.writeUInt16(m.channelMax)
            encoder.writeUInt32(m.frameMax)
            encoder.writeUInt16(m.heartbeat)

        case .connectionOpen(let m):
            try encoder.writeShortString(m.virtualHost)
            try encoder.writeShortString(m.reserved1)
            encoder.writeBits([m.reserved2])

        case .connectionOpenOk(let m):
            try encoder.writeShortString(m.reserved1)

        case .connectionClose(let m):
            encoder.writeUInt16(m.replyCode)
            try encoder.writeShortString(m.replyText)
            encoder.writeUInt16(m.classId)
            encoder.writeUInt16(m.methodId)

        case .connectionCloseOk:
            break  // no payload

        case .connectionBlocked(let m):
            try encoder.writeShortString(m.reason)

        case .connectionUnblocked:
            break  // no payload

        // Channel class
        case .channelOpen(let m):
            try encoder.writeShortString(m.reserved1)

        case .channelOpenOk(let m):
            encoder.writeLongString(m.reserved1)

        case .channelFlow(let m):
            encoder.writeBits([m.active])

        case .channelFlowOk(let m):
            encoder.writeBits([m.active])

        case .channelClose(let m):
            encoder.writeUInt16(m.replyCode)
            try encoder.writeShortString(m.replyText)
            encoder.writeUInt16(m.classId)
            encoder.writeUInt16(m.methodId)

        case .channelCloseOk:
            break  // no payload

        // Exchange class
        case .exchangeDeclare(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.type)
            encoder.writeBits([m.passive, m.durable, m.autoDelete, m.internal, m.noWait])
            try encodeTable(m.arguments, to: &encoder)

        case .exchangeDeclareOk:
            break

        case .exchangeDelete(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.exchange)
            encoder.writeBits([m.ifUnused, m.noWait])

        case .exchangeDeleteOk:
            break

        case .exchangeBind(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.destination)
            try encoder.writeShortString(m.source)
            try encoder.writeShortString(m.routingKey)
            encoder.writeBits([m.noWait])
            try encodeTable(m.arguments, to: &encoder)

        case .exchangeBindOk:
            break

        case .exchangeUnbind(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.destination)
            try encoder.writeShortString(m.source)
            try encoder.writeShortString(m.routingKey)
            encoder.writeBits([m.noWait])
            try encodeTable(m.arguments, to: &encoder)

        case .exchangeUnbindOk:
            break

        // Queue class
        case .queueDeclare(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            encoder.writeBits([m.passive, m.durable, m.exclusive, m.autoDelete, m.noWait])
            try encodeTable(m.arguments, to: &encoder)

        case .queueDeclareOk(let m):
            try encoder.writeShortString(m.queue)
            encoder.writeUInt32(m.messageCount)
            encoder.writeUInt32(m.consumerCount)

        case .queueBind(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.routingKey)
            encoder.writeBits([m.noWait])
            try encodeTable(m.arguments, to: &encoder)

        case .queueBindOk:
            break

        case .queueUnbind(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.routingKey)
            try encodeTable(m.arguments, to: &encoder)

        case .queueUnbindOk:
            break

        case .queuePurge(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            encoder.writeBits([m.noWait])

        case .queuePurgeOk(let m):
            encoder.writeUInt32(m.messageCount)

        case .queueDelete(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            encoder.writeBits([m.ifUnused, m.ifEmpty, m.noWait])

        case .queueDeleteOk(let m):
            encoder.writeUInt32(m.messageCount)

        // Basic class
        case .basicQos(let m):
            encoder.writeUInt32(m.prefetchSize)
            encoder.writeUInt16(m.prefetchCount)
            encoder.writeBits([m.global])

        case .basicQosOk:
            break

        case .basicConsume(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            try encoder.writeShortString(m.consumerTag)
            encoder.writeBits([m.noLocal, m.noAck, m.exclusive, m.noWait])
            try encodeTable(m.arguments, to: &encoder)

        case .basicConsumeOk(let m):
            try encoder.writeShortString(m.consumerTag)

        case .basicCancel(let m):
            try encoder.writeShortString(m.consumerTag)
            encoder.writeBits([m.noWait])

        case .basicCancelOk(let m):
            try encoder.writeShortString(m.consumerTag)

        case .basicPublish(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.routingKey)
            encoder.writeBits([m.mandatory, m.immediate])

        case .basicReturn(let m):
            encoder.writeUInt16(m.replyCode)
            try encoder.writeShortString(m.replyText)
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.routingKey)

        case .basicDeliver(let m):
            try encoder.writeShortString(m.consumerTag)
            encoder.writeUInt64(m.deliveryTag)
            encoder.writeBits([m.redelivered])
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.routingKey)

        case .basicGet(let m):
            encoder.writeUInt16(m.reserved1)
            try encoder.writeShortString(m.queue)
            encoder.writeBits([m.noAck])

        case .basicGetOk(let m):
            encoder.writeUInt64(m.deliveryTag)
            encoder.writeBits([m.redelivered])
            try encoder.writeShortString(m.exchange)
            try encoder.writeShortString(m.routingKey)
            encoder.writeUInt32(m.messageCount)

        case .basicGetEmpty(let m):
            try encoder.writeShortString(m.reserved1)

        case .basicAck(let m):
            encoder.writeUInt64(m.deliveryTag)
            encoder.writeBits([m.multiple])

        case .basicReject(let m):
            encoder.writeUInt64(m.deliveryTag)
            encoder.writeBits([m.requeue])

        case .basicRecoverAsync(let m):
            encoder.writeBits([m.requeue])

        case .basicRecover(let m):
            encoder.writeBits([m.requeue])

        case .basicRecoverOk:
            break

        case .basicNack(let m):
            encoder.writeUInt64(m.deliveryTag)
            encoder.writeBits([m.multiple, m.requeue])

        // Tx class
        case .txSelect, .txSelectOk, .txCommit, .txCommitOk, .txRollback, .txRollbackOk:
            break  // no payload

        // Confirm class
        case .confirmSelect(let m):
            encoder.writeBits([m.noWait])

        case .confirmSelectOk:
            break
        }
    }

    // MARK: - Method Payload Decoding

    public func decodeMethod(from data: Data) throws -> Method {
        try decodeMethodPayload(data)
    }

    private func decodeMethodPayload(_ data: Data) throws -> Method {
        var decoder = data.wireDecoder()
        let classID = try decoder.readUInt16()
        let methodID = try decoder.readUInt16()

        switch (classID, methodID) {
        // Connection class (10)
        case (10, 10):  // Start
            let versionMajor = try decoder.readUInt8()
            let versionMinor = try decoder.readUInt8()
            let serverProperties = try decodeTable(from: &decoder)
            let mechanisms = try decoder.readLongString()
            let locales = try decoder.readLongString()
            return .connectionStart(ConnectionStart(
                versionMajor: versionMajor,
                versionMinor: versionMinor,
                serverProperties: serverProperties,
                mechanisms: mechanisms,
                locales: locales
            ))

        case (10, 11):  // StartOk
            let clientProperties = try decodeTable(from: &decoder)
            let mechanism = try decoder.readShortString()
            let response = try decoder.readLongString()
            let locale = try decoder.readShortString()
            return .connectionStartOk(ConnectionStartOk(
                clientProperties: clientProperties,
                mechanism: mechanism,
                response: response,
                locale: locale
            ))

        case (10, 20):  // Secure
            let challenge = try decoder.readLongString()
            return .connectionSecure(ConnectionSecure(challenge: challenge))

        case (10, 21):  // SecureOk
            let response = try decoder.readLongString()
            return .connectionSecureOk(ConnectionSecureOk(response: response))

        case (10, 30):  // Tune
            let channelMax = try decoder.readUInt16()
            let frameMax = try decoder.readUInt32()
            let heartbeat = try decoder.readUInt16()
            return .connectionTune(ConnectionTune(channelMax: channelMax, frameMax: frameMax, heartbeat: heartbeat))

        case (10, 31):  // TuneOk
            let channelMax = try decoder.readUInt16()
            let frameMax = try decoder.readUInt32()
            let heartbeat = try decoder.readUInt16()
            return .connectionTuneOk(ConnectionTuneOk(channelMax: channelMax, frameMax: frameMax, heartbeat: heartbeat))

        case (10, 40):  // Open
            let virtualHost = try decoder.readShortString()
            let reserved1 = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            return .connectionOpen(ConnectionOpen(virtualHost: virtualHost, reserved1: reserved1, reserved2: bits[0]))

        case (10, 41):  // OpenOk
            let reserved1 = try decoder.readShortString()
            return .connectionOpenOk(ConnectionOpenOk(reserved1: reserved1))

        case (10, 50):  // Close
            let replyCode = try decoder.readUInt16()
            let replyText = try decoder.readShortString()
            let classId = try decoder.readUInt16()
            let methodId = try decoder.readUInt16()
            return .connectionClose(ConnectionClose(replyCode: replyCode, replyText: replyText, classId: classId, methodId: methodId))

        case (10, 51):  // CloseOk
            return .connectionCloseOk

        case (10, 60):  // Blocked
            let reason = try decoder.readShortString()
            return .connectionBlocked(ConnectionBlocked(reason: reason))

        case (10, 61):  // Unblocked
            return .connectionUnblocked

        // Channel class (20)
        case (20, 10):  // Open
            let reserved1 = try decoder.readShortString()
            return .channelOpen(ChannelOpen(reserved1: reserved1))

        case (20, 11):  // OpenOk
            let reserved1 = try decoder.readLongString()
            return .channelOpenOk(ChannelOpenOk(reserved1: reserved1))

        case (20, 20):  // Flow
            let bits = try decoder.readBits(1)
            return .channelFlow(ChannelFlow(active: bits[0]))

        case (20, 21):  // FlowOk
            let bits = try decoder.readBits(1)
            return .channelFlowOk(ChannelFlowOk(active: bits[0]))

        case (20, 40):  // Close
            let replyCode = try decoder.readUInt16()
            let replyText = try decoder.readShortString()
            let classId = try decoder.readUInt16()
            let methodId = try decoder.readUInt16()
            return .channelClose(ChannelClose(replyCode: replyCode, replyText: replyText, classId: classId, methodId: methodId))

        case (20, 41):  // CloseOk
            return .channelCloseOk

        // Exchange class (40)
        case (40, 10):  // Declare
            let reserved1 = try decoder.readUInt16()
            let exchange = try decoder.readShortString()
            let type = try decoder.readShortString()
            let bits = try decoder.readBits(5)
            let arguments = try decodeTable(from: &decoder)
            return .exchangeDeclare(ExchangeDeclare(
                reserved1: reserved1, exchange: exchange, type: type,
                passive: bits[0], durable: bits[1], autoDelete: bits[2],
                internal: bits[3], noWait: bits[4], arguments: arguments
            ))

        case (40, 11):  // DeclareOk
            return .exchangeDeclareOk

        case (40, 20):  // Delete
            let reserved1 = try decoder.readUInt16()
            let exchange = try decoder.readShortString()
            let bits = try decoder.readBits(2)
            return .exchangeDelete(ExchangeDelete(reserved1: reserved1, exchange: exchange, ifUnused: bits[0], noWait: bits[1]))

        case (40, 21):  // DeleteOk
            return .exchangeDeleteOk

        case (40, 30):  // Bind
            let reserved1 = try decoder.readUInt16()
            let destination = try decoder.readShortString()
            let source = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            let arguments = try decodeTable(from: &decoder)
            return .exchangeBind(ExchangeBind(
                reserved1: reserved1, destination: destination, source: source,
                routingKey: routingKey, noWait: bits[0], arguments: arguments
            ))

        case (40, 31):  // BindOk
            return .exchangeBindOk

        case (40, 40):  // Unbind
            let reserved1 = try decoder.readUInt16()
            let destination = try decoder.readShortString()
            let source = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            let arguments = try decodeTable(from: &decoder)
            return .exchangeUnbind(ExchangeUnbind(
                reserved1: reserved1, destination: destination, source: source,
                routingKey: routingKey, noWait: bits[0], arguments: arguments
            ))

        case (40, 51):  // UnbindOk
            return .exchangeUnbindOk

        // Queue class (50)
        case (50, 10):  // Declare
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let bits = try decoder.readBits(5)
            let arguments = try decodeTable(from: &decoder)
            return .queueDeclare(QueueDeclare(
                reserved1: reserved1, queue: queue,
                passive: bits[0], durable: bits[1], exclusive: bits[2],
                autoDelete: bits[3], noWait: bits[4], arguments: arguments
            ))

        case (50, 11):  // DeclareOk
            let queue = try decoder.readShortString()
            let messageCount = try decoder.readUInt32()
            let consumerCount = try decoder.readUInt32()
            return .queueDeclareOk(QueueDeclareOk(queue: queue, messageCount: messageCount, consumerCount: consumerCount))

        case (50, 20):  // Bind
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let exchange = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            let arguments = try decodeTable(from: &decoder)
            return .queueBind(QueueBind(
                reserved1: reserved1, queue: queue, exchange: exchange,
                routingKey: routingKey, noWait: bits[0], arguments: arguments
            ))

        case (50, 21):  // BindOk
            return .queueBindOk

        case (50, 30):  // Purge
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            return .queuePurge(QueuePurge(reserved1: reserved1, queue: queue, noWait: bits[0]))

        case (50, 31):  // PurgeOk
            let messageCount = try decoder.readUInt32()
            return .queuePurgeOk(QueuePurgeOk(messageCount: messageCount))

        case (50, 40):  // Delete
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let bits = try decoder.readBits(3)
            return .queueDelete(QueueDelete(
                reserved1: reserved1, queue: queue,
                ifUnused: bits[0], ifEmpty: bits[1], noWait: bits[2]
            ))

        case (50, 41):  // DeleteOk
            let messageCount = try decoder.readUInt32()
            return .queueDeleteOk(QueueDeleteOk(messageCount: messageCount))

        case (50, 50):  // Unbind
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let exchange = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            let arguments = try decodeTable(from: &decoder)
            return .queueUnbind(QueueUnbind(
                reserved1: reserved1, queue: queue, exchange: exchange,
                routingKey: routingKey, arguments: arguments
            ))

        case (50, 51):  // UnbindOk
            return .queueUnbindOk

        // Basic class (60)
        case (60, 10):  // Qos
            let prefetchSize = try decoder.readUInt32()
            let prefetchCount = try decoder.readUInt16()
            let bits = try decoder.readBits(1)
            return .basicQos(BasicQos(prefetchSize: prefetchSize, prefetchCount: prefetchCount, global: bits[0]))

        case (60, 11):  // QosOk
            return .basicQosOk

        case (60, 20):  // Consume
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let consumerTag = try decoder.readShortString()
            let bits = try decoder.readBits(4)
            let arguments = try decodeTable(from: &decoder)
            return .basicConsume(BasicConsume(
                reserved1: reserved1, queue: queue, consumerTag: consumerTag,
                noLocal: bits[0], noAck: bits[1], exclusive: bits[2],
                noWait: bits[3], arguments: arguments
            ))

        case (60, 21):  // ConsumeOk
            let consumerTag = try decoder.readShortString()
            return .basicConsumeOk(BasicConsumeOk(consumerTag: consumerTag))

        case (60, 30):  // Cancel
            let consumerTag = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            return .basicCancel(BasicCancel(consumerTag: consumerTag, noWait: bits[0]))

        case (60, 31):  // CancelOk
            let consumerTag = try decoder.readShortString()
            return .basicCancelOk(BasicCancelOk(consumerTag: consumerTag))

        case (60, 40):  // Publish
            let reserved1 = try decoder.readUInt16()
            let exchange = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            let bits = try decoder.readBits(2)
            return .basicPublish(BasicPublish(
                reserved1: reserved1, exchange: exchange, routingKey: routingKey,
                mandatory: bits[0], immediate: bits[1]
            ))

        case (60, 50):  // Return
            let replyCode = try decoder.readUInt16()
            let replyText = try decoder.readShortString()
            let exchange = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            return .basicReturn(BasicReturn(replyCode: replyCode, replyText: replyText, exchange: exchange, routingKey: routingKey))

        case (60, 60):  // Deliver
            let consumerTag = try decoder.readShortString()
            let deliveryTag = try decoder.readUInt64()
            let bits = try decoder.readBits(1)
            let exchange = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            return .basicDeliver(BasicDeliver(
                consumerTag: consumerTag, deliveryTag: deliveryTag,
                redelivered: bits[0], exchange: exchange, routingKey: routingKey
            ))

        case (60, 70):  // Get
            let reserved1 = try decoder.readUInt16()
            let queue = try decoder.readShortString()
            let bits = try decoder.readBits(1)
            return .basicGet(BasicGet(reserved1: reserved1, queue: queue, noAck: bits[0]))

        case (60, 71):  // GetOk
            let deliveryTag = try decoder.readUInt64()
            let bits = try decoder.readBits(1)
            let exchange = try decoder.readShortString()
            let routingKey = try decoder.readShortString()
            let messageCount = try decoder.readUInt32()
            return .basicGetOk(BasicGetOk(
                deliveryTag: deliveryTag, redelivered: bits[0],
                exchange: exchange, routingKey: routingKey, messageCount: messageCount
            ))

        case (60, 72):  // GetEmpty
            let reserved1 = try decoder.readShortString()
            return .basicGetEmpty(BasicGetEmpty(reserved1: reserved1))

        case (60, 80):  // Ack
            let deliveryTag = try decoder.readUInt64()
            let bits = try decoder.readBits(1)
            return .basicAck(BasicAck(deliveryTag: deliveryTag, multiple: bits[0]))

        case (60, 90):  // Reject
            let deliveryTag = try decoder.readUInt64()
            let bits = try decoder.readBits(1)
            return .basicReject(BasicReject(deliveryTag: deliveryTag, requeue: bits[0]))

        case (60, 100):  // RecoverAsync
            let bits = try decoder.readBits(1)
            return .basicRecoverAsync(BasicRecoverAsync(requeue: bits[0]))

        case (60, 110):  // Recover
            let bits = try decoder.readBits(1)
            return .basicRecover(BasicRecover(requeue: bits[0]))

        case (60, 111):  // RecoverOk
            return .basicRecoverOk

        case (60, 120):  // Nack
            let deliveryTag = try decoder.readUInt64()
            let bits = try decoder.readBits(2)
            return .basicNack(BasicNack(deliveryTag: deliveryTag, multiple: bits[0], requeue: bits[1]))

        // Tx class (90)
        case (90, 10):  // Select
            return .txSelect

        case (90, 11):  // SelectOk
            return .txSelectOk

        case (90, 20):  // Commit
            return .txCommit

        case (90, 21):  // CommitOk
            return .txCommitOk

        case (90, 30):  // Rollback
            return .txRollback

        case (90, 31):  // RollbackOk
            return .txRollbackOk

        // Confirm class (85)
        case (85, 10):  // Select
            let bits = try decoder.readBits(1)
            return .confirmSelect(ConfirmSelect(noWait: bits[0]))

        case (85, 11):  // SelectOk
            return .confirmSelectOk

        default:
            throw AMQPProtocolError.unknownMethod(classID: classID, methodID: methodID)
        }
    }
}

// MARK: - Protocol Errors

public enum AMQPProtocolError: Error, Sendable {
    case unknownMethod(classID: UInt16, methodID: UInt16)
}
