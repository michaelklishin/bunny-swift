// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// FrameCodec Tests
// Tests for AMQP frame encoding/decoding

import Foundation
import Testing
@testable import AMQPProtocol

@Suite("Frame Type Tests")
struct FrameTypeTests {
    @Test("Frame type raw values")
    func frameTypeRawValues() {
        #expect(FrameType.method.rawValue == 1)
        #expect(FrameType.header.rawValue == 2)
        #expect(FrameType.body.rawValue == 3)
        #expect(FrameType.heartbeat.rawValue == 8)
    }

    @Test("Frame channelID accessor")
    func frameChannelID() {
        let methodFrame = Frame.method(channelID: 5, method: .channelCloseOk)
        #expect(methodFrame.channelID == 5)

        let headerFrame = Frame.header(channelID: 3, classID: 60, bodySize: 100, properties: BasicProperties())
        #expect(headerFrame.channelID == 3)

        let bodyFrame = Frame.body(channelID: 7, payload: Data())
        #expect(bodyFrame.channelID == 7)

        let heartbeat = Frame.heartbeat
        #expect(heartbeat.channelID == 0)
    }

    @Test("Frame frameType accessor")
    func frameFrameType() {
        #expect(Frame.method(channelID: 0, method: .connectionCloseOk).frameType == .method)
        #expect(Frame.header(channelID: 0, classID: 60, bodySize: 0, properties: BasicProperties()).frameType == .header)
        #expect(Frame.body(channelID: 0, payload: Data()).frameType == .body)
        #expect(Frame.heartbeat.frameType == .heartbeat)
    }
}

@Suite("Heartbeat Frame Tests")
struct HeartbeatFrameTests {
    @Test("Encode heartbeat frame")
    func encodeHeartbeat() throws {
        let codec = FrameCodec()
        let data = try codec.encode(.heartbeat)
        // Type(1) + Channel(2) + Size(4) + FrameEnd(1) = 8 bytes
        #expect(data.count == 8)
        // Type 8, Channel 0, Size 0, FrameEnd 0xCE
        #expect(data == Data([0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xCE]))
    }

    @Test("Decode heartbeat frame")
    func decodeHeartbeat() throws {
        let codec = FrameCodec()
        var buffer = Data([0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xCE])
        let frame = try codec.decode(from: &buffer)
        #expect(frame == .heartbeat)
        #expect(buffer.isEmpty)
    }

    @Test("Heartbeat roundtrip")
    func heartbeatRoundtrip() throws {
        let codec = FrameCodec()
        var data = try codec.encode(.heartbeat)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == .heartbeat)
    }
}

@Suite("Body Frame Tests")
struct BodyFrameTests {
    @Test("Encode body frame")
    func encodeBody() throws {
        let codec = FrameCodec()
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let data = try codec.encode(.body(channelID: 1, payload: payload))
        // Header(7) + Payload(4) + FrameEnd(1) = 12 bytes
        #expect(data.count == 12)
    }

    @Test("Body frame roundtrip")
    func bodyRoundtrip() throws {
        let codec = FrameCodec()
        let original = Frame.body(channelID: 5, payload: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        var data = try codec.encode(original)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == original)
    }

    @Test("Empty body frame")
    func emptyBody() throws {
        let codec = FrameCodec()
        let original = Frame.body(channelID: 1, payload: Data())
        var data = try codec.encode(original)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == original)
    }

    @Test("Large body frames are split")
    func largeBodySplit() throws {
        let codec = FrameCodec(maxFrameSize: 100)
        let payload = Data(repeating: 0xAB, count: 200)
        let frames = try codec.encodeBodyFrames(channelID: 1, payload: payload)
        #expect(frames.count > 1)

        // Decode all frames and reassemble
        var reassembled = Data()
        for var frame in frames {
            if let decoded = try codec.decode(from: &frame) {
                if case .body(_, let data) = decoded {
                    reassembled.append(data)
                }
            }
        }
        #expect(reassembled == payload)
    }
}

@Suite("Header Frame Tests")
struct HeaderFrameTests {
    @Test("Encode header frame with empty properties")
    func encodeEmptyHeader() throws {
        let codec = FrameCodec()
        let frame = Frame.header(channelID: 1, classID: 60, bodySize: 100, properties: BasicProperties())
        let data = try codec.encode(frame)
        #expect(data.count > 8)  // Header + class + weight + size + flags + frame end
    }

