// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Minimal RabbitMQ HTTP API client for integration tests.
// Modelled after Hop (Java) and rabbitmq-http-api-client (Rust).

import Foundation

/// A lightweight RabbitMQ HTTP API client for use in tests.
struct RabbitMQHTTPAPIClient {
  let endpoint: URL
  let username: String
  let password: String

  init(
    endpoint: String = "http://127.0.0.1:15672",
    username: String = "guest",
    password: String = "guest"
  ) {
    self.endpoint = URL(string: endpoint)!
    self.username = username
    self.password = password
  }

  // MARK: - Connections

  func listConnections() async throws -> [ConnectionInfo] {
    try await get("/api/connections")
  }

  func getConnection(_ name: String) async throws -> ConnectionInfo {
    try await get("/api/connections/\(encodePathSegment(name))")
  }

  /// Close a connection by its server-assigned name.
  func closeConnection(_ name: String, reason: String? = nil) async throws {
    var headers: [String: String] = [:]
    if let reason { headers["X-Reason"] = reason }
    try await delete("/api/connections/\(encodePathSegment(name))", headers: headers)
  }

  /// Close all connections whose `client_properties.connection_name` matches.
  /// Retries for up to `timeout` seconds because RabbitMQ stats are emitted
  /// periodically (every 5 s by default) and the connection may not appear
  /// in the listing immediately after being opened.
  func closeAllConnectionsWithName(
    _ connectionName: String, timeout: TimeInterval = 10
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let connections: [ConnectionInfo] = try await listConnections()
      let matching = connections.filter {
        $0.clientProperties.connectionName == connectionName
      }
      if !matching.isEmpty {
        for conn in matching {
          try await closeConnection(conn.name, reason: "Closed by test")
        }
        return
      }
      if Date() >= deadline {
        throw HTTPAPIError.connectionNotFound(connectionName)
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  // MARK: - Channels

  func listChannels() async throws -> [ChannelInfo] {
    try await get("/api/channels")
  }

  func getChannel(_ name: String) async throws -> ChannelInfo {
    try await get("/api/channels/\(encodePathSegment(name))")
  }

  // MARK: - Queues

  func listQueues(in vhost: String = "/") async throws -> [QueueInfo] {
    try await get("/api/queues/\(encodePathSegment(vhost))")
  }

  func getQueue(_ name: String, in vhost: String = "/") async throws -> QueueInfo {
    try await get("/api/queues/\(encodePathSegment(vhost))/\(encodePathSegment(name))")
  }

  func getQueueOrNil(_ name: String, in vhost: String = "/") async -> QueueInfo? {
    try? await getQueue(name, in: vhost)
  }

  func deleteQueue(_ name: String, in vhost: String = "/") async throws {
    try await delete(
      "/api/queues/\(encodePathSegment(vhost))/\(encodePathSegment(name))")
  }

  func purgeQueue(_ name: String, in vhost: String = "/") async throws {
    try await delete(
      "/api/queues/\(encodePathSegment(vhost))/\(encodePathSegment(name))/contents")
  }

  // MARK: - Bindings

  func listQueueBindings(
    queue: String, in vhost: String = "/"
  ) async throws -> [BindingInfo] {
    try await get(
      "/api/queues/\(encodePathSegment(vhost))/\(encodePathSegment(queue))/bindings")
  }

  func listExchangeBindingsAsSource(
    exchange: String, in vhost: String = "/"
  ) async throws -> [BindingInfo] {
    try await get(
      "/api/exchanges/\(encodePathSegment(vhost))/\(encodePathSegment(exchange))/bindings/source")
  }

  // MARK: - Exchanges

  func listExchanges(in vhost: String = "/") async throws -> [ExchangeInfo] {
    try await get("/api/exchanges/\(encodePathSegment(vhost))")
  }

  func getExchange(_ name: String, in vhost: String = "/") async throws -> ExchangeInfo {
    try await get("/api/exchanges/\(encodePathSegment(vhost))/\(encodePathSegment(name))")
  }

  func getExchangeOrNil(_ name: String, in vhost: String = "/") async -> ExchangeInfo? {
    try? await getExchange(name, in: vhost)
  }

  // MARK: - Consumers

  func listConsumers(in vhost: String = "/") async throws -> [ConsumerInfo] {
    try await get("/api/consumers/\(encodePathSegment(vhost))")
  }

  // MARK: - Publishing (for test verification only)

  /// Publish a message to an exchange via the HTTP API.
  /// Returns true if the message was routed to at least one queue.
  @discardableResult
  func publishMessage(
    exchange: String,
    routingKey: String,
    payload: String,
    in vhost: String = "/"
  ) async throws -> Bool {
    let body: [String: Any] = [
      "routing_key": routingKey,
      "payload": payload,
      "payload_encoding": "string",
      "properties": [String: Any](),
    ]
    let result: PublishResult = try await post(
      "/api/exchanges/\(encodePathSegment(vhost))/\(encodePathSegment(exchange))/publish",
      body: body
    )
    return result.routed
  }

  // MARK: - Getting Messages (for test verification only)

  /// Fetch messages from a queue via the HTTP API without consuming them.
  func getMessages(
    queue: String, count: Int = 1, requeue: Bool = true,
    in vhost: String = "/"
  ) async throws -> [HTTPMessage] {
    let body: [String: Any] = [
      "count": count,
      "ackmode": requeue ? "ack_requeue_true" : "ack_requeue_false",
      "encoding": "auto",
    ]
    return try await post(
      "/api/queues/\(encodePathSegment(vhost))/\(encodePathSegment(queue))/get",
      body: body
    )
  }

  // MARK: - Overview

  func getOverview() async throws -> OverviewInfo {
    try await get("/api/overview")
  }

  /// Returns true if the management API is reachable.
  var isAvailable: Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ManagedAtomic(false)
    let url = URL(string: "/api/overview", relativeTo: endpoint)!
    var request = URLRequest(url: url, timeoutInterval: 2)
    applyAuth(&request)
    URLSession.shared.dataTask(with: request) { _, response, _ in
      if let http = response as? HTTPURLResponse, http.statusCode == 200 {
        box.store(true)
      }
      semaphore.signal()
    }.resume()
    semaphore.wait()
    return box.load()
  }

  // MARK: - HTTP Primitives

  private func get<T: Decodable>(_ path: String) async throws -> T {
    let (data, response) = try await perform(path, method: "GET")
    let http = response as! HTTPURLResponse
    guard http.statusCode == 200 else {
      throw HTTPAPIError.unexpectedResponse(http.statusCode, path)
    }
    return try JSONDecoder.apiDecoder.decode(T.self, from: data)
  }

  private func post<T: Decodable>(
    _ path: String, body: [String: Any]
  ) async throws -> T {
    let jsonData = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await perform(
      path, method: "POST",
      extraHeaders: ["Content-Type": "application/json"],
      body: jsonData
    )
    let http = response as! HTTPURLResponse
    guard http.statusCode == 200 else {
      throw HTTPAPIError.unexpectedResponse(http.statusCode, path)
    }
    return try JSONDecoder.apiDecoder.decode(T.self, from: data)
  }

  private func delete(_ path: String, headers: [String: String] = [:]) async throws {
    let (_, response) = try await perform(path, method: "DELETE", extraHeaders: headers)
    let http = response as! HTTPURLResponse
    guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
      throw HTTPAPIError.unexpectedResponse(http.statusCode, path)
    }
  }

