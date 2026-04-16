// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

@_exported import AMQPProtocol
import Foundation
import NIO
import Recovery
@_exported import Transport

public actor Connection {
  private var transport: AMQPTransport
  private let configuration: ConnectionConfiguration
  private var negotiatedParams: NegotiatedParameters?
  private var channels: [UInt16: Channel] = [:]
  private var nextChannelID: UInt16 = 1
  private var isOpen = false
  private var blockedReason: String?

  private var frameIterator: FrameIterator?
  private var frameDispatchTask: Task<Void, Never>?
  private var closedByClient = false
  private var recovering = false

  /// Resolved endpoint list, shuffled once at creation time.
  private var resolvedEndpoints: [Endpoint]
  private var endpointIndex: Int = 0

  // Pending response for connection-level (channel 0) RPC methods like update-secret.
  private var pendingConnectionResponse: CheckedContinuation<AMQPMethod, any Error>?

  private var onBlockedHandlers: [@Sendable (String) -> Void] = []
  private var onUnblockedHandlers: [@Sendable () -> Void] = []
  private var onCloseHandlers: [@Sendable (ConnectionClose) -> Void] = []
  private var onRecoveryHandlers: [@Sendable () async -> Void] = []
  private var onRecoveryFailureHandlers: [@Sendable (any Error) async -> Void] = []
  private var onQueueNameChangeHandlers:
    [@Sendable (_ oldName: String, _ newName: String) async -> Void] =
      []
  private var onConsumerTagChangeHandlers:
    [@Sendable (_ oldTag: String, _ newTag: String) async -> Void] = []

  // MARK: - Topology

  /// Recorded topology used for automatic recovery after reconnection.
  public let topologyRegistry: TopologyRegistry

  /// Optional filter to selectively exclude entities from topology recovery.
  private var _topologyRecoveryFilter: TopologyRecoveryFilter?

  /// Set a filter to selectively exclude entities from topology recovery.
  public func setTopologyRecoveryFilter(_ filter: TopologyRecoveryFilter?) {
    _topologyRecoveryFilter = filter
  }

  // MARK: - Initialization

  private init(transport: AMQPTransport, configuration: ConnectionConfiguration) {
    self.transport = transport
    self.configuration = configuration
    self.topologyRegistry = TopologyRegistry()

    var endpoints =
      configuration.endpoints.isEmpty
      ? [Endpoint(host: configuration.host, port: configuration.port)]
      : configuration.endpoints
    if configuration.shuffleEndpoints && endpoints.count > 1 {
      endpoints.shuffle()
    }
    self.resolvedEndpoints = endpoints
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
    let params = try await connectToNextEndpoint()
    self.negotiatedParams = params
    self.isOpen = true
    await startFrameDispatcher()
  }

  /// Tries each endpoint in sequence, advancing the index on failure.
  private func connectToNextEndpoint() async throws -> NegotiatedParameters {
    var lastError: (any Error)?
    for _ in resolvedEndpoints.indices {
      let endpoint = resolvedEndpoints[endpointIndex]
      var config = configuration
      config.host = endpoint.host
      config.port = endpoint.port
      do {
        return try await transport.connect(configuration: config)
      } catch {
        lastError = error
        endpointIndex = (endpointIndex + 1) % resolvedEndpoints.count
        await transport.resetForRecovery()
      }
    }
    throw lastError ?? ConnectionError.notConnected
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

  public func withChannel<T: Sendable>(
    _ operation: (Channel) async throws -> T
  ) async throws -> T {
    let channel = try await openChannel()
    do {
      let result = try await operation(channel)
      try await channel.close()
      return result
    } catch {
      try? await channel.close()
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

  /// Reads frames from the transport's AsyncStream in a non-actor-isolated Task,
  /// dispatching each frame into the Connection actor. This avoids an actor hop
  /// on the Transport for every inbound frame.
  private func startFrameDispatcher() async {
    guard let iterator = await transport.handoffFrameIterator() else { return }
    self.frameIterator = iterator
    frameDispatchTask = Task { [weak self, iterator] in
      while let frame = await iterator.next() {
        guard let self else { break }
        await self.dispatchFrame(frame)
      }
      guard let self else { return }
      await self.handleDisconnection()
    }
  }

  private func dispatchFrame(_ frame: Frame) async {
    switch frame {
    case .method(channelID: 0, let method):
      await handleConnectionMethod(method)
    case .method(let channelID, method: _),
      .header(let channelID, _, _, _),
      .body(let channelID, _):
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
      if let continuation = pendingConnectionResponse {
        pendingConnectionResponse = nil
        continuation.resume(throwing: ConnectionError.protocolError(close.replyText))
      }
      try? await transport.send(.method(channelID: 0, method: .connectionCloseOk))

    case .connectionBlocked(let blocked):
      blockedReason = blocked.reason
      for handler in onBlockedHandlers { handler(blocked.reason) }

    case .connectionUnblocked:
      blockedReason = nil
      for handler in onUnblockedHandlers { handler() }

    case .connectionUpdateSecretOk:
      pendingConnectionResponse?.resume(returning: method)
      pendingConnectionResponse = nil

    default:
      break
    }
  }

  // MARK: - Automatic Recovery

  /// Called when the frame dispatch loop terminates (network failure, heartbeat timeout).
  private func handleDisconnection() async {
    guard !closedByClient else { return }
    guard !recovering else { return }

    isOpen = false
    frameDispatchTask = nil
    frameIterator = nil

    if let continuation = pendingConnectionResponse {
      pendingConnectionResponse = nil
      continuation.resume(throwing: ConnectionError.notConnected)
    }

    await transport.markDisconnected()

    for channel in channels.values {
      await channel.handleConnectionLost()
    }

    guard configuration.automaticRecovery else {
      for channel in channels.values {
        await channel.terminateConsumers()
      }
      return
    }

    recovering = true
    Task { [weak self] in
      await self?.performRecovery()
    }
  }

  /// Attempts to reconnect, restore channels, and recover topology.
  private func performRecovery() async {
    defer { recovering = false }

    var attempt = 1
    var currentInterval = configuration.networkRecoveryInterval

    while !closedByClient {
      if let maxAttempts = configuration.maxRecoveryAttempts, attempt > maxAttempts {
        let error = ConnectionError.protocolError("Max recovery attempts (\(maxAttempts)) exceeded")
        for channel in channels.values {
          await channel.terminateConsumers()
        }
        for handler in onRecoveryFailureHandlers {
          await handler(error)
        }
        return
      }

      do {
        try await Task.sleep(for: .seconds(currentInterval))
      } catch {
        return
      }

      do {
        await transport.resetForRecovery()
        let params = try await connectToNextEndpoint()
        self.negotiatedParams = params
        self.isOpen = true

        // Start the frame dispatcher before channel recovery so RPC
        // responses (channel.open-ok, basic.qos-ok, etc.) are delivered.
        await startFrameDispatcher()

        for (_, channel) in channels {
          try await channel.recoverOnNewConnection()
        }

        if configuration.topologyRecovery {
          await recoverTopology()
        }

        for (_, channel) in channels {
          await channel.notifyRecovered()
        }

        for handler in onRecoveryHandlers {
          await handler()
        }
        return
      } catch {
        attempt += 1
        currentInterval = min(
          currentInterval * configuration.recoveryBackoffMultiplier,
          configuration.maxRecoveryInterval
        )
      }
    }
  }

  private func recoverTopology() async {
    guard let channel = channels.values.first else { return }
    let filter = _topologyRecoveryFilter

    // 1. Exchanges (skip predeclared amq.* and default exchange)
    for exchange in await topologyRegistry.allExchanges() {
      if exchange.name.isEmpty || exchange.name.hasPrefix("amq.") { continue }
      if let f = filter?.exchangeFilter, !f(exchange) { continue }
      do { try await channel.redeclareExchange(exchange) } catch {}
    }

    // 2. Queues (updating server-named queue names)
    for queue in await topologyRegistry.allQueues() {
      if let f = filter?.queueFilter, !f(queue) { continue }
      do {
        let newName = try await channel.redeclareQueue(queue)
        if queue.serverNamed && newName != queue.name {
          let oldName = queue.name
          await topologyRegistry.updateQueueName(from: oldName, to: newName)
          for handler in onQueueNameChangeHandlers {
            await handler(oldName, newName)
          }
        }
      } catch {}
    }

    // 3. Queue bindings
    for binding in await topologyRegistry.allQueueBindings() {
      if let f = filter?.queueBindingFilter, !f(binding) { continue }
      do {
        try await channel.queueBindWithoutRecording(
          queue: binding.queue,
          exchange: binding.exchange,
          routingKey: binding.routingKey,
          arguments: binding.arguments
        )
      } catch {}
    }

    // 4. Exchange bindings
    for binding in await topologyRegistry.allExchangeBindings() {
      if let f = filter?.exchangeBindingFilter, !f(binding) { continue }
      do {
        try await channel.exchangeBindWithoutRecording(
          destination: binding.destination,
          source: binding.source,
          routingKey: binding.routingKey,
          arguments: binding.arguments
        )
      } catch {}
    }

    // 5. Consumers (each channel recovers its own, respecting filter)
    for (_, ch) in channels {
      let tagChanges = await ch.recoverOwnConsumers(
        from: topologyRegistry, filter: filter?.consumerFilter)
      for (oldTag, newTag) in tagChanges {
        for handler in onConsumerTagChangeHandlers {
          await handler(oldTag, newTag)
        }
      }
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

  /// Direct access to the transport for bypassing the Connection actor on hot paths
  internal var transportRef: AMQPTransport { transport }

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

  /// Register a handler called after successful automatic recovery.
  public func onRecovery(_ handler: @escaping @Sendable () async -> Void) {
    onRecoveryHandlers.append(handler)
  }

  /// Register a handler called when recovery fails permanently (max attempts exceeded).
  public func onRecoveryFailure(_ handler: @escaping @Sendable (any Error) async -> Void) {
    onRecoveryFailureHandlers.append(handler)
  }

  /// Register a handler called when a server-named queue gets a new name after recovery.
  public func onQueueNameChange(
    _ handler: @escaping @Sendable (_ oldName: String, _ newName: String) async -> Void
  ) {
    onQueueNameChangeHandlers.append(handler)
  }

  /// Register a handler called when a consumer tag changes after recovery.
  public func onConsumerTagChange(
    _ handler: @escaping @Sendable (_ oldTag: String, _ newTag: String) async -> Void
  ) {
    onConsumerTagChangeHandlers.append(handler)
  }

  // MARK: - Secret Update

  /// Sends `connection.update-secret` to the broker, e.g. after an OAuth 2 token refresh.
  public func updateSecret(_ newSecret: String, reason: String) async throws {
    guard isOpen else { throw ConnectionError.notConnected }
    guard pendingConnectionResponse == nil else {
      throw ConnectionError.protocolError("Another connection-level RPC is already in progress")
    }

    let method = Method.connectionUpdateSecret(
      ConnectionUpdateSecret(newSecret: newSecret, reason: reason))
    try await transport.send(.method(channelID: 0, method: method))

    let response = try await withCheckedThrowingContinuation { continuation in
      pendingConnectionResponse = continuation
    }

    guard case .connectionUpdateSecretOk = response else {
      throw ConnectionError.protocolError("Expected connection.update-secret-ok")
    }
  }

  // MARK: - Close

  public func close() async throws {
    guard isOpen else { return }
    closedByClient = true
    isOpen = false

    if let continuation = pendingConnectionResponse {
      pendingConnectionResponse = nil
      continuation.resume(throwing: ConnectionError.notConnected)
    }

    for channel in channels.values {
      try? await channel.close()
    }
    channels.removeAll()

    // Stop the dispatch loop before closing the transport
    frameDispatchTask?.cancel()
    _ = await frameDispatchTask?.value
    frameDispatchTask = nil
    frameIterator = nil

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
  public var connectionName: String? { configuration.connectionName }

  /// The endpoint this connection last connected to.
  public var currentEndpoint: Endpoint { resolvedEndpoints[endpointIndex] }
}