    @Test("Header frame roundtrip with properties")
    func headerRoundtrip() throws {
        let codec = FrameCodec()
        let props = BasicProperties(
            contentType: "application/json",
            deliveryMode: .persistent,
            priority: 5,
            correlationId: "abc123",
            messageId: "msg-001"
        )
        let frame = Frame.header(channelID: 3, classID: 60, bodySize: 1024, properties: props)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .header(let channelID, let classID, let bodySize, let decodedProps) = decoded {
            #expect(channelID == 3)
            #expect(classID == 60)
            #expect(bodySize == 1024)
            #expect(decodedProps.contentType == "application/json")
            #expect(decodedProps.deliveryMode == .persistent)
            #expect(decodedProps.priority == 5)
            #expect(decodedProps.correlationId == "abc123")
            #expect(decodedProps.messageId == "msg-001")
        } else {
            Issue.record("Expected header frame")
        }
    }

    @Test("Header frame with all properties")
    func headerAllProperties() throws {
        let codec = FrameCodec()
        let props = BasicProperties(
            contentType: "text/plain",
            contentEncoding: "utf-8",
            headers: ["custom": .string("value")],
            deliveryMode: .transient,
            priority: 9,
            correlationId: "corr-id",
            replyTo: "reply-queue",
            expiration: "60000",
            messageId: "msg-id",
            timestamp: Date(timeIntervalSince1970: 1234567890),
            type: "message.type",
            userId: "guest",
            appId: "my-app"
        )
        let frame = Frame.header(channelID: 1, classID: 60, bodySize: 0, properties: props)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .header(_, _, _, let decodedProps) = decoded {
            #expect(decodedProps.contentType == props.contentType)
            #expect(decodedProps.contentEncoding == props.contentEncoding)
            #expect(decodedProps.headers?["custom"]?.stringValue == "value")
            #expect(decodedProps.deliveryMode == props.deliveryMode)
            #expect(decodedProps.priority == props.priority)
            #expect(decodedProps.correlationId == props.correlationId)
            #expect(decodedProps.replyTo == props.replyTo)
            #expect(decodedProps.expiration == props.expiration)
            #expect(decodedProps.messageId == props.messageId)
            #expect(decodedProps.timestamp == props.timestamp)
            #expect(decodedProps.type == props.type)
            #expect(decodedProps.userId == props.userId)
            #expect(decodedProps.appId == props.appId)
        } else {
            Issue.record("Expected header frame")
        }
    }
}

@Suite("Connection Method Frame Tests")
struct ConnectionMethodTests {
    @Test("Connection.Start roundtrip")
    func connectionStart() throws {
        let codec = FrameCodec()
        let start = ConnectionStart(
            versionMajor: 0,
            versionMinor: 9,
            serverProperties: ["product": .string("RabbitMQ")],
            mechanisms: "PLAIN AMQPLAIN",
            locales: "en_US"
        )
        let frame = Frame.method(channelID: 0, method: .connectionStart(start))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(let ch, .connectionStart(let s)) = decoded {
            #expect(ch == 0)
            #expect(s.versionMajor == 0)
            #expect(s.versionMinor == 9)
            #expect(s.mechanisms == "PLAIN AMQPLAIN")
            #expect(s.locales == "en_US")
            #expect(s.serverProperties["product"]?.stringValue == "RabbitMQ")
        } else {
            Issue.record("Expected connectionStart")
        }
    }

