// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// AMQP 0-9-1 Protocol Constants

import Foundation

/// AMQP 0-9-1 protocol header
/// Format: "AMQP" + 0x00 + 0x00 + 0x09 + 0x01
public let amqpProtocolHeader = Data([0x41, 0x4D, 0x51, 0x50, 0x00, 0x00, 0x09, 0x01])

/// Frame types in AMQP 0-9-1
public enum FrameType: UInt8, Sendable {
    case method = 1
    case header = 2
    case body = 3
    case heartbeat = 8
}

/// Frame end marker
public let frameEnd: UInt8 = 0xCE

/// Default frame size limits
public enum FrameDefaults {
    public static let minSize: UInt32 = 4096
    public static let maxSize: UInt32 = 131072  // 128 KB
    public static let headerSize: Int = 7  // type(1) + channel(2) + size(4)
}

// MARK: - Class IDs

/// AMQP method class IDs
public enum ClassID: UInt16, Sendable {
    case connection = 10
    case channel = 20
    case exchange = 40
    case queue = 50
    case basic = 60
    case confirm = 85
    case tx = 90
}

// MARK: - Method IDs

/// Connection class method IDs
public enum ConnectionMethodID: UInt16, Sendable {
    case start = 10
    case startOk = 11
    case secure = 20
    case secureOk = 21
    case tune = 30
    case tuneOk = 31
    case open = 40
    case openOk = 41
    case close = 50
    case closeOk = 51
    case blocked = 60
    case unblocked = 61
    case updateSecret = 70
    case updateSecretOk = 71
}

/// Channel class method IDs
public enum ChannelMethodID: UInt16, Sendable {
    case open = 10
    case openOk = 11
    case flow = 20
    case flowOk = 21
    case close = 40
    case closeOk = 41
}

/// Exchange class method IDs
public enum ExchangeMethodID: UInt16, Sendable {
    case declare = 10
    case declareOk = 11
    case delete = 20
    case deleteOk = 21
    case bind = 30
    case bindOk = 31
    case unbind = 40
    case unbindOk = 51
}

/// Queue class method IDs
public enum QueueMethodID: UInt16, Sendable {
    case declare = 10
    case declareOk = 11
    case bind = 20
    case bindOk = 21
    case purge = 30
    case purgeOk = 31
    case delete = 40
    case deleteOk = 41
    case unbind = 50
    case unbindOk = 51
}

/// Basic class method IDs
public enum BasicMethodID: UInt16, Sendable {
    case qos = 10
    case qosOk = 11
    case consume = 20
    case consumeOk = 21
    case cancel = 30
    case cancelOk = 31
    case publish = 40
    case `return` = 50
    case deliver = 60
    case get = 70
    case getOk = 71
    case getEmpty = 72
    case ack = 80
    case reject = 90
    case recoverAsync = 100
    case recover = 110
    case recoverOk = 111
    case nack = 120
}

/// Tx class method IDs
public enum TxMethodID: UInt16, Sendable {
    case select = 10
    case selectOk = 11
    case commit = 20
    case commitOk = 21
    case rollback = 30
    case rollbackOk = 31
}

/// Confirm class method IDs
public enum ConfirmMethodID: UInt16, Sendable {
    case select = 10
    case selectOk = 11
}

// MARK: - Reply Codes

/// AMQP reply codes
public enum ReplyCode: UInt16, Sendable {
    // Success
    case success = 200

    // Soft errors (channel closed)
    case contentTooLarge = 311
    case noRoute = 312
    case noConsumers = 313
    case accessRefused = 403
    case notFound = 404
    case resourceLocked = 405
    case preconditionFailed = 406

    // Hard errors (connection closed)
    case connectionForced = 320
    case invalidPath = 402
    case frameError = 501
    case syntaxError = 502
    case commandInvalid = 503
    case channelError = 504
    case unexpectedFrame = 505
    case resourceError = 506
    case notAllowed = 530
    case notImplemented = 540
    case internalError = 541

    /// Whether this is a soft error (channel-level)
    public var isSoftError: Bool {
        switch self {
        case .contentTooLarge, .noRoute, .noConsumers,
             .accessRefused, .notFound, .resourceLocked, .preconditionFailed:
            return true
        default:
            return false
        }
    }

    /// Whether this is a hard error (connection-level)
    public var isHardError: Bool {
        switch self {
        case .connectionForced, .invalidPath, .frameError, .syntaxError,
             .commandInvalid, .channelError, .unexpectedFrame, .resourceError,
             .notAllowed, .notImplemented, .internalError:
            return true
        default:
            return false
        }
    }
}

// MARK: - Field Value Type Tags

/// AMQP table field value type tags
public enum FieldValueTag: UInt8, Sendable {
    case boolean = 0x74        // 't'
    case signedInt8 = 0x62     // 'b'
    case unsignedInt8 = 0x42   // 'B'  (RabbitMQ extension)
    case signedInt16 = 0x73    // 's'
    case unsignedInt16 = 0x75  // 'u'  (RabbitMQ extension)
    case signedInt32 = 0x49    // 'I'
    case unsignedInt32 = 0x69  // 'i'  (RabbitMQ extension)
    case signedInt64 = 0x6C    // 'l'
    case float32 = 0x66        // 'f'
    case float64 = 0x64        // 'd'
    case decimal = 0x44        // 'D'
    // shortString uses same tag as signedInt16 (0x73), not used separately
    case longString = 0x53     // 'S'
    case array = 0x41          // 'A'
    case timestamp = 0x54      // 'T'
    case table = 0x46          // 'F'
    case byteArray = 0x78      // 'x'
    case void = 0x56           // 'V'
}

// MARK: - Basic Properties Flags

/// Property flags for BasicProperties (14 optional properties)
public struct PropertyFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let contentType = PropertyFlags(rawValue: 1 << 15)
    public static let contentEncoding = PropertyFlags(rawValue: 1 << 14)
    public static let headers = PropertyFlags(rawValue: 1 << 13)
    public static let deliveryMode = PropertyFlags(rawValue: 1 << 12)
    public static let priority = PropertyFlags(rawValue: 1 << 11)
    public static let correlationId = PropertyFlags(rawValue: 1 << 10)
    public static let replyTo = PropertyFlags(rawValue: 1 << 9)
    public static let expiration = PropertyFlags(rawValue: 1 << 8)
    public static let messageId = PropertyFlags(rawValue: 1 << 7)
    public static let timestamp = PropertyFlags(rawValue: 1 << 6)
    public static let type = PropertyFlags(rawValue: 1 << 5)
    public static let userId = PropertyFlags(rawValue: 1 << 4)
    public static let appId = PropertyFlags(rawValue: 1 << 3)
    public static let clusterId = PropertyFlags(rawValue: 1 << 2)  // deprecated
}

// MARK: - Exchange Types

/// Standard AMQP exchange types
public enum ExchangeTypeName: String, Sendable {
    case direct = "direct"
    case fanout = "fanout"
    case topic = "topic"
    case headers = "headers"
}

// MARK: - Delivery Mode

/// Message delivery mode
public enum DeliveryMode: UInt8, Sendable {
    case transient = 1
    case persistent = 2
}
