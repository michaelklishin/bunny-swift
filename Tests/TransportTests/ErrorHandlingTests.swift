// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Testing
@testable import Transport

@Suite("Error Handling Tests")
struct ErrorHandlingTests {

    // MARK: - ConnectionError Tests

    @Test("ConnectionError has error descriptions")
    func errorDescriptions() {
        let errors: [ConnectionError] = [
            .invalidURI("amqp://bad"),
            .notConnected,
            .alreadyConnected,
            .heartbeatTimeout,
            .authenticationFailed(username: "guest", vhost: "/", reason: "ACCESS_REFUSED"),
            .protocolError("Bad frame"),
            .connectionClosed(replyCode: 320, replyText: "CONNECTION_FORCED"),
            .channelClosed(replyCode: 404, replyText: "NOT_FOUND", classID: 50, methodID: 10)
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("ConnectionError has recovery suggestions")
    func recoverySuggestions() {
        let errors: [ConnectionError] = [
            .invalidURI("bad"),
            .notConnected,
            .alreadyConnected,
            .heartbeatTimeout,
            .authenticationFailed(username: "guest", vhost: "/", reason: "test")
        ]

        for error in errors {
            #expect(error.recoverySuggestion != nil)
        }
    }

    @Test("Channel closed error is soft error for 404")
    func channelClosedIsSoftError() {
        let error = ConnectionError.channelClosed(
            replyCode: 404,
            replyText: "NOT_FOUND",
            classID: 50,
            methodID: 10
        )
        #expect(error.isSoftError == true)
        #expect(error.isHardError == false)
    }

    @Test("Connection closed error is hard error")
    func connectionClosedIsHardError() {
        let error = ConnectionError.connectionClosed(
            replyCode: 320,
            replyText: "CONNECTION_FORCED"
        )
        #expect(error.isHardError == true)
        #expect(error.isSoftError == false)
    }

    @Test("Heartbeat timeout is hard error")
    func heartbeatTimeoutIsHardError() {
        let error = ConnectionError.heartbeatTimeout
        #expect(error.isHardError == true)
    }

    @Test("Authentication failed is hard error")
    func authFailedIsHardError() {
        let error = ConnectionError.authenticationFailed(
            username: "guest",
            vhost: "/",
            reason: "ACCESS_REFUSED"
        )
        #expect(error.isHardError == true)
    }

    // MARK: - AMQPReplyCode Tests

    @Test("Soft error codes are classified correctly")
    func softErrorCodes() {
        let softCodes: [AMQPReplyCode] = [
            .contentTooLarge,
            .noRoute,
            .noConsumers,
            .accessRefused,
            .notFound,
            .resourceLocked,
            .preconditionFailed
        ]

        for code in softCodes {
            #expect(code.isSoftError == true, "Expected \(code) to be soft error")
            #expect(code.isHardError == false, "Expected \(code) not to be hard error")
        }
    }

    @Test("Hard error codes are classified correctly")
    func hardErrorCodes() {
        let hardCodes: [AMQPReplyCode] = [
            .connectionForced,
            .invalidPath,
            .frameError,
            .syntaxError,
            .commandInvalid,
            .channelError,
            .unexpectedFrame,
            .resourceError,
            .notAllowed,
            .notImplemented,
            .internalError
        ]

        for code in hardCodes {
            #expect(code.isHardError == true, "Expected \(code) to be hard error")
            #expect(code.isSoftError == false, "Expected \(code) not to be soft error")
        }
    }

    @Test("Success code is neither soft nor hard error")
    func successCode() {
        let code = AMQPReplyCode.success
        #expect(code.isSoftError == false)
        #expect(code.isHardError == false)
    }

    @Test("Reply codes have recovery suggestions")
    func replyCodeRecoverySuggestions() {
        let codes: [AMQPReplyCode] = [
            .contentTooLarge,
            .noRoute,
            .notFound,
            .preconditionFailed,
            .connectionForced,
            .frameError,
            .resourceError
        ]

        for code in codes {
            let suggestion = code.recoverySuggestion(isChannel: true)
            #expect(suggestion != nil, "Expected \(code) to have recovery suggestion")
        }
    }

    @Test("Reply code raw values match AMQP spec")
    func replyCodeRawValues() {
        #expect(AMQPReplyCode.success.rawValue == 200)
        #expect(AMQPReplyCode.contentTooLarge.rawValue == 311)
        #expect(AMQPReplyCode.noRoute.rawValue == 312)
        #expect(AMQPReplyCode.noConsumers.rawValue == 313)
        #expect(AMQPReplyCode.connectionForced.rawValue == 320)
        #expect(AMQPReplyCode.invalidPath.rawValue == 402)
        #expect(AMQPReplyCode.accessRefused.rawValue == 403)
        #expect(AMQPReplyCode.notFound.rawValue == 404)
        #expect(AMQPReplyCode.resourceLocked.rawValue == 405)
        #expect(AMQPReplyCode.preconditionFailed.rawValue == 406)
        #expect(AMQPReplyCode.frameError.rawValue == 501)
        #expect(AMQPReplyCode.syntaxError.rawValue == 502)
        #expect(AMQPReplyCode.commandInvalid.rawValue == 503)
        #expect(AMQPReplyCode.channelError.rawValue == 504)
        #expect(AMQPReplyCode.unexpectedFrame.rawValue == 505)
        #expect(AMQPReplyCode.resourceError.rawValue == 506)
        #expect(AMQPReplyCode.notAllowed.rawValue == 530)
        #expect(AMQPReplyCode.notImplemented.rawValue == 540)
        #expect(AMQPReplyCode.internalError.rawValue == 541)
    }
}