    @Test("Connection.StartOk roundtrip")
    func connectionStartOk() throws {
        let codec = FrameCodec()
        let startOk = ConnectionStartOk.plainAuth(
            username: "guest",
            password: "guest",
            clientProperties: ["product": .string("BunnySwift")]
        )
        let frame = Frame.method(channelID: 0, method: .connectionStartOk(startOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(let ch, .connectionStartOk(let s)) = decoded {
            #expect(ch == 0)
            #expect(s.mechanism == "PLAIN")
            #expect(s.response == "\0guest\0guest")
            #expect(s.locale == "en_US")
        } else {
            Issue.record("Expected connectionStartOk")
        }
    }

    @Test("Connection.Tune roundtrip")
    func connectionTune() throws {
        let codec = FrameCodec()
        let tune = ConnectionTune(channelMax: 2047, frameMax: 131072, heartbeat: 60)
        let frame = Frame.method(channelID: 0, method: .connectionTune(tune))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .connectionTune(let t)) = decoded {
            #expect(t.channelMax == 2047)
            #expect(t.frameMax == 131072)
            #expect(t.heartbeat == 60)
        } else {
            Issue.record("Expected connectionTune")
        }
    }

    @Test("Connection.TuneOk roundtrip")
    func connectionTuneOk() throws {
        let codec = FrameCodec()
        let tuneOk = ConnectionTuneOk(channelMax: 1024, frameMax: 65536, heartbeat: 30)
        let frame = Frame.method(channelID: 0, method: .connectionTuneOk(tuneOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .connectionTuneOk(let t)) = decoded {
            #expect(t.channelMax == 1024)
            #expect(t.frameMax == 65536)
            #expect(t.heartbeat == 30)
        } else {
            Issue.record("Expected connectionTuneOk")
        }
    }

    @Test("Connection.Open roundtrip")
    func connectionOpen() throws {
        let codec = FrameCodec()
        let open = ConnectionOpen(virtualHost: "/my-vhost")
        let frame = Frame.method(channelID: 0, method: .connectionOpen(open))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .connectionOpen(let o)) = decoded {
            #expect(o.virtualHost == "/my-vhost")
        } else {
            Issue.record("Expected connectionOpen")
        }
    }

    @Test("Connection.OpenOk roundtrip")
    func connectionOpenOk() throws {
        let codec = FrameCodec()
        let openOk = ConnectionOpenOk()
        let frame = Frame.method(channelID: 0, method: .connectionOpenOk(openOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .connectionOpenOk(_)) = decoded {
            // Success
        } else {
            Issue.record("Expected connectionOpenOk")
        }
    }

    @Test("Connection.Close roundtrip")
    func connectionClose() throws {
        let codec = FrameCodec()
        let close = ConnectionClose(replyCode: 200, replyText: "Normal shutdown", classId: 0, methodId: 0)
        let frame = Frame.method(channelID: 0, method: .connectionClose(close))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .connectionClose(let c)) = decoded {
            #expect(c.replyCode == 200)
            #expect(c.replyText == "Normal shutdown")
        } else {
            Issue.record("Expected connectionClose")
        }
    }

    @Test("Connection.CloseOk roundtrip")
    func connectionCloseOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 0, method: .connectionCloseOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Connection.Blocked roundtrip")
    func connectionBlocked() throws {
        let codec = FrameCodec()
        let blocked = ConnectionBlocked(reason: "resource-alarm")
        let frame = Frame.method(channelID: 0, method: .connectionBlocked(blocked))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .connectionBlocked(let b)) = decoded {
            #expect(b.reason == "resource-alarm")
        } else {
            Issue.record("Expected connectionBlocked")
        }
    }

    @Test("Connection.Unblocked roundtrip")
    func connectionUnblocked() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 0, method: .connectionUnblocked)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }
}

@Suite("Channel Method Frame Tests")
struct ChannelMethodTests {
    @Test("Channel.Open roundtrip")
    func channelOpen() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .channelOpen(ChannelOpen()))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(let ch, .channelOpen(_)) = decoded {
            #expect(ch == 1)
        } else {
            Issue.record("Expected channelOpen")
        }
    }

    @Test("Channel.OpenOk roundtrip")
    func channelOpenOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .channelOpenOk(ChannelOpenOk()))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(let ch, .channelOpenOk(_)) = decoded {
            #expect(ch == 1)
        } else {
            Issue.record("Expected channelOpenOk")
        }
    }

    @Test("Channel.Flow roundtrip")
    func channelFlow() throws {
        let codec = FrameCodec()
        for active in [true, false] {
            let frame = Frame.method(channelID: 1, method: .channelFlow(ChannelFlow(active: active)))
            var data = try codec.encode(frame)
            let decoded = try codec.decode(from: &data)

            if case .method(_, .channelFlow(let f)) = decoded {
                #expect(f.active == active)
            } else {
                Issue.record("Expected channelFlow")
            }
        }
    }

    @Test("Channel.Close roundtrip")
    func channelClose() throws {
        let codec = FrameCodec()
        let close = ChannelClose(replyCode: 404, replyText: "NOT_FOUND", classId: 50, methodId: 10)
        let frame = Frame.method(channelID: 1, method: .channelClose(close))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .channelClose(let c)) = decoded {
            #expect(c.replyCode == 404)
            #expect(c.replyText == "NOT_FOUND")
            #expect(c.classId == 50)
            #expect(c.methodId == 10)
        } else {
            Issue.record("Expected channelClose")
        }
    }

    @Test("Channel.CloseOk roundtrip")
    func channelCloseOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .channelCloseOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }
}

