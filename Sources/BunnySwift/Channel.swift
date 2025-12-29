// This source code is dual-licensed under the Apache License, version 2.0,
// and the MIT license.
//
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Copyright (c) 2025-2026 Michael S. Klishin

import Foundation
import NIO
@_exported import AMQPProtocol
@_exported import Transport

/// Type alias to disambiguate from Objective-C Method
public typealias AMQPMethod = AMQPProtocol.Method

public actor Channel {
    private weak var connection: Connection?
    private let channelID: UInt16
    private var isOpen = false
    private var confirmMode = false
    private var transactionMode = false

    // Pending RPC responses
    private var pendingResponses: [CheckedContinuation<AMQPMethod, Error>] = []
    private var pendingGetResponses: [CheckedContinuation<GetResponse?, Error>] = []

    // Message assembly
    private var incomingMessage: IncomingMessage?

    // Consumers
    private var consumers: [String: AsyncStream<Message>.Continuation] = [:]
    private var returnHandlers: [@Sendable (ReturnedMessage) -> Void] = []

    // Channel close event handlers
    private var closeHandlers: [@Sendable (ChannelCloseInfo) -> Void] = []

    // Publisher confirms
    private var nextPublishSeqNo: UInt64 = 1
    private var confirmHandlers: [UInt64: CheckedContinuation<Bool, Error>] = [:]
    private var publisherConfirmationTracking = false
    private var outstandingConfirmsLimit: Int = 0
    private var outstandingConfirmsCount: Int = 0
    private var confirmLimitWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Initialization

    internal init(connection: Connection, channelID: UInt16) {
        self.connection = connection
        self.channelID = channelID
    }

    internal func open() async throws {
        try await sendMethod(.channelOpen(ChannelOpen()))
        let response = try await waitForResponse()
        guard case .channelOpenOk = response else {
            throw ConnectionError.protocolError("Expected Channel.OpenOk, got \(response)")
        }
        isOpen = true
    }

    // MARK: - Exchange Operations

    public func exchange(
        _ name: String,
        type: ExchangeType,
        durable: Bool = false,
        autoDelete: Bool = false,
        internal: Bool = false,
        arguments: Table = [:]
    ) async throws -> Exchange {
        let declare = ExchangeDeclare(
            reserved1: 0,
            exchange: name,
            type: type.rawValue,
            passive: false,
            durable: durable,
            autoDelete: autoDelete,
            internal: `internal`,
            noWait: false,
            arguments: arguments
        )
        try await sendMethod(.exchangeDeclare(declare))
        let response = try await waitForResponse()
        guard case .exchangeDeclareOk = response else {
            throw ConnectionError.protocolError("Expected Exchange.DeclareOk, got \(response)")
        }
        return Exchange(channel: self, name: name, type: type)
    }

    public func direct(_ name: String, durable: Bool = false, autoDelete: Bool = false) async throws -> Exchange {
        try await exchange(name, type: .direct, durable: durable, autoDelete: autoDelete)
    }

    public func fanout(_ name: String, durable: Bool = false, autoDelete: Bool = false) async throws -> Exchange {
        try await exchange(name, type: .fanout, durable: durable, autoDelete: autoDelete)
    }

    public func topic(_ name: String, durable: Bool = false, autoDelete: Bool = false) async throws -> Exchange {
        try await exchange(name, type: .topic, durable: durable, autoDelete: autoDelete)
    }

    public func headers(_ name: String, durable: Bool = false, autoDelete: Bool = false) async throws -> Exchange {
        try await exchange(name, type: .headers, durable: durable, autoDelete: autoDelete)
    }

    public var defaultExchange: Exchange {
        Exchange(channel: self, name: "", type: .direct)
    }

    public func exchangeDelete(_ name: String, ifUnused: Bool = false) async throws {
        let delete = ExchangeDelete(
            reserved1: 0,
            exchange: name,
            ifUnused: ifUnused,
            noWait: false
        )
        try await sendMethod(.exchangeDelete(delete))
        let response = try await waitForResponse()
        guard case .exchangeDeleteOk = response else {
            throw ConnectionError.protocolError("Expected Exchange.DeleteOk, got \(response)")
        }
    }

    public func exchangeBind(
        destination: String,
        source: String,
        routingKey: String = "",
        arguments: Table = [:]
    ) async throws {
        let bind = ExchangeBind(
            reserved1: 0,
            destination: destination,
            source: source,
            routingKey: routingKey,
            noWait: false,
            arguments: arguments
        )
        try await sendMethod(.exchangeBind(bind))
        let response = try await waitForResponse()
        guard case .exchangeBindOk = response else {
            throw ConnectionError.protocolError("Expected Exchange.BindOk, got \(response)")
        }
    }

    public func exchangeUnbind(
        destination: String,
        source: String,
        routingKey: String = "",
        arguments: Table = [:]
    ) async throws {
        let unbind = ExchangeUnbind(
            reserved1: 0,
            destination: destination,
            source: source,
            routingKey: routingKey,
            noWait: false,
            arguments: arguments
        )
        try await sendMethod(.exchangeUnbind(unbind))
        let response = try await waitForResponse()
        guard case .exchangeUnbindOk = response else {
            throw ConnectionError.protocolError("Expected Exchange.UnbindOk, got \(response)")
        }
    }

    // MARK: - Queue Operations

    public func queue(
        _ name: String = "",
        type: QueueType? = nil,
        durable: Bool = false,
        exclusive: Bool = false,
        autoDelete: Bool = false,
        arguments: Table = [:]
    ) async throws -> Queue {
        var args = arguments
        if let queueType = type {
            args[XArguments.queueType] = queueType.asTableValue
        }
        let declare = QueueDeclare(
            reserved1: 0,
            queue: name,
            passive: false,
            durable: durable,
            exclusive: exclusive,
            autoDelete: autoDelete,
            noWait: false,
            arguments: args
        )
        try await sendMethod(.queueDeclare(declare))
        let response = try await waitForResponse()
        guard case .queueDeclareOk(let ok) = response else {
            throw ConnectionError.protocolError("Expected Queue.DeclareOk, got \(response)")
        }
        return Queue(channel: self, name: ok.queue, messageCount: ok.messageCount, consumerCount: ok.consumerCount)
    }

    public func queueDelete(
        _ name: String,
        ifUnused: Bool = false,
        ifEmpty: Bool = false
    ) async throws -> UInt32 {
        let delete = QueueDelete(
            reserved1: 0,
            queue: name,
            ifUnused: ifUnused,
            ifEmpty: ifEmpty,
            noWait: false
        )
        try await sendMethod(.queueDelete(delete))
        let response = try await waitForResponse()
        guard case .queueDeleteOk(let ok) = response else {
            throw ConnectionError.protocolError("Expected Queue.DeleteOk, got \(response)")
        }
        return ok.messageCount
    }

    public func queuePurge(_ name: String) async throws -> UInt32 {
        let purge = QueuePurge(reserved1: 0, queue: name, noWait: false)
        try await sendMethod(.queuePurge(purge))
        let response = try await waitForResponse()
        guard case .queuePurgeOk(let ok) = response else {
            throw ConnectionError.protocolError("Expected Queue.PurgeOk, got \(response)")
        }
        return ok.messageCount
    }

    public func queueBind(
        queue: String,
        exchange: String,
        routingKey: String = "",
        arguments: Table = [:]
    ) async throws {
        let bind = QueueBind(
            reserved1: 0,
            queue: queue,
            exchange: exchange,
            routingKey: routingKey,
            noWait: false,
            arguments: arguments
        )
        try await sendMethod(.queueBind(bind))
        let response = try await waitForResponse()
        guard case .queueBindOk = response else {
            throw ConnectionError.protocolError("Expected Queue.BindOk, got \(response)")
        }
    }

    public func queueUnbind(
        queue: String,
        exchange: String,
        routingKey: String = "",
        arguments: Table = [:]
    ) async throws {
        let unbind = QueueUnbind(
            reserved1: 0,
            queue: queue,
            exchange: exchange,
            routingKey: routingKey,
            arguments: arguments
        )
        try await sendMethod(.queueUnbind(unbind))
        let response = try await waitForResponse()
        guard case .queueUnbindOk = response else {
            throw ConnectionError.protocolError("Expected Queue.UnbindOk, got \(response)")
        }
    }

    // MARK: - Publishing

    /// Immediate flush for low-latency single messages.
    ///
    /// When publisher confirmation tracking is enabled, this method waits for broker
    /// confirmation before returning. If the broker nacks the message, throws an error.
    public func basicPublish(
        body: Data,
        exchange: String = "",
        routingKey: String,
        mandatory: Bool = false,
        immediate: Bool = false,
        properties: BasicProperties = .persistent
    ) async throws {
        guard isOpen, let connection = connection else {
            throw ConnectionError.notConnected
        }

        // Wait for a slot if we're at the limit
        if publisherConfirmationTracking {
            await waitForConfirmSlot()
        }

        let seqNo = confirmMode ? nextPublishSeqNo : 0

        let frames = buildPublishFrames(
            body: body,
            exchange: exchange,
            routingKey: routingKey,
            mandatory: mandatory,
            immediate: immediate,
            properties: properties,
            frameMax: await connection.frameMax
        )

        try await connection.writeBatch(frames)
        await connection.flush()

        if confirmMode {
            nextPublishSeqNo += 1
            if publisherConfirmationTracking {
                try await awaitConfirmation(seqNo: seqNo)
            }
        }
    }

    /// Buffers writes for high throughput; call flush after batch.
    ///
    /// When publisher confirmation tracking is enabled, this method waits for broker
    /// confirmation before returning. If the broker nacks the message, throws an error.
    public func publish(
        body: Data,
        exchange: String = "",
        routingKey: String,
        mandatory: Bool = false,
        properties: BasicProperties = .persistent
    ) async throws {
        guard isOpen, let connection = connection else {
            throw ConnectionError.notConnected
        }

        // Wait for a slot if we're at the limit
        if publisherConfirmationTracking {
            await waitForConfirmSlot()
        }

        let seqNo = confirmMode ? nextPublishSeqNo : 0

        let frames = buildPublishFrames(
            body: body,
            exchange: exchange,
            routingKey: routingKey,
            mandatory: mandatory,
            immediate: false,
            properties: properties,
            frameMax: await connection.frameMax
        )

        try await connection.writeBatch(frames)

        if confirmMode {
            nextPublishSeqNo += 1
            if publisherConfirmationTracking {
                await connection.flush()
                try await awaitConfirmation(seqNo: seqNo)
            }
        }
    }

    private func waitForConfirmSlot() async {
        guard outstandingConfirmsLimit > 0 else { return }
        while outstandingConfirmsCount >= outstandingConfirmsLimit {
            await withCheckedContinuation { cont in
                confirmLimitWaiters.append(cont)
            }
        }
        outstandingConfirmsCount += 1
    }

    private func awaitConfirmation(seqNo: UInt64) async throws {
        let confirmed = try await withCheckedThrowingContinuation { cont in
            confirmHandlers[seqNo] = cont
        }
        if !confirmed {
            throw ConnectionError.publisherNack(seqNo: seqNo)
        }
    }

    public func flush() async {
        await connection?.flush()
    }

    private func buildPublishFrames(
        body: Data,
        exchange: String,
        routingKey: String,
        mandatory: Bool,
        immediate: Bool,
        properties: BasicProperties,
        frameMax: UInt32
    ) -> [Frame] {
        let maxBodySize = Int(frameMax) - 8
        let bodyFrameCount = body.isEmpty ? 1 : (body.count + maxBodySize - 1) / maxBodySize
        var frames: [Frame] = []
        frames.reserveCapacity(2 + bodyFrameCount)

        let publish = BasicPublish(
            reserved1: 0,
            exchange: exchange,
            routingKey: routingKey,
            mandatory: mandatory,
            immediate: immediate
        )
        frames.append(.method(channelID: channelID, method: .basicPublish(publish)))

        frames.append(.header(
            channelID: channelID,
            classID: ClassID.basic.rawValue,
            bodySize: UInt64(body.count),
            properties: properties
        ))

        if body.count <= maxBodySize {
            // Fast path: body fits in single frame, no copy needed
            frames.append(.body(channelID: channelID, payload: body))
        } else {
            // Chunked: split into multiple frames
            var offset = 0
            while offset < body.count {
                let end = min(offset + maxBodySize, body.count)
                frames.append(.body(channelID: channelID, payload: body[offset..<end]))
                offset = end
            }
        }

        return frames
    }

    // MARK: - Consuming

    public func basicConsume(
        queue: String,
        consumerTag: String = "",
        acknowledgementMode: ConsumerAcknowledgementMode = .manual,
        exclusive: Bool = false,
        arguments: Table = [:]
    ) async throws -> MessageStream {
        let consume = BasicConsume(
            reserved1: 0,
            queue: queue,
            consumerTag: consumerTag,
            noLocal: false,
            noAck: acknowledgementMode.noAckFieldValue,
            exclusive: exclusive,
            noWait: false,
            arguments: arguments
        )
        try await sendMethod(.basicConsume(consume))
        let response = try await waitForResponse()
        guard case .basicConsumeOk(let ok) = response else {
            throw ConnectionError.protocolError("Expected Basic.ConsumeOk, got \(response)")
        }

        let (stream, continuation) = AsyncStream<Message>.makeStream()
        consumers[ok.consumerTag] = continuation
        return MessageStream(channel: self, consumerTag: ok.consumerTag, stream: stream)
    }

    public func basicCancel(_ consumerTag: String) async throws {
        let cancel = BasicCancel(consumerTag: consumerTag, noWait: false)
        try await sendMethod(.basicCancel(cancel))
        let response = try await waitForResponse()
        guard case .basicCancelOk = response else {
            throw ConnectionError.protocolError("Expected Basic.CancelOk, got \(response)")
        }
        removeConsumer(consumerTag)
    }

    /// Synchronously fetch a single message from a queue (pull API).
    ///
    /// - Warning: This method is inefficient and strongly discouraged for production use.
    ///   It requires a network round-trip per message, resulting in very low throughput.
    ///   Use ``basicConsume(queue:consumerTag:acknowledgementMode:exclusive:arguments:)`` instead for
    ///   efficient push-based message delivery.
    ///
    /// This method is suitable only for tests, debugging, or administrative tools
    /// where occasional single-message retrieval is acceptable.
    ///
    /// - Parameters:
    ///   - queue: The queue name to fetch from
    ///   - acknowledgementMode: Whether messages require manual acknowledgement (default) or are auto-acknowledged.
    /// - Returns: A ``GetResponse`` if a message was available, or `nil` if the queue was empty.
    @_documentation(visibility: private)
    public func basicGet(queue: String, acknowledgementMode: ConsumerAcknowledgementMode = .manual) async throws -> GetResponse? {
        let get = BasicGet(reserved1: 0, queue: queue, noAck: acknowledgementMode.noAckFieldValue)
        try await sendMethod(.basicGet(get))

        return try await withCheckedThrowingContinuation { cont in
            pendingGetResponses.append(cont)
        }
    }

    // MARK: - Acknowledgements

    public func basicAck(deliveryTag: UInt64, multiple: Bool = false) async throws {
        let ack = BasicAck(deliveryTag: deliveryTag, multiple: multiple)
        try await sendMethod(.basicAck(ack))
    }

    public func basicNack(deliveryTag: UInt64, multiple: Bool = false, requeue: Bool = true) async throws {
        let nack = BasicNack(deliveryTag: deliveryTag, multiple: multiple, requeue: requeue)
        try await sendMethod(.basicNack(nack))
    }

    public func basicReject(deliveryTag: UInt64, requeue: Bool = true) async throws {
        let reject = BasicReject(deliveryTag: deliveryTag, requeue: requeue)
        try await sendMethod(.basicReject(reject))
    }

    // MARK: - QoS

    public func basicQos(prefetchSize: UInt32 = 0, prefetchCount: UInt16 = 0, global: Bool = false) async throws {
        let qos = BasicQos(prefetchSize: prefetchSize, prefetchCount: prefetchCount, global: global)
        try await sendMethod(.basicQos(qos))
        let response = try await waitForResponse()
        guard case .basicQosOk = response else {
            throw ConnectionError.protocolError("Expected Basic.QosOk, got \(response)")
        }
    }

    // MARK: - Publisher Confirms

    /// Enable publisher confirms mode.
    ///
    /// - Parameter tracking: If `true`, publish methods will automatically wait for broker
    ///   confirmation before returning. Defaults to `false`.
    /// - Parameter outstandingLimit: Maximum number of unconfirmed messages before publish
    ///   methods block. Only applies when `tracking` is `true`. Use `0` for unlimited.
    public func confirmSelect(tracking: Bool = false, outstandingLimit: Int = 0) async throws {
        let select = ConfirmSelect(noWait: false)
        try await sendMethod(.confirmSelect(select))
        let response = try await waitForResponse()
        guard case .confirmSelectOk = response else {
            throw ConnectionError.protocolError("Expected Confirm.SelectOk, got \(response)")
        }
        confirmMode = true
        publisherConfirmationTracking = tracking
        outstandingConfirmsLimit = outstandingLimit
        nextPublishSeqNo = 1
    }

    /// Whether publisher confirmation tracking is enabled.
    public var isPublisherConfirmationTrackingEnabled: Bool {
        publisherConfirmationTracking
    }

    public var publishSeqNo: UInt64 {
        nextPublishSeqNo
    }

    /// Wait for all outstanding publisher confirmations to complete.
    public func waitForConfirms() async throws {
        guard confirmMode else { return }
        while !confirmHandlers.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - Transactions

    public func txSelect() async throws {
        try await sendMethod(.txSelect)
        let response = try await waitForResponse()
        guard case .txSelectOk = response else {
            throw ConnectionError.protocolError("Expected Tx.SelectOk, got \(response)")
        }
        transactionMode = true
    }

    public func txCommit() async throws {
        try await sendMethod(.txCommit)
        let response = try await waitForResponse()
        guard case .txCommitOk = response else {
            throw ConnectionError.protocolError("Expected Tx.CommitOk, got \(response)")
        }
    }

    public func txRollback() async throws {
        try await sendMethod(.txRollback)
        let response = try await waitForResponse()
        guard case .txRollbackOk = response else {
            throw ConnectionError.protocolError("Expected Tx.RollbackOk, got \(response)")
        }
    }

    // MARK: - Returns

    public func onReturn(_ handler: @escaping @Sendable (ReturnedMessage) -> Void) {
        returnHandlers.append(handler)
    }

    // MARK: - Channel Close Events

    /// Register a handler for channel close events (server or client initiated)
    public func onClose(_ handler: @escaping @Sendable (ChannelCloseInfo) -> Void) {
        closeHandlers.append(handler)
    }

    // MARK: - Frame Handling

    internal func handleFrame(_ frame: Frame) async {
        switch frame {
        case .method(channelID: _, method: let method):
            await handleMethod(method)
        case .header(channelID: _, classID: _, bodySize: let bodySize, properties: let properties):
            if var msg = incomingMessage {
                msg.properties = properties
                msg.bodySize = bodySize
                incomingMessage = msg
            }
        case .body(channelID: _, payload: let chunk):
            if var msg = incomingMessage {
                msg.appendBody(chunk)
                if UInt64(msg.receivedBytes) >= msg.bodySize {
                    await deliverMessage(msg)
                    incomingMessage = nil
                } else {
                    incomingMessage = msg
                }
            }
        case .heartbeat:
            break
        }
    }

    private func handleMethod(_ method: AMQPMethod) async {
        switch method {
        case .channelOpenOk, .channelCloseOk, .channelFlowOk,
             .exchangeDeclareOk, .exchangeDeleteOk, .exchangeBindOk, .exchangeUnbindOk,
             .queueDeclareOk, .queueDeleteOk, .queuePurgeOk, .queueBindOk, .queueUnbindOk,
             .basicQosOk, .basicConsumeOk, .basicCancelOk, .basicRecoverOk,
             .txSelectOk, .txCommitOk, .txRollbackOk,
             .confirmSelectOk:
            if let cont = pendingResponses.first {
                pendingResponses.removeFirst()
                cont.resume(returning: method)
            }

        case .channelClose(let close):
            isOpen = false
            try? await sendMethod(.channelCloseOk)
            let error = ConnectionError.channelClosed(
                replyCode: close.replyCode,
                replyText: close.replyText,
                classID: close.classId,
                methodID: close.methodId
            )
            // Notify close handlers
            let closeInfo = ChannelCloseInfo(
                replyCode: close.replyCode,
                replyText: close.replyText,
                classID: close.classId,
                methodID: close.methodId,
                initiatedByServer: true
            )
            for handler in closeHandlers {
                handler(closeInfo)
            }
            for cont in pendingResponses {
                cont.resume(throwing: error)
            }
            pendingResponses.removeAll()
            for cont in pendingGetResponses {
                cont.resume(throwing: error)
            }
            pendingGetResponses.removeAll()
            await connection?.channelClosed(channelID)

        case .basicDeliver(let deliver):
            incomingMessage = IncomingMessage(
                properties: BasicProperties(),
                bodySize: 0,
                deliveryInfo: DeliveryInfo(
                    consumerTag: deliver.consumerTag,
                    deliveryTag: deliver.deliveryTag,
                    redelivered: deliver.redelivered,
                    exchange: deliver.exchange,
                    routingKey: deliver.routingKey
                )
            )

        case .basicGetOk(let ok):
            incomingMessage = IncomingMessage(
                properties: BasicProperties(),
                bodySize: 0,
                getInfo: GetInfo(
                    deliveryTag: ok.deliveryTag,
                    redelivered: ok.redelivered,
                    exchange: ok.exchange,
                    routingKey: ok.routingKey,
                    messageCount: ok.messageCount
                )
            )

        case .basicGetEmpty:
            if let cont = pendingGetResponses.first {
                pendingGetResponses.removeFirst()
                cont.resume(returning: nil)
            }

        case .basicReturn(let ret):
            incomingMessage = IncomingMessage(
                properties: BasicProperties(),
                bodySize: 0,
                returnInfo: ReturnInfo(
                    replyCode: ret.replyCode,
                    replyText: ret.replyText,
                    exchange: ret.exchange,
                    routingKey: ret.routingKey
                )
            )

        case .basicAck(let ack):
            handleConfirm(deliveryTag: ack.deliveryTag, multiple: ack.multiple, ack: true)

        case .basicNack(let nack):
            handleConfirm(deliveryTag: nack.deliveryTag, multiple: nack.multiple, ack: false)

        case .basicCancel(let cancel):
            removeConsumer(cancel.consumerTag)
            let cancelOk = BasicCancelOk(consumerTag: cancel.consumerTag)
            try? await sendMethod(.basicCancelOk(cancelOk))

        default:
            break
        }
    }

    private func deliverMessage(_ incoming: IncomingMessage) async {
        let body = incoming.assembleBody()
        if let deliveryInfo = incoming.deliveryInfo {
            let message = Message(
                body: body,
                properties: incoming.properties,
                deliveryInfo: deliveryInfo,
                channel: self
            )
            consumers[deliveryInfo.consumerTag]?.yield(message)
        } else if let getInfo = incoming.getInfo {
            let response = GetResponse(
                body: body,
                properties: incoming.properties,
                deliveryTag: getInfo.deliveryTag,
                redelivered: getInfo.redelivered,
                exchange: getInfo.exchange,
                routingKey: getInfo.routingKey,
                messageCount: getInfo.messageCount,
                channel: self
            )
            if let cont = pendingGetResponses.first {
                pendingGetResponses.removeFirst()
                cont.resume(returning: response)
            }
        } else if let returnInfo = incoming.returnInfo {
            let returned = ReturnedMessage(
                body: body,
                properties: incoming.properties,
                replyCode: returnInfo.replyCode,
                replyText: returnInfo.replyText,
                exchange: returnInfo.exchange,
                routingKey: returnInfo.routingKey
            )
            for handler in returnHandlers {
                handler(returned)
            }
        }
    }

    private func handleConfirm(deliveryTag: UInt64, multiple: Bool, ack: Bool) {
        var confirmedCount = 0
        if multiple {
            var toResume: [(UInt64, CheckedContinuation<Bool, Error>)] = []
            for (tag, cont) in confirmHandlers where tag <= deliveryTag {
                toResume.append((tag, cont))
            }
            for (tag, cont) in toResume {
                confirmHandlers.removeValue(forKey: tag)
                cont.resume(returning: ack)
                confirmedCount += 1
            }
        } else if let cont = confirmHandlers.removeValue(forKey: deliveryTag) {
            cont.resume(returning: ack)
            confirmedCount += 1
        }

        // Release waiters if we freed up slots
        if publisherConfirmationTracking && outstandingConfirmsLimit > 0 {
            outstandingConfirmsCount -= confirmedCount
            while !confirmLimitWaiters.isEmpty && outstandingConfirmsCount < outstandingConfirmsLimit {
                let waiter = confirmLimitWaiters.removeFirst()
                waiter.resume()
            }
        }
    }

    // MARK: - Private Helpers

    private func removeConsumer(_ tag: String) {
        consumers[tag]?.finish()
        consumers.removeValue(forKey: tag)
    }

    private func sendMethod(_ method: AMQPMethod) async throws {
        guard let connection = connection else {
            throw ConnectionError.notConnected
        }
        try await connection.send(.method(channelID: channelID, method: method))
    }

    private func waitForResponse() async throws -> AMQPMethod {
        try await withCheckedThrowingContinuation { cont in
            pendingResponses.append(cont)
        }
    }

    // MARK: - Close

    public func close() async throws {
        guard isOpen else { return }
        isOpen = false

        for continuation in consumers.values {
            continuation.finish()
        }
        consumers.removeAll()

        let close = ChannelClose(replyCode: 200, replyText: "Normal shutdown", classId: 0, methodId: 0)
        try await sendMethod(.channelClose(close))
        _ = try? await waitForResponse()

        await connection?.channelClosed(channelID)
    }

    // MARK: - Properties

    public var open: Bool { isOpen }
    public var number: UInt16 { channelID }
}

// MARK: - Supporting Types

public enum ExchangeType: String, Sendable {
    case direct
    case fanout
    case topic
    case headers
}

private struct IncomingMessage {
    var properties: BasicProperties
    var bodySize: UInt64
    var bodyChunks: [Data] = []
    var receivedBytes: Int = 0
    var deliveryInfo: DeliveryInfo?
    var getInfo: GetInfo?
    var returnInfo: ReturnInfo?

    mutating func appendBody(_ chunk: Data) {
        bodyChunks.append(chunk)
        receivedBytes += chunk.count
    }

    func assembleBody() -> Data {
        guard bodyChunks.count > 1 else {
            return bodyChunks.first ?? Data()
        }
        var result = Data(capacity: receivedBytes)
        for chunk in bodyChunks {
            result.append(chunk)
        }
        return result
    }
}

public struct DeliveryInfo: Sendable {
    public let consumerTag: String
    public let deliveryTag: UInt64
    public let redelivered: Bool
    public let exchange: String
    public let routingKey: String
}

private struct GetInfo {
    let deliveryTag: UInt64
    let redelivered: Bool
    let exchange: String
    let routingKey: String
    let messageCount: UInt32
}

private struct ReturnInfo {
    let replyCode: UInt16
    let replyText: String
    let exchange: String
    let routingKey: String
}

public struct ChannelCloseInfo: Sendable {
    public let replyCode: UInt16
    public let replyText: String
    public let classID: UInt16
    public let methodID: UInt16
    public let initiatedByServer: Bool

    public var isSoftError: Bool {
        AMQPReplyCode(rawValue: replyCode)?.isSoftError ?? false
    }

    public var amqpReplyCode: AMQPReplyCode? {
        AMQPReplyCode(rawValue: replyCode)
    }
}
