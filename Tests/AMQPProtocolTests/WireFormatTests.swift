// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// WireFormat Tests
// Tests for AMQP wire format encoding/decoding

import Foundation
import Testing
@testable import AMQPProtocol

@Suite("WireEncoder Tests")
struct WireEncoderTests {
    @Test("writeUInt8 encodes single byte")
    func writeUInt8() {
        var encoder = WireEncoder()
        encoder.writeUInt8(0xAB)
        #expect(encoder.encodedData == Data([0xAB]))
    }

    @Test("writeInt8 encodes signed byte")
    func writeInt8() {
        var encoder = WireEncoder()
        encoder.writeInt8(-1)
        #expect(encoder.encodedData == Data([0xFF]))

        var encoder2 = WireEncoder()
        encoder2.writeInt8(127)
        #expect(encoder2.encodedData == Data([0x7F]))
    }

    @Test("writeUInt16 encodes big-endian 16-bit integer")
    func writeUInt16() {
        var encoder = WireEncoder()
        encoder.writeUInt16(0x1234)
        #expect(encoder.encodedData == Data([0x12, 0x34]))
    }

    @Test("writeInt16 encodes signed 16-bit integer")
    func writeInt16() {
        var encoder = WireEncoder()
        encoder.writeInt16(-1)
        #expect(encoder.encodedData == Data([0xFF, 0xFF]))
    }

    @Test("writeUInt32 encodes big-endian 32-bit integer")
    func writeUInt32() {
        var encoder = WireEncoder()
        encoder.writeUInt32(0x12345678)
        #expect(encoder.encodedData == Data([0x12, 0x34, 0x56, 0x78]))
    }

    @Test("writeInt32 encodes signed 32-bit integer")
    func writeInt32() {
        var encoder = WireEncoder()
        encoder.writeInt32(-1)
        #expect(encoder.encodedData == Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    @Test("writeUInt64 encodes big-endian 64-bit integer")
    func writeUInt64() {
        var encoder = WireEncoder()
        encoder.writeUInt64(0x123456789ABCDEF0)
        #expect(encoder.encodedData == Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
    }

    @Test("writeInt64 encodes signed 64-bit integer")
    func writeInt64() {
        var encoder = WireEncoder()
        encoder.writeInt64(-1)
        #expect(encoder.encodedData == Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    @Test("writeFloat encodes IEEE 754 float")
    func writeFloat() {
        var encoder = WireEncoder()
        encoder.writeFloat(1.0)
        // 1.0 in IEEE 754 = 0x3F800000
        #expect(encoder.encodedData == Data([0x3F, 0x80, 0x00, 0x00]))
    }

    @Test("writeDouble encodes IEEE 754 double")
    func writeDouble() {
        var encoder = WireEncoder()
        encoder.writeDouble(1.0)
        // 1.0 in IEEE 754 double = 0x3FF0000000000000
        #expect(encoder.encodedData == Data([0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
    }

    @Test("writeShortString encodes length-prefixed string")
    func writeShortString() throws {
        var encoder = WireEncoder()
        try encoder.writeShortString("hello")
        #expect(encoder.encodedData == Data([5, 0x68, 0x65, 0x6C, 0x6C, 0x6F]))
    }

    @Test("writeShortString throws for strings over 255 bytes")
    func writeShortStringTooLong() {
        var encoder = WireEncoder()
        let longString = String(repeating: "x", count: 256)
        #expect(throws: WireFormatError.self) {
            try encoder.writeShortString(longString)
        }
    }

    @Test("writeLongString encodes 32-bit length prefix")
    func writeLongString() {
        var encoder = WireEncoder()
        encoder.writeLongString("test")
        #expect(encoder.encodedData == Data([0x00, 0x00, 0x00, 0x04, 0x74, 0x65, 0x73, 0x74]))
    }

    @Test("writeBits packs booleans into bytes")
    func writeBits() {
        var encoder = WireEncoder()
        encoder.writeBits([true, false, true, false, false, false, false, true])
        // bits: 1,0,1,0,0,0,0,1 = 0b10000101 = 0x85
        #expect(encoder.encodedData == Data([0x85]))
    }

    @Test("writeBits handles fewer than 8 bits")
    func writeBitsPartial() {
        var encoder = WireEncoder()
        encoder.writeBits([true, true, false])
        // bits: 1,1,0 padded with zeros = 0b00000011 = 0x03
        #expect(encoder.encodedData == Data([0x03]))
    }

    @Test("writeBits handles more than 8 bits")
    func writeBitsMultipleBytes() {
        var encoder = WireEncoder()
        encoder.writeBits([true, false, true, false, true, false, true, false, true])
        // First byte: 0b01010101 = 0x55, Second byte: 0b00000001 = 0x01
        #expect(encoder.encodedData == Data([0x55, 0x01]))
    }

    @Test("writeBoolean encodes as single byte")
    func writeBoolean() {
        var encoder = WireEncoder()
        encoder.writeBoolean(true)
        encoder.writeBoolean(false)
        #expect(encoder.encodedData == Data([0x01, 0x00]))
    }
}

@Suite("WireDecoder Tests")
struct WireDecoderTests {
    @Test("readUInt8 decodes single byte")
    func readUInt8() throws {
        var decoder = WireDecoder(Data([0xAB]))
        let value = try decoder.readUInt8()
        #expect(value == 0xAB)
        #expect(decoder.remaining == 0)
    }

