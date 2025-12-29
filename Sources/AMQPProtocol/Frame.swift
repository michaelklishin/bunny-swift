// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// AMQP 0-9-1 Frame Types

import Foundation

// MARK: - Frame

/// AMQP frame variants
public enum Frame: Sendable, Equatable {
    /// Method frame containing an AMQP method
    case method(channelID: UInt16, method: Method)

    /// Content header frame with message properties
    case header(channelID: UInt16, classID: UInt16, bodySize: UInt64, properties: BasicProperties)

    /// Content body frame with message payload
    case body(channelID: UInt16, payload: Data)

    /// Heartbeat frame (always on channel 0)
    case heartbeat

    /// Channel ID for this frame
    public var channelID: UInt16 {
        switch self {
        case .method(let id, _): return id
        case .header(let id, _, _, _): return id
        case .body(let id, _): return id
        case .heartbeat: return 0
        }
    }

    /// Frame type
    public var frameType: FrameType {
        switch self {
        case .method: return .method
        case .header: return .header
        case .body: return .body
        case .heartbeat: return .heartbeat
        }
    }
}

// MARK: - Method Identification

/// Identifies an AMQP method by class and method ID
public struct MethodID: Sendable, Equatable, Hashable {
    public let classID: UInt16
    public let methodID: UInt16

    public init(classID: UInt16, methodID: UInt16) {
        self.classID = classID
        self.methodID = methodID
    }

    /// Combined index: (classID << 16) | methodID
    public var index: UInt32 {
        (UInt32(classID) << 16) | UInt32(methodID)
    }
}

// MARK: - Method

/// AMQP method payload
public enum Method: Sendable, Equatable {
    // Connection class (10)
    case connectionStart(ConnectionStart)
    case connectionStartOk(ConnectionStartOk)
    case connectionSecure(ConnectionSecure)
    case connectionSecureOk(ConnectionSecureOk)
    case connectionTune(ConnectionTune)
    case connectionTuneOk(ConnectionTuneOk)
    case connectionOpen(ConnectionOpen)
    case connectionOpenOk(ConnectionOpenOk)
    case connectionClose(ConnectionClose)
    case connectionCloseOk
    case connectionBlocked(ConnectionBlocked)
    case connectionUnblocked

    // Channel class (20)
    case channelOpen(ChannelOpen)
    case channelOpenOk(ChannelOpenOk)
    case channelFlow(ChannelFlow)
    case channelFlowOk(ChannelFlowOk)
    case channelClose(ChannelClose)
    case channelCloseOk

    // Exchange class (40)
    case exchangeDeclare(ExchangeDeclare)
    case exchangeDeclareOk
    case exchangeDelete(ExchangeDelete)
    case exchangeDeleteOk
    case exchangeBind(ExchangeBind)
    case exchangeBindOk
    case exchangeUnbind(ExchangeUnbind)
    case exchangeUnbindOk

    // Queue class (50)
    case queueDeclare(QueueDeclare)
    case queueDeclareOk(QueueDeclareOk)
    case queueBind(QueueBind)
    case queueBindOk
    case queueUnbind(QueueUnbind)
    case queueUnbindOk
    case queuePurge(QueuePurge)
    case queuePurgeOk(QueuePurgeOk)
    case queueDelete(QueueDelete)
    case queueDeleteOk(QueueDeleteOk)

    // Basic class (60)
    case basicQos(BasicQos)
    case basicQosOk
    case basicConsume(BasicConsume)
    case basicConsumeOk(BasicConsumeOk)
    case basicCancel(BasicCancel)
    case basicCancelOk(BasicCancelOk)
    case basicPublish(BasicPublish)
    case basicReturn(BasicReturn)
    case basicDeliver(BasicDeliver)
    case basicGet(BasicGet)
    case basicGetOk(BasicGetOk)
    case basicGetEmpty(BasicGetEmpty)
    case basicAck(BasicAck)
    case basicReject(BasicReject)
    case basicRecoverAsync(BasicRecoverAsync)
    case basicRecover(BasicRecover)
    case basicRecoverOk
    case basicNack(BasicNack)

    // Tx class (90)
    case txSelect
    case txSelectOk
    case txCommit
    case txCommitOk
    case txRollback
    case txRollbackOk

