// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing
@testable import Transport

@Suite("ConnectionConfiguration Tests")
struct ConnectionConfigurationTests {

    // MARK: - Default Values

    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = ConnectionConfiguration()
        #expect(config.host == "localhost")
        #expect(config.port == 5672)
        #expect(config.virtualHost == "/")
        #expect(config.username == "guest")
        #expect(config.password == "guest")
        #expect(config.tls == nil)
        #expect(config.heartbeat == 60)
        #expect(config.frameMax == 131072)
        #expect(config.channelMax == 2047)
    }

    // MARK: - URI Parsing

    @Test("Parse simple AMQP URI")
    func parseSimpleURI() throws {
        let config = try ConnectionConfiguration.from(uri: "amqp://localhost")
        #expect(config.host == "localhost")
        #expect(config.port == 5672)
        #expect(config.tls == nil)
    }

    @Test("Parse URI with credentials")
    func parseURIWithCredentials() throws {
        let config = try ConnectionConfiguration.from(uri: "amqp://user:pass@rabbit.example.com")
        #expect(config.host == "rabbit.example.com")
        #expect(config.username == "user")
        #expect(config.password == "pass")
    }

    @Test("Parse URI with port")
    func parseURIWithPort() throws {
        let config = try ConnectionConfiguration.from(uri: "amqp://localhost:5673")
        #expect(config.port == 5673)
    }

    @Test("Parse URI with vhost")
    func parseURIWithVhost() throws {
        let config = try ConnectionConfiguration.from(uri: "amqp://localhost/myvhost")
        #expect(config.virtualHost == "myvhost")
    }

    @Test("Parse AMQPS URI enables TLS")
    func parseAMQPSURI() throws {
        let config = try ConnectionConfiguration.from(uri: "amqps://secure.example.com")
        #expect(config.tls != nil)
        #expect(config.port == 5671)
    }

    @Test("Parse AMQPS URI with non-standard port preserves port")
    func parseAMQPSURIWithPort() throws {
        let config = try ConnectionConfiguration.from(uri: "amqps://secure.example.com:5673")
        #expect(config.port == 5673)
        #expect(config.tls != nil)
    }

    @Test("Parse full URI")
    func parseFullURI() throws {
        let config = try ConnectionConfiguration.from(uri: "amqp://admin:secret@rabbit.local:5673/production")
        #expect(config.host == "rabbit.local")
        #expect(config.port == 5673)
        #expect(config.username == "admin")
        #expect(config.password == "secret")
        #expect(config.virtualHost == "production")
    }

    @Test("Empty URI throws error")
    func emptyURIThrows() {
        #expect(throws: ConnectionError.self) {
            _ = try ConnectionConfiguration.from(uri: "")
        }
    }

    // MARK: - Write Buffer Configuration

    @Test("Write buffer configuration defaults")
    func writeBufferDefaults() {
        let config = ConnectionConfiguration()
        #expect(config.writeBufferFlushThreshold == 64)
    }

    @Test("Custom write buffer configuration")
    func customWriteBuffer() {
        let config = ConnectionConfiguration(
            writeBufferFlushThreshold: 128
        )
        #expect(config.writeBufferFlushThreshold == 128)
    }
}

@Suite("TLSConfiguration Tests")
struct TLSConfigurationTests {

    @Test("Default client configuration")
    func defaultClientConfig() {
        let config = TLSConfiguration.makeClientConfiguration()
        #expect(config.certificateVerification == .fullVerification)
        #expect(config.minimumTLSVersion == .tlsv12)
    }

    @Test("Insecure configuration disables verification")
    func insecureConfig() {
        let config = TLSConfiguration.insecure()
        #expect(config.certificateVerification == .none)
    }
}