    @Test("readInt8 decodes signed byte")
    func readInt8() throws {
        var decoder = WireDecoder(Data([0xFF]))
        let value = try decoder.readInt8()
        #expect(value == -1)
    }

    @Test("readUInt16 decodes big-endian 16-bit integer")
    func readUInt16() throws {
        var decoder = WireDecoder(Data([0x12, 0x34]))
        let value = try decoder.readUInt16()
        #expect(value == 0x1234)
    }

    @Test("readInt16 decodes signed 16-bit integer")
    func readInt16() throws {
        var decoder = WireDecoder(Data([0xFF, 0xFF]))
        let value = try decoder.readInt16()
        #expect(value == -1)
    }

    @Test("readUInt32 decodes big-endian 32-bit integer")
    func readUInt32() throws {
        var decoder = WireDecoder(Data([0x12, 0x34, 0x56, 0x78]))
        let value = try decoder.readUInt32()
        #expect(value == 0x12345678)
    }

    @Test("readInt32 decodes signed 32-bit integer")
    func readInt32() throws {
        var decoder = WireDecoder(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        let value = try decoder.readInt32()
        #expect(value == -1)
    }

    @Test("readUInt64 decodes big-endian 64-bit integer")
    func readUInt64() throws {
        var decoder = WireDecoder(Data([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]))
        let value = try decoder.readUInt64()
        #expect(value == 0x123456789ABCDEF0)
    }

    @Test("readInt64 decodes signed 64-bit integer")
    func readInt64() throws {
        var decoder = WireDecoder(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        let value = try decoder.readInt64()
        #expect(value == -1)
    }

    @Test("readFloat decodes IEEE 754 float")
    func readFloat() throws {
        var decoder = WireDecoder(Data([0x3F, 0x80, 0x00, 0x00]))
        let value = try decoder.readFloat()
        #expect(value == 1.0)
    }

    @Test("readDouble decodes IEEE 754 double")
    func readDouble() throws {
        var decoder = WireDecoder(Data([0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        let value = try decoder.readDouble()
        #expect(value == 1.0)
    }

    @Test("readShortString decodes length-prefixed string")
    func readShortString() throws {
        var decoder = WireDecoder(Data([5, 0x68, 0x65, 0x6C, 0x6C, 0x6F]))
        let value = try decoder.readShortString()
        #expect(value == "hello")
    }

    @Test("readLongString decodes 32-bit length-prefixed string")
    func readLongString() throws {
        var decoder = WireDecoder(Data([0x00, 0x00, 0x00, 0x04, 0x74, 0x65, 0x73, 0x74]))
        let value = try decoder.readLongString()
        #expect(value == "test")
    }

    @Test("readBits unpacks booleans from bytes")
    func readBits() throws {
        var decoder = WireDecoder(Data([0x85]))
        let bits = try decoder.readBits(8)
        #expect(bits == [true, false, true, false, false, false, false, true])
    }

    @Test("readBits handles fewer than 8 bits")
    func readBitsPartial() throws {
        var decoder = WireDecoder(Data([0x03]))
        let bits = try decoder.readBits(3)
        #expect(bits == [true, true, false])
    }

    @Test("readBoolean decodes single byte to bool")
    func readBoolean() throws {
        var decoder = WireDecoder(Data([0x01, 0x00]))
        #expect(try decoder.readBoolean() == true)
        #expect(try decoder.readBoolean() == false)
    }

    @Test("peekUInt8 reads without advancing position")
    func peekUInt8() throws {
        let decoder = WireDecoder(Data([0xAB, 0xCD]))
        let value = try decoder.peekUInt8()
        #expect(value == 0xAB)
        #expect(decoder.position == 0)
    }

    @Test("skip advances position")
    func skip() throws {
        var decoder = WireDecoder(Data([0x01, 0x02, 0x03, 0x04]))
        try decoder.skip(2)
        let value = try decoder.readUInt8()
        #expect(value == 0x03)
    }

    @Test("throws on insufficient data")
    func insufficientData() {
        var decoder = WireDecoder(Data([0x01]))
        #expect(throws: WireFormatError.self) {
            _ = try decoder.readUInt16()
        }
    }
}

@Suite("Wire Format Roundtrip Tests")
struct WireFormatRoundtripTests {
    @Test("UInt8 roundtrip", arguments: [UInt8.min, UInt8.max, 0, 1, 127, 128, 255])
    func uint8Roundtrip(value: UInt8) throws {
        var encoder = WireEncoder()
        encoder.writeUInt8(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readUInt8() == value)
    }

    @Test("Int8 roundtrip", arguments: [Int8.min, Int8.max, 0, 1, -1, 127, -128])
    func int8Roundtrip(value: Int8) throws {
        var encoder = WireEncoder()
        encoder.writeInt8(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readInt8() == value)
    }

    @Test("UInt16 roundtrip", arguments: [UInt16.min, UInt16.max, 0, 1, 0x1234, 0xFF00, 0x00FF])
    func uint16Roundtrip(value: UInt16) throws {
        var encoder = WireEncoder()
        encoder.writeUInt16(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readUInt16() == value)
    }

    @Test("Int16 roundtrip", arguments: [Int16.min, Int16.max, 0, 1, -1, 0x1234, -0x1234])
    func int16Roundtrip(value: Int16) throws {
        var encoder = WireEncoder()
        encoder.writeInt16(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readInt16() == value)
    }

    @Test("UInt32 roundtrip", arguments: [UInt32.min, UInt32.max, 0, 1, 0x12345678, 0xFF000000])
    func uint32Roundtrip(value: UInt32) throws {
        var encoder = WireEncoder()
        encoder.writeUInt32(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readUInt32() == value)
    }

    @Test("Int32 roundtrip", arguments: [Int32.min, Int32.max, 0, 1, -1, 0x12345678, -0x12345678])
    func int32Roundtrip(value: Int32) throws {
        var encoder = WireEncoder()
        encoder.writeInt32(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readInt32() == value)
    }

    @Test("UInt64 roundtrip")
    func uint64Roundtrip() throws {
        let values: [UInt64] = [UInt64.min, UInt64.max, 0, 1, 0x123456789ABCDEF0]
        for value in values {
            var encoder = WireEncoder()
            encoder.writeUInt64(value)
            var decoder = encoder.encodedData.wireDecoder()
            #expect(try decoder.readUInt64() == value)
        }
    }

    @Test("Int64 roundtrip")
    func int64Roundtrip() throws {
        let values: [Int64] = [Int64.min, Int64.max, 0, 1, -1, 0x123456789ABCDEF0]
        for value in values {
            var encoder = WireEncoder()
            encoder.writeInt64(value)
            var decoder = encoder.encodedData.wireDecoder()
            #expect(try decoder.readInt64() == value)
        }
    }

    @Test("Float roundtrip", arguments: [Float.zero, 1.0, -1.0, Float.pi, Float.greatestFiniteMagnitude])
    func floatRoundtrip(value: Float) throws {
        var encoder = WireEncoder()
        encoder.writeFloat(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readFloat() == value)
    }

    @Test("Double roundtrip", arguments: [Double.zero, 1.0, -1.0, Double.pi, Double.greatestFiniteMagnitude])
    func doubleRoundtrip(value: Double) throws {
        var encoder = WireEncoder()
        encoder.writeDouble(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readDouble() == value)
    }

    @Test("Short string roundtrip", arguments: ["", "hello", "test123", "unicode: 日本語"])
    func shortStringRoundtrip(value: String) throws {
        var encoder = WireEncoder()
        try encoder.writeShortString(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readShortString() == value)
    }

    @Test("Long string roundtrip")
    func longStringRoundtrip() throws {
        let values = ["", "hello", String(repeating: "x", count: 1000)]
        for value in values {
            var encoder = WireEncoder()
            encoder.writeLongString(value)
            var decoder = encoder.encodedData.wireDecoder()
            #expect(try decoder.readLongString() == value)
        }
    }

    @Test("Bytes roundtrip")
    func bytesRoundtrip() throws {
        let values = [Data(), Data([0x01, 0x02, 0x03]), Data(repeating: 0xAB, count: 100)]
        for value in values {
            var encoder = WireEncoder()
            encoder.writeLongBytes(value)
            var decoder = encoder.encodedData.wireDecoder()
            #expect(try decoder.readLongBytes() == value)
        }
    }

    @Test("Boolean roundtrip", arguments: [true, false])
    func booleanRoundtrip(value: Bool) throws {
        var encoder = WireEncoder()
        encoder.writeBoolean(value)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readBoolean() == value)
    }

    @Test("Bits roundtrip")
    func bitsRoundtrip() throws {
        let testCases: [[Bool]] = [
            [true],
            [false],
            [true, false],
            [true, true, true],
            [false, false, false, false],
            [true, false, true, false, true, false, true, false],
            [true, false, true, false, true, false, true, false, true],
        ]
        for bits in testCases {
            var encoder = WireEncoder()
            encoder.writeBits(bits)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try decoder.readBits(bits.count)
            #expect(decoded == bits, "Failed for bits: \(bits)")
        }
    }
}

@Suite("Wire Format Edge Cases")
struct WireFormatEdgeCaseTests {
    @Test("Empty data handling")
    func emptyData() {
        let decoder = WireDecoder(Data())
        #expect(decoder.remaining == 0)
        #expect(decoder.hasMore == false)
    }

    @Test("UTF-8 string encoding")
    func utf8Strings() throws {
        let strings = ["ASCII", "Ümläut", "日本語", "🎉🚀", "Mixed: café ☕"]
        for str in strings {
            var encoder = WireEncoder()
            try encoder.writeShortString(str)
            var decoder = encoder.encodedData.wireDecoder()
            #expect(try decoder.readShortString() == str)
        }
    }

    @Test("Maximum short string length")
    func maxShortString() throws {
        let maxString = String(repeating: "x", count: 255)
        var encoder = WireEncoder()
        try encoder.writeShortString(maxString)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readShortString() == maxString)
    }

    @Test("Sequential reads consume buffer correctly")
    func sequentialReads() throws {
        var encoder = WireEncoder()
        encoder.writeUInt8(1)
        encoder.writeUInt16(2)
        encoder.writeUInt32(3)
        encoder.writeUInt64(4)

        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readUInt8() == 1)
        #expect(try decoder.readUInt16() == 2)
        #expect(try decoder.readUInt32() == 3)
        #expect(try decoder.readUInt64() == 4)
        #expect(decoder.remaining == 0)
    }

    @Test("Short string with multibyte UTF-8 at limit")
    func shortStringMultibyteLimit() throws {
        // 63 emoji * 4 bytes each = 252 bytes, plus 3 ASCII = 255 bytes exactly
        let emoji = String(repeating: "🎉", count: 63)
        let str = emoji + "abc"
        #expect(str.utf8.count == 255)

        var encoder = WireEncoder()
        try encoder.writeShortString(str)
        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readShortString() == str)
    }