    // Confirm class (85)
    case confirmSelect(ConfirmSelect)
    case confirmSelectOk

    /// Method identifier
    public var methodID: MethodID {
        switch self {
        // Connection
        case .connectionStart: return MethodID(classID: 10, methodID: 10)
        case .connectionStartOk: return MethodID(classID: 10, methodID: 11)
        case .connectionSecure: return MethodID(classID: 10, methodID: 20)
        case .connectionSecureOk: return MethodID(classID: 10, methodID: 21)
        case .connectionTune: return MethodID(classID: 10, methodID: 30)
        case .connectionTuneOk: return MethodID(classID: 10, methodID: 31)
        case .connectionOpen: return MethodID(classID: 10, methodID: 40)
        case .connectionOpenOk: return MethodID(classID: 10, methodID: 41)
        case .connectionClose: return MethodID(classID: 10, methodID: 50)
        case .connectionCloseOk: return MethodID(classID: 10, methodID: 51)
        case .connectionBlocked: return MethodID(classID: 10, methodID: 60)
        case .connectionUnblocked: return MethodID(classID: 10, methodID: 61)

        // Channel
        case .channelOpen: return MethodID(classID: 20, methodID: 10)
        case .channelOpenOk: return MethodID(classID: 20, methodID: 11)
        case .channelFlow: return MethodID(classID: 20, methodID: 20)
        case .channelFlowOk: return MethodID(classID: 20, methodID: 21)
        case .channelClose: return MethodID(classID: 20, methodID: 40)
        case .channelCloseOk: return MethodID(classID: 20, methodID: 41)

        // Exchange
        case .exchangeDeclare: return MethodID(classID: 40, methodID: 10)
        case .exchangeDeclareOk: return MethodID(classID: 40, methodID: 11)
        case .exchangeDelete: return MethodID(classID: 40, methodID: 20)
        case .exchangeDeleteOk: return MethodID(classID: 40, methodID: 21)
        case .exchangeBind: return MethodID(classID: 40, methodID: 30)
        case .exchangeBindOk: return MethodID(classID: 40, methodID: 31)
        case .exchangeUnbind: return MethodID(classID: 40, methodID: 40)
        case .exchangeUnbindOk: return MethodID(classID: 40, methodID: 51)

        // Queue
        case .queueDeclare: return MethodID(classID: 50, methodID: 10)
        case .queueDeclareOk: return MethodID(classID: 50, methodID: 11)
        case .queueBind: return MethodID(classID: 50, methodID: 20)
        case .queueBindOk: return MethodID(classID: 50, methodID: 21)
        case .queueUnbind: return MethodID(classID: 50, methodID: 50)
        case .queueUnbindOk: return MethodID(classID: 50, methodID: 51)
        case .queuePurge: return MethodID(classID: 50, methodID: 30)
        case .queuePurgeOk: return MethodID(classID: 50, methodID: 31)
        case .queueDelete: return MethodID(classID: 50, methodID: 40)
        case .queueDeleteOk: return MethodID(classID: 50, methodID: 41)

        // Basic
        case .basicQos: return MethodID(classID: 60, methodID: 10)
        case .basicQosOk: return MethodID(classID: 60, methodID: 11)
        case .basicConsume: return MethodID(classID: 60, methodID: 20)
        case .basicConsumeOk: return MethodID(classID: 60, methodID: 21)
        case .basicCancel: return MethodID(classID: 60, methodID: 30)
        case .basicCancelOk: return MethodID(classID: 60, methodID: 31)
        case .basicPublish: return MethodID(classID: 60, methodID: 40)
        case .basicReturn: return MethodID(classID: 60, methodID: 50)
        case .basicDeliver: return MethodID(classID: 60, methodID: 60)
        case .basicGet: return MethodID(classID: 60, methodID: 70)
        case .basicGetOk: return MethodID(classID: 60, methodID: 71)
        case .basicGetEmpty: return MethodID(classID: 60, methodID: 72)
        case .basicAck: return MethodID(classID: 60, methodID: 80)
        case .basicReject: return MethodID(classID: 60, methodID: 90)
        case .basicRecoverAsync: return MethodID(classID: 60, methodID: 100)
        case .basicRecover: return MethodID(classID: 60, methodID: 110)
        case .basicRecoverOk: return MethodID(classID: 60, methodID: 111)
        case .basicNack: return MethodID(classID: 60, methodID: 120)

        // Tx
        case .txSelect: return MethodID(classID: 90, methodID: 10)
        case .txSelectOk: return MethodID(classID: 90, methodID: 11)
        case .txCommit: return MethodID(classID: 90, methodID: 20)
        case .txCommitOk: return MethodID(classID: 90, methodID: 21)
        case .txRollback: return MethodID(classID: 90, methodID: 30)
        case .txRollbackOk: return MethodID(classID: 90, methodID: 31)

        // Confirm
        case .confirmSelect: return MethodID(classID: 85, methodID: 10)
        case .confirmSelectOk: return MethodID(classID: 85, methodID: 11)
        }
    }