@Suite("Exchange Method Frame Tests")
struct ExchangeMethodTests {
    @Test("Exchange.Declare roundtrip")
    func exchangeDeclare() throws {
        let codec = FrameCodec()
        let declare = ExchangeDeclare(
            exchange: "my.exchange",
            type: "topic",
            passive: false,
            durable: true,
            autoDelete: false,
            internal: false,
            noWait: false,
            arguments: ["alternate-exchange": .string("my.alt")]
        )
        let frame = Frame.method(channelID: 1, method: .exchangeDeclare(declare))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .exchangeDeclare(let d)) = decoded {
            #expect(d.exchange == "my.exchange")
            #expect(d.type == "topic")
            #expect(d.durable == true)
            #expect(d.arguments["alternate-exchange"]?.stringValue == "my.alt")
        } else {
            Issue.record("Expected exchangeDeclare")
        }
    }

    @Test("Exchange.DeclareOk roundtrip")
    func exchangeDeclareOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .exchangeDeclareOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Exchange.Delete roundtrip")
    func exchangeDelete() throws {
        let codec = FrameCodec()
        let delete = ExchangeDelete(exchange: "old.exchange", ifUnused: true)
        let frame = Frame.method(channelID: 1, method: .exchangeDelete(delete))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .exchangeDelete(let d)) = decoded {
            #expect(d.exchange == "old.exchange")
            #expect(d.ifUnused == true)
        } else {
            Issue.record("Expected exchangeDelete")
        }
    }

    @Test("Exchange.Bind roundtrip")
    func exchangeBind() throws {
        let codec = FrameCodec()
        let bind = ExchangeBind(destination: "dest", source: "src", routingKey: "key.*")
        let frame = Frame.method(channelID: 1, method: .exchangeBind(bind))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .exchangeBind(let b)) = decoded {
            #expect(b.destination == "dest")
            #expect(b.source == "src")
            #expect(b.routingKey == "key.*")
        } else {
            Issue.record("Expected exchangeBind")
        }
    }

    @Test("Exchange.Unbind roundtrip")
    func exchangeUnbind() throws {
        let codec = FrameCodec()
        let unbind = ExchangeUnbind(destination: "dest", source: "src", routingKey: "key.*")
        let frame = Frame.method(channelID: 1, method: .exchangeUnbind(unbind))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .exchangeUnbind(let u)) = decoded {
            #expect(u.destination == "dest")
            #expect(u.source == "src")
            #expect(u.routingKey == "key.*")
        } else {
            Issue.record("Expected exchangeUnbind")
        }
    }
}

@Suite("Queue Method Frame Tests")
struct QueueMethodTests {
    @Test("Queue.Declare roundtrip")
    func queueDeclare() throws {
        let codec = FrameCodec()
        let declare = QueueDeclare(
            queue: "my.queue",
            passive: false,
            durable: true,
            exclusive: false,
            autoDelete: false,
            arguments: ["x-message-ttl": .int32(60000)]
        )
        let frame = Frame.method(channelID: 1, method: .queueDeclare(declare))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queueDeclare(let d)) = decoded {
            #expect(d.queue == "my.queue")
            #expect(d.durable == true)
            #expect(d.arguments["x-message-ttl"]?.intValue == 60000)
        } else {
            Issue.record("Expected queueDeclare")
        }
    }

    @Test("Queue.DeclareOk roundtrip")
    func queueDeclareOk() throws {
        let codec = FrameCodec()
        let declareOk = QueueDeclareOk(queue: "amq.gen-abc123", messageCount: 100, consumerCount: 5)
        let frame = Frame.method(channelID: 1, method: .queueDeclareOk(declareOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queueDeclareOk(let d)) = decoded {
            #expect(d.queue == "amq.gen-abc123")
            #expect(d.messageCount == 100)
            #expect(d.consumerCount == 5)
        } else {
            Issue.record("Expected queueDeclareOk")
        }
    }

    @Test("Queue.Bind roundtrip")
    func queueBind() throws {
        let codec = FrameCodec()
        let bind = QueueBind(queue: "my.queue", exchange: "my.exchange", routingKey: "routing.key")
        let frame = Frame.method(channelID: 1, method: .queueBind(bind))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queueBind(let b)) = decoded {
            #expect(b.queue == "my.queue")
            #expect(b.exchange == "my.exchange")
            #expect(b.routingKey == "routing.key")
        } else {
            Issue.record("Expected queueBind")
        }
    }

    @Test("Queue.Unbind roundtrip")
    func queueUnbind() throws {
        let codec = FrameCodec()
        let unbind = QueueUnbind(queue: "my.queue", exchange: "my.exchange", routingKey: "routing.key")
        let frame = Frame.method(channelID: 1, method: .queueUnbind(unbind))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queueUnbind(let u)) = decoded {
            #expect(u.queue == "my.queue")
            #expect(u.exchange == "my.exchange")
            #expect(u.routingKey == "routing.key")
        } else {
            Issue.record("Expected queueUnbind")
        }
    }

    @Test("Queue.Purge roundtrip")
    func queuePurge() throws {
        let codec = FrameCodec()
        let purge = QueuePurge(queue: "my.queue")
        let frame = Frame.method(channelID: 1, method: .queuePurge(purge))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queuePurge(let p)) = decoded {
            #expect(p.queue == "my.queue")
        } else {
            Issue.record("Expected queuePurge")
        }
    }

    @Test("Queue.PurgeOk roundtrip")
    func queuePurgeOk() throws {
        let codec = FrameCodec()
        let purgeOk = QueuePurgeOk(messageCount: 42)
        let frame = Frame.method(channelID: 1, method: .queuePurgeOk(purgeOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queuePurgeOk(let p)) = decoded {
            #expect(p.messageCount == 42)
        } else {
            Issue.record("Expected queuePurgeOk")
        }
    }

    @Test("Queue.Delete roundtrip")
    func queueDelete() throws {
        let codec = FrameCodec()
        let delete = QueueDelete(queue: "my.queue", ifUnused: true, ifEmpty: true)
        let frame = Frame.method(channelID: 1, method: .queueDelete(delete))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queueDelete(let d)) = decoded {
            #expect(d.queue == "my.queue")
            #expect(d.ifUnused == true)
            #expect(d.ifEmpty == true)
        } else {
            Issue.record("Expected queueDelete")
        }
    }

    @Test("Queue.DeleteOk roundtrip")
    func queueDeleteOk() throws {
        let codec = FrameCodec()
        let deleteOk = QueueDeleteOk(messageCount: 10)
        let frame = Frame.method(channelID: 1, method: .queueDeleteOk(deleteOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .queueDeleteOk(let d)) = decoded {
            #expect(d.messageCount == 10)
        } else {
            Issue.record("Expected queueDeleteOk")
        }
    }
}