  private func perform(
    _ path: String,
    method: String,
    extraHeaders: [String: String] = [:],
    body: Data? = nil
  ) async throws -> (Data, URLResponse) {
    let url = URL(string: path, relativeTo: endpoint)!
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = method
    request.httpBody = body
    applyAuth(&request)
    for (key, value) in extraHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    return try await URLSession.shared.data(for: request)
  }

  private func applyAuth(_ request: inout URLRequest) {
    let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
    request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
  }

  // MARK: - Path Encoding

  /// Percent-encode a path segment, encoding all non-unreserved characters.
  /// Matches the behaviour of Hop's PercentEncoder.encodePathSegment and
  /// the Rust client's percent_encoding::NON_ALPHANUMERIC.
  private func encodePathSegment(_ segment: String) -> String {
    // RFC 3986 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
  }
}

// MARK: - Error

enum HTTPAPIError: Error, CustomStringConvertible {
  case unexpectedResponse(Int, String)
  case connectionNotFound(String)

  var description: String {
    switch self {
    case .unexpectedResponse(let code, let path):
      "HTTP \(code) for \(path)"
    case .connectionNotFound(let name):
      "Connection with client name '\(name)' not found in listing"
    }
  }
}

// MARK: - Response Types

struct ConnectionInfo: Decodable {
  let name: String
  let node: String
  let state: String?
  let channels: Int?
  let clientProperties: ClientProperties