    /// Whether this method expects a response
    public var expectsResponse: Bool {
        switch self {
        case .connectionStartOk, .connectionSecureOk, .connectionTuneOk,
             .connectionOpen, .connectionClose,
             .channelOpen, .channelFlow, .channelClose,
             .exchangeDeclare, .exchangeDelete, .exchangeBind, .exchangeUnbind,
             .queueDeclare, .queueBind, .queueUnbind, .queuePurge, .queueDelete,
             .basicQos, .basicConsume, .basicCancel, .basicGet, .basicRecover,
             .txSelect, .txCommit, .txRollback,
             .confirmSelect:
            return true
        default:
            return false
        }
    }

    /// Whether this method carries content (header + body frames follow)
    public var hasContent: Bool {
        switch self {
        case .basicPublish, .basicReturn, .basicDeliver, .basicGetOk:
            return true
        default:
            return false
        }
    }
}

// MARK: - Method Payload Structures

// Connection class payloads
public struct ConnectionStart: Sendable, Equatable {
    public var versionMajor: UInt8
    public var versionMinor: UInt8
    public var serverProperties: Table
    public var mechanisms: String
    public var locales: String

    public init(
        versionMajor: UInt8 = 0,
        versionMinor: UInt8 = 9,
        serverProperties: Table = [:],
        mechanisms: String = "PLAIN",
        locales: String = "en_US"
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.serverProperties = serverProperties
        self.mechanisms = mechanisms
        self.locales = locales
    }
}

public struct ConnectionStartOk: Sendable, Equatable {
    public var clientProperties: Table
    public var mechanism: String
    public var response: String
    public var locale: String

    public init(
        clientProperties: Table = [:],
        mechanism: String = "PLAIN",
        response: String,
        locale: String = "en_US"
    ) {
        self.clientProperties = clientProperties
        self.mechanism = mechanism
        self.response = response
        self.locale = locale
    }

    /// Create PLAIN auth response
    public static func plainAuth(username: String, password: String, clientProperties: Table = [:]) -> ConnectionStartOk {
        // PLAIN format: \0username\0password
        let response = "\0\(username)\0\(password)"
        return ConnectionStartOk(
            clientProperties: clientProperties,
            mechanism: "PLAIN",
            response: response,
            locale: "en_US"
        )
    }
}

public struct ConnectionSecure: Sendable, Equatable {
    public var challenge: String

    public init(challenge: String) {
        self.challenge = challenge
    }
}

public struct ConnectionSecureOk: Sendable, Equatable {
    public var response: String

    public init(response: String) {
        self.response = response
    }
}

public struct ConnectionTune: Sendable, Equatable {
    public var channelMax: UInt16
    public var frameMax: UInt32
    public var heartbeat: UInt16

    public init(channelMax: UInt16 = 2047, frameMax: UInt32 = 131072, heartbeat: UInt16 = 60) {
        self.channelMax = channelMax
        self.frameMax = frameMax
        self.heartbeat = heartbeat
    }
}

public struct ConnectionTuneOk: Sendable, Equatable {
    public var channelMax: UInt16
    public var frameMax: UInt32
    public var heartbeat: UInt16

    public init(channelMax: UInt16 = 2047, frameMax: UInt32 = 131072, heartbeat: UInt16 = 60) {
        self.channelMax = channelMax
        self.frameMax = frameMax
        self.heartbeat = heartbeat
    }
}

