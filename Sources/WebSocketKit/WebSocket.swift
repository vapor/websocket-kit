import NIO
import NIOWebSocket
import NIOHTTP1
import NIOSSL
import Foundation
import NIOFoundationCompat

public final class WebSocket {
    enum PeerType {
        case server
        case client
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

    private let channel: Channel
    private var onTextCallback: (WebSocket, String) -> ()
    private var onBinaryCallback: (WebSocket, ByteBuffer) -> ()
    private var onPongCallback: (WebSocket) -> ()
    private var onPingCallback: (WebSocket) -> ()
    private var frameSequence: WebSocketFrameSequence?
    private let type: PeerType
    private var waitingForPong: Bool
    private var waitingForClose: Bool
    private var scheduledTimeoutTask: Scheduled<Void>?

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
                self.channel.close(mode: .output, promise: nil)
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
                    self.channel.close(mode: .output, promise: nil)
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
                self.onBinaryCallback(self, frameSequence.binaryBuffer)
            case .text:
                self.onTextCallback(self, frameSequence.textBuffer)
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
