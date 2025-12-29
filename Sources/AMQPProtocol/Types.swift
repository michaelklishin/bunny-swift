// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation

// MARK: - Field Table

public typealias Table = [String: FieldValue]

// MARK: - Field Value

public enum FieldValue: Sendable, Equatable, Hashable {
    case boolean(Bool)
    case int8(Int8)
    case uint8(UInt8)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case float(Float)
    case double(Double)
    case decimal(scale: UInt8, value: UInt32)
    case string(String)
    case bytes(Data)
    case array([FieldValue])
    case timestamp(Date)
    case table(Table)
    case void
}

// MARK: - ExpressibleByLiteral Conformances

extension FieldValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}

extension FieldValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int64(value)
    }
}

extension FieldValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension FieldValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension FieldValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: FieldValue...) {
        self = .array(elements)
    }
}

extension FieldValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, FieldValue)...) {
        self = .table(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension FieldValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .void
    }
}

// MARK: - Convenience Accessors

extension FieldValue {
    public var boolValue: Bool? {
        if case .boolean(let v) = self { return v }
        return nil
    }

    /// Coerces from smaller integer types
    public var intValue: Int64? {
        switch self {
        case .int8(let v): return Int64(v)
        case .uint8(let v): return Int64(v)
        case .int16(let v): return Int64(v)
        case .uint16(let v): return Int64(v)
        case .int32(let v): return Int64(v)
        case .uint32(let v): return Int64(v)
        case .int64(let v): return v
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .float(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var dataValue: Data? {
        if case .bytes(let v) = self { return v }
        return nil
    }

    public var dateValue: Date? {
        if case .timestamp(let v) = self { return v }
        return nil
    }

    public var arrayValue: [FieldValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var tableValue: Table? {
        if case .table(let v) = self { return v }
        return nil
    }

    public var isVoid: Bool {
        if case .void = self { return true }
        return false
    }
}

// MARK: - Table Encoding

extension FieldValue {
    /// Encode a field value to wire format
    public func encode(to encoder: inout WireEncoder) throws {
        switch self {
        case .boolean(let v):
            encoder.writeUInt8(0x74)  // 't'
            encoder.writeBoolean(v)

        case .int8(let v):
            encoder.writeUInt8(0x62)  // 'b'
            encoder.writeInt8(v)

        case .uint8(let v):
            encoder.writeUInt8(0x42)  // 'B'
            encoder.writeUInt8(v)

        case .int16(let v):
            encoder.writeUInt8(0x73)  // 's'
            encoder.writeInt16(v)

        case .uint16(let v):
            encoder.writeUInt8(0x75)  // 'u'
            encoder.writeUInt16(v)

        case .int32(let v):
            encoder.writeUInt8(0x49)  // 'I'
            encoder.writeInt32(v)

        case .uint32(let v):
            encoder.writeUInt8(0x69)  // 'i'
            encoder.writeUInt32(v)

        case .int64(let v):
            encoder.writeUInt8(0x6C)  // 'l'
            encoder.writeInt64(v)

        case .float(let v):
            encoder.writeUInt8(0x66)  // 'f'
            encoder.writeFloat(v)

        case .double(let v):
            encoder.writeUInt8(0x64)  // 'd'
            encoder.writeDouble(v)

        case .decimal(let scale, let value):
            encoder.writeUInt8(0x44)  // 'D'
            encoder.writeUInt8(scale)
            encoder.writeUInt32(value)

        case .string(let v):
            encoder.writeUInt8(0x53)  // 'S'
            encoder.writeLongString(v)

        case .bytes(let v):
            encoder.writeUInt8(0x78)  // 'x'
            encoder.writeLongBytes(v)

        case .array(let v):
            encoder.writeUInt8(0x41)  // 'A'
            var arrayEncoder = WireEncoder()
            for element in v {
                try element.encode(to: &arrayEncoder)
            }
            encoder.writeLongBytes(arrayEncoder.encodedData)

        case .timestamp(let v):
            encoder.writeUInt8(0x54)  // 'T'
            encoder.writeUInt64(UInt64(v.timeIntervalSince1970))

        case .table(let v):
            encoder.writeUInt8(0x46)  // 'F'
            try encodeTable(v, to: &encoder)

        case .void:
            encoder.writeUInt8(0x56)  // 'V'
        }
    }

    /// Decode a field value from wire format
    public static func decode(from decoder: inout WireDecoder) throws -> FieldValue {
        let typeTag = try decoder.readUInt8()

        switch typeTag {
        case 0x74:  // 't' - boolean
            return .boolean(try decoder.readBoolean())

        case 0x62:  // 'b' - int8
            return .int8(try decoder.readInt8())

        case 0x42:  // 'B' - uint8
            return .uint8(try decoder.readUInt8())

        case 0x73:  // 's' - int16
            return .int16(try decoder.readInt16())

        case 0x75:  // 'u' - uint16
            return .uint16(try decoder.readUInt16())

        case 0x49:  // 'I' - int32
            return .int32(try decoder.readInt32())

        case 0x69:  // 'i' - uint32
            return .uint32(try decoder.readUInt32())

        case 0x6C:  // 'l' - int64
            return .int64(try decoder.readInt64())

        case 0x66:  // 'f' - float
            return .float(try decoder.readFloat())

        case 0x64:  // 'd' - double
            return .double(try decoder.readDouble())

        case 0x44:  // 'D' - decimal
            let scale = try decoder.readUInt8()
            let value = try decoder.readUInt32()
            return .decimal(scale: scale, value: value)

        case 0x53:  // 'S' - long string
            return .string(try decoder.readLongString())

        case 0x78:  // 'x' - byte array
            return .bytes(try decoder.readLongBytes())

        case 0x41:  // 'A' - array
            let arrayData = try decoder.readLongBytes()
            var arrayDecoder = WireDecoder(arrayData)
            var elements = [FieldValue]()
            while arrayDecoder.hasMore {
                elements.append(try FieldValue.decode(from: &arrayDecoder))
            }
            return .array(elements)

        case 0x54:  // 'T' - timestamp
            let timestamp = try decoder.readUInt64()
            return .timestamp(Date(timeIntervalSince1970: TimeInterval(timestamp)))

        case 0x46:  // 'F' - table
            return .table(try decodeTable(from: &decoder))

        case 0x56:  // 'V' - void
            return .void

        default:
            throw WireFormatError.unknownFieldType(typeTag)
        }
    }
}

// MARK: - Table Encoding Helpers

public func encodeTable(_ table: Table, to encoder: inout WireEncoder) throws {
    var tableEncoder = WireEncoder()
    for (key, value) in table {
        try tableEncoder.writeShortString(key)
        try value.encode(to: &tableEncoder)
    }
    encoder.writeLongBytes(tableEncoder.encodedData)
}

public func encodeTable(_ table: Table) throws -> Data {
    var encoder = WireEncoder()
    try encodeTable(table, to: &encoder)
    return encoder.encodedData
}

public func decodeTable(from decoder: inout WireDecoder) throws -> Table {
    let tableData = try decoder.readLongBytes()
    var tableDecoder = WireDecoder(tableData)
    var table = Table()
    while tableDecoder.hasMore {
        let key = try tableDecoder.readShortString()
        let value = try FieldValue.decode(from: &tableDecoder)
        table[key] = value
    }
    return table
}

public func decodeTable(from data: Data) throws -> Table {
    var decoder = WireDecoder(data)
    return try decodeTable(from: &decoder)
}

// MARK: - Basic Properties

public struct BasicProperties: Sendable, Equatable {
    public var contentType: String?
    public var contentEncoding: String?
    public var headers: Table?
    public var deliveryMode: DeliveryMode?
    public var priority: UInt8?
    public var correlationId: String?
    public var replyTo: String?
    public var expiration: String?
    public var messageId: String?
    public var timestamp: Date?
    public var type: String?
    public var userId: String?
    public var appId: String?
    public var clusterId: String?  // deprecated but still in spec

    public init(
        contentType: String? = nil,
        contentEncoding: String? = nil,
        headers: Table? = nil,
        deliveryMode: DeliveryMode? = nil,
        priority: UInt8? = nil,
        correlationId: String? = nil,
        replyTo: String? = nil,
        expiration: String? = nil,
        messageId: String? = nil,
        timestamp: Date? = nil,
        type: String? = nil,
        userId: String? = nil,
        appId: String? = nil,
        clusterId: String? = nil
    ) {
        self.contentType = contentType
        self.contentEncoding = contentEncoding
        self.headers = headers
        self.deliveryMode = deliveryMode
        self.priority = priority
        self.correlationId = correlationId
        self.replyTo = replyTo
        self.expiration = expiration
        self.messageId = messageId
        self.timestamp = timestamp
        self.type = type
        self.userId = userId
        self.appId = appId
        self.clusterId = clusterId
    }

    /// Persistent message properties (deliveryMode = 2)
    public static var persistent: BasicProperties {
        BasicProperties(deliveryMode: .persistent)
    }

    /// Transient message properties (deliveryMode = 1)
    public static var transient: BasicProperties {
        BasicProperties(deliveryMode: .transient)
    }

    /// Compute property flags for encoding
    public var propertyFlags: PropertyFlags {
        var flags = PropertyFlags()
        if contentType != nil { flags.insert(.contentType) }
        if contentEncoding != nil { flags.insert(.contentEncoding) }
        if headers != nil { flags.insert(.headers) }
        if deliveryMode != nil { flags.insert(.deliveryMode) }
        if priority != nil { flags.insert(.priority) }
        if correlationId != nil { flags.insert(.correlationId) }
        if replyTo != nil { flags.insert(.replyTo) }
        if expiration != nil { flags.insert(.expiration) }
        if messageId != nil { flags.insert(.messageId) }
        if timestamp != nil { flags.insert(.timestamp) }
        if type != nil { flags.insert(.type) }
        if userId != nil { flags.insert(.userId) }
        if appId != nil { flags.insert(.appId) }
        if clusterId != nil { flags.insert(.clusterId) }
        return flags
    }
}

// MARK: - Basic Properties Encoding

extension BasicProperties {
    /// Encode properties to wire format
    public func encode(to encoder: inout WireEncoder) throws {
        encoder.writeUInt16(propertyFlags.rawValue)

        if let v = contentType { try encoder.writeShortString(v) }
        if let v = contentEncoding { try encoder.writeShortString(v) }
        if let v = headers { try encodeTable(v, to: &encoder) }
        if let v = deliveryMode { encoder.writeUInt8(v.rawValue) }
        if let v = priority { encoder.writeUInt8(v) }
        if let v = correlationId { try encoder.writeShortString(v) }
        if let v = replyTo { try encoder.writeShortString(v) }
        if let v = expiration { try encoder.writeShortString(v) }
        if let v = messageId { try encoder.writeShortString(v) }
        if let v = timestamp { encoder.writeUInt64(UInt64(v.timeIntervalSince1970)) }
        if let v = type { try encoder.writeShortString(v) }
        if let v = userId { try encoder.writeShortString(v) }
        if let v = appId { try encoder.writeShortString(v) }
        if let v = clusterId { try encoder.writeShortString(v) }
    }

    /// Decode properties from wire format
    public static func decode(from decoder: inout WireDecoder) throws -> BasicProperties {
        let flagsRaw = try decoder.readUInt16()
        let flags = PropertyFlags(rawValue: flagsRaw)

        var props = BasicProperties()

        if flags.contains(.contentType) {
            props.contentType = try decoder.readShortString()
        }
        if flags.contains(.contentEncoding) {
            props.contentEncoding = try decoder.readShortString()
        }
        if flags.contains(.headers) {
            props.headers = try decodeTable(from: &decoder)
        }
        if flags.contains(.deliveryMode) {
            let mode = try decoder.readUInt8()
            props.deliveryMode = DeliveryMode(rawValue: mode)
        }
        if flags.contains(.priority) {
            props.priority = try decoder.readUInt8()
        }
        if flags.contains(.correlationId) {
            props.correlationId = try decoder.readShortString()
        }
        if flags.contains(.replyTo) {
            props.replyTo = try decoder.readShortString()
        }
        if flags.contains(.expiration) {
            props.expiration = try decoder.readShortString()
        }
        if flags.contains(.messageId) {
            props.messageId = try decoder.readShortString()
        }
        if flags.contains(.timestamp) {
            let ts = try decoder.readUInt64()
            props.timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
        }
        if flags.contains(.type) {
            props.type = try decoder.readShortString()
        }
        if flags.contains(.userId) {
            props.userId = try decoder.readShortString()
        }
        if flags.contains(.appId) {
            props.appId = try decoder.readShortString()
        }
        if flags.contains(.clusterId) {
            props.clusterId = try decoder.readShortString()
        }

        return props
    }
}

// MARK: - Fluent Builders

extension BasicProperties {
    public func withContentType(_ value: String) -> BasicProperties {
        var copy = self
        copy.contentType = value
        return copy
    }

    public func withContentEncoding(_ value: String) -> BasicProperties {
        var copy = self
        copy.contentEncoding = value
        return copy
    }

    public func withHeaders(_ value: Table) -> BasicProperties {
        var copy = self
        copy.headers = value
        return copy
    }

    public func withDeliveryMode(_ value: DeliveryMode) -> BasicProperties {
        var copy = self
        copy.deliveryMode = value
        return copy
    }

    public func withPriority(_ value: UInt8) -> BasicProperties {
        var copy = self
        copy.priority = value
        return copy
    }

    public func withCorrelationId(_ value: String) -> BasicProperties {
        var copy = self
        copy.correlationId = value
        return copy
    }

    public func withReplyTo(_ value: String) -> BasicProperties {
        var copy = self
        copy.replyTo = value
        return copy
    }

    /// TTL in milliseconds as string
    public func withExpiration(_ value: String) -> BasicProperties {
        var copy = self
        copy.expiration = value
        return copy
    }

    /// TTL in milliseconds (AMQP 0-9-1 requires string encoding)
    public func withExpiration(milliseconds: Int) -> BasicProperties {
        withExpiration(String(milliseconds))
    }

    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    public func withExpiration(_ duration: Duration) -> BasicProperties {
        let milliseconds = Int64(duration.components.seconds) * 1000 +
                          Int64(duration.components.attoseconds) / 1_000_000_000_000_000
        return withExpiration(String(milliseconds))
    }

    public func withMessageId(_ value: String) -> BasicProperties {
        var copy = self
        copy.messageId = value
        return copy
    }

    public func withTimestamp(_ value: Date) -> BasicProperties {
        var copy = self
        copy.timestamp = value
        return copy
    }

    public func withType(_ value: String) -> BasicProperties {
        var copy = self
        copy.type = value
        return copy
    }

    public func withUserId(_ value: String) -> BasicProperties {
        var copy = self
        copy.userId = value
        return copy
    }

    public func withAppId(_ value: String) -> BasicProperties {
        var copy = self
        copy.appId = value
        return copy
    }
}