public struct ConnectionOpen: Sendable, Equatable {
    public var virtualHost: String
    public var reserved1: String
    public var reserved2: Bool

    public init(virtualHost: String = "/", reserved1: String = "", reserved2: Bool = false) {
        self.virtualHost = virtualHost
        self.reserved1 = reserved1
        self.reserved2 = reserved2
    }
}

public struct ConnectionOpenOk: Sendable, Equatable {
    public var reserved1: String

    public init(reserved1: String = "") {
        self.reserved1 = reserved1
    }
}

public struct ConnectionClose: Sendable, Equatable {
    public var replyCode: UInt16
    public var replyText: String
    public var classId: UInt16
    public var methodId: UInt16

    public init(replyCode: UInt16, replyText: String, classId: UInt16 = 0, methodId: UInt16 = 0) {
        self.replyCode = replyCode
        self.replyText = replyText
        self.classId = classId
        self.methodId = methodId
    }
}

public struct ConnectionBlocked: Sendable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// Channel class payloads
public struct ChannelOpen: Sendable, Equatable {
    public var reserved1: String

    public init(reserved1: String = "") {
        self.reserved1 = reserved1
    }
}

public struct ChannelOpenOk: Sendable, Equatable {
    public var reserved1: String

    public init(reserved1: String = "") {
        self.reserved1 = reserved1
    }
}

public struct ChannelFlow: Sendable, Equatable {
    public var active: Bool

    public init(active: Bool) {
        self.active = active
    }
}

public struct ChannelFlowOk: Sendable, Equatable {
    public var active: Bool

    public init(active: Bool) {
        self.active = active
    }
}

public struct ChannelClose: Sendable, Equatable {
    public var replyCode: UInt16
    public var replyText: String
    public var classId: UInt16
    public var methodId: UInt16

    public init(replyCode: UInt16, replyText: String, classId: UInt16 = 0, methodId: UInt16 = 0) {
        self.replyCode = replyCode
        self.replyText = replyText
        self.classId = classId
        self.methodId = methodId
    }
}

// Exchange class payloads
public struct ExchangeDeclare: Sendable, Equatable {
    public var reserved1: UInt16
    public var exchange: String
    public var type: String
    public var passive: Bool
    public var durable: Bool
    public var autoDelete: Bool
    public var `internal`: Bool
    public var noWait: Bool
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        exchange: String,
        type: String = "direct",
        passive: Bool = false,
        durable: Bool = false,
        autoDelete: Bool = false,
        internal: Bool = false,
        noWait: Bool = false,
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.exchange = exchange
        self.type = type
        self.passive = passive
        self.durable = durable
        self.autoDelete = autoDelete
        self.internal = `internal`
        self.noWait = noWait
        self.arguments = arguments
    }
}

public struct ExchangeDelete: Sendable, Equatable {
    public var reserved1: UInt16
    public var exchange: String
    public var ifUnused: Bool
    public var noWait: Bool

    public init(reserved1: UInt16 = 0, exchange: String, ifUnused: Bool = false, noWait: Bool = false) {
        self.reserved1 = reserved1
        self.exchange = exchange
        self.ifUnused = ifUnused
        self.noWait = noWait
    }
}

public struct ExchangeBind: Sendable, Equatable {
    public var reserved1: UInt16
    public var destination: String
    public var source: String
    public var routingKey: String
    public var noWait: Bool
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        destination: String,
        source: String,
        routingKey: String = "",
        noWait: Bool = false,
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.destination = destination
        self.source = source
        self.routingKey = routingKey
        self.noWait = noWait
        self.arguments = arguments
    }
}

public struct ExchangeUnbind: Sendable, Equatable {
    public var reserved1: UInt16
    public var destination: String
    public var source: String
    public var routingKey: String
    public var noWait: Bool
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        destination: String,
        source: String,
        routingKey: String = "",
        noWait: Bool = false,
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.destination = destination
        self.source = source
        self.routingKey = routingKey
        self.noWait = noWait
        self.arguments = arguments
    }
}