  struct ClientProperties: Decodable {
    let connectionName: String?

    enum CodingKeys: String, CodingKey {
      case connectionName = "connection_name"
    }
  }

  enum CodingKeys: String, CodingKey {
    case name, node, state, channels
    case clientProperties = "client_properties"
  }
}

struct QueueInfo: Decodable {
  let name: String
  let vhost: String
  let durable: Bool
  let exclusive: Bool
  let autoDelete: Bool
  let messages: UInt32?
  let consumers: UInt32?
  let state: String?

  enum CodingKeys: String, CodingKey {
    case name, vhost, durable, exclusive, state, messages, consumers
    case autoDelete = "auto_delete"
  }
}

struct ExchangeInfo: Decodable {
  let name: String
  let vhost: String
  let type: String
  let durable: Bool
  let autoDelete: Bool

  enum CodingKeys: String, CodingKey {
    case name, vhost, type, durable
    case autoDelete = "auto_delete"
  }
}

struct ChannelInfo: Decodable {
  let name: String
  let node: String
  let number: Int
  let state: String?
  let connectionDetails: ConnectionDetails?
  let prefetchCount: Int?
  let consumerCount: Int?
  let messagesUnacknowledged: Int?
  let confirm: Bool?

  struct ConnectionDetails: Decodable {
    let name: String
    let peerHost: String?
    let peerPort: Int?

    enum CodingKeys: String, CodingKey {
      case name
      case peerHost = "peer_host"
      case peerPort = "peer_port"
    }
  }

  enum CodingKeys: String, CodingKey {
    case name, node, number, state, confirm
    case connectionDetails = "connection_details"
    case prefetchCount = "prefetch_count"
    case consumerCount = "consumer_count"
    case messagesUnacknowledged = "messages_unacknowledged"
  }
}

struct BindingInfo: Decodable {
  let source: String
  let destination: String
  let destinationType: String
  let routingKey: String
  let vhost: String

  enum CodingKeys: String, CodingKey {
    case source, destination, vhost
    case destinationType = "destination_type"
    case routingKey = "routing_key"
  }
}

struct ConsumerInfo: Decodable {
  let consumerTag: String
  let exclusive: Bool
  let ackRequired: Bool?
  let queue: ConsumerQueueInfo

  struct ConsumerQueueInfo: Decodable {
    let name: String
    let vhost: String
  }

  enum CodingKeys: String, CodingKey {
    case exclusive, queue
    case consumerTag = "consumer_tag"
    case ackRequired = "ack_required"
  }
}

struct PublishResult: Decodable {
  let routed: Bool
}

struct HTTPMessage: Decodable {
  let payload: String
  let payloadEncoding: String
  let exchange: String
  let routingKey: String
  let redelivered: Bool

  enum CodingKeys: String, CodingKey {
    case payload, exchange, redelivered
    case payloadEncoding = "payload_encoding"
    case routingKey = "routing_key"
  }
}

struct OverviewInfo: Decodable {
  let managementVersion: String

  enum CodingKeys: String, CodingKey {
    case managementVersion = "management_version"
  }
}

// MARK: - JSON Decoder

extension JSONDecoder {
  fileprivate static let apiDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    return decoder
  }()
}