    @Test("Short string exceeds limit with multibyte")
    func shortStringMultibyteExceedsLimit() {
        // 64 emoji * 4 bytes = 256 bytes, exceeds limit
        let str = String(repeating: "🎉", count: 64)
        #expect(str.utf8.count == 256)

        var encoder = WireEncoder()
        #expect(throws: WireFormatError.self) {
            try encoder.writeShortString(str)
        }
    }

    @Test("Peek operations do not consume data")
    func peekDoesNotConsume() throws {
        let decoder = WireDecoder(Data([0x12, 0x34, 0x56, 0x78]))
        let peeked = try decoder.peekBytes(4)
        #expect(peeked == Data([0x12, 0x34, 0x56, 0x78]))
        #expect(decoder.position == 0)
        #expect(decoder.remaining == 4)
    }

    @Test("Read raw bytes")
    func readRawBytes() throws {
        var decoder = WireDecoder(Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        let bytes = try decoder.readBytes(3)
        #expect(bytes == Data([0x01, 0x02, 0x03]))
        #expect(decoder.remaining == 2)
    }

    @Test("Write raw bytes")
    func writeRawBytes() {
        var encoder = WireEncoder()
        encoder.writeBytes(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(encoder.encodedData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("Boundary values for integers")
    func boundaryValues() throws {
        var encoder = WireEncoder()
        encoder.writeUInt16(UInt16.max)
        encoder.writeUInt32(UInt32.max)
        encoder.writeInt16(Int16.min)
        encoder.writeInt32(Int32.min)

        var decoder = encoder.encodedData.wireDecoder()
        #expect(try decoder.readUInt16() == UInt16.max)
        #expect(try decoder.readUInt32() == UInt32.max)
        #expect(try decoder.readInt16() == Int16.min)
        #expect(try decoder.readInt32() == Int32.min)
    }
}