// Queue class payloads
public struct QueueDeclare: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var passive: Bool
    public var durable: Bool
    public var exclusive: Bool
    public var autoDelete: Bool
    public var noWait: Bool
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        queue: String = "",
        passive: Bool = false,
        durable: Bool = false,
        exclusive: Bool = false,
        autoDelete: Bool = false,
        noWait: Bool = false,
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.queue = queue
        self.passive = passive
        self.durable = durable
        self.exclusive = exclusive
        self.autoDelete = autoDelete
        self.noWait = noWait
        self.arguments = arguments
    }
}

public struct QueueDeclareOk: Sendable, Equatable {
    public var queue: String
    public var messageCount: UInt32
    public var consumerCount: UInt32

    public init(queue: String, messageCount: UInt32 = 0, consumerCount: UInt32 = 0) {
        self.queue = queue
        self.messageCount = messageCount
        self.consumerCount = consumerCount
    }
}

public struct QueueBind: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var exchange: String
    public var routingKey: String
    public var noWait: Bool
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        queue: String,
        exchange: String,
        routingKey: String = "",
        noWait: Bool = false,
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.queue = queue
        self.exchange = exchange
        self.routingKey = routingKey
        self.noWait = noWait
        self.arguments = arguments
    }
}

public struct QueueUnbind: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var exchange: String
    public var routingKey: String
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        queue: String,
        exchange: String,
        routingKey: String = "",
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.queue = queue
        self.exchange = exchange
        self.routingKey = routingKey
        self.arguments = arguments
    }
}

public struct QueuePurge: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var noWait: Bool

    public init(reserved1: UInt16 = 0, queue: String, noWait: Bool = false) {
        self.reserved1 = reserved1
        self.queue = queue
        self.noWait = noWait
    }
}

public struct QueuePurgeOk: Sendable, Equatable {
    public var messageCount: UInt32

    public init(messageCount: UInt32) {
        self.messageCount = messageCount
    }
}

public struct QueueDelete: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var ifUnused: Bool
    public var ifEmpty: Bool
    public var noWait: Bool

    public init(
        reserved1: UInt16 = 0,
        queue: String,
        ifUnused: Bool = false,
        ifEmpty: Bool = false,
        noWait: Bool = false
    ) {
        self.reserved1 = reserved1
        self.queue = queue
        self.ifUnused = ifUnused
        self.ifEmpty = ifEmpty
        self.noWait = noWait
    }
}

public struct QueueDeleteOk: Sendable, Equatable {
    public var messageCount: UInt32

    public init(messageCount: UInt32) {
        self.messageCount = messageCount
    }
}

// Basic class payloads
public struct BasicQos: Sendable, Equatable {
    public var prefetchSize: UInt32
    public var prefetchCount: UInt16
    public var global: Bool

    public init(prefetchSize: UInt32 = 0, prefetchCount: UInt16, global: Bool = false) {
        self.prefetchSize = prefetchSize
        self.prefetchCount = prefetchCount
        self.global = global
    }
}

/// Consumer acknowledgement mode.
public enum ConsumerAcknowledgementMode: Sendable {
    /// Messages must be explicitly acknowledged via `ack`, `nack`, or `reject`.
    case manual
    /// Messages are automatically acknowledged upon delivery.
    case automatic

    /// Converts to the AMQP `no_ack` field value.
    public var noAckFieldValue: Bool {
        self == .automatic
    }
}

public struct BasicConsume: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var consumerTag: String
    public var noLocal: Bool
    public var noAck: Bool
    public var exclusive: Bool
    public var noWait: Bool
    public var arguments: Table

    public init(
        reserved1: UInt16 = 0,
        queue: String,
        consumerTag: String = "",
        noLocal: Bool = false,
        noAck: Bool = false,
        exclusive: Bool = false,
        noWait: Bool = false,
        arguments: Table = [:]
    ) {
        self.reserved1 = reserved1
        self.queue = queue
        self.consumerTag = consumerTag
        self.noLocal = noLocal
        self.noAck = noAck
        self.exclusive = exclusive
        self.noWait = noWait
        self.arguments = arguments
    }
}

public struct BasicConsumeOk: Sendable, Equatable {
    public var consumerTag: String

    public init(consumerTag: String) {
        self.consumerTag = consumerTag
    }
}

public struct BasicCancel: Sendable, Equatable {
    public var consumerTag: String
    public var noWait: Bool