@Suite("Basic Method Frame Tests")
struct BasicMethodTests {
    @Test("Basic.Qos roundtrip")
    func basicQos() throws {
        let codec = FrameCodec()
        let qos = BasicQos(prefetchSize: 0, prefetchCount: 10, global: true)
        let frame = Frame.method(channelID: 1, method: .basicQos(qos))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicQos(let q)) = decoded {
            #expect(q.prefetchCount == 10)
            #expect(q.global == true)
        } else {
            Issue.record("Expected basicQos")
        }
    }

    @Test("Basic.QosOk roundtrip")
    func basicQosOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .basicQosOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Basic.Consume roundtrip")
    func basicConsume() throws {
        let codec = FrameCodec()
        let consume = BasicConsume(
            queue: "my.queue",
            consumerTag: "consumer-1",
            noLocal: false,
            noAck: false,
            exclusive: true
        )
        let frame = Frame.method(channelID: 1, method: .basicConsume(consume))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicConsume(let c)) = decoded {
            #expect(c.queue == "my.queue")
            #expect(c.consumerTag == "consumer-1")
            #expect(c.exclusive == true)
        } else {
            Issue.record("Expected basicConsume")
        }
    }

    @Test("Basic.ConsumeOk roundtrip")
    func basicConsumeOk() throws {
        let codec = FrameCodec()
        let consumeOk = BasicConsumeOk(consumerTag: "consumer-1")
        let frame = Frame.method(channelID: 1, method: .basicConsumeOk(consumeOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicConsumeOk(let c)) = decoded {
            #expect(c.consumerTag == "consumer-1")
        } else {
            Issue.record("Expected basicConsumeOk")
        }
    }

    @Test("Basic.Cancel roundtrip")
    func basicCancel() throws {
        let codec = FrameCodec()
        let cancel = BasicCancel(consumerTag: "consumer-1", noWait: false)
        let frame = Frame.method(channelID: 1, method: .basicCancel(cancel))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicCancel(let c)) = decoded {
            #expect(c.consumerTag == "consumer-1")
        } else {
            Issue.record("Expected basicCancel")
        }
    }

    @Test("Basic.Publish roundtrip")
    func basicPublish() throws {
        let codec = FrameCodec()
        let publish = BasicPublish(exchange: "my.exchange", routingKey: "routing.key", mandatory: true)
        let frame = Frame.method(channelID: 1, method: .basicPublish(publish))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicPublish(let p)) = decoded {
            #expect(p.exchange == "my.exchange")
            #expect(p.routingKey == "routing.key")
            #expect(p.mandatory == true)
        } else {
            Issue.record("Expected basicPublish")
        }
    }

    @Test("Basic.Return roundtrip")
    func basicReturn() throws {
        let codec = FrameCodec()
        let ret = BasicReturn(replyCode: 312, replyText: "NO_ROUTE", exchange: "my.exchange", routingKey: "key")
        let frame = Frame.method(channelID: 1, method: .basicReturn(ret))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicReturn(let r)) = decoded {
            #expect(r.replyCode == 312)
            #expect(r.replyText == "NO_ROUTE")
        } else {
            Issue.record("Expected basicReturn")
        }
    }

    @Test("Basic.Deliver roundtrip")
    func basicDeliver() throws {
        let codec = FrameCodec()
        let deliver = BasicDeliver(
            consumerTag: "consumer-1",
            deliveryTag: 12345,
            redelivered: true,
            exchange: "my.exchange",
            routingKey: "routing.key"
        )
        let frame = Frame.method(channelID: 1, method: .basicDeliver(deliver))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicDeliver(let d)) = decoded {
            #expect(d.consumerTag == "consumer-1")
            #expect(d.deliveryTag == 12345)
            #expect(d.redelivered == true)
            #expect(d.exchange == "my.exchange")
            #expect(d.routingKey == "routing.key")
        } else {
            Issue.record("Expected basicDeliver")
        }
    }

    @Test("Basic.Get roundtrip")
    func basicGet() throws {
        let codec = FrameCodec()
        let get = BasicGet(queue: "my.queue", noAck: true)
        let frame = Frame.method(channelID: 1, method: .basicGet(get))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicGet(let g)) = decoded {
            #expect(g.queue == "my.queue")
            #expect(g.noAck == true)
        } else {
            Issue.record("Expected basicGet")
        }
    }

    @Test("Basic.GetOk roundtrip")
    func basicGetOk() throws {
        let codec = FrameCodec()
        let getOk = BasicGetOk(deliveryTag: 42, redelivered: false, exchange: "ex", routingKey: "key", messageCount: 10)
        let frame = Frame.method(channelID: 1, method: .basicGetOk(getOk))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicGetOk(let g)) = decoded {
            #expect(g.deliveryTag == 42)
            #expect(g.messageCount == 10)
        } else {
            Issue.record("Expected basicGetOk")
        }
    }

    @Test("Basic.GetEmpty roundtrip")
    func basicGetEmpty() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .basicGetEmpty(BasicGetEmpty()))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicGetEmpty(_)) = decoded {
            // Success
        } else {
            Issue.record("Expected basicGetEmpty")
        }
    }

    @Test("Basic.Ack roundtrip")
    func basicAck() throws {
        let codec = FrameCodec()
        let ack = BasicAck(deliveryTag: 42, multiple: true)
        let frame = Frame.method(channelID: 1, method: .basicAck(ack))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicAck(let a)) = decoded {
            #expect(a.deliveryTag == 42)
            #expect(a.multiple == true)
        } else {
            Issue.record("Expected basicAck")
        }
    }

    @Test("Basic.Reject roundtrip")
    func basicReject() throws {
        let codec = FrameCodec()
        let reject = BasicReject(deliveryTag: 42, requeue: true)
        let frame = Frame.method(channelID: 1, method: .basicReject(reject))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicReject(let r)) = decoded {
            #expect(r.deliveryTag == 42)
            #expect(r.requeue == true)
        } else {
            Issue.record("Expected basicReject")
        }
    }

    @Test("Basic.Nack roundtrip")
    func basicNack() throws {
        let codec = FrameCodec()
        let nack = BasicNack(deliveryTag: 42, multiple: true, requeue: false)
        let frame = Frame.method(channelID: 1, method: .basicNack(nack))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicNack(let n)) = decoded {
            #expect(n.deliveryTag == 42)
            #expect(n.multiple == true)
            #expect(n.requeue == false)
        } else {
            Issue.record("Expected basicNack")
        }
    }

    @Test("Basic.Recover roundtrip")
    func basicRecover() throws {
        let codec = FrameCodec()
        let recover = BasicRecover(requeue: true)
        let frame = Frame.method(channelID: 1, method: .basicRecover(recover))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicRecover(let r)) = decoded {
            #expect(r.requeue == true)
        } else {
            Issue.record("Expected basicRecover")
        }
    }

    @Test("Basic.RecoverOk roundtrip")
    func basicRecoverOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .basicRecoverOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }
}

