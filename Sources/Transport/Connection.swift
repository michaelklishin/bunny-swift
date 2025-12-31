// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import AMQPProtocol
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSL

// MARK: - Connection Configuration

/// Configuration for AMQP connection
public struct ConnectionConfiguration: Sendable {
  public var host: String
  public var port: Int
  public var virtualHost: String
  public var username: String
  public var password: String
  public var tls: TLSConfiguration?
  public var heartbeat: UInt16
  public var frameMax: UInt32
  public var channelMax: UInt16
  public var connectionTimeout: TimeAmount
  public var connectionName: String?

  /// Write buffering: number of frames before forcing a flush (lower = better latency)
  public var writeBufferFlushThreshold: Int
  /// Write buffering: max time before flushing pending writes
  public var writeBufferFlushInterval: TimeAmount

  public init(
    host: String = "localhost",
    port: Int = 5672,
    virtualHost: String = "/",
    username: String = "guest",
    password: String = "guest",
    tls: TLSConfiguration? = nil,
    heartbeat: UInt16 = 60,
    frameMax: UInt32 = 131072,
    channelMax: UInt16 = 2047,
    connectionTimeout: TimeAmount = .seconds(30),
    connectionName: String? = nil,
    writeBufferFlushThreshold: Int = 64,
    writeBufferFlushInterval: TimeAmount = .milliseconds(1)
  ) {
    self.host = host
    self.port = port
    self.virtualHost = virtualHost
    self.username = username
    self.password = password
    self.tls = tls
    self.heartbeat = heartbeat
    self.frameMax = frameMax
    self.channelMax = channelMax
    self.connectionTimeout = connectionTimeout
    self.connectionName = connectionName
    self.writeBufferFlushThreshold = writeBufferFlushThreshold
    self.writeBufferFlushInterval = writeBufferFlushInterval
  }

  /// Create configuration from AMQP URI
  public static func from(uri: String) throws -> ConnectionConfiguration {
    guard !uri.isEmpty, let url = URL(string: uri) else {
      throw ConnectionError.invalidURI(uri)
    }

    var config = ConnectionConfiguration()

    if let host = url.host {
      config.host = host
    }
    if let port = url.port {
      config.port = port
    }
    if url.scheme == "amqps" {
      config.tls = TLSConfiguration.makeClientConfiguration()
      if config.port == 5672 {
        config.port = 5671
      }
    }
    if let user = url.user {
      config.username = user
    }
    if let password = url.password {
      config.password = password
    }
    if !url.path.isEmpty && url.path != "/" {
      config.virtualHost = String(url.path.dropFirst())
    }

    return config
  }
}

// MARK: - TLS Configuration

/// TLS configuration options
public struct TLSConfiguration: Sendable {
  public var certificateChain: [NIOSSLCertificateSource]
  public var privateKey: NIOSSLPrivateKeySource?
  public var trustRoots: NIOSSLTrustRoots
  public var certificateVerification: CertificateVerification
  public var minimumTLSVersion: TLSVersion
  public var maximumTLSVersion: TLSVersion?

  public init(
    certificateChain: [NIOSSLCertificateSource] = [],
    privateKey: NIOSSLPrivateKeySource? = nil,
    trustRoots: NIOSSLTrustRoots = .default,
    certificateVerification: CertificateVerification = .fullVerification,
    minimumTLSVersion: TLSVersion = .tlsv12,
    maximumTLSVersion: TLSVersion? = nil
  ) {
    self.certificateChain = certificateChain
    self.privateKey = privateKey
    self.trustRoots = trustRoots
    self.certificateVerification = certificateVerification
    self.minimumTLSVersion = minimumTLSVersion
    self.maximumTLSVersion = maximumTLSVersion
  }

  /// Default client configuration with system trust roots
  public static func makeClientConfiguration() -> TLSConfiguration {
    TLSConfiguration()
  }

  /// Configuration that skips certificate verification (for testing only)
  public static func insecure() -> TLSConfiguration {
    TLSConfiguration(certificateVerification: .none)
  }

