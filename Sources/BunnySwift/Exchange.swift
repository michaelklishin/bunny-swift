// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import AMQPProtocol

public struct Exchange: Sendable {
    public let name: String
    public let type: ExchangeType
    private let channel: Channel

    internal init(channel: Channel, name: String, type: ExchangeType) {
        self.channel = channel
        self.name = name
        self.type = type
    }

    // MARK: - Publishing

    public func publish(
        _ body: Data,
        routingKey: String = "",
        mandatory: Bool = false,
        immediate: Bool = false,
        properties: BasicProperties = .persistent
    ) async throws {
        try await channel.basicPublish(
            body: body,
            exchange: name,
            routingKey: routingKey,
            mandatory: mandatory,
            immediate: immediate,
            properties: properties
        )
    }

    public func publish(
        _ message: String,
        routingKey: String = "",
        mandatory: Bool = false,
        immediate: Bool = false,
        properties: BasicProperties = .persistent
    ) async throws {
        guard let data = message.data(using: .utf8) else {
            throw ConnectionError.protocolError("Failed to encode message as UTF-8")
        }
        try await publish(data, routingKey: routingKey, mandatory: mandatory, immediate: immediate, properties: properties)
    }

    // MARK: - Binding

    @discardableResult
    public func bind(to source: Exchange, routingKey: String = "", arguments: Table = [:]) async throws -> Exchange {
        try await channel.exchangeBind(destination: name, source: source.name, routingKey: routingKey, arguments: arguments)
        return self
    }

    @discardableResult
    public func bind(to sourceName: String, routingKey: String = "", arguments: Table = [:]) async throws -> Exchange {
        try await channel.exchangeBind(destination: name, source: sourceName, routingKey: routingKey, arguments: arguments)
        return self
    }

    @discardableResult
    public func unbind(from source: Exchange, routingKey: String = "", arguments: Table = [:]) async throws -> Exchange {
        try await channel.exchangeUnbind(destination: name, source: source.name, routingKey: routingKey, arguments: arguments)
        return self
    }

    @discardableResult
    public func unbind(from sourceName: String, routingKey: String = "", arguments: Table = [:]) async throws -> Exchange {
        try await channel.exchangeUnbind(destination: name, source: sourceName, routingKey: routingKey, arguments: arguments)
        return self
    }

    // MARK: - Management

    public func delete(ifUnused: Bool = false) async throws {
        try await channel.exchangeDelete(name, ifUnused: ifUnused)
    }
}