@Suite("Tx Method Frame Tests")
struct TxMethodTests {
    @Test("Tx.Select roundtrip")
    func txSelect() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .txSelect)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Tx.SelectOk roundtrip")
    func txSelectOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .txSelectOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Tx.Commit roundtrip")
    func txCommit() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .txCommit)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Tx.CommitOk roundtrip")
    func txCommitOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .txCommitOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Tx.Rollback roundtrip")
    func txRollback() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .txRollback)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }

    @Test("Tx.RollbackOk roundtrip")
    func txRollbackOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .txRollbackOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }
}

@Suite("Confirm Method Frame Tests")
struct ConfirmMethodTests {
    @Test("Confirm.Select roundtrip")
    func confirmSelect() throws {
        let codec = FrameCodec()
        let confirm = ConfirmSelect(noWait: false)
        let frame = Frame.method(channelID: 1, method: .confirmSelect(confirm))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .confirmSelect(let c)) = decoded {
            #expect(c.noWait == false)
        } else {
            Issue.record("Expected confirmSelect")
        }
    }

    @Test("Confirm.SelectOk roundtrip")
    func confirmSelectOk() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 1, method: .confirmSelectOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)
        #expect(decoded == frame)
    }
}

@Suite("Protocol Header Tests")
struct ProtocolHeaderTests {
    @Test("Detect protocol header")
    func detectProtocolHeader() {
        let header = Data([0x41, 0x4D, 0x51, 0x50, 0x00, 0x00, 0x09, 0x01])
        #expect(FrameCodec.isProtocolHeader(header) == true)

        let notHeader = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xCE])
        #expect(FrameCodec.isProtocolHeader(notHeader) == false)
    }

    @Test("Decode protocol header")
    func decodeProtocolHeader() throws {
        let header = Data([0x41, 0x4D, 0x51, 0x50, 0x00, 0x00, 0x09, 0x01])
        let version = try FrameCodec.decodeProtocolHeader(header)
        #expect(version?.major == 0)
        #expect(version?.minor == 9)
        #expect(version?.revision == 1)
    }
}

