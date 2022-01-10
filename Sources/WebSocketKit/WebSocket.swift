import NIO
import NIOWebSocket
import NIOHTTP1
import NIOSSL
import Foundation
import NIOFoundationCompat
import Logging

public final class WebSocket {
    enum PeerType {
        case server
        case client
    }

    public enum WebSocketSendType {
        case text
        case binary
    }

    public var eventLoop: EventLoop {
        return channel.eventLoop
    }

    public var isClosed: Bool {
        !self.channel.isActive
    }
    public private(set) var closeCode: WebSocketErrorCode?

    public var onClose: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    public var jsonDecoder = JSONDecoder()
    public var jsonEncoder = JSONEncoder()

    private let channel: Channel
    private let logger: Logger
    private var onTextCallback: (WebSocket, String) -> ()
    private var onBinaryCallback: (WebSocket, ByteBuffer) -> ()
    private var onPongCallback: (WebSocket) -> ()
    private var onPingCallback: (WebSocket) -> ()
    private var frameSequence: WebSocketFrameSequence?
    private let type: PeerType
    private var waitingForPong: Bool
    private var waitingForClose: Bool
    private var scheduledTimeoutTask: Scheduled<Void>?
    private var events: [String : (WebSocket, Data) -> Void] = [:]

    init(channel: Channel, type: PeerType) {
        self.channel = channel
        self.type = type
        self.onTextCallback = { _, _ in }
        self.onBinaryCallback = { _, _ in }
        self.onPongCallback = { _ in }
        self.onPingCallback = { _ in }
        self.waitingForPong = false
        self.waitingForClose = false
        self.scheduledTimeoutTask = nil
        self.logger = Logger(label: "codes.vapor.websocket")
    }

    public func onText(_ callback: @escaping (WebSocket, String) -> ()) {
        self.onTextCallback = callback
    }

    public func onBinary(_ callback: @escaping (WebSocket, ByteBuffer) -> ()) {
        self.onBinaryCallback = callback
    }
    
    public func onPong(_ callback: @escaping (WebSocket) -> ()) {
        self.onPongCallback = callback
    }

    public func onPing(_ callback: @escaping (WebSocket) -> ()) {
        self.onPingCallback = callback
    }

    public func onEvent(_ identifier: String, _ handler: @escaping (WebSocket) -> Void) {
        events[identifier] = { ws, data in
            handler(ws)
        }
    }

    public func onEvent<T>(_ identifier: String, _ type: T.Type, _ handler: @escaping (WebSocket, T) -> Void) where T: Codable {
        onEvent(identifier, handler)
    }

    public func onEvent<T>(_ identifier: String, _ handler: @escaping (WebSocket, T) -> Void) where T: Codable {
        events[identifier] = { [weak self] ws, data in
            guard let self = self else { return }
            do {
                let res = try JSONDecoder().decode(WebSocketEvent<T>.self, from: data)
                if let data = res.data {
                    handler(ws, data)
                } else {
                    self.logger.warning("Unable to unwrap data for event `\(identifier)`, because it is unexpectedly nil. Please use another `bind` method which support optional payload to avoid this message.")
                }
            } catch {
                self.logger.error("Unable to decode incoming event `\(identifier)`: \(error)")
            }
        }
    }

    /// If set, this will trigger automatic pings on the connection. If ping is not answered before
    /// the next ping is sent, then the WebSocket will be presumed innactive and will be closed
    /// automatically.
    /// These pings can also be used to keep the WebSocket alive if there is some other timeout
    /// mechanism shutting down innactive connections, such as a Load Balancer deployed in
    /// front of the server.
    public var pingInterval: TimeAmount? {
        didSet {
            if pingInterval != nil {
                if scheduledTimeoutTask == nil {
                    waitingForPong = false
                    self.pingAndScheduleNextTimeoutTask()
                }
            } else {
                scheduledTimeoutTask?.cancel()
            }
        }
    }

