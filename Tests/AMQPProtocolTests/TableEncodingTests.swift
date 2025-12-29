// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Table Encoding Tests
// Tests for AMQP field table and value encoding/decoding

import Foundation
import Testing
@testable import AMQPProtocol

@Suite("FieldValue Type Tests")
struct FieldValueTypeTests {
    @Test("Boolean field value")
    func booleanValue() throws {
        let values: [FieldValue] = [.boolean(true), .boolean(false)]
        for value in values {
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Int8 field value")
    func int8Value() throws {
        let testValues: [Int8] = [0, 1, -1, Int8.min, Int8.max]
        for v in testValues {
            let value = FieldValue.int8(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("UInt8 field value")
    func uint8Value() throws {
        let testValues: [UInt8] = [0, 1, UInt8.max]
        for v in testValues {
            let value = FieldValue.uint8(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Int16 field value")
    func int16Value() throws {
        let testValues: [Int16] = [0, 1, -1, Int16.min, Int16.max]
        for v in testValues {
            let value = FieldValue.int16(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("UInt16 field value")
    func uint16Value() throws {
        let testValues: [UInt16] = [0, 1, UInt16.max]
        for v in testValues {
            let value = FieldValue.uint16(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Int32 field value")
    func int32Value() throws {
        let testValues: [Int32] = [0, 1, -1, Int32.min, Int32.max]
        for v in testValues {
            let value = FieldValue.int32(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("UInt32 field value")
    func uint32Value() throws {
        let testValues: [UInt32] = [0, 1, UInt32.max]
        for v in testValues {
            let value = FieldValue.uint32(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Int64 field value")
    func int64Value() throws {
        let testValues: [Int64] = [0, 1, -1, Int64.min, Int64.max]
        for v in testValues {
            let value = FieldValue.int64(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Float field value")
    func floatValue() throws {
        let testValues: [Float] = [0.0, 1.0, -1.0, Float.pi, Float.greatestFiniteMagnitude]
        for v in testValues {
            let value = FieldValue.float(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Double field value")
    func doubleValue() throws {
        let testValues: [Double] = [0.0, 1.0, -1.0, Double.pi, Double.greatestFiniteMagnitude]
        for v in testValues {
            let value = FieldValue.double(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Decimal field value")
    func decimalValue() throws {
        let value = FieldValue.decimal(scale: 2, value: 12345)
        var encoder = WireEncoder()
        try value.encode(to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try FieldValue.decode(from: &decoder)
        #expect(decoded == value)
    }

    @Test("String field value")
    func stringValue() throws {
        let testValues = ["", "hello", "test with spaces", "unicode: 日本語 🎉"]
        for v in testValues {
            let value = FieldValue.string(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Bytes field value")
    func bytesValue() throws {
        let testValues = [Data(), Data([0x01, 0x02, 0x03]), Data(repeating: 0xAB, count: 100)]
        for v in testValues {
            let value = FieldValue.bytes(v)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Timestamp field value")
    func timestampValue() throws {
        let dates = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1234567890),
            Date()
        ]
        for date in dates {
            // Timestamps are stored as whole seconds
            let truncatedDate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
            let value = FieldValue.timestamp(truncatedDate)
            var encoder = WireEncoder()
            try value.encode(to: &encoder)
            var decoder = encoder.encodedData.wireDecoder()
            let decoded = try FieldValue.decode(from: &decoder)
            #expect(decoded == value)
        }
    }

    @Test("Void field value")
    func voidValue() throws {
        let value = FieldValue.void
        var encoder = WireEncoder()
        try value.encode(to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try FieldValue.decode(from: &decoder)
        #expect(decoded == value)
    }

    @Test("Array field value")
    func arrayValue() throws {
        let value = FieldValue.array([
            .string("hello"),
            .int32(42),
            .boolean(true)
        ])
        var encoder = WireEncoder()
        try value.encode(to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try FieldValue.decode(from: &decoder)
        #expect(decoded == value)
    }

    @Test("Nested array field value")
    func nestedArrayValue() throws {
        let value = FieldValue.array([
            .array([.string("nested"), .int32(1)]),
            .string("outer")
        ])
        var encoder = WireEncoder()
        try value.encode(to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try FieldValue.decode(from: &decoder)
        #expect(decoded == value)
    }
}

@Suite("Table Encoding Tests")
struct TableEncodingTests {
    @Test("Empty table")
    func emptyTable() throws {
        let table: Table = [:]
        let encoded = try encodeTable(table)
        let decoded = try decodeTable(from: encoded)
        #expect(decoded.isEmpty)
    }

    @Test("Simple table with string value")
    func simpleStringTable() throws {
        let table: Table = ["key": .string("value")]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)
        #expect(decoded["key"] == .string("value"))
    }

    @Test("Table with multiple value types")
    func mixedTypeTable() throws {
        let table: Table = [
            "string": .string("hello"),
            "int": .int32(42),
            "bool": .boolean(true),
            "double": .double(3.14)
        ]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)
        #expect(decoded["string"] == .string("hello"))
        #expect(decoded["int"] == .int32(42))
        #expect(decoded["bool"] == .boolean(true))
        #expect(decoded["double"] == .double(3.14))
    }

    @Test("Nested table")
    func nestedTable() throws {
        let inner: Table = ["inner_key": .string("inner_value")]
        let outer: Table = ["nested": .table(inner)]
        var encoder = WireEncoder()
        try encodeTable(outer, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)

        if case .table(let nested) = decoded["nested"] {
            #expect(nested["inner_key"] == .string("inner_value"))
        } else {
            Issue.record("Expected nested table")
        }
    }

    @Test("Table with array value")
    func tableWithArray() throws {
        let table: Table = [
            "array": .array([.string("a"), .string("b"), .string("c")])
        ]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)

        if case .array(let arr) = decoded["array"] {
            #expect(arr.count == 3)
            #expect(arr[0] == .string("a"))
        } else {
            Issue.record("Expected array")
        }
    }

    @Test("Table roundtrip preserves all types")
    func tableRoundtrip() throws {
        let table: Table = [
            "bool": .boolean(true),
            "int8": .int8(-42),
            "uint8": .uint8(200),
            "int16": .int16(-1000),
            "uint16": .uint16(60000),
            "int32": .int32(-100000),
            "uint32": .uint32(3000000000),
            "int64": .int64(-9000000000000),
            "float": .float(3.14),
            "double": .double(2.71828),
            "decimal": .decimal(scale: 2, value: 12345),
            "string": .string("test"),
            "bytes": .bytes(Data([0x01, 0x02, 0x03])),
            "void": .void,
            "timestamp": .timestamp(Date(timeIntervalSince1970: 1234567890)),
            "array": .array([.string("a"), .int32(1)]),
            "nested": .table(["inner": .string("value")])
        ]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)

        #expect(decoded["bool"] == table["bool"])
        #expect(decoded["int8"] == table["int8"])
        #expect(decoded["uint8"] == table["uint8"])
        #expect(decoded["int16"] == table["int16"])
        #expect(decoded["uint16"] == table["uint16"])
        #expect(decoded["int32"] == table["int32"])
        #expect(decoded["uint32"] == table["uint32"])
        #expect(decoded["int64"] == table["int64"])
        #expect(decoded["float"] == table["float"])
        #expect(decoded["double"] == table["double"])
        #expect(decoded["decimal"] == table["decimal"])
        #expect(decoded["string"] == table["string"])
        #expect(decoded["bytes"] == table["bytes"])
        #expect(decoded["void"] == table["void"])
        #expect(decoded["timestamp"] == table["timestamp"])
        #expect(decoded["array"] == table["array"])
        #expect(decoded["nested"] == table["nested"])
    }
}

@Suite("FieldValue Literal Conformance Tests")
struct FieldValueLiteralTests {
    @Test("ExpressibleByBooleanLiteral")
    func booleanLiteral() {
        let value: FieldValue = true
        #expect(value == .boolean(true))
        let value2: FieldValue = false
        #expect(value2 == .boolean(false))
    }

    @Test("ExpressibleByIntegerLiteral")
    func integerLiteral() {
        let value: FieldValue = 42
        #expect(value == .int64(42))
    }

    @Test("ExpressibleByFloatLiteral")
    func floatLiteral() {
        let value: FieldValue = 3.14
        #expect(value == .double(3.14))
    }

    @Test("ExpressibleByStringLiteral")
    func stringLiteral() {
        let value: FieldValue = "hello"
        #expect(value == .string("hello"))
    }

    @Test("ExpressibleByArrayLiteral")
    func arrayLiteral() {
        let value: FieldValue = [1, 2, 3]
        #expect(value == .array([.int64(1), .int64(2), .int64(3)]))
    }

    @Test("ExpressibleByDictionaryLiteral")
    func dictionaryLiteral() {
        let value: FieldValue = ["key": "value"]
        if case .table(let table) = value {
            #expect(table["key"] == .string("value"))
        } else {
            Issue.record("Expected table")
        }
    }

    @Test("ExpressibleByNilLiteral")
    func nilLiteral() {
        let value: FieldValue = nil
        #expect(value == .void)
    }
}

@Suite("FieldValue Accessor Tests")
struct FieldValueAccessorTests {
    @Test("boolValue accessor")
    func boolAccessor() {
        #expect(FieldValue.boolean(true).boolValue == true)
        #expect(FieldValue.string("test").boolValue == nil)
    }

    @Test("intValue accessor coerces integer types")
    func intAccessor() {
        #expect(FieldValue.int8(42).intValue == 42)
        #expect(FieldValue.uint8(200).intValue == 200)
        #expect(FieldValue.int16(-100).intValue == -100)
        #expect(FieldValue.uint16(60000).intValue == 60000)
        #expect(FieldValue.int32(-100000).intValue == -100000)
        #expect(FieldValue.uint32(3000000000).intValue == 3000000000)
        #expect(FieldValue.int64(-9000000000000).intValue == -9000000000000)
        #expect(FieldValue.string("test").intValue == nil)
    }

    @Test("doubleValue accessor")
    func doubleAccessor() {
        #expect(FieldValue.float(3.14).doubleValue! == Double(Float(3.14)))
        #expect(FieldValue.double(2.718).doubleValue == 2.718)
        #expect(FieldValue.string("test").doubleValue == nil)
    }

    @Test("stringValue accessor")
    func stringAccessor() {
        #expect(FieldValue.string("hello").stringValue == "hello")
        #expect(FieldValue.int32(42).stringValue == nil)
    }

    @Test("dataValue accessor")
    func dataAccessor() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(FieldValue.bytes(data).dataValue == data)
        #expect(FieldValue.string("test").dataValue == nil)
    }

    @Test("dateValue accessor")
    func dateAccessor() {
        let date = Date(timeIntervalSince1970: 1234567890)
        #expect(FieldValue.timestamp(date).dateValue == date)
        #expect(FieldValue.string("test").dateValue == nil)
    }

    @Test("arrayValue accessor")
    func arrayAccessor() {
        let arr: [FieldValue] = [.string("a"), .int32(1)]
        #expect(FieldValue.array(arr).arrayValue == arr)
        #expect(FieldValue.string("test").arrayValue == nil)
    }

    @Test("tableValue accessor")
    func tableAccessor() {
        let table: Table = ["key": .string("value")]
        #expect(FieldValue.table(table).tableValue == table)
        #expect(FieldValue.string("test").tableValue == nil)
    }

    @Test("isVoid accessor")
    func voidAccessor() {
        #expect(FieldValue.void.isVoid == true)
        #expect(FieldValue.string("test").isVoid == false)
    }
}

@Suite("Unknown Field Type Error Tests")
struct FieldTypeErrorTests {
    @Test("Unknown field type throws error")
    func unknownFieldType() {
        var decoder = WireDecoder(Data([0xFF, 0x00]))
        #expect(throws: WireFormatError.self) {
            _ = try FieldValue.decode(from: &decoder)
        }
    }
}

@Suite("Table with RabbitMQ Headers Tests")
struct RabbitMQHeadersTests {
    @Test("x-message-ttl header")
    func messageTTL() throws {
        let table: Table = ["x-message-ttl": .int32(60000)]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)
        #expect(decoded["x-message-ttl"]?.intValue == 60000)
    }

    @Test("x-max-length header")
    func maxLength() throws {
        let table: Table = ["x-max-length": .int32(1000)]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)
        #expect(decoded["x-max-length"]?.intValue == 1000)
    }

    @Test("x-dead-letter-exchange header")
    func deadLetterExchange() throws {
        let table: Table = ["x-dead-letter-exchange": .string("dlx")]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)
        #expect(decoded["x-dead-letter-exchange"]?.stringValue == "dlx")
    }

    @Test("x-queue-type header")
    func queueType() throws {
        let table: Table = ["x-queue-type": .string("quorum")]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)
        #expect(decoded["x-queue-type"]?.stringValue == "quorum")
    }

    @Test("CC and BCC headers (array of strings)")
    func ccBccHeaders() throws {
        let table: Table = [
            "CC": .array([.string("route1"), .string("route2")]),
            "BCC": .array([.string("hidden1")])
        ]
        var encoder = WireEncoder()
        try encodeTable(table, to: &encoder)
        var decoder = encoder.encodedData.wireDecoder()
        let decoded = try decodeTable(from: &decoder)

        if case .array(let cc) = decoded["CC"] {
            #expect(cc.count == 2)
            #expect(cc[0].stringValue == "route1")
        } else {
            Issue.record("Expected CC array")
        }
    }
}
