// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// AMQP 0-9-1 Wire Format Encoding/Decoding
// All multi-byte values are big-endian (network byte order)

import Foundation

// MARK: - Wire Format Encoder

/// Encodes values into AMQP wire format (big-endian).
/// Not Sendable: has mutating methods for sequential encoding.
public struct WireEncoder {
    private var data: Data

    public init(capacity: Int = 256) {
        self.data = Data()
        self.data.reserveCapacity(capacity)
    }

    /// Get the encoded data
    public var encodedData: Data {
        data
    }

    /// Current size of encoded data
    public var count: Int {
        data.count
    }

    // MARK: - Primitive Types

    /// Write a single byte
    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    /// Write a signed byte
    public mutating func writeInt8(_ value: Int8) {
        data.append(UInt8(bitPattern: value))
    }

    /// Write a 16-bit unsigned integer (big-endian)
    public mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    /// Write a 16-bit signed integer (big-endian)
    public mutating func writeInt16(_ value: Int16) {
        writeUInt16(UInt16(bitPattern: value))
    }

    /// Write a 32-bit unsigned integer (big-endian)
    public mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// Write a 32-bit signed integer (big-endian)
    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    /// Write a 64-bit unsigned integer (big-endian)
    public mutating func writeUInt64(_ value: UInt64) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// Write a 64-bit signed integer (big-endian)
    public mutating func writeInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value))
    }

    /// Write a 32-bit float (big-endian IEEE 754)
    public mutating func writeFloat(_ value: Float) {
        writeUInt32(value.bitPattern)
    }

    /// Write a 64-bit double (big-endian IEEE 754)
    public mutating func writeDouble(_ value: Double) {
        writeUInt64(value.bitPattern)
    }

    // MARK: - AMQP String Types

    /// Write a short string (max 255 bytes)
    /// Format: [length:1][data:length]
    public mutating func writeShortString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 255 else {
            throw WireFormatError.stringTooLong(length: bytes.count, maxLength: 255)
        }
        writeUInt8(UInt8(bytes.count))
        data.append(bytes)
    }

    /// Write a long string (up to 4GB)
    /// Format: [length:4][data:length]
    public mutating func writeLongString(_ value: String) {
        let bytes = Data(value.utf8)
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    /// Write raw bytes with a 32-bit length prefix
    public mutating func writeLongBytes(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }

    /// Write raw bytes without length prefix
    public mutating func writeBytes(_ value: Data) {
        data.append(value)
    }

    // MARK: - Bit Packing

    /// Write packed boolean flags (up to 8 flags per byte)
    public mutating func writeBits(_ flags: [Bool]) {
        var byteIndex = 0
        while byteIndex * 8 < flags.count {
            var byte: UInt8 = 0
            for bitIndex in 0..<8 {
                let flagIndex = byteIndex * 8 + bitIndex
                if flagIndex < flags.count && flags[flagIndex] {
                    byte |= UInt8(1 << bitIndex)
                }
            }
            writeUInt8(byte)
            byteIndex += 1
        }
    }

    /// Write a single boolean as a byte
    public mutating func writeBoolean(_ value: Bool) {
        writeUInt8(value ? 1 : 0)
    }
}

// MARK: - Wire Format Decoder

/// Decodes values from AMQP wire format (big-endian).
/// Not Sendable: has mutating methods for sequential decoding.
public struct WireDecoder {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    /// Current read position
    public var position: Int {
        offset
    }

    /// Bytes remaining to read
    public var remaining: Int {
        data.count - offset
    }

    /// Check if there's more data to read
    public var hasMore: Bool {
        offset < data.count
    }

    // MARK: - Primitive Types