  /// Create a TLS configuration from PEM file paths.
  ///
  /// This is the recommended way to configure mutual TLS authentication.
  ///
  /// - Parameters:
  ///   - certificatePath: Path to client certificate PEM file
  ///   - keyPath: Path to client private key PEM file
  ///   - caCertificatePath: Path to CA certificate PEM file for server verification
  ///   - verifyPeer: Whether to verify server certificate (default: true)
  /// - Returns: A configured TLSConfiguration
  /// - Throws: If certificate files cannot be loaded
  public static func fromPEMFiles(
    certificatePath: String,
    keyPath: String,
    caCertificatePath: String,
    verifyPeer: Bool = true
  ) throws -> TLSConfiguration {
    let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
    let privateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
    let caCertificates = try NIOSSLCertificate.fromPEMFile(caCertificatePath)

    return TLSConfiguration(
      certificateChain: certificates.map { .certificate($0) },
      privateKey: .privateKey(privateKey),
      trustRoots: .certificates(caCertificates),
      certificateVerification: verifyPeer ? .fullVerification : .none
    )
  }

  /// Create a TLS configuration with only a CA certificate bundle.
  ///
  /// The client will verify the server but not the other way around.
  ///
  /// - Parameters:
  ///   - caCertificatePath: Path to CA certificate PEM file for server verification
  ///   - verifyPeer: Whether to verify server certificate (default: true)
  /// - Returns: A configured TLSConfiguration
  /// - Throws: If the CA certificate file cannot be loaded
  public static func withCACertificate(
    path caCertificatePath: String,
    verifyPeer: Bool = true
  ) throws -> TLSConfiguration {
    let caCertificates = try NIOSSLCertificate.fromPEMFile(caCertificatePath)

    return TLSConfiguration(
      trustRoots: .certificates(caCertificates),
      certificateVerification: verifyPeer ? .fullVerification : .none
    )
  }

  func toNIOSSLConfiguration() throws -> NIOSSL.TLSConfiguration {
    var config = NIOSSL.TLSConfiguration.makeClientConfiguration()
    config.certificateChain = certificateChain
    config.privateKey = privateKey
    config.trustRoots = trustRoots
    config.certificateVerification = certificateVerification
    config.minimumTLSVersion = minimumTLSVersion
    if let max = maximumTLSVersion {
      config.maximumTLSVersion = max
    }
    return config
  }
}

// MARK: - Connection Errors

public enum ConnectionError: Error, Sendable, LocalizedError {
  // Connection lifecycle
  case invalidURI(String)
  case connectionFailed(underlying: any Error & Sendable)
  case notConnected
  case alreadyConnected
  case heartbeatTimeout

  // Authentication
  case authenticationFailed(username: String, vhost: String, reason: String)

  // Protocol errors
  case protocolError(String)

  // Server-initiated closes
  case connectionClosed(replyCode: UInt16, replyText: String)
  case channelClosed(replyCode: UInt16, replyText: String, classID: UInt16, methodID: UInt16)

  // Publisher confirms
  case publisherNack(seqNo: UInt64)

  public var errorDescription: String? {
    switch self {
    case .invalidURI(let uri):
      return "Invalid AMQP URI: \(uri)"
    case .connectionFailed(let error):
      return "Connection failed: \(error)"
    case .notConnected:
      return "Not connected to RabbitMQ"
    case .alreadyConnected:
      return "Already connected"
    case .heartbeatTimeout:
      return "Heartbeat timeout - server unresponsive"
    case .authenticationFailed(let user, let vhost, let reason):
      return "Authentication failed for '\(user)' on vhost '\(vhost)': \(reason)"
    case .protocolError(let msg):
      return "Protocol error: \(msg)"
    case .connectionClosed(let code, let text):
      return "Connection closed by server (\(code)): \(text)"
    case .channelClosed(let code, let text, _, _):
      return "Channel closed by server (\(code)): \(text)"
    case .publisherNack(let seqNo):
      return "Message with sequence number \(seqNo) was nacked by broker"
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .invalidURI:
      return "Check URI format: amqp://user:pass@host:port/vhost"
    case .connectionFailed:
      return "Verify RabbitMQ is running and network is reachable"
    case .notConnected:
      return "Call connect() before performing operations"
    case .alreadyConnected:
      return "Close existing connection first or reuse it"
    case .heartbeatTimeout:
      return "Check network connectivity; consider increasing heartbeat interval"
    case .authenticationFailed:
      return "Verify credentials and vhost permissions in RabbitMQ"
    case .protocolError:
      return nil
    case .connectionClosed(let code, _):
      return recoverySuggestionForCode(code, isChannel: false)
    case .channelClosed(let code, _, _, _):
      return recoverySuggestionForCode(code, isChannel: true)
    case .publisherNack:
      return "The broker rejected the message; check exchange/queue configuration"
    }
  }