    public init(consumerTag: String, noWait: Bool = false) {
        self.consumerTag = consumerTag
        self.noWait = noWait
    }
}

public struct BasicCancelOk: Sendable, Equatable {
    public var consumerTag: String

    public init(consumerTag: String) {
        self.consumerTag = consumerTag
    }
}

public struct BasicPublish: Sendable, Equatable {
    public var reserved1: UInt16
    public var exchange: String
    public var routingKey: String
    public var mandatory: Bool
    public var immediate: Bool

    public init(
        reserved1: UInt16 = 0,
        exchange: String = "",
        routingKey: String,
        mandatory: Bool = false,
        immediate: Bool = false
    ) {
        self.reserved1 = reserved1
        self.exchange = exchange
        self.routingKey = routingKey
        self.mandatory = mandatory
        self.immediate = immediate
    }
}

public struct BasicReturn: Sendable, Equatable {
    public var replyCode: UInt16
    public var replyText: String
    public var exchange: String
    public var routingKey: String

    public init(replyCode: UInt16, replyText: String, exchange: String, routingKey: String) {
        self.replyCode = replyCode
        self.replyText = replyText
        self.exchange = exchange
        self.routingKey = routingKey
    }
}

public struct BasicDeliver: Sendable, Equatable {
    public var consumerTag: String
    public var deliveryTag: UInt64
    public var redelivered: Bool
    public var exchange: String
    public var routingKey: String

    public init(
        consumerTag: String,
        deliveryTag: UInt64,
        redelivered: Bool,
        exchange: String,
        routingKey: String
    ) {
        self.consumerTag = consumerTag
        self.deliveryTag = deliveryTag
        self.redelivered = redelivered
        self.exchange = exchange
        self.routingKey = routingKey
    }
}

public struct BasicGet: Sendable, Equatable {
    public var reserved1: UInt16
    public var queue: String
    public var noAck: Bool

    public init(reserved1: UInt16 = 0, queue: String, noAck: Bool = false) {
        self.reserved1 = reserved1
        self.queue = queue
        self.noAck = noAck
    }
}

public struct BasicGetOk: Sendable, Equatable {
    public var deliveryTag: UInt64
    public var redelivered: Bool
    public var exchange: String
    public var routingKey: String
    public var messageCount: UInt32

    public init(
        deliveryTag: UInt64,
        redelivered: Bool,
        exchange: String,
        routingKey: String,
        messageCount: UInt32
    ) {
        self.deliveryTag = deliveryTag
        self.redelivered = redelivered
        self.exchange = exchange
        self.routingKey = routingKey
        self.messageCount = messageCount
    }
}

public struct BasicGetEmpty: Sendable, Equatable {
    public var reserved1: String

    public init(reserved1: String = "") {
        self.reserved1 = reserved1
    }
}

public struct BasicAck: Sendable, Equatable {
    public var deliveryTag: UInt64
    public var multiple: Bool

    public init(deliveryTag: UInt64, multiple: Bool = false) {
        self.deliveryTag = deliveryTag
        self.multiple = multiple
    }
}

public struct BasicReject: Sendable, Equatable {
    public var deliveryTag: UInt64
    public var requeue: Bool

    public init(deliveryTag: UInt64, requeue: Bool = true) {
        self.deliveryTag = deliveryTag
        self.requeue = requeue
    }
}

public struct BasicRecoverAsync: Sendable, Equatable {
    public var requeue: Bool

    public init(requeue: Bool = true) {
        self.requeue = requeue
    }
}

public struct BasicRecover: Sendable, Equatable {
    public var requeue: Bool

    public init(requeue: Bool = true) {
        self.requeue = requeue
    }
}

public struct BasicNack: Sendable, Equatable {
    public var deliveryTag: UInt64
    public var multiple: Bool
    public var requeue: Bool

    public init(deliveryTag: UInt64, multiple: Bool = false, requeue: Bool = true) {
        self.deliveryTag = deliveryTag
        self.multiple = multiple
        self.requeue = requeue
    }
}

// Confirm class payloads
public struct ConfirmSelect: Sendable, Equatable {
    public var noWait: Bool

    public init(noWait: Bool = false) {
        self.noWait = noWait
    }
}