    public func send<S>(_ text: S, promise: EventLoopPromise<Void>? = nil)
        where S: Collection, S.Element == Character
    {
        let string = String(text)
        var buffer = channel.allocator.buffer(capacity: text.count)
        buffer.writeString(string)
        self.send(raw: buffer.readableBytesView, opcode: .text, fin: true, promise: promise)

    }

    public func send(_ binary: [UInt8], promise: EventLoopPromise<Void>? = nil) {
        self.send(raw: binary, opcode: .binary, fin: true, promise: promise)
    }

    public func send<T>(_ data: T, type: WebSocketSendType = .text, promise: EventLoopPromise<Void>? = nil) where T: Codable {
        guard let data = try? jsonEncoder.encode(data), let dataString = String(data: data, encoding: .utf8) else {
            return
        }
        switch type {
        case .text:
            self.send(dataString, promise: promise)
        case .binary:
            self.send(String(dataString).utf8.map{ UInt8($0) }, promise: promise)
        }
    }

    public func sendPing(promise: EventLoopPromise<Void>? = nil) {
        self.send(
            raw: Data(),
            opcode: .ping,
            fin: true,
            promise: promise
        )
    }

    public func send<Data>(
        raw data: Data,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    )
        where Data: DataProtocol
    {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(
            fin: fin,
            opcode: opcode,
            maskKey: self.makeMaskKey(),
            data: buffer
        )
        self.channel.writeAndFlush(frame, promise: promise)
    }