  /// Whether this is a soft error (channel-level, recoverable)
  public var isSoftError: Bool {
    switch self {
    case .channelClosed(let code, _, _, _):
      return AMQPReplyCode(rawValue: code)?.isSoftError ?? false
    default:
      return false
    }
  }

  /// Whether this is a hard error (connection-level, requires reconnect)
  public var isHardError: Bool {
    switch self {
    case .connectionClosed, .connectionFailed, .heartbeatTimeout, .authenticationFailed:
      return true
    case .channelClosed(let code, _, _, _):
      return AMQPReplyCode(rawValue: code)?.isHardError ?? false
    default:
      return false
    }
  }

  private func recoverySuggestionForCode(_ code: UInt16, isChannel: Bool) -> String? {
    guard let replyCode = AMQPReplyCode(rawValue: code) else { return nil }
    return replyCode.recoverySuggestion(isChannel: isChannel)
  }
}

// MARK: - AMQP Reply Codes

/// AMQP reply codes with classification and recovery guidance
public enum AMQPReplyCode: UInt16, Sendable {
  // Success
  case success = 200

  // Soft errors (channel closed, recoverable)
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

  public var isSoftError: Bool {
    switch self {
    case .contentTooLarge, .noRoute, .noConsumers,
      .accessRefused, .notFound, .resourceLocked, .preconditionFailed:
      return true
    default:
      return false
    }
  }

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

  public func recoverySuggestion(isChannel: Bool) -> String? {
    switch self {
    case .success:
      return nil
    case .contentTooLarge:
      return "Reduce message size or increase server limits"
    case .noRoute:
      return "Ensure queue is bound to exchange with matching routing key"
    case .noConsumers:
      return "Start consumers before publishing with immediate flag"
    case .accessRefused:
      return "Check user permissions for this resource in RabbitMQ"
    case .notFound:
      return "Declare queue/exchange before use, or check spelling"
    case .resourceLocked:
      return "Exclusive queue accessed from wrong connection"
    case .preconditionFailed:
      return
        "Queue/exchange exists with different properties; delete and recreate or use matching properties"
    case .connectionForced:
      return "Server closed connection; check server logs"
    case .invalidPath:
      return "Vhost does not exist; create it in RabbitMQ"
    case .frameError, .syntaxError, .commandInvalid, .unexpectedFrame:
      return "Protocol violation - this may be a client bug"
    case .channelError:
      return "Channel error; open a new channel"
    case .resourceError:
      return "Server resource exhausted; check memory/disk alarms"
    case .notAllowed:
      return "Operation not allowed; check RabbitMQ configuration"
    case .notImplemented:
      return "Feature not supported by this RabbitMQ version"
    case .internalError:
      return "Server internal error; check RabbitMQ logs"
    }
  }
}

// MARK: - Negotiated Parameters

/// Parameters negotiated during connection handshake
public struct NegotiatedParameters: Sendable {
  public let channelMax: UInt16
  public let frameMax: UInt32
  public let heartbeat: UInt16
  public let serverProperties: Table

  public init(
    channelMax: UInt16,
    frameMax: UInt32,
    heartbeat: UInt16,
    serverProperties: Table
  ) {
    self.channelMax = channelMax
    self.frameMax = frameMax
    self.heartbeat = heartbeat
    self.serverProperties = serverProperties
  }
}