@Suite("Frame Codec Edge Cases")
struct FrameCodecEdgeCaseTests {
    @Test("Incomplete frame returns nil")
    func incompleteFrame() throws {
        let codec = FrameCodec()
        var buffer = Data([0x08, 0x00, 0x00])  // Incomplete heartbeat
        let frame = try codec.decode(from: &buffer)
        #expect(frame == nil)
        #expect(buffer.count == 3)  // Buffer unchanged
    }

    @Test("Invalid frame end throws error")
    func invalidFrameEnd() {
        let codec = FrameCodec()
        var buffer = Data([0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])  // Wrong frame end
        #expect(throws: WireFormatError.self) {
            _ = try codec.decode(from: &buffer)
        }
    }

    @Test("Unknown frame type throws error")
    func unknownFrameType() {
        let codec = FrameCodec()
        var buffer = Data([0x99, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xCE])  // Unknown type
        #expect(throws: WireFormatError.self) {
            _ = try codec.decode(from: &buffer)
        }
    }

    @Test("Frame too large on encode throws error")
    func frameTooLargeEncode() {
        let codec = FrameCodec(maxFrameSize: 100)
        let largePayload = Data(repeating: 0xAB, count: 200)
        #expect(throws: WireFormatError.self) {
            _ = try codec.encode(.body(channelID: 1, payload: largePayload))
        }
    }

    @Test("Frame too large on decode throws error")
    func frameTooLargeDecode() {
        let codec = FrameCodec(maxFrameSize: 100)
        // Craft a frame header claiming a payload size larger than allowed
        // Type=body(3), Channel=1, Size=0x00001000 (4096 bytes)
        // Need at least FrameDefaults.headerSize + 1 (= 8 bytes) to pass initial check
        var buffer = Data([
            0x03,                      // body frame type
            0x00, 0x01,                // channel 1
            0x00, 0x00, 0x10, 0x00,    // size = 4096 (way over 100 limit)
            0xCE                       // frame end (won't be reached)
        ])
        #expect(throws: WireFormatError.self) {
            _ = try codec.decode(from: &buffer)
        }
    }

    @Test("Unknown method throws error")
    func unknownMethod() {
        let codec = FrameCodec()
        // Frame with unknown class/method IDs
        var buffer = Data([
            0x01,  // method frame
            0x00, 0x01,  // channel 1
            0x00, 0x00, 0x00, 0x04,  // size 4
            0xFF, 0xFF,  // class 65535
            0xFF, 0xFF,  // method 65535
            0xCE  // frame end
        ])
        #expect(throws: AMQPProtocolError.self) {
            _ = try codec.decode(from: &buffer)
        }
    }

    @Test("Multiple frames in buffer")
    func multipleFrames() throws {
        let codec = FrameCodec()
        let frame1 = Frame.heartbeat
        let frame2 = Frame.method(channelID: 1, method: .channelCloseOk)

        var buffer = try codec.encode(frame1)
        buffer.append(try codec.encode(frame2))

        let decoded1 = try codec.decode(from: &buffer)
        let decoded2 = try codec.decode(from: &buffer)

        #expect(decoded1 == frame1)
        #expect(decoded2 == frame2)
        #expect(buffer.isEmpty)
    }

    @Test("Maximum channel ID")
    func maxChannelID() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: UInt16.max, method: .channelCloseOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(let ch, _) = decoded {
            #expect(ch == UInt16.max)
        } else {
            Issue.record("Expected method frame")
        }
    }

    @Test("Channel ID zero for connection methods")
    func channelZero() throws {
        let codec = FrameCodec()
        let frame = Frame.method(channelID: 0, method: .connectionCloseOk)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(let ch, _) = decoded {
            #expect(ch == 0)
        } else {
            Issue.record("Expected method frame")
        }
    }

    @Test("Body frame at exact frame max minus overhead")
    func bodyFrameExactMax() throws {
        let frameMax: UInt32 = 100
        let codec = FrameCodec(maxFrameSize: frameMax)
        // Frame overhead: type(1) + channel(2) + size(4) + end(1) = 8 bytes
        let payload = Data(repeating: 0xAB, count: Int(frameMax) - 8)
        let frame = Frame.body(channelID: 1, payload: payload)
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .body(_, let decodedPayload) = decoded {
            #expect(decodedPayload == payload)
        } else {
            Issue.record("Expected body frame")
        }
    }

    @Test("Large delivery tag")
    func largeDeliveryTag() throws {
        let codec = FrameCodec()
        let deliver = BasicDeliver(
            consumerTag: "ctag",
            deliveryTag: UInt64.max,
            redelivered: false,
            exchange: "ex",
            routingKey: "key"
        )
        let frame = Frame.method(channelID: 1, method: .basicDeliver(deliver))
        var data = try codec.encode(frame)
        let decoded = try codec.decode(from: &data)

        if case .method(_, .basicDeliver(let d)) = decoded {
            #expect(d.deliveryTag == UInt64.max)
        } else {
            Issue.record("Expected basicDeliver")
        }
    }
}

