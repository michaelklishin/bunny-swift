// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

// Minimal RS256 JWT generator using swift-crypto.
// Works on both macOS and Linux.

import Foundation
import _CryptoExtras

/// Generates RS256-signed JWT tokens for RabbitMQ OAuth2 testing.
struct JWTGenerator {
  private let privateKey: _RSA.Signing.PrivateKey
  let kid: String

  /// Loads an RSA private key from a PEM file (PKCS#8 and PKCS#1 are both supported).
  init(pemPath: String, kid: String) throws {
    let pemString = try String(contentsOfFile: pemPath, encoding: .utf8)
    self.kid = kid
    self.privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: pemString)
  }

  /// Generates a JWT with the given claims and lifetime.
  func generateToken(
    subject: String,
    audience: String,
    issuer: String,
    scope: String,
    lifetimeSeconds: Int = 3600
  ) throws -> String {
    let now = Int(Date().timeIntervalSince1970)

    let header = #"{"alg":"RS256","typ":"JWT","kid":"\#(kid)"}"#
    let payload =
      #"{"sub":"\#(subject)","aud":"\#(audience)","iss":"\#(issuer)","scope":"\#(scope)","iat":\#(now),"exp":\#(now + lifetimeSeconds)}"#

    let signingInput = base64url(Data(header.utf8)) + "." + base64url(Data(payload.utf8))

    let signature = try privateKey.signature(
      for: Data(signingInput.utf8),
      padding: .insecurePKCS1v1_5
    )

    return signingInput + "." + base64url(signature.rawRepresentation)
  }

  private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
