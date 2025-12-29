// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import NIO
@_exported import Transport
@_exported import AMQPProtocol

public actor Connection {
    private let transport: AMQPTransport
    private let configuration: ConnectionConfiguration
    private var negotiatedParams: NegotiatedParameters?
    private var channels: [UInt16: Channel] = [:]
    private var nextChannelID: UInt16 = 1
    private var isOpen = false
    private var blockedReason: String?

    private var onBlockedHandlers: [@Sendable (String) -> Void] = []
    private var onUnblockedHandlers: [@Sendable () -> Void] = []
    private var onCloseHandlers: [@Sendable (ConnectionClose) -> Void] = []

    private init(transport: AMQPTransport, configuration: ConnectionConfiguration) {
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: - Factory

    public static func open(_ configuration: ConnectionConfiguration) async throws -> Connection {
        let transport = AMQPTransport()
        let connection = Connection(transport: transport, configuration: configuration)
        try await connection.connect()
        return connection
    }

    public static func open(uri: String) async throws -> Connection {
        let configuration = try ConnectionConfiguration.from(uri: uri)
        return try await open(configuration)
    }

    public static func open(
        host: String = "localhost",
        port: Int = 5672,
        virtualHost: String = "/",
        username: String = "guest",
        password: String = "guest"
    ) async throws -> Connection {
        let configuration = ConnectionConfiguration(
            host: host,
            port: port,
            virtualHost: virtualHost,
            username: username,
            password: password
        )
        return try await open(configuration)
    }

    private func connect() async throws {
        let params = try await transport.connect(configuration: configuration)
        self.negotiatedParams = params
        self.isOpen = true
        await startFrameDispatcher()
    }

    // MARK: - Channels

    public func openChannel() async throws -> Channel {
        guard isOpen else {
            throw ConnectionError.notConnected
        }

        let channelID = try allocateChannelID()
        let channel = Channel(connection: self, channelID: channelID)
        channels[channelID] = channel
        do {
            try await channel.open()
            return channel
        } catch {
            channels.removeValue(forKey: channelID)
            throw error
        }
    }

    private func allocateChannelID() throws -> UInt16 {
        guard let params = negotiatedParams else {
            throw ConnectionError.notConnected
        }

        let maxChannels = params.channelMax == 0 ? UInt16.max : params.channelMax
        let startID = nextChannelID

        repeat {
            if channels[nextChannelID] == nil {
                let id = nextChannelID
                advanceChannelID(max: maxChannels)
                return id
            }
            advanceChannelID(max: maxChannels)
        } while nextChannelID != startID

        throw ConnectionError.protocolError("All \(maxChannels) channel IDs in use")
    }

    private func advanceChannelID(max: UInt16) {
        nextChannelID = nextChannelID < max ? nextChannelID + 1 : 1
    }

    internal func channelClosed(_ channelID: UInt16) {
        channels.removeValue(forKey: channelID)
    }

    // MARK: - Frame Dispatch

    private func startFrameDispatcher() async {
        await transport.setFrameHandler { [weak self] frame in
            guard let self = self else { return }
            await self.dispatchFrame(frame)
        }
    }

    private func dispatchFrame(_ frame: Frame) async {
        switch frame {
        case .method(channelID: 0, method: let method):
            await handleConnectionMethod(method)
        case .method(channelID: let channelID, method: _),
             .header(channelID: let channelID, _, _, _),
             .body(channelID: let channelID, _):
            if let channel = channels[channelID] {
                await channel.handleFrame(frame)
            }
        case .heartbeat:
            break
        }
    }

    private func handleConnectionMethod(_ method: AMQPMethod) async {
        switch method {
        case .connectionClose(let close):
            for handler in onCloseHandlers { handler(close) }
            isOpen = false
            try? await transport.send(.method(channelID: 0, method: .connectionCloseOk))
            await transport.forceClose()

        case .connectionBlocked(let blocked):
            blockedReason = blocked.reason
            for handler in onBlockedHandlers { handler(blocked.reason) }

        case .connectionUnblocked:
            blockedReason = nil
            for handler in onUnblockedHandlers { handler() }

        default:
            break
        }
    }

    // MARK: - Frame I/O

    internal func send(_ frame: Frame) async throws {
        guard isOpen else { throw ConnectionError.notConnected }
        try await transport.send(frame)
    }

    internal func write(_ frame: Frame) async throws {
        guard isOpen else { throw ConnectionError.notConnected }
        try await transport.write(frame)
    }

    internal func writeBatch(_ frames: [Frame]) async throws {
        guard isOpen else { throw ConnectionError.notConnected }
        try await transport.writeBatch(frames)
    }

    internal func flush() async {
        await transport.flush()
    }

    // MARK: - Events

    public func onBlocked(_ handler: @escaping @Sendable (String) -> Void) {
        onBlockedHandlers.append(handler)
    }

    public func onUnblocked(_ handler: @escaping @Sendable () -> Void) {
        onUnblockedHandlers.append(handler)
    }

    public func onClose(_ handler: @escaping @Sendable (ConnectionClose) -> Void) {
        onCloseHandlers.append(handler)
    }

    // MARK: - Close

    public func close() async throws {
        guard isOpen else { return }
        isOpen = false

        for channel in channels.values {
            try? await channel.close()
        }
        channels.removeAll()
        await transport.close()
    }

    // MARK: - Properties

    public var connected: Bool { isOpen }
    public var blocked: Bool { blockedReason != nil }
    public var blockedMessage: String? { blockedReason }
    public var serverProperties: Table? { negotiatedParams?.serverProperties }
    public var frameMax: UInt32 { negotiatedParams?.frameMax ?? FrameDefaults.maxSize }
    public var heartbeat: UInt16 { negotiatedParams?.heartbeat ?? 60 }
    public var channelMax: UInt16 { negotiatedParams?.channelMax ?? 2047 }
}