    public func close(code: WebSocketErrorCode = .goingAway) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.close(code: code, promise: promise)
        return promise.futureResult
    }

    public func close(
        code: WebSocketErrorCode = .goingAway,
        promise: EventLoopPromise<Void>?
    ) {
        guard !self.isClosed else {
            promise?.succeed(())
            return
        }
        guard !self.waitingForClose else {
            promise?.succeed(())
            return
        }
        self.waitingForClose = true
        self.closeCode = code

        let codeAsInt = UInt16(webSocketErrorCode: code)
        let codeToSend: WebSocketErrorCode
        if codeAsInt == 1005 || codeAsInt == 1006 {
            /// Code 1005 and 1006 are used to report errors to the application, but must never be sent over
            /// the wire (per https://tools.ietf.org/html/rfc6455#section-7.4)
            codeToSend = .normalClosure
        } else {
            codeToSend = code
        }

        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)

        self.send(raw: buffer.readableBytesView, opcode: .connectionClose, fin: true, promise: promise)
    }

    func makeMaskKey() -> WebSocketMaskingKey? {
        switch type {
        case .client:
            var bytes: [UInt8] = []
            for _ in 0..<4 {
                bytes.append(.random(in: .min ..< .max))
            }
            return WebSocketMaskingKey(bytes)
        case .server:
            return nil
        }
    }

    func handle(incoming frame: WebSocketFrame) {
        switch frame.opcode {
        case .connectionClose:
            if self.waitingForClose {
                // peer confirmed close, time to close channel
                self.channel.close(mode: .all, promise: nil)
            } else {
                // peer asking for close, confirm and close output side channel
                let promise = self.eventLoop.makePromise(of: Void.self)
                var data = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    data.webSocketUnmask(maskingKey)
                }
                self.close(
                    code: data.readWebSocketErrorCode() ?? .unknown(1005),
                    promise: promise
                )
                promise.futureResult.whenComplete { _ in
                    self.channel.close(mode: .all, promise: nil)
                }
            }
        case .ping:
            if frame.fin {
                var frameData = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    frameData.webSocketUnmask(maskingKey)
                }
                self.send(
                    raw: frameData.readableBytesView,
                    opcode: .pong,
                    fin: true,
                    promise: nil
                )
            } else {
                self.close(code: .protocolError, promise: nil)
            }
        case .text, .binary, .pong:
            // create a new frame sequence or use existing
            var frameSequence: WebSocketFrameSequence
            if let existing = self.frameSequence {
                frameSequence = existing
            } else {
                frameSequence = WebSocketFrameSequence(type: frame.opcode)
            }
            // append this frame and update the sequence
            frameSequence.append(frame)
            self.frameSequence = frameSequence
        case .continuation:
            // we must have an existing sequence
            if var frameSequence = self.frameSequence {
                // append this frame and update
                frameSequence.append(frame)
                self.frameSequence = frameSequence
            } else {
                self.close(code: .protocolError, promise: nil)
            }
        default:
            // We ignore all other frames.
            break
        }

        // if this frame was final and we have a non-nil frame sequence,
        // output it to the websocket and clear storage
        if let frameSequence = self.frameSequence, frame.fin {
            switch frameSequence.type {
            case .binary:
                if !proceedEventData(self, frameSequence.binaryBuffer) {
                    self.onBinaryCallback(self, frameSequence.binaryBuffer)
                }
            case .text:
                if !proceedEventData(self, frameSequence.textBuffer) {
                    self.onTextCallback(self, frameSequence.textBuffer)
                }
            case .pong:
                self.waitingForPong = false
                self.onPongCallback(self)
            case .ping:
                self.onPingCallback(self)
            default: break
            }
            self.frameSequence = nil
        }
    }

    private func proceedEventData(_ socket: WebSocket, _ text: String) -> Bool {
        guard !events.isEmpty, let data = text.data(using: .utf8) else { return false }
        do {
            let prototype = try jsonDecoder.decode(WebSocketEventPrototype.self, from: data)
            if let bind = events.first(where: { $0.0 == prototype.event }) {
                bind.value(socket, data)
                return true
            }
        } catch {
            logger.trace("Unable to decode incoming event cause it doesn't conform to `WebSocketEventPrototype` model: \(error)")
        }
        return false
    }

    private func proceedEventData(_ socket: WebSocket, _ byteBuffer: ByteBuffer) -> Bool {
        guard !events.isEmpty, byteBuffer.readableBytes > 0 else { return false }
        do {
            var bytes: [UInt8] = byteBuffer.getBytes(at: byteBuffer.readerIndex, length: byteBuffer.readableBytes) ?? []
            let data = Data(bytes: &bytes, count: byteBuffer.readableBytes)

            let prototype = try jsonDecoder.decode(WebSocketEventPrototype.self, from: data)
            if let bind = events.first(where: { $0.0 == prototype.event }) {
                bind.value(socket, data)
                return true
            }
        } catch {
            logger.trace("Unable to decode incoming event cause it doesn't conform to `WebSocketEventPrototype` model: \(error)")
        }
        return false
    }

    private func pingAndScheduleNextTimeoutTask() {
        guard channel.isActive, let pingInterval = pingInterval else {
            return
        }

        if waitingForPong {
            // We never received a pong from our last ping, so the connection has timed out
            let promise = self.eventLoop.makePromise(of: Void.self)
            self.close(code: .unknown(1006), promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocket is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                self.channel.close(mode: .all, promise: nil)
            }
        } else {
            self.sendPing()
            self.waitingForPong = true
            self.scheduledTimeoutTask = self.eventLoop.scheduleTask(
                deadline: .now() + pingInterval,
                self.pingAndScheduleNextTimeoutTask
            )
        }
    }

    deinit {
        assert(self.isClosed, "WebSocket was not closed before deinit.")
    }
}

private struct WebSocketFrameSequence {
    var binaryBuffer: ByteBuffer
    var textBuffer: String
    var type: WebSocketOpcode

    init(type: WebSocketOpcode) {
        self.binaryBuffer = ByteBufferAllocator().buffer(capacity: 0)
        self.textBuffer = .init()
        self.type = type
    }

    mutating func append(_ frame: WebSocketFrame) {
        var data = frame.unmaskedData
        switch type {
        case .binary:
            self.binaryBuffer.writeBuffer(&data)
        case .text:
            if let string = data.readString(length: data.readableBytes) {
                self.textBuffer += string
            }
        default: break
        }
    }
}

private struct WebSocketEvent<T: Codable>: Codable {
    public let event: String
    public let data: T?
    public init (event: String, data: T? = nil) {
        self.event = event
        self.data = data
    }
}

private struct WebSocketEventPrototype: Codable {
    public var event: String
}
