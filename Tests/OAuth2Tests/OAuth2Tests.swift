// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// OAuth2 Update-Secret Integration Tests
//
// These tests require a RabbitMQ node configured with the OAuth2 auth backend
// and a static RSA signing key. They are skipped by default.
//
// To run:
//
//   RUN_OAUTH2_TESTS=1 swift test --filter OAuth2
//
// Required environment variables:
//
//   RUN_OAUTH2_TESTS=1:  enables the suite
//   OAUTH2_SIGNING_KEY_PATH: a path to a private RSA key in the PEM format (default: /tmp/oauth2-test-rmq/signing_key.pem)
//   OAUTH2_RABBITMQ_PORT: AMQP port of the target OAuth 2-configured node (default: 5680)

import Foundation
import Testing

@testable import BunnySwift

// MARK: - OAuth2 Test Configuration

private struct OAuth2Config {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["RUN_OAUTH2_TESTS"] == "1"
  }

  static var signingKeyPath: String {
    ProcessInfo.processInfo.environment["OAUTH2_SIGNING_KEY_PATH"]
      ?? "/tmp/oauth2-test-rmq/signing_key.pem"
  }

  static var port: Int {
    Int(ProcessInfo.processInfo.environment["OAUTH2_RABBITMQ_PORT"] ?? "5680") ?? 5680
  }

  static let kid = "test-key"
  static let subject = "oauth2-test-user"
  static let audience = "rabbitmq"
  static let issuer = "test-issuer"
  static let scope = "rabbitmq.configure:*/* rabbitmq.read:*/* rabbitmq.write:*/*"

  static func makeTokenGenerator() throws -> JWTGenerator {
    try JWTGenerator(pemPath: signingKeyPath, kid: kid)
  }

  static func generateToken(lifetimeSeconds: Int = 3600) throws -> String {
    let gen = try makeTokenGenerator()
    return try gen.generateToken(
      subject: subject,
      audience: audience,
      issuer: issuer,
      scope: scope,
      lifetimeSeconds: lifetimeSeconds
    )
  }

  static func openConnection(token: String) async throws -> Connection {
    let config = ConnectionConfiguration(
      port: port,
      username: subject,
      password: token
    )
    return try await Connection.open(config)
  }
}

// MARK: - Tests

@Suite("OAuth2 UpdateSecret Tests", .disabled(if: !OAuth2Config.enabled))
struct OAuth2UpdateSecretTests {

  @Test("connect with JWT and refresh token via update-secret", .timeLimit(.minutes(1)))
  func connectAndRefreshToken() async throws {
    let initialToken = try OAuth2Config.generateToken(lifetimeSeconds: 3600)
    let connection = try await OAuth2Config.openConnection(token: initialToken)
    defer { Task { try? await connection.close() } }

    let isConnected = await connection.connected
    #expect(isConnected)

    // Refresh the token via update-secret.
    let refreshedToken = try OAuth2Config.generateToken(lifetimeSeconds: 7200)
    try await connection.updateSecret(refreshedToken, reason: "token refresh")

    let stillConnected = await connection.connected
    #expect(stillConnected)

    // Verify that the connection is usable after the secret update
    let channel = try await connection.openChannel()
    let q = try await channel.queue("", exclusive: true)
    let queueName = await q.name
    #expect(!queueName.isEmpty)
    try await channel.close()
  }

  @Test("update-secret can be called multiple times with fresh tokens", .timeLimit(.minutes(1)))
  func multipleTokenRefreshes() async throws {
    let initialToken = try OAuth2Config.generateToken()
    let connection = try await OAuth2Config.openConnection(token: initialToken)
    defer { Task { try? await connection.close() } }

    for i in 1...3 {
      let freshToken = try OAuth2Config.generateToken(lifetimeSeconds: 3600 + i * 100)
      try await connection.updateSecret(freshToken, reason: "refresh #\(i)")
    }

    let isConnected = await connection.connected
    #expect(isConnected)
  }

  @Test("update-secret with invalid token is rejected by OAuth2 backend", .timeLimit(.minutes(1)))
  func invalidTokenRejected() async throws {
    let initialToken = try OAuth2Config.generateToken()
    let connection = try await OAuth2Config.openConnection(token: initialToken)
    defer { Task { try? await connection.close() } }

    // The server should close the connection (with the status code of `530 NOT_ALLOWED`)
    do {
      try await connection.updateSecret("this-is-not-a-valid-jwt", reason: "bad refresh")
      Issue.record("Expected an error from invalid token")
    } catch {
      let isDisconnected = await !connection.connected
      #expect(isDisconnected)
    }
  }
}