@Suite("Method Properties Tests")
struct MethodPropertiesTests {
    @Test("Method IDs are correct")
    func methodIDs() {
        #expect(Method.connectionStart(ConnectionStart()).methodID == MethodID(classID: 10, methodID: 10))
        #expect(Method.channelOpen(ChannelOpen()).methodID == MethodID(classID: 20, methodID: 10))
        #expect(Method.exchangeDeclare(ExchangeDeclare(exchange: "")).methodID == MethodID(classID: 40, methodID: 10))
        #expect(Method.queueDeclare(QueueDeclare()).methodID == MethodID(classID: 50, methodID: 10))
        #expect(Method.basicPublish(BasicPublish(routingKey: "")).methodID == MethodID(classID: 60, methodID: 40))
        #expect(Method.txSelect.methodID == MethodID(classID: 90, methodID: 10))
        #expect(Method.confirmSelect(ConfirmSelect()).methodID == MethodID(classID: 85, methodID: 10))
    }

    @Test("Methods with content")
    func methodsWithContent() {
        #expect(Method.basicPublish(BasicPublish(routingKey: "")).hasContent == true)
        #expect(Method.basicReturn(BasicReturn(replyCode: 0, replyText: "", exchange: "", routingKey: "")).hasContent == true)
        #expect(Method.basicDeliver(BasicDeliver(consumerTag: "", deliveryTag: 0, redelivered: false, exchange: "", routingKey: "")).hasContent == true)
        #expect(Method.basicGetOk(BasicGetOk(deliveryTag: 0, redelivered: false, exchange: "", routingKey: "", messageCount: 0)).hasContent == true)
        #expect(Method.basicAck(BasicAck(deliveryTag: 0)).hasContent == false)
        #expect(Method.queueDeclare(QueueDeclare()).hasContent == false)
    }

    @Test("Methods expecting response")
    func methodsExpectingResponse() {
        #expect(Method.connectionOpen(ConnectionOpen()).expectsResponse == true)
        #expect(Method.channelOpen(ChannelOpen()).expectsResponse == true)
        #expect(Method.queueDeclare(QueueDeclare()).expectsResponse == true)
        #expect(Method.basicAck(BasicAck(deliveryTag: 0)).expectsResponse == false)
        #expect(Method.connectionCloseOk.expectsResponse == false)
    }
}

@Suite("BasicProperties Tests")
struct BasicPropertiesTests {
    @Test("Property flags are computed correctly")
    func propertyFlags() {
        let props = BasicProperties(
            contentType: "application/json",
            deliveryMode: .persistent
        )
        let flags = props.propertyFlags
        #expect(flags.contains(.contentType))
        #expect(flags.contains(.deliveryMode))
        #expect(!flags.contains(.headers))
        #expect(!flags.contains(.priority))
    }

    @Test("Persistent static property")
    func persistentProperty() {
        let props = BasicProperties.persistent.withContentType("text/plain")
        #expect(props.deliveryMode == DeliveryMode.persistent)
        #expect(props.contentType == "text/plain")
    }

    @Test("Transient static property")
    func transientProperty() {
        let props = BasicProperties.transient
        #expect(props.deliveryMode == DeliveryMode.transient)
    }

    @Test("Fluent builders")
    func fluentBuilders() {
        let props = BasicProperties()
            .withContentType("application/json")
            .withCorrelationId("abc123")
            .withPriority(5)
            .withDeliveryMode(.persistent)

        #expect(props.contentType == "application/json")
        #expect(props.correlationId == "abc123")
        #expect(props.priority == 5)
        #expect(props.deliveryMode == .persistent)
    }

    @Test("Expiration from Duration")
    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    func expirationFromDuration() {
        let props = BasicProperties().withExpiration(.seconds(60))
        #expect(props.expiration == "60000")
    }

    @Test("Expiration from milliseconds")
    func expirationFromMilliseconds() {
        let props = BasicProperties().withExpiration(milliseconds: 5000)
        #expect(props.expiration == "5000")

        let props2 = BasicProperties().withExpiration(milliseconds: 0)
        #expect(props2.expiration == "0")
    }
}