    /// Read a single byte
    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw WireFormatError.insufficientData(needed: 1, available: remaining)
        }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    /// Read a signed byte
    public mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    /// Read a 16-bit unsigned integer (big-endian)
    public mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else {
            throw WireFormatError.insufficientData(needed: 2, available: remaining)
        }
        let start = data.startIndex + offset
        let value = (UInt16(data[start]) << 8) | UInt16(data[start + 1])
        offset += 2
        return value
    }

    /// Read a 16-bit signed integer (big-endian)
    public mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    /// Read a 32-bit unsigned integer (big-endian)
    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw WireFormatError.insufficientData(needed: 4, available: remaining)
        }
        let start = data.startIndex + offset
        let value = (UInt32(data[start]) << 24) |
                    (UInt32(data[start + 1]) << 16) |
                    (UInt32(data[start + 2]) << 8) |
                    UInt32(data[start + 3])
        offset += 4
        return value
    }

    /// Read a 32-bit signed integer (big-endian)
    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// Read a 64-bit unsigned integer (big-endian)
    public mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else {
            throw WireFormatError.insufficientData(needed: 8, available: remaining)
        }
        let start = data.startIndex + offset
        let high: UInt64 = (UInt64(data[start]) << 56) |
                           (UInt64(data[start + 1]) << 48) |
                           (UInt64(data[start + 2]) << 40) |
                           (UInt64(data[start + 3]) << 32)
        let low: UInt64 = (UInt64(data[start + 4]) << 24) |
                          (UInt64(data[start + 5]) << 16) |
                          (UInt64(data[start + 6]) << 8) |
                          UInt64(data[start + 7])
        offset += 8
        return high | low
    }

    /// Read a 64-bit signed integer (big-endian)
    public mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    /// Read a 32-bit float (big-endian IEEE 754)
    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    /// Read a 64-bit double (big-endian IEEE 754)
    public mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    // MARK: - AMQP String Types

    /// Read a short string (max 255 bytes)
    /// Format: [length:1][data:length]
    public mutating func readShortString() throws -> String {
        let length = Int(try readUInt8())
        guard remaining >= length else {
            throw WireFormatError.insufficientData(needed: length, available: remaining)
        }
        let start = data.startIndex + offset
        let bytes = data[start..<start + length]
        offset += length
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw WireFormatError.invalidUTF8
        }
        return string
    }

    /// Read a long string
    /// Format: [length:4][data:length]
    public mutating func readLongString() throws -> String {
        let length = Int(try readUInt32())
        guard remaining >= length else {
            throw WireFormatError.insufficientData(needed: length, available: remaining)
        }
        let start = data.startIndex + offset
        let bytes = data[start..<start + length]
        offset += length
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw WireFormatError.invalidUTF8
        }
        return string
    }

    /// Read raw bytes with a 32-bit length prefix
    public mutating func readLongBytes() throws -> Data {
        let length = Int(try readUInt32())
        guard remaining >= length else {
            throw WireFormatError.insufficientData(needed: length, available: remaining)
        }
        let start = data.startIndex + offset
        let bytes = data[start..<start + length]
        offset += length
        return Data(bytes)
    }

    /// Read a specific number of raw bytes
    public mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw WireFormatError.insufficientData(needed: count, available: remaining)
        }
        let start = data.startIndex + offset
        let bytes = data[start..<start + count]
        offset += count
        return Data(bytes)
    }

    /// Skip a number of bytes
    public mutating func skip(_ count: Int) throws {
        guard remaining >= count else {
            throw WireFormatError.insufficientData(needed: count, available: remaining)
        }
        offset += count
    }

    // MARK: - Bit Unpacking

    /// Read packed boolean flags
    public mutating func readBits(_ count: Int) throws -> [Bool] {
        let byteCount = (count + 7) / 8
        guard remaining >= byteCount else {
            throw WireFormatError.insufficientData(needed: byteCount, available: remaining)
        }

        var flags = [Bool]()
        flags.reserveCapacity(count)

        for byteIndex in 0..<byteCount {
            let byte = try readUInt8()
            for bitIndex in 0..<8 {
                let flagIndex = byteIndex * 8 + bitIndex
                if flagIndex < count {
                    flags.append((byte & (1 << bitIndex)) != 0)
                }
            }
        }

        return flags
    }

    /// Read a single boolean
    public mutating func readBoolean() throws -> Bool {
        try readUInt8() != 0
    }

    // MARK: - Peek Operations

    /// Peek at a byte without advancing the position
    public func peekUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw WireFormatError.insufficientData(needed: 1, available: remaining)
        }
        return data[data.startIndex + offset]
    }

    /// Peek at multiple bytes without advancing the position
    public func peekBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw WireFormatError.insufficientData(needed: count, available: remaining)
        }
        let start = data.startIndex + offset
        return Data(data[start..<start + count])
    }
}

// MARK: - Wire Format Errors

/// Errors that can occur during wire format encoding/decoding
public enum WireFormatError: Error, Sendable, Equatable {
    case insufficientData(needed: Int, available: Int)
    case stringTooLong(length: Int, maxLength: Int)
    case invalidUTF8
    case invalidFrameEnd(expected: UInt8, actual: UInt8)
    case unknownFrameType(UInt8)
    case unknownFieldType(UInt8)
    case frameTooLarge(size: UInt32, maxSize: UInt32)
}

// MARK: - Convenience Extensions

extension Data {
    /// Create a WireDecoder for this data
    public func wireDecoder() -> WireDecoder {
        WireDecoder(self)
    }
}
